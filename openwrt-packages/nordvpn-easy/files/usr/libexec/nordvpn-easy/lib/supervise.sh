#!/bin/sh

# Supervisor phase runner (S7). nordvpn_easy_run_phase is DEFINED here but has NO
# callers yet: the supervised state machine that drives it lands in a later
# increment (it stays dead code, gated behind orchestrator=supervisor, until then).
#
# run_phase records a journal phase boundary (preserving the transaction identity),
# runs the phase body under a best-effort watchdog, and retries only
# network-classified failures with a capped backoff. The watchdog bounds an
# INTERRUPTIBLE overrun; it cannot kill a D-state syscall -- the TTL reaper (in the
# lock acquire path) is the authoritative bound for a wedged worker. A body forked
# behind the subshell may briefly outlive a kill; that is acceptable best-effort.

# Classify a phase failure from the journal's last_error. A 'network.*' error is
# transient (retry); local/config/unknown fail fast (a bad token or invalid config
# will not fix itself by retrying, and blind retries just churn).
nordvpn_easy_phase_error_retryable() {
	case "${1:-}" in
		network|network.*) return 0 ;;
		*) return 1 ;;
	esac
}

# Capped backoff (seconds) for attempt N. Base is overridable so tests do not sleep.
nordvpn_easy_phase_backoff_seconds() {
	local attempt="${1:-1}"
	local base cap val
	base="${NORDVPN_EASY_PHASE_BACKOFF_BASE:-2}"
	cap="${NORDVPN_EASY_PHASE_BACKOFF_CAP:-30}"
	case "$attempt" in ''|*[!0-9]*) attempt=1 ;; esac
	case "$base" in ''|*[!0-9]*) base=2 ;; esac
	case "$cap" in ''|*[!0-9]*) cap=30 ;; esac
	val=$((base * attempt))
	[ "$val" -gt "$cap" ] && val="$cap"
	printf '%s' "$val"
}

# run_phase NAME TIMEOUT RETRIES FN
#   NAME     journal phase name written before the body runs
#   TIMEOUT  seconds the watchdog allows the body before it is killed
#   RETRIES  max attempts (>=1); only network-classified failures are retried
#   FN       the phase body (a function name); rc 0 = success
# Returns 0 on success, else the last attempt's rc.
nordvpn_easy_run_phase() {
	local name="$1"
	local timeout="$2"
	local retries="$3"
	local fn="$4"
	local attempt=1 rc now deadline last_error fpid wpid backoff

	case "$timeout" in ''|*[!0-9]*) timeout=60 ;; esac
	case "$retries" in ''|*[!0-9]*) retries=1 ;; esac
	[ "$retries" -ge 1 ] || retries=1

	while :; do
		now="$(date +%s 2>/dev/null || printf '0')"
		case "$now" in ''|*[!0-9]*) now=0 ;; esac
		deadline=$((now + timeout))

		# Journal boundary BEFORE the body, so a concurrent status/reaper sees the
		# phase and its deadline. OWNER-FENCED identity-preserving merge: a reaped
		# worker's boundary refuses (owner_assert fails) so it cannot advance the new
		# owner's journal; a legit or tokenless owner merges (keeps the txn identity).
		# Fall back to the unfenced merge where common.sh is not sourced (unit tests).
		if command -v nordvpn_easy_fenced_journal_merge >/dev/null 2>&1; then
			nordvpn_easy_fenced_journal_merge \
				"phase=$name" \
				"phase_attempt=$attempt" \
				"phase_deadline=$deadline" >/dev/null 2>&1 || true
		elif command -v nordvpn_easy_journal_set >/dev/null 2>&1; then
			nordvpn_easy_journal_set \
				"phase=$name" \
				"phase_attempt=$attempt" \
				"phase_deadline=$deadline" >/dev/null 2>&1 || true
		fi

		# Run the body in the background and cap it with a POLLING watchdog: it wakes
		# every second and exits the instant the body is gone, so it never blocks the
		# cleanup for the full timeout (a plain `sleep $timeout` watchdog would, if the
		# post-body kill raced and missed it). It kills the body only on a real
		# overrun. Best-effort: it cannot kill a D-state syscall (the TTL reaper is the
		# authoritative bound). wait's non-zero is handled under `set -e` (|| rc=$?).
		rc=0
		"$fn" & fpid=$!
		(
			wd_n=0
			while [ "$wd_n" -lt "$timeout" ] && kill -0 "$fpid" 2>/dev/null; do
				sleep 1
				wd_n=$((wd_n + 1))
			done
			kill -0 "$fpid" 2>/dev/null && kill "$fpid" 2>/dev/null
		) & wpid=$!
		wait "$fpid" 2>/dev/null || rc=$?
		kill "$wpid" 2>/dev/null || true
		wait "$wpid" 2>/dev/null || true

		[ "$rc" -eq 0 ] && return 0

		last_error="$(nordvpn_easy_journal_get last_error 2>/dev/null || printf '')"
		if nordvpn_easy_phase_error_retryable "$last_error" && [ "$attempt" -lt "$retries" ]; then
			backoff="$(nordvpn_easy_phase_backoff_seconds "$attempt")"
			case "$backoff" in ''|*[!0-9]*) backoff=0 ;; esac
			[ "$backoff" -gt 0 ] && sleep "$backoff"
			attempt=$((attempt + 1))
			continue
		fi
		return "$rc"
	done
}
# ============================================================================
# S7 supervised apply state machine (increment 5c). ONE process, flag-gated
# behind orchestrator=supervisor. INERT: only reachable when a caller invokes
# nordvpn_easy_supervise, whose first statement re-gates on the flag. Nothing
# in inc 5c routes here except an explicit `core.sh supervise` under the flag.
# All phase bodies run under nordvpn_easy_run_phase (supervise.sh above).
# ============================================================================

# A journal record is TERMINAL (not in flight) when its phase is done/failed, or
# when there is no record at all.
nordvpn_easy_supervise_phase_is_terminal() {
	case "${1:-}" in
		done|failed|'') return 0 ;;
		*) return 1 ;;
	esac
}

nordvpn_easy_supervise_pid_alive() {
	local pid="${1:-}"
	case "$pid" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$pid" -gt 0 ] || return 1
	kill -0 "$pid" 2>/dev/null
}

# Persist a CLASSIFIED cause (network.* | local.* | config.*) into the journal
# last_error. run_phase reads it back from disk (the body runs in a background
# subshell; the journal is file-backed so it survives) to decide retry --
# network.* is retryable, local/config fail fast -- and the terminal handler
# surfaces it. Owner-fenced merge so a reaped worker cannot stamp the new owner.
nordvpn_easy_supervise_record_error() {
	local class="$1" detail="${2:-}"
	nordvpn_easy_log_blocker 'supervise' "${class}: ${detail}"
	if command -v nordvpn_easy_fenced_journal_merge >/dev/null 2>&1; then
		nordvpn_easy_fenced_journal_merge "last_error=$class" >/dev/null 2>&1 || true
	elif command -v nordvpn_easy_journal_set >/dev/null 2>&1; then
		nordvpn_easy_journal_set "last_error=$class" >/dev/null 2>&1 || true
	fi
	# S8: also write the human message to the runtime last-error CACHE (which status_json
	# emits as last_error and the LuCI Save&Apply surfaces), so a supervised failure shows
	# the actual reason -- the journal only carries the classification token, and the JS
	# reads the cache, not the journal, for last_error. The apply verb cleared this cache
	# synchronously before the fork, so it reflects only THIS apply.
	if command -v nordvpn_easy_record_last_error >/dev/null 2>&1; then
		nordvpn_easy_record_last_error "supervise: ${detail:-$class}" >/dev/null 2>&1 || true
	fi
}

# Stamp FAILED a FOREIGN (target-mismatch) non-terminal record whose owner is
# dead, so a same-target record can still be adopted by open_txn and a foreign
# crashed txn is not silently overwritten (observability). A SAME-target record
# is left untouched (open_txn adopts it); a LIVE foreign owner is left to the
# TTL reaper / owner fence. Runs BEFORE open_txn so the foreign record is stamped
# before open_txn's fresh full-write would replace it.
nordvpn_easy_supervise_reap_stale_journal() {
	local target="${1:-}"
	local existing_phase existing_target owner_pid txn_id origin started_at now
	existing_phase="$(nordvpn_easy_journal_get phase 2>/dev/null || printf '')"
	if nordvpn_easy_supervise_phase_is_terminal "$existing_phase"; then
		return 0
	fi
	existing_target="$(nordvpn_easy_journal_get target_fingerprint 2>/dev/null || printf '')"
	if [ "$existing_target" = "$target" ]; then
		return 0
	fi
	owner_pid="$(nordvpn_easy_journal_get owner_pid 2>/dev/null || printf '')"
	if nordvpn_easy_supervise_pid_alive "$owner_pid"; then
		return 0
	fi
	txn_id="$(nordvpn_easy_journal_get txn_id 2>/dev/null || printf '')"
	origin="$(nordvpn_easy_journal_get origin 2>/dev/null || printf '')"
	started_at="$(nordvpn_easy_journal_get started_at 2>/dev/null || printf '')"
	now="$(date +%s 2>/dev/null || printf '0')"
	[ -n "$started_at" ] || started_at="$now"
	nordvpn_easy_log_phase 'supervise' "reaping stale foreign apply record (txn=${txn_id:-unknown}, dead owner_pid=${owner_pid:-unknown})"
	nordvpn_easy_fenced_journal_set \
		'phase=failed' \
		"txn_id=$txn_id" \
		"target_fingerprint=$existing_target" \
		"origin=${origin:-apply}" \
		"owner_pid=$owner_pid" \
		"started_at=$started_at" \
		"finished_at=$now" \
		'rc=1' \
		'last_error=local.reaped_stale' \
		'country=' >/dev/null 2>&1 || true
}

# Open the apply transaction. ADOPT a SAME-target non-terminal record (keep its
# txn_id + started_at so a re-entry does not fork the transaction), but CLEAR
# fetch_done -- a crashed predecessor may have stamped fetch_done=1 without a
# surviving in-process PRIVATE_KEY, so this run must re-fetch. Otherwise open a
# FRESH transaction via the owner-fenced full write (new txn_id). Both writes go
# through fenced_journal_set so a superseded owner refuses.
nordvpn_easy_supervise_open_txn() {
	local target="${1:-}"
	local existing_phase existing_target existing_txn started_at now
	now="$(date +%s 2>/dev/null || printf '0')"
	existing_phase="$(nordvpn_easy_journal_get phase 2>/dev/null || printf '')"
	existing_target="$(nordvpn_easy_journal_get target_fingerprint 2>/dev/null || printf '')"
	existing_txn="$(nordvpn_easy_journal_get txn_id 2>/dev/null || printf '')"
	if nordvpn_easy_supervise_phase_is_terminal "$existing_phase"; then
		existing_phase=''
	fi
	if [ -n "$existing_phase" ] && [ -n "$existing_txn" ] && [ "$existing_target" = "$target" ]; then
		started_at="$(nordvpn_easy_journal_get started_at 2>/dev/null || printf '')"
		[ -n "$started_at" ] || started_at="$now"
		nordvpn_easy_fenced_journal_set \
			'phase=applying' \
			"txn_id=$existing_txn" \
			"target_fingerprint=$target" \
			'origin=supervise' \
			"owner_pid=$$" \
			"started_at=$started_at" \
			'fetch_done=' \
			'last_error=' \
			'finished_at=' \
			'rc=' \
			'country=' >/dev/null 2>&1 || true
		return 0
	fi
	nordvpn_easy_fenced_journal_set \
		'phase=applying' \
		"txn_id=$(nordvpn_easy_journal_new_id)" \
		"target_fingerprint=$target" \
		'origin=supervise' \
		"owner_pid=$$" \
		"started_at=$now" \
		'fetch_done=' \
		'last_error=' \
		'finished_at=' \
		'rc=' \
		'country=' >/dev/null 2>&1 || true
}

# VALIDATE (local / fail-fast): the setup-runtime validator (reads NORDVPN_TOKEN,
# WAN_IF, VPN_IF, VPN_ADDR, VPN_PORT; sets MISSING_FIELDS). No commit.
_supervise_validate() {
	if validate_setup_runtime; then
		return 0
	fi
	nordvpn_easy_supervise_record_error 'local.validate' "setup runtime validation failed (missing: ${MISSING_FIELDS:-unknown})"
	return 1
}

# PERSIST (local): stage enabled=1 then owner-fenced commit; revert + fail on a
# fenced refusal so a refused delta cannot be flushed by a later commit.
_supervise_persist() {
	if ! uci set 'nordvpn_easy.main.enabled=1' 2>/dev/null; then
		uci -q revert nordvpn_easy 2>/dev/null || true
		nordvpn_easy_supervise_record_error 'local.persist' 'failed to stage enabled=1'
		return 1
	fi
	if ! nordvpn_easy_fenced_uci_commit nordvpn_easy; then
		uci -q revert nordvpn_easy 2>/dev/null || true
		nordvpn_easy_supervise_record_error 'local.persist' 'enabled-flag commit refused or failed (superseded owner?)'
		return 1
	fi
	# S7 inc 6: arm the kill-switch EARLY, before CONVERGE's teardown. ensure_vpn_firewall
	# is a pure function of DESIRED (a clean-slate rebuild) whose kill-switch rules drop
	# LAN->WAN FORWARDING (the client leak path), NOT the router's own egress -- so arming
	# it here does not block the later CONVERGE fetch (a router-output call to the NordVPN
	# API). This closes the window where TEARDOWN has removed the tunnel but CONFIGURE has
	# not yet committed the firewall: a kill/reap mid-CONFIGURE finds the kill-switch already
	# up, so LAN traffic cannot fall back to the bare WAN and leak. CONFIGURE re-runs
	# ensure_vpn_firewall idempotently (same DESIRED -> same ruleset). Supervisor-only: the
	# legacy path still arms the firewall only inside configure.
	if ! nordvpn_easy_ensure_vpn_firewall; then
		nordvpn_easy_supervise_record_error 'local.persist' 'kill-switch arm-early (firewall commit) failed'
		return 1
	fi
	return 0
}

# HOOKS (non-fatal): core.sh does NOT source hooks.sh, so source it here, install
# the SHIM the installers read at call time (cfg_* bridged from the UPPERCASE
# action-context env + the init.d-only consts + log_service_*/restart_cron_service
# functions), then call the installers with config_ready=1 so they DO NOT
# self-load service config and clobber the shim cfg_*. Runs in a background
# subshell (run_phase), so these assignments never leak into the parent process.
_supervise_hooks() {
	local libdir="${LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"
	if [ ! -r "${libdir}/hooks.sh" ]; then
		nordvpn_easy_log_phase 'supervise' 'hooks library missing; skipping hook install (non-fatal)'
		return 0
	fi
	# shellcheck disable=SC1090
	. "${libdir}/hooks.sh" || return 1
	cfg_vpn_if="${VPN_IF:-}"
	cfg_wan_if="${WAN_IF:-}"
	cfg_check_cron_schedule="${CHECK_CRON_SCHEDULE:-}"
	cfg_enable_hotplug="${ENABLE_HOTPLUG:-0}"
	cfg_hotplug_debounce_seconds="${HOTPLUG_DEBOUNCE_SECONDS:-0}"
	cfg_enabled="${DESIRED_ENABLED:-0}"
	SERVICE_NAME="${SERVICE_NAME:-nordvpn-easy}"
	CRON_PATH="${CRON_PATH:-/etc/cron.d/nordvpn-easy}"
	CRONTAB_PATH="${CRONTAB_PATH:-/etc/crontabs/root}"
	CRON_BLOCK_BEGIN="${CRON_BLOCK_BEGIN:-# BEGIN nordvpn-easy}"
	CRON_BLOCK_END="${CRON_BLOCK_END:-# END nordvpn-easy}"
	HOTPLUG_PATH="${HOTPLUG_PATH:-/etc/hotplug.d/iface/95-nordvpn-easy}"
	CONNECT_APPLY_GUARD="${NORDVPN_EASY_CONNECT_APPLY_GUARD:-/tmp/run/nordvpn-easy/connect-apply-guard}"
	log_service_info() { nordvpn_easy_log "service: $*"; }
	log_service_error() { nordvpn_easy_log "service: $*"; }
	restart_cron_service() {
		/etc/init.d/cron restart >/dev/null 2>&1 ||
		/etc/init.d/cron reload >/dev/null 2>&1 ||
		true
	}
	install_cron_hook 1 || return 1
	install_hotplug_hook 1 || return 1
	return 0
}

# S7 inc 7: write the self-ifevent sentinel the hotplug hook reads to recognise -- and
# skip -- an interface event the supervisor generated itself (its own bring-up). The
# lock-busy check the hook already does covers the event WHILE this apply holds the
# execution lock; this sentinel additionally covers the window where the async ifup
# hotplug fires AFTER the apply has released the lock. It is TTL-based (wall-clock, to
# match the hook's `date +%s`), so a crash self-expires it -- no cleanup needed. The
# sentinel lives in the shared run dir (same one the generated hook hardcodes).
nordvpn_easy_supervise_mark_self_ifevent() {
	local iface="${1:-${VPN_IF:-wg0}}" rundir now ttl expiry
	rundir="${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}"
	mkdir -p "$rundir" 2>/dev/null || true
	now="$(date +%s 2>/dev/null || printf '0')"
	case "$now" in ''|*[!0-9]*) now=0 ;; esac
	# The TTL must outlast the REST of this apply (bring-up + the connectivity wait +
	# VERIFYING, ~40s) so the sentinel is still valid at lock release AND covers the
	# window just after -- while the apply holds the lock the hook's lock-busy check
	# already suppresses the ifup, so the sentinel's real job is the post-release tail.
	# 60s covers a typical apply-plus-settle; the trade-off is that a genuine external
	# flap of this iface within 60s of an apply defers only the fast-path health-check
	# (the cron check still recovers it). Tunable via NORDVPN_EASY_SELF_IFEVENT_TTL.
	ttl="${NORDVPN_EASY_SELF_IFEVENT_TTL:-60}"
	case "$ttl" in ''|*[!0-9]*) ttl=60 ;; esac
	expiry=$((now + ttl))
	{
		printf 'iface=%s\n' "$iface"
		printf 'expires=%s\n' "$expiry"
		printf 'target_fingerprint=%s\n' "$(nordvpn_easy_target_identity 2>/dev/null || printf '')"
	} > "${rundir}/self-ifevent" 2>/dev/null || true
}

# CONVERGE: ONE run_phase body = ONE background subshell, so the PRIVATE_KEY
# global that FETCH sets survives into CONFIGURE within THIS subshell (the
# same-process handoff the split configure requires). Order preserves the
# fetch-before-teardown invariant [B1]: a FETCH failure returns before teardown,
# so network.${VPN_IF} is never destroyed without a fresh key/server in hand.
_supervise_converge() {
	if ! nordvpn_easy_fetch_provision_prerequisites; then
		nordvpn_easy_supervise_record_error 'network.fetch' 'provision prerequisite fetch failed'
		return 1
	fi
	NORDVPN_EASY_PROVISION_FETCH_DONE=1
	export NORDVPN_EASY_PROVISION_FETCH_DONE
	nordvpn_easy_fenced_journal_merge 'fetch_done=1' >/dev/null 2>&1 || true
	# B1: teardown gated on the durable fetch_done flag.
	if [ "$(nordvpn_easy_journal_get fetch_done 2>/dev/null || printf '')" = '1' ]; then
		if ! nordvpn_easy_teardown_vpn; then
			nordvpn_easy_supervise_record_error 'local.teardown' 'vpn teardown failed (commit refused or interface persisted)'
			return 1
		fi
	fi
	if ! nordvpn_easy_configure_vpn_interface_no_bringup; then
		nordvpn_easy_supervise_record_error 'config.configure' 'interface configure/commit failed (fenced refusal or invalid config)'
		return 1
	fi
	# S7 inc 7: mark the imminent bring-up as a SELF-generated interface event so the
	# hotplug hook skips it (see nordvpn_easy_supervise_mark_self_ifevent). Written
	# BEFORE the ifup so the sentinel is already in place when the async hotplug fires.
	nordvpn_easy_supervise_mark_self_ifevent "$VPN_IF"
	if ! nordvpn_easy_bring_up_vpn_interface "$VPN_IF"; then
		nordvpn_easy_supervise_record_error 'local.bringup' 'interface bring-up failed'
		return 1
	fi
	# Reproduce the legacy success-log ordering: 'created successfully' + state
	# snapshot ONLY after bring-up succeeded (mirrors configure_vpn_interface).
	nordvpn_easy_log_phase 'supervise' "apply: $VPN_IF created successfully"
	if command -v nordvpn_easy_log_vpn_interface_state >/dev/null 2>&1; then
		nordvpn_easy_log_vpn_interface_state 'after-create' >/dev/null 2>&1 || true
	fi
	if ! nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "${POST_RESTART_DELAY:-}" "provisioning $VPN_IF"; then
		nordvpn_easy_supervise_record_error 'network.connectivity' 'timed out waiting for vpn connectivity'
		return 1
	fi
	return 0
}

# VERIFYING (non-fatal): verify_public_country_selection ALWAYS returns 0 (it
# only writes the public-verification status file), so never key a failure off
# it. commit_pending_server_preference (no-op unless a preference is pending) and
# mark_applied (best-effort, command -v guarded) run here, exactly where the
# legacy default provision tail runs them.
_supervise_verify() {
	verify_public_country_selection >/dev/null 2>&1 || true
	nordvpn_easy_commit_pending_server_preference >/dev/null 2>&1 || true
	if command -v nordvpn_easy_mark_applied >/dev/null 2>&1; then
		nordvpn_easy_mark_applied "$(nordvpn_easy_config_fingerprint 2>/dev/null || printf '')" >/dev/null 2>&1 || true
	fi
	return 0
}

# The supervised apply machine. 3rd structural flag gate = first statement.
nordvpn_easy_supervise() {
	# GATE 1/2 (of this function): orchestrator mode. Absent/garbage => 'legacy'
	# per nordvpn_easy_orchestrator_mode => refuse as a benign no-op (return 0);
	# the legacy path is unaffected because nothing routes here in inc 5c.
	if [ "$(nordvpn_easy_orchestrator_mode)" != 'supervisor' ]; then
		nordvpn_easy_log_phase 'supervise' 'orchestrator mode is legacy; supervisor state machine is inert (no-op)'
		return 0
	fi
	# GATE 2/2: disable (DESIRED_ENABLED=0) is REFUSED in inc 5c -- it stays on the
	# legacy disconnect/disable_runtime path. Return 0 so it is not a failure.
	if [ "${DESIRED_ENABLED:-0}" != '1' ]; then
		nordvpn_easy_log_phase 'supervise' 'disable request (DESIRED_ENABLED=0) is not handled by the supervisor in this increment; staying on the legacy path'
		return 0
	fi
	LOG_PHASE='supervise'
	local target last_error
	target="$(nordvpn_easy_target_identity 2>/dev/null || printf '')"
	# Reap a foreign dead record FIRST (so it is stamped failed before open_txn's
	# fresh write would replace it), THEN open/adopt this transaction.
	nordvpn_easy_supervise_reap_stale_journal "$target"
	nordvpn_easy_supervise_open_txn "$target"
	if nordvpn_easy_run_phase 'validate' 30 1 _supervise_validate &&
		nordvpn_easy_run_phase 'persist' 30 1 _supervise_persist; then
		# HOOKS is non-fatal (legacy install_hooks is best-effort).
		nordvpn_easy_run_phase 'hooks' 30 1 _supervise_hooks ||
			nordvpn_easy_log_phase 'supervise' 'recovery hook installation failed (non-fatal); continuing'
		if nordvpn_easy_run_phase 'converge' "${NORDVPN_EASY_SUPERVISE_CONVERGE_TIMEOUT:-180}" "${NORDVPN_EASY_SUPERVISE_CONVERGE_RETRIES:-3}" _supervise_converge; then
			# VERIFYING is non-fatal.
			nordvpn_easy_run_phase 'verifying' 60 1 _supervise_verify ||
				nordvpn_easy_log_phase 'supervise' 'verification phase reported non-zero (non-fatal)'
			nordvpn_easy_fenced_journal_finish 0 "${RESOLVED_COUNTRY_CODE:-${VPN_COUNTRY:-}}" >/dev/null 2>&1 || true
			return 0
		fi
	fi
	# A fatal phase (validate|persist|converge) failed. The failing phase's record_error
	# already wrote the HUMAN detail to the last_error CACHE FILE (S8) -- it runs in the
	# run_phase background subshell so its RECORDED shell-flag does not reach here, but the
	# cache file persists. Only fall back to the classified journal token if that cache is
	# still EMPTY (nothing recorded a cause yet), so we do not clobber the specific message
	# the LuCI Save&Apply surfaces. Then stamp the journal FAILED.
	if [ ! -s "${NORDVPN_EASY_LAST_ERROR_CACHE:-/tmp/run/nordvpn-easy/last_error}" ]; then
		last_error="$(nordvpn_easy_journal_get last_error 2>/dev/null || printf '')"
		[ -n "$last_error" ] || last_error='config.supervise'
		nordvpn_easy_record_last_error "supervise: convergence failed ($last_error)"
	fi
	nordvpn_easy_fenced_journal_finish 1 '' >/dev/null 2>&1 || true
	return 1
}

