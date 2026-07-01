#!/bin/sh

NORDVPN_EASY_TEMP_PATHS="${NORDVPN_EASY_TEMP_PATHS:-}"
NORDVPN_EASY_EXIT_TRAP_INSTALLED="${NORDVPN_EASY_EXIT_TRAP_INSTALLED:-0}"

nordvpn_easy_log() {
	[ -t 2 ] && printf '*** %s ***\n' "$*" >&2
	if command -v logger >/dev/null 2>&1; then
		logger -t 'nordvpn-easy' "$*" >/dev/null 2>&1 || true
	fi
	return 0
}

nordvpn_easy_log_phase() {
	local phase="$1"
	shift
	local prefix=''

	if [ -n "${ACTION:-}" ] && [ -n "${ACTION_TRACE_ID:-}" ]; then
		prefix="${phase}[${ACTION}/${ACTION_TRACE_ID}]"
	elif [ -n "${ACTION:-}" ]; then
		prefix="${phase}[${ACTION}]"
	else
		prefix="$phase"
	fi

	nordvpn_easy_log "${prefix}: $*"
}

nordvpn_easy_log_blocker() {
	local phase="${1:-runtime}"
	local message=''
	shift

	message="$*"
	if [ -n "$message" ] &&
		[ "${NORDVPN_EASY_LAST_ERROR_RECORDED:-0}" -ne 1 ] &&
		command -v nordvpn_easy_record_last_error >/dev/null 2>&1; then
		nordvpn_easy_record_last_error "$message"
	fi

	nordvpn_easy_log_phase "$phase" "BLOCKER: $message"
}

nordvpn_easy_handshake_epoch_indicates_connection() {
	local epoch="$1"
	local now diff

	case "$epoch" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$epoch" -gt 0 ] || return 1
	now="$(date +%s 2>/dev/null)"
	case "$now" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	diff=$((now - epoch))
	[ "$diff" -lt 0 ] && diff=0
	# A WireGuard session is only valid for REJECT_AFTER_TIME (180s); a handshake
	# older than that means the tunnel is no longer actively connected. This also
	# matches the LuCI 180s convergence threshold, so the status banner and the
	# Save & Apply result agree instead of a long-dead tunnel reporting connected.
	[ "$diff" -le 180 ]
}

nordvpn_easy_install_exit_trap() {
	[ "${NORDVPN_EASY_EXIT_TRAP_INSTALLED:-0}" -eq 1 ] && return 0

	trap 'nordvpn_easy_on_exit' EXIT
	trap 'nordvpn_easy_on_signal 1' HUP
	trap 'nordvpn_easy_on_signal 2' INT
	trap 'nordvpn_easy_on_signal 15' TERM
	NORDVPN_EASY_EXIT_TRAP_INSTALLED=1
}

nordvpn_easy_register_temp_path() {
	local temp_path="$1"

	[ -n "$temp_path" ] || return 1

	case "
$NORDVPN_EASY_TEMP_PATHS
" in
	*"
$temp_path
"*)
		return 0
		;;
	esac

	NORDVPN_EASY_TEMP_PATHS="${NORDVPN_EASY_TEMP_PATHS}${temp_path}
"
}

nordvpn_easy_cleanup_temp_paths() {
	local old_ifs="$IFS"
	local temp_path

	IFS='
'
	for temp_path in $NORDVPN_EASY_TEMP_PATHS; do
		[ -n "$temp_path" ] || continue
		rm -rf -- "$temp_path"
	done
	IFS="$old_ifs"

	NORDVPN_EASY_TEMP_PATHS=''
}

nordvpn_easy_valid_wireguard_key() {
	# A WireGuard key (private NordLynx key or peer public key) is 32 raw bytes,
	# i.e. 43 base64 characters plus a single '=' pad = 44 chars. Reject anything
	# else so a corrupt/truncated API response is caught at retrieval instead of
	# surfacing much later as a generic no-handshake failure.
	local key="$1"

	[ -n "$key" ] || return 1
	case "$key" in
		*[!A-Za-z0-9+/=]*) return 1 ;;
	esac
	case "$key" in
		*=) ;;
		*) return 1 ;;
	esac
	[ "${#key}" -eq 44 ] || return 1
}

nordvpn_easy_token_shape_is_canonical () {
	# A NordVPN access token is 64 lowercase hex chars. Used ONLY to warn, never
	# to reject, since the token format is owned by NordVPN and may change.
	case "$1" in
		''|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#1}" -eq 64 ]
}

nordvpn_easy_remove_app_firewall_sections() {
	# Remove every firewall section this app owns (named nordvpn_*) so the VPN
	# zone, lan->vpn forwarding and kill-switch rules can be rebuilt idempotently
	# (provisioning) and fully cleaned up on disable (restoring plain LAN->WAN).
	local section
	for section in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\(nordvpn_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u); do
		uci -q delete "firewall.${section}"
	done
}

nordvpn_easy_teardown_vpn_firewall() {
	# Tear the app's firewall objects down and reload, restoring plain LAN->WAN so
	# a disabled VPN does not leave the kill switch blocking the user's internet.
	nordvpn_easy_remove_app_firewall_sections
	# Fenced: reached both under the transaction lock (disconnect/reconcile) and
	# lock-free (boot-disable / the disable_runtime verb). A superseded/reaped
	# disconnect must NOT strip the new owner's kill-switch (that would leak); the
	# revert restores the staged section deletes so the kill-switch stays. A
	# tokenless (lock-free) caller is allowed through and commits normally.
	nordvpn_easy_fenced_uci_commit firewall 2>/dev/null || {
		uci revert firewall >/dev/null 2>&1 || true
		return 1
	}
	"${NORDVPN_EASY_FIREWALL_INIT:-/etc/init.d/firewall}" reload >/dev/null 2>&1 || return 1
}

nordvpn_easy_mktemp_dir() {
	local prefix="${1:-runtime}"
	local result_var="${2:-}"
	local workspace_dir=''
	local original_umask=''

	command -v mktemp >/dev/null 2>&1 || {
		nordvpn_easy_log_blocker 'runtime' "required command 'mktemp' is missing"
		return 1
	}

	original_umask="$(umask)"
	umask 077
	workspace_dir="$(mktemp -d "/tmp/nordvpn-easy.${prefix}.XXXXXX" 2>/dev/null)" || {
		umask "$original_umask"
		nordvpn_easy_log_blocker 'runtime' "could not create secure temporary workspace for ${prefix}"
		return 1
	}
	umask "$original_umask"

	nordvpn_easy_register_temp_path "$workspace_dir" || {
		rm -rf -- "$workspace_dir"
		return 1
	}

	if [ -n "$result_var" ]; then
		eval "$result_var='$(printf "%s" "$workspace_dir" | sed "s/'/'\\\\''/g")'"
	else
		printf '%s\n' "$workspace_dir"
	fi
}

nordvpn_easy_temp_file_path() {
	printf '%s/%s\n' "$1" "$2"
}

nordvpn_easy_debug_cli_args() {
	if [ $# -eq 0 ]; then
		printf '%s\n' 'none'
		return 0
	fi

	printf '%s' "$1"
	shift

	while [ $# -gt 0 ]; do
		printf ' %s' "$1"
		shift
	done

	printf '\n'
}

nordvpn_easy_curl_rc_meaning() {
	case "$1" in
		0)  printf 'ok' ;;
		6)  printf 'could not resolve host (DNS failure)' ;;
		7)  printf 'failed to connect to host' ;;
		22) printf 'HTTP error response' ;;
		28) printf 'operation timed out' ;;
		35) printf 'SSL/TLS handshake failed' ;;
		52) printf 'empty reply from server' ;;
		56) printf 'receive failure' ;;
		60) printf 'certificate verification failed' ;;
		77) printf 'CA certificate problem' ;;
		*)  printf 'curl error %s' "$1" ;;
	esac
}

nordvpn_easy_curl_error_summary() {
	local error_file="$1"

	sed -n '1,3p' "$error_file" 2>/dev/null |
		tr '\r\n' '  ' |
		nordvpn_easy_sanitize_diagnostics_stream
}

# Single newline / carriage-return sentinels for the json-escape fast path,
# computed once (command substitution strips the trailing 'x', not the control
# character before it).
NORDVPN_EASY_JSON_NL="$(printf '\nx')"; NORDVPN_EASY_JSON_NL="${NORDVPN_EASY_JSON_NL%x}"
NORDVPN_EASY_JSON_CR="$(printf '\rx')"; NORDVPN_EASY_JSON_CR="${NORDVPN_EASY_JSON_CR%x}"

nordvpn_easy_json_escape() {
	# Fast path: a value with no backslash, double quote, newline or CR needs no
	# escaping and no subprocess. This is the common case on the status hot path
	# (json_escape is called ~30x per status emit), so it must not fork.
	case "$1" in
		*\\*|*\"*|*"$NORDVPN_EASY_JSON_NL"*|*"$NORDVPN_EASY_JSON_CR"*) ;;
		*) printf '%s' "$1"; return 0 ;;
	esac
	# Slow path: escape backslash/quote/CR PER LINE first, then join lines with
	# \n. A single slurp-then-substitute sed leaves a single-line value UNescaped
	# (at EOF `N` auto-prints the pattern space before the s/// commands run), so
	# a lone line with a " or \ (e.g. last_error from an API error) would break
	# JSON.parse of the whole status document.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/\\r/g' | sed ':a;N;$!ba;s/\n/\\n/g'
}

nordvpn_easy_lock_contention_is_nonfatal() {
	case "$ACTION" in
		run|check|refresh_countries)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_require_commands() {
	local cmd
	local log_mode="${NORDVPN_EASY_REQUIRE_COMMANDS_LOG_MODE:-verbose}"

	[ "$log_mode" = 'quiet' ] || nordvpn_easy_log 'Validating required system commands'
	for cmd in awk curl ifdown ifup ip jq mktemp ping uci; do
		command -v "$cmd" >/dev/null 2>&1 || {
			nordvpn_easy_log_blocker 'runtime' "required command '$cmd' is missing"
			return 1
		}
	done
	[ "$log_mode" = 'quiet' ] || nordvpn_easy_log 'Required system commands are available'
}

nordvpn_easy_lock_age_seconds() {
	local lock_path="$1"
	local started_at="${2:-}"
	local now_ts=0
	local lock_ts=0
	local age=0

	now_ts="$(date +%s 2>/dev/null || printf '0')"
	case "$started_at" in
		''|*[!0-9]*)
			lock_ts="$(stat -c %Y "$lock_path" 2>/dev/null || printf '0')"
			;;
		*)
			lock_ts="$started_at"
			;;
	esac

	case "$now_ts:$lock_ts" in
		*[!0-9:]*|0:*|*:0)
			printf '%s\n' '0'
			return 0
			;;
	esac

	age=$((now_ts - lock_ts))
	[ "$age" -lt 0 ] && age=0
	printf '%s\n' "$age"
}

# Seconds since boot from /proc/uptime -- a MONOTONIC clock, immune to the NTP
# step that jumps the wall clock forward minutes after an OpenWrt router boots.
# The lock records this at acquire so the reaper measures a true elapsed age
# instead of a clock-jump artifact. Zero-fork (read is a builtin); fails to 0.
nordvpn_easy_uptime_seconds() {
	local up

	read -r up < /proc/uptime 2>/dev/null || up=''
	up="${up%%.*}"
	case "$up" in
		''|*[!0-9]*) printf '0' ;;
		*) printf '%s' "$up" ;;
	esac
}

# The TTL (seconds) after which a still-LIVE lock holder is treated as wedged and
# reaped. Generously above any legitimate hold (a full provision + bringup, well
# past the rpcd ceiling); an override is normalized so a garbage
# NORDVPN_EASY_LOCK_TTL cannot make every holder look expired.
nordvpn_easy_lock_ttl_seconds() {
	local ttl="${NORDVPN_EASY_LOCK_TTL:-300}"

	case "$ttl" in
		''|*[!0-9]*) printf '300' ;;
		*) printf '%s' "$ttl" ;;
	esac
}

# The reaper's age for a live holder: prefer the MONOTONIC anchor (started_mono)
# so an NTP step cannot inflate it into a false reap; fall back to the wall-clock
# age only for a lock written by a pre-reaper build mid-upgrade (no started_mono).
# If uptime is unreadable the age clamps to 0 (fail-safe: never reap when we
# cannot measure elapsed time).
nordvpn_easy_lock_wedge_age_seconds() {
	local lock_path="$1"
	local started_at="${2:-}"
	local started_mono now_mono age

	started_mono="$(cat "${lock_path}/started_mono" 2>/dev/null)" || started_mono=''
	case "$started_mono" in
		''|*[!0-9]*)
			nordvpn_easy_lock_age_seconds "$lock_path" "$started_at"
			return 0
			;;
	esac
	now_mono="$(nordvpn_easy_uptime_seconds)"
	case "$now_mono" in
		''|*[!0-9]*) now_mono=0 ;;
	esac
	age=$((now_mono - started_mono))
	[ "$age" -lt 0 ] && age=0
	printf '%s\n' "$age"
}

nordvpn_easy_server_selection_is_manual() {
	[ "$SERVER_SELECTION_MODE" = 'manual' ]
}

nordvpn_easy_server_cache_is_enabled() {
	[ "$SERVER_CACHE_ENABLED" = '1' ]
}

nordvpn_easy_current_server_station() {
	local vpn_if="${VPN_IF:-wg0}"

	uci -q get "network.${vpn_if}server.nordvpn_station" 2>/dev/null || true
}

nordvpn_easy_current_server_country() {
	local vpn_if="${VPN_IF:-wg0}"

	uci -q get "network.${vpn_if}server.nordvpn_country_code" 2>/dev/null || true
}

nordvpn_easy_set_server_preference_in_uci() {
	uci set "nordvpn_easy.main.preferred_server_hostname"="$1"
	uci set "nordvpn_easy.main.preferred_server_station"="$2"
}

nordvpn_easy_has_fallback_server_preference() {
	[ -n "${FALLBACK_SERVER_STATION:-}" ]
}

nordvpn_easy_require_manual_server_preference() {
	nordvpn_easy_server_selection_is_manual || return 0

	[ -n "$VPN_COUNTRY" ] || {
		nordvpn_easy_log_blocker 'apply' 'manual server selection requires a VPN_COUNTRY'
		return 1
	}

	[ -n "$PREFERRED_SERVER_HOSTNAME" ] || {
		nordvpn_easy_log_blocker 'apply' 'manual server selection requires a PREFERRED_SERVER_HOSTNAME'
		return 1
	}

	[ -n "$PREFERRED_SERVER_STATION" ] || {
		nordvpn_easy_log_blocker 'apply' 'manual server selection requires a PREFERRED_SERVER_STATION'
		return 1
	}
}

nordvpn_easy_server_cache_ttl_value() {
	case "$SERVER_CACHE_TTL" in
		''|*[!0-9]*)
			printf '%s\n' '86400'
			;;
		*)
			printf '%s\n' "$SERVER_CACHE_TTL"
			;;
	esac
}

# Field 22 of /proc/PID/stat (process start time, jiffies since boot) -- the
# PID-reuse discriminator in the owner token. The comm (field 2) is wrapped in
# parens and may contain spaces, parens or newlines, so strip through the LAST
# ") " (the true comm close) before counting fields; a naive `awk '{print $22}'`
# misparses a spaced comm. Fail CLOSED with a NOSTAT sentinel that never silently
# matches a healthy holder.
nordvpn_easy_proc_starttime() {
	local pid="${1:-$$}"
	local stat rest tok i=1

	stat="$(cat "/proc/${pid}/stat" 2>/dev/null)" || { printf '%s' 'NOSTAT'; return 1; }
	rest="${stat##*) }"
	[ "$rest" = "$stat" ] && { printf '%s' 'NOSTAT'; return 1; }
	# shellcheck disable=SC2086
	set -- $rest
	[ "$#" -lt 20 ] && { printf '%s' 'NOSTAT'; return 1; }
	for tok in "$@"; do
		if [ "$i" -eq 20 ]; then
			case "$tok" in
				''|*[!0-9]*) printf '%s' 'NOSTAT'; return 1 ;;
				*) printf '%s' "$tok"; return 0 ;;
			esac
		fi
		i=$((i + 1))
	done
	printf '%s' 'NOSTAT'
	return 1
}

# A per-transaction owner identity: claim_id:pid:starttime. claim_id is a random
# uuid (the primary uniqueness guarantor: even PID reuse yields a distinct token);
# pid+starttime make the token PID-reuse-proof. Self-contained (reads the uuid
# directly) so any caller that sources only common.sh still mints a unique id.
nordvpn_easy_new_owner_token() {
	local claim_id

	# `|| true` so an unreadable uuid (failed redirect) never aborts a set -e
	# caller; a failed read just yields an empty claim_id and the fallback below
	# takes over.
	claim_id="$(tr -d '\n' < /proc/sys/kernel/random/uuid 2>/dev/null || true)"
	[ -n "$claim_id" ] || claim_id="fallback-$$-$(date +%s 2>/dev/null || printf '0')"
	printf '%s:%s:%s' "$claim_id" "$$" "$(nordvpn_easy_proc_starttime "$$")"
}

# Fail-closed ownership check: true only when the on-disk lock token equals this
# process's minted token. Consulted ONLY by release_lock and the fenced_* helpers
# -- never on the acquire/recover path -- so it can never block reclamation of a
# foreign, tokenless or half-written dir (preserves the no-deadlock invariant).
nordvpn_easy_owner_assert() {
	local on_disk

	[ -n "${NORDVPN_EASY_OWNER_TOKEN:-}" ] || return 1
	[ -n "${LOCK_DIR:-}" ] || return 1
	on_disk="$(cat "${LOCK_DIR}/token" 2>/dev/null)" || return 1
	[ -n "$on_disk" ] || return 1
	[ "$on_disk" = "$NORDVPN_EASY_OWNER_TOKEN" ]
}

# Deny a fenced mutation ONLY when this process holds an owner token that no longer
# matches the on-disk lock -- i.e. it acquired the execution lock and was then
# superseded/reaped. A process holding NO token is not a lock owner at all (the
# boot-disable path and the disable_runtime rpcd verb legitimately run OUTSIDE any
# lock), so it is allowed through. This "fence only what you claimed" rule is what
# lets the dual-use teardown effects (reached both under the transaction lock AND
# lock-free) be fenced without breaking their tokenless callers. For the provision
# effects, which always run with a token, it is identical to a bare owner_assert.
nordvpn_easy_owner_fence_denied() {
	[ -n "${NORDVPN_EASY_OWNER_TOKEN:-}" ] || return 1
	nordvpn_easy_owner_assert && return 1
	return 0
}

# Owner-fenced mutation wrappers: refuse (no side effect) when a superseded/reaped
# owner would otherwise mutate the new owner's runtime. fenced_uci_commit,
# fenced_ifupdown and fenced_ip_link_del are wired (S7a/S7b) into the
# runtime-mutating sites (provision interface/firewall commits, ifup/ifdown, wg
# device deletion, and the dual-use disable-runtime firewall/network commits), so
# once the S7b TTL reaper can revoke a live holder's token a superseded writer's
# effects refuse instead of corrupting the new owner's runtime. Callers that abort
# on a fenced uci-commit refusal `uci -q revert <pkg>` first (S7b), so a refused
# staged delta cannot be flushed by a later unfenced same-package commit (cf.
# service-config.sh). fenced_journal_set stays defined-but-unwired for the S7
# supervisor.
nordvpn_easy_fenced_journal_set() {
	nordvpn_easy_owner_fence_denied && { nordvpn_easy_log_phase 'runtime' 'refusing journal write: superseded execution-lock owner'; return 1; }
	nordvpn_easy_journal_write_full "$@"
}

nordvpn_easy_fenced_uci_commit() {
	nordvpn_easy_owner_fence_denied && { nordvpn_easy_log_blocker 'runtime' 'refusing uci commit: superseded execution-lock owner'; return 1; }
	uci commit "$@"
}

nordvpn_easy_fenced_ifupdown() {
	nordvpn_easy_owner_fence_denied && { nordvpn_easy_log_blocker 'runtime' 'refusing ifup/ifdown: superseded execution-lock owner'; return 1; }
	case "${1:-}" in
		up) ifup "${2:-}" ;;
		down) ifdown "${2:-}" ;;
		*) return 2 ;;
	esac
}

# Deleting the kernel wireguard device is a runtime mutation just like ifdown, but
# it sits behind a non-aborting `|| true` at its call sites, so a fence-refused
# ifdown does not stop it. Fence it too: a reaped-then-thawed holder must not delete
# the new owner's freshly-created $VPN_IF device (a split-brain teardown of a live
# tunnel). No-op for the legitimate owner (fence_denied is false).
nordvpn_easy_fenced_ip_link_del() {
	nordvpn_easy_owner_fence_denied && { nordvpn_easy_log_blocker 'runtime' 'refusing ip link del: superseded execution-lock owner'; return 1; }
	ip link del dev "${1:-}"
}

nordvpn_easy_release_lock() {
	[ "${LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
	[ -n "${LOCK_DIR:-}" ] || return 0
	# B-2 LOAD-BEARING GATE: only delete the dir when its on-disk token is still
	# ours. A thawed/superseded/PID-reused ex-holder whose LOCK_ACQUIRED is still 1
	# in its own memory finds a different token on disk and must NOT delete the
	# live owner's lock.
	if ! nordvpn_easy_owner_assert; then
		LOCK_ACQUIRED=0
		nordvpn_easy_log_phase 'runtime' "execution lock at $LOCK_DIR is no longer owned by this process; not releasing (superseded)"
		return 0
	fi
	rm -rf "${LOCK_DIR:-}"
	LOCK_ACQUIRED=0
	nordvpn_easy_log_phase 'runtime' "execution lock released at $LOCK_DIR"
}

nordvpn_easy_clear_stale_runtime_lock() {
	local lock_dir="${1:-/tmp/nordvpn-easy.lock}"
	local lock_pid_file="${lock_dir}/pid"
	local lock_pid=''

	[ -d "$lock_dir" ] || return 0

	if [ ! -f "$lock_pid_file" ]; then
		rm -rf "$lock_dir" 2>/dev/null || true
		return 0
	fi

	lock_pid="$(cat "$lock_pid_file" 2>/dev/null)"
	case "$lock_pid" in
		''|*[!0-9]*)
			rm -rf "$lock_dir" 2>/dev/null || true
			return 0
			;;
	esac

	if kill -0 "$lock_pid" 2>/dev/null; then
		return 1
	fi

	rm -rf "$lock_dir" 2>/dev/null || true
	return 0
}

_nordvpn_easy_connect_apply_result_get() {
	local target="$1"
	local key="$2"

	[ -r "$target" ] || return 1
	sed -n "s/^${key}=//p" "$target" 2>/dev/null | head -n1
}

nordvpn_easy_connect_apply_result_begin() {
	local target="${1:-/tmp/run/nordvpn-easy/connect-apply-result}"
	local target_dir tmp now_ts started_at existing_state existing_started_at

	target_dir="$(dirname "$target")"
	mkdir -p "$target_dir" 2>/dev/null || return 1
	tmp="$(mktemp "${target_dir}/.connect-apply-result.XXXXXX" 2>/dev/null)" || return 1
	now_ts="$(date +%s 2>/dev/null || printf '%s' '0')"

	# Idempotent re-begin: the connect-apply lifecycle is begun by several owners
	# (rpcd start_connect, init connect, core stop_vpn). If an apply is already
	# pending, keep its original started_at so a second begin does not move the
	# start time backwards/forwards and skew the client's convergence window.
	started_at="$now_ts"
	existing_state="$(_nordvpn_easy_connect_apply_result_get "$target" state 2>/dev/null || true)"
	if [ "$existing_state" = 'pending' ]; then
		existing_started_at="$(_nordvpn_easy_connect_apply_result_get "$target" started_at 2>/dev/null || true)"
		case "$existing_started_at" in
			''|*[!0-9]*) ;;
			*) started_at="$existing_started_at" ;;
		esac
	fi

	if ! cat > "$tmp" <<EOF
state=pending
rc=
finished_at=
country=
started_at=$started_at
EOF
	then
		rm -f "$tmp" 2>/dev/null || true
		return 1
	fi

	mv "$tmp" "$target" || {
		rm -f "$tmp" 2>/dev/null || true
		return 1
	}

	# Shadow dual-write: mirror the apply lifecycle into the journal (not yet
	# authoritative). A journal error must never fail the result write.
	if command -v nordvpn_easy_journal_begin >/dev/null 2>&1; then
		nordvpn_easy_journal_begin apply >/dev/null 2>&1 || true
	fi
}

nordvpn_easy_connect_apply_result_finish() {
	local target="${1:-/tmp/run/nordvpn-easy/connect-apply-result}"
	local rc="${2:-1}"
	local country="${3:-}"
	local target_dir tmp
	local finished_at=''
	local previous_started_at=''
	local state='failed'

	finished_at="$(date +%s 2>/dev/null || printf '%s' '0')"
	[ "$rc" -eq 0 ] && state='success'
	previous_started_at="$(_nordvpn_easy_connect_apply_result_get "$target" started_at 2>/dev/null)"

	target_dir="$(dirname "$target")"
	mkdir -p "$target_dir" 2>/dev/null || return 1
	tmp="$(mktemp "${target_dir}/.connect-apply-result.XXXXXX" 2>/dev/null)" || return 1
	if ! cat > "$tmp" <<EOF
state=$state
rc=$rc
finished_at=$finished_at
country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
started_at=${previous_started_at:-$finished_at}
EOF
	then
		rm -f "$tmp" 2>/dev/null || true
		return 1
	fi

	mv "$tmp" "$target" || {
		rm -f "$tmp" 2>/dev/null || true
		return 1
	}

	# Shadow dual-write of the terminal phase before refreshing the status cache,
	# so the cached status reflects the finished journal state.
	if command -v nordvpn_easy_journal_finish >/dev/null 2>&1; then
		nordvpn_easy_journal_finish "$rc" "$country" >/dev/null 2>&1 || true
	fi

	if command -v nordvpn_easy_write_status_cache >/dev/null 2>&1; then
		nordvpn_easy_write_status_cache >/dev/null 2>&1 || true
	fi
}

# Sets: CONNECT_APPLY_STATE CONNECT_APPLY_RC CONNECT_APPLY_FINISHED_AT CONNECT_APPLY_COUNTRY CONNECT_APPLY_STARTED_AT
nordvpn_easy_connect_apply_result_read() {
	local target="${1:-/tmp/run/nordvpn-easy/connect-apply-result}"

	CONNECT_APPLY_STATE=''
	CONNECT_APPLY_RC=''
	CONNECT_APPLY_FINISHED_AT=''
	CONNECT_APPLY_COUNTRY=''
	CONNECT_APPLY_STARTED_AT=''

	[ -r "$target" ] || return 1

	CONNECT_APPLY_STATE="$(_nordvpn_easy_connect_apply_result_get "$target" state)"
	CONNECT_APPLY_RC="$(_nordvpn_easy_connect_apply_result_get "$target" rc)"
	CONNECT_APPLY_FINISHED_AT="$(_nordvpn_easy_connect_apply_result_get "$target" finished_at)"
	CONNECT_APPLY_COUNTRY="$(_nordvpn_easy_connect_apply_result_get "$target" country)"
	CONNECT_APPLY_STARTED_AT="$(_nordvpn_easy_connect_apply_result_get "$target" started_at)"
	[ -n "$CONNECT_APPLY_STATE" ] || return 1
	return 0
}

nordvpn_easy_write_lock_metadata() {
	local lock_dir="$1"
	local lock_pid="$2"
	local lock_action="$3"
	local lock_started_at="$4"
	local lock_state="$5"
	local lock_token="${6:-}"

	printf '%s\n' "$lock_pid" > "${lock_dir}/pid" || return 1
	printf '%s\n' "$lock_action" > "${lock_dir}/action" || return 1
	printf '%s\n' "$lock_started_at" > "${lock_dir}/started_at" || return 1
	printf '%s\n' "$lock_state" > "${lock_dir}/state" || return 1
	# Monotonic acquire time for the reaper's NTP-immune age check, written BEFORE
	# the token so the B-3 token-last invariant below still holds.
	printf '%s\n' "$(nordvpn_easy_uptime_seconds)" > "${lock_dir}/started_mono" || return 1
	# B-3 invariant: the token is the STRICTLY LAST write, after pid. A dir seen
	# without a token is therefore pre-pid (pidless-grace) or post-pid-pre-token
	# (live-busy/dead-recover) -- always reclaimable by the existing pid/age paths.
	if [ -n "$lock_token" ]; then
		printf '%s\n' "$lock_token" > "${lock_dir}/token" || return 1
	fi
}

_nordvpn_easy_try_acquire_lock() {
	local lock_pid_file="${LOCK_DIR}/pid"
	local lock_action_file="${LOCK_DIR}/action"
	local lock_started_at_file="${LOCK_DIR}/started_at"
	local lock_pid=''
	local lock_action=''
	local lock_started_at=''
	local lock_age='0'
	local lock_ttl='300'
	local now_ts=0
	local stale_reason='unknown'
	local owner_token=''

	# Adopt a lock a parent transaction already holds. The init service's
	# acquire_runtime_transaction_lock takes the runtime lock once for the whole
	# connect/reconnect/reconcile sequence and exports NORDVPN_EASY_LOCK_INHERITED
	# so each child core.sh run shares that single lock instead of re-acquiring
	# (and releasing) it between steps, which is what used to leave the runtime
	# unprotected in the gaps. We only adopt when a live holder still owns the
	# dir; we install the exit trap so temp paths are still cleaned, but leave
	# LOCK_ACQUIRED=0 so this child never releases a lock it did not create.
	if [ "${NORDVPN_EASY_LOCK_INHERITED:-0}" = '1' ]; then
		lock_pid="$(cat "$lock_pid_file" 2>/dev/null)"
		case "$lock_pid" in
			''|*[!0-9]*)
				;;
			*)
				if kill -0 "$lock_pid" 2>/dev/null; then
					LOCK_ACQUIRED=0
					# Adopt the parent transaction's identity from disk so this
					# child's S7 owner-fenced writes count as the same transaction.
					# LOCK_ACQUIRED=0 (not the token) is what stops the child from
					# ever releasing the parent's lock: release_lock short-circuits
					# on it BEFORE owner_assert is consulted. The parent keeps the
					# token UNEXPORTED, so it reaches the child only via this read.
					NORDVPN_EASY_OWNER_TOKEN="$(cat "${LOCK_DIR}/token" 2>/dev/null || printf '')"
					nordvpn_easy_install_exit_trap
					nordvpn_easy_log_phase 'runtime' "adopting inherited execution lock at $LOCK_DIR (holder pid=$lock_pid)"
					return 0
				fi
				;;
		esac
		# The inherited lock vanished or its holder died: fall through and
		# acquire/recover it directly so this run is never left unprotected.
		nordvpn_easy_log_phase 'runtime' "inherited execution lock at $LOCK_DIR is no longer held; acquiring directly"
	fi

	now_ts="$(date +%s 2>/dev/null || printf '0')"
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		owner_token="$(nordvpn_easy_new_owner_token)"
		if ! nordvpn_easy_write_lock_metadata "$LOCK_DIR" "$$" "${ACTION:-unknown}" "$now_ts" 'held' "$owner_token"; then
			rm -rf "$LOCK_DIR" 2>/dev/null
			nordvpn_easy_log_blocker 'runtime' "could not write execution lock metadata into $LOCK_DIR"
			return 1
		fi
		NORDVPN_EASY_OWNER_TOKEN="$owner_token"
		LOCK_ACQUIRED=1
		nordvpn_easy_install_exit_trap
		nordvpn_easy_log_phase 'runtime' "execution lock acquired at $LOCK_DIR"
		return 0
	fi

	if [ ! -d "$LOCK_DIR" ]; then
		nordvpn_easy_log_blocker 'runtime' "could not create execution lock directory at $LOCK_DIR"
		return 1
	fi

	if [ ! -f "$lock_pid_file" ]; then
		lock_action="$(cat "$lock_action_file" 2>/dev/null)"
		lock_started_at="$(cat "$lock_started_at_file" 2>/dev/null)"
		lock_age="$(nordvpn_easy_lock_age_seconds "$LOCK_DIR" "$lock_started_at")"
		# A lock dir with no pid file means a crash between mkdir and the
		# metadata write -- a window of microseconds. Within a short grace
		# period stay conservative (a creator may legitimately be mid-write) and
		# report contention; once the dir has aged past it no live owner can
		# ever appear, so fall through to recovery instead of leaving every
		# future operation blocked while status reports the runtime as idle.
		case "$lock_age" in
			''|*[!0-9]*) lock_age=0 ;;
		esac
		if [ "$lock_age" -lt "${NORDVPN_EASY_LOCK_PIDLESS_GRACE:-30}" ]; then
			nordvpn_easy_log_blocker 'runtime' "execution lock metadata is incomplete (missing pid metadata, action=${lock_action:-unknown}, age=${lock_age}s)"
			return 2
		fi
		stale_reason="missing pid metadata (age=${lock_age}s; creator died mid-acquire)"
	else
		lock_pid="$(cat "$lock_pid_file" 2>/dev/null)"
		case "$lock_pid" in
			''|*[!0-9]*)
				stale_reason="invalid pid metadata (${lock_pid:-empty})"
				;;
			*)
				if kill -0 "$lock_pid" 2>/dev/null; then
					lock_action="$(cat "$lock_action_file" 2>/dev/null)"
					lock_started_at="$(cat "$lock_started_at_file" 2>/dev/null)"
					lock_age="$(nordvpn_easy_lock_wedge_age_seconds "$LOCK_DIR" "$lock_started_at")"
					case "$lock_age" in
						''|*[!0-9]*) lock_age=0 ;;
					esac
					lock_ttl="$(nordvpn_easy_lock_ttl_seconds)"
					# TTL REAPER: a live holder WITHIN the TTL is a legitimately
					# in-flight operation -> report contention. A live holder aged
					# PAST a generous TTL (well above any real apply) is WEDGED (a
					# D-state syscall, a hung child) and would otherwise block every
					# future operation forever, so fall through to the mv-aside
					# recovery, which mints a NEW token. This is safe because the S7a
					# effect fence neutralizes the wedged holder: on thaw its
					# owner_assert fails against the new token, so it can neither
					# release the lock nor commit/ifupdown the runtime. The recovery's
					# live-different-pid restore still protects a DIFFERENT holder that
					# legitimately re-acquired in the window (moved_pid != lock_pid),
					# so only this exact wedged holder is reaped.
					if [ "$lock_age" -le "$lock_ttl" ]; then
						nordvpn_easy_log_blocker 'runtime' "execution lock is already held by PID $lock_pid (action=${lock_action:-unknown}, age=${lock_age}s)"
						return 2
					fi
					stale_reason="owner PID $lock_pid alive but wedged (age=${lock_age}s > TTL ${lock_ttl}s); reclaiming"
				else
					stale_reason="owner PID $lock_pid is no longer alive"
				fi
				;;
		esac
	fi

	nordvpn_easy_log_phase 'runtime' "recovering stale execution lock at $LOCK_DIR (reason: ${stale_reason})"

	# Atomically claim the stale dir by renaming it aside (mkdir/rename are the
	# only atomic primitives here): only one recoverer wins the mv, and we never
	# rm -rf a directory that a concurrent process may have just legitimately
	# created. If the moved dir turns out to belong to a different, still-live
	# PID, a real holder re-acquired during the window: restore it and yield.
	local recover_dir="${LOCK_DIR}.recover.$$"
	local moved_pid=''
	rm -rf "$recover_dir" 2>/dev/null || true
	if ! mv "$LOCK_DIR" "$recover_dir" 2>/dev/null; then
		nordvpn_easy_log_blocker 'runtime' "lost race recovering stale lock at $LOCK_DIR"
		return 2
	fi
	moved_pid="$(cat "${recover_dir}/pid" 2>/dev/null)"
	if [ -n "$moved_pid" ] && [ "$moved_pid" != "$lock_pid" ] && kill -0 "$moved_pid" 2>/dev/null; then
		mv "$recover_dir" "$LOCK_DIR" 2>/dev/null || rm -rf "$recover_dir" 2>/dev/null || true
		nordvpn_easy_log_blocker 'runtime' "execution lock re-acquired by live PID $moved_pid during recovery; yielding"
		return 2
	fi
	rm -rf "$recover_dir" 2>/dev/null || true

	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		if [ -d "$LOCK_DIR" ]; then
			nordvpn_easy_log_blocker 'runtime' "lost race recovering stale lock at $LOCK_DIR"
			return 2
		fi
		nordvpn_easy_log_blocker 'runtime' "could not recreate execution lock directory at $LOCK_DIR"
		return 1
	fi
	owner_token="$(nordvpn_easy_new_owner_token)"
	if ! nordvpn_easy_write_lock_metadata "$LOCK_DIR" "$$" "${ACTION:-unknown}" "$now_ts" 'stale_recovered' "$owner_token"; then
		rm -rf "$LOCK_DIR" 2>/dev/null
		nordvpn_easy_log_blocker 'runtime' "could not write execution lock metadata into $LOCK_DIR"
		return 1
	fi

	local verify_pid
	verify_pid="$(cat "$lock_pid_file" 2>/dev/null)"
	if [ "$verify_pid" != "$$" ]; then
		nordvpn_easy_log_blocker 'runtime' "lock ownership verification failed (expected $$, got ${verify_pid:-empty})"
		rm -rf "$LOCK_DIR" 2>/dev/null
		return 2
	fi

	NORDVPN_EASY_OWNER_TOKEN="$owner_token"
	LOCK_ACQUIRED=1
	nordvpn_easy_install_exit_trap
	nordvpn_easy_log_phase 'runtime' "recovered and acquired execution lock at $LOCK_DIR (reason: ${stale_reason})"
	return 0
}

# Bounded blocking acquire. Default behavior is unchanged (one attempt, fail
# fast): NORDVPN_EASY_LOCK_WAIT_SECONDS<=0 => single try. Deliberate, user-driven
# apply actions set a positive wait (via the init transaction lock) so a TRANSIENT
# holder -- a slow stop_vpn teardown, an in-flight reconcile -- just delays this
# connect for a few seconds instead of aborting the apply and leaving the runtime
# torn down. Only a busy result (rc 2) is retried; acquired/adopted/recovered (0)
# and hard errors (1) return immediately. Each retry re-runs the full try (incl.
# stale-lock recovery), so a genuinely dead lock is recovered on a later pass and
# we never wait forever on a dead owner.
nordvpn_easy_acquire_lock() {
	local wait_seconds="${NORDVPN_EASY_LOCK_WAIT_SECONDS:-0}"
	local poll_interval="${NORDVPN_EASY_LOCK_WAIT_INTERVAL:-1}"
	local rc=0
	local now_ts=0
	local deadline=0
	local logged_wait=0
	local iters=0
	local max_iters=0

	case "$wait_seconds" in
		''|*[!0-9]*) wait_seconds=0 ;;
	esac
	case "$poll_interval" in
		''|*[!0-9]*|0) poll_interval=1 ;;
	esac

	if [ "$wait_seconds" -le 0 ]; then
		_nordvpn_easy_try_acquire_lock
		return $?
	fi

	now_ts="$(date +%s 2>/dev/null || printf '0')"
	case "$now_ts" in ''|*[!0-9]*) now_ts=0 ;; esac
	deadline=$((now_ts + wait_seconds))
	# Iteration cap bounds the loop independently of the wall clock, so a broken
	# or non-monotonic `date +%s` (which could leave the deadline check never
	# true) can never produce an unbounded wait. With poll_interval seconds per
	# pass this caps real wait near wait_seconds.
	max_iters=$(( (wait_seconds / poll_interval) + 5 ))

	while :; do
		_nordvpn_easy_try_acquire_lock
		rc=$?
		# 0 = acquired/adopted/recovered, 1 = hard error: both terminal.
		[ "$rc" -ne 2 ] && return "$rc"

		iters=$((iters + 1))
		now_ts="$(date +%s 2>/dev/null || printf '0')"
		case "$now_ts" in ''|*[!0-9]*) now_ts=0 ;; esac
		{ [ "$now_ts" -ge "$deadline" ] || [ "$iters" -ge "$max_iters" ]; } && return 2

		if [ "$logged_wait" -eq 0 ]; then
			nordvpn_easy_log_phase 'runtime' "execution lock busy at $LOCK_DIR; waiting up to ${wait_seconds}s for the current operation to finish"
			logged_wait=1
		fi
		sleep "$poll_interval"
	done
}

nordvpn_easy_on_exit() {
	nordvpn_easy_release_lock
	nordvpn_easy_cleanup_temp_paths
}

nordvpn_easy_on_signal() {
	local signal_num="${1:-0}"

	trap - EXIT HUP INT TERM
	nordvpn_easy_on_exit

	case "$signal_num" in
		''|*[!0-9]*)
			exit 1
			;;
		*)
			exit $((128 + signal_num))
			;;
	esac
}

nordvpn_easy_sanitize_diagnostics_stream() {
	sed \
		-e "s/\([._[:alnum:]-]*nordvpn_token='\)[^']*'/\1***REDACTED***'/g" \
		-e "s/\([._[:alnum:]-]*private_key='\)[^']*'/\1***REDACTED***'/g" \
		-e "s/\([._[:alnum:]-]*preshared_key='\)[^']*'/\1***REDACTED***'/g" \
		-e 's/\("nordvpn_token"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1***REDACTED***"/g' \
		-e 's/\("private_key"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1***REDACTED***"/g' \
		-e 's/\("nordlynx_private_key"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1***REDACTED***"/g' \
		-e 's/\("preshared_key"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1***REDACTED***"/g' \
		-e 's/\("access_token"[[:space:]]*:[[:space:]]*"\)[^"]*"/\1***REDACTED***"/g' \
		-e 's/\(token:\)[^"[:space:]]*/\1***REDACTED***/g' \
		-e 's/\(Authorization:[[:space:]]*Basic[[:space:]]\)[^"[:space:]]*/\1***REDACTED***/g' \
		-e 's/\(Authorization:[[:space:]]*Bearer[[:space:]]\)[^"[:space:]]*/\1***REDACTED***/g'
}

# /etc/config/network holds the NordLynx private key and /etc/config/nordvpn_easy
# holds the account token. Keep them readable by root only. uci commit preserves
# an existing file's mode, so asserting 0600 after our own commits keeps the
# secrets protected across subsequent commits (including LuCI's).
nordvpn_easy_harden_secret_config_perms() {
	local name=''

	for name in "$@"; do
		case "$name" in
			network|nordvpn_easy) ;;
			*) continue ;;
		esac
		[ -e "/etc/config/$name" ] || continue
		chmod 0600 "/etc/config/$name" 2>/dev/null || true
	done

	return 0
}

nordvpn_easy_diagnostics_section() {
	printf '\n## %s\n' "$1"
}

nordvpn_easy_print_sanitized_command() {
	local title="$1"
	shift

	nordvpn_easy_diagnostics_section "$title"
	"$@" 2>&1 | nordvpn_easy_sanitize_diagnostics_stream || true
}

nordvpn_easy_diagnostics_csv_append() {
	if [ -n "$1" ]; then
		printf '%s,%s' "$1" "$2"
	else
		printf '%s' "$2"
	fi
}

nordvpn_easy_wireguard_peer_section_name() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"
	local peer_section=''

	if uci -q get "network.${vpn_if}server.endpoint_host" >/dev/null 2>&1; then
		printf '%s\n' "${vpn_if}server"
		return 0
	fi

	peer_section="$(
		uci show network 2>/dev/null | awk -F '[.=]' -v target="wireguard_${vpn_if}" '
			$1 == "network" && $3 == target {
				print $2
				exit
			}
		'
	)"
	[ -n "$peer_section" ] || return 1
	printf '%s\n' "$peer_section"
}

nordvpn_easy_peer_section_name() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"

	nordvpn_easy_wireguard_peer_section_name "$vpn_if"
}

nordvpn_easy_diagnostics_peer_section_name() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"

	nordvpn_easy_wireguard_peer_section_name "$vpn_if"
}

nordvpn_easy_export_diagnostics_log() {
	local service_name="${1:-nordvpn-easy}"
	local temp_dir=''
	local tmp_log=''
	local tail_lines="${NORDVPN_EASY_DIAGNOSTICS_TAIL_LINES:-2000}"
	local tail_rc=0
	local vpn_if="${VPN_IF:-wg0}"
	local firewall_zone=''

	case "$tail_lines" in
		''|*[!0-9]*)
			tail_lines='2000'
			;;
	esac

	nordvpn_easy_mktemp_dir 'diagnostics' temp_dir || return 1
	tmp_log="$(nordvpn_easy_temp_file_path "$temp_dir" "${service_name}.diagnostics.log")"

	printf '# NordVPN Easy Diagnostics\n'
	printf 'generated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date 2>/dev/null || printf '%s' 'unknown')"
	printf 'vpn_if=%s\n' "$vpn_if"

	if command -v nordvpn_easy_emit_status_json >/dev/null 2>&1; then
		nordvpn_easy_print_sanitized_command 'Runtime status JSON' nordvpn_easy_emit_status_json
	fi

	if command -v nordvpn_easy_diagnostics_print_health_summary >/dev/null 2>&1; then
		nordvpn_easy_diagnostics_print_health_summary "$vpn_if" | nordvpn_easy_sanitize_diagnostics_stream
		nordvpn_easy_diagnostics_print_connectivity_assessment "$vpn_if" | nordvpn_easy_sanitize_diagnostics_stream
		nordvpn_easy_diagnostics_print_runtime_caches "$vpn_if" | nordvpn_easy_sanitize_diagnostics_stream
	else
		nordvpn_easy_diagnostics_section 'Health summary'
		printf '%s\n' 'diagnostics module not loaded'
	fi

	if command -v wg >/dev/null 2>&1; then
		nordvpn_easy_print_sanitized_command 'WireGuard status' wg show "$vpn_if"
	else
		nordvpn_easy_diagnostics_section 'WireGuard status'
		printf '%s\n' 'wg command not found'
	fi

	if command -v uci >/dev/null 2>&1; then
		nordvpn_easy_print_sanitized_command 'UCI nordvpn_easy' uci show nordvpn_easy
		nordvpn_easy_print_sanitized_command "UCI network.${vpn_if}" uci show "network.${vpn_if}"
		nordvpn_easy_print_sanitized_command "UCI network.${vpn_if}server" uci show "network.${vpn_if}server"

		if command -v nordvpn_easy_find_firewall_zone_section >/dev/null 2>&1; then
			firewall_zone="$(nordvpn_easy_find_firewall_zone_section "$vpn_if" 2>/dev/null || true)"
			if [ -n "$firewall_zone" ]; then
				nordvpn_easy_print_sanitized_command "UCI firewall zone for ${vpn_if}" uci show "$firewall_zone"
			fi
		fi
	fi

	if command -v ip >/dev/null 2>&1; then
		nordvpn_easy_print_sanitized_command "IP link ${vpn_if}" ip -o link show dev "$vpn_if"
		nordvpn_easy_print_sanitized_command "Routes via ${vpn_if}" ip route show dev "$vpn_if"
		nordvpn_easy_print_sanitized_command 'Default routes' ip route show default
	fi

	nordvpn_easy_diagnostics_section 'DNS'
	{
		printf '%s\n' '# /etc/resolv.conf'
		cat /etc/resolv.conf 2>/dev/null || true
		printf '%s\n' '# /tmp/resolv.conf.d/resolv.conf.auto'
		cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || true
	} | nordvpn_easy_sanitize_diagnostics_stream

	nordvpn_easy_diagnostics_section 'NordVPN Easy log'
	if command -v logread >/dev/null 2>&1; then
		logread -e "$service_name" > "$tmp_log" || {
			rm -rf -- "$temp_dir"
			return 1
		}

		tail -n "$tail_lines" "$tmp_log" | nordvpn_easy_sanitize_diagnostics_stream || tail_rc=$?
	else
		printf '%s\n' 'logread command not found'
	fi

	rm -rf -- "$temp_dir"
	return "$tail_rc"
}
