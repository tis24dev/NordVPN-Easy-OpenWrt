#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# S7 increment 5c: the supervised apply state machine (lib/supervise.sh
# nordvpn_easy_supervise + open_txn + reap_stale + converge + phase bodies). Covers
# the flag-gate inertness, the disable refusal, the phase order, the B1
# fetch-before-teardown gate + failure classification, open_txn adopt/fresh, and the
# reap-stale foreign-only rule. The machine is exercised with the provision helpers
# stubbed; the direct-function groups run first (real functions), then the
# orchestration groups override the phase bodies.

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "expected: [$1]" >&2
		printf '%s\n' "actual:   [$2]" >&2
		exit 1
	fi
}

fail() {
	printf '%s\n' "FAIL: $1" >&2
	exit 1
}

NORDVPN_EASY_JOURNAL_FILE="$TMP_DIR/journal"
NORDVPN_EASY_RUN_DIR="$TMP_DIR/rundir"
NORDVPN_EASY_PHASE_BACKOFF_BASE=0
CALL_LOG="$TMP_DIR/calls"
SENTINEL="$TMP_DIR/teardown-ran"
LOCK_DIR="$TMP_DIR/lock"
mkdir -p "$LOCK_DIR"
# The last-error cache the supervise epilogue checks (so it does not clobber a detail
# a phase already recorded); point it at the same temp file the record_last_error stub
# writes, so the epilogue's `-s` check and the stub agree.
NORDVPN_EASY_LAST_ERROR_CACHE="$TMP_DIR/last_error_cache"

# shellcheck disable=SC1090
. "$LIB/journal.sh"
# shellcheck disable=SC1090
. "$LIB/common.sh"
# shellcheck disable=SC1090
. "$LIB/supervise.sh"

# Silence the loggers (defined here so common.sh/supervise.sh calls are quiet).
nordvpn_easy_log() { :; }
nordvpn_easy_log_phase() { :; }
nordvpn_easy_log_blocker() { :; }
nordvpn_easy_record_last_error() { printf '%s\n' "${1:-}" > "$TMP_DIR/last_error_cache"; }

reset_journal() {
	rm -f "$NORDVPN_EASY_JOURNAL_FILE" "$CALL_LOG" "$SENTINEL" "$NORDVPN_EASY_RUN_DIR/self-ifevent" "$NORDVPN_EASY_LAST_ERROR_CACHE"
	NORDVPN_EASY_OWNER_TOKEN=''
}

# =============================================================================
# S8: record_error writes BOTH the journal (classification token) AND the runtime
# last-error CACHE (the human message the JS Save&Apply surfaces via status.last_error).
# =============================================================================
reset_journal
rm -f "$TMP_DIR/last_error_cache"
nordvpn_easy_journal_write_full 'phase=converge' 'txn_id=T-err'
nordvpn_easy_supervise_record_error 'network.fetch' 'provision prerequisite fetch failed'
assert_eq 'network.fetch' "$(nordvpn_easy_journal_get last_error)" 'S8: record_error writes the classification token to the journal'
[ -r "$TMP_DIR/last_error_cache" ] || fail 'S8: record_error must write the runtime last-error cache'
grep -q 'provision prerequisite fetch failed' "$TMP_DIR/last_error_cache" || fail 'S8: the cache carries the human failure detail (surfaced as status.last_error)'

# =============================================================================
# GROUP 1: reap_stale_journal -- FAILED only a FOREIGN, dead-owner, non-terminal
# record; leave a same-target one (open_txn adopts it) and a live/terminal one.
# =============================================================================
reset_journal
# (a) foreign target + dead owner + non-terminal -> reaped (phase=failed)
nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-foreign' 'target_fingerprint=fp-OLD:1' 'owner_pid=999999' 'started_at=1'
nordvpn_easy_supervise_reap_stale_journal 'fp-NEW:1'
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'reap stamps a foreign dead non-terminal record FAILED'
assert_eq 'local.reaped_stale' "$(nordvpn_easy_journal_get last_error)" 'reaped record carries the reaped_stale cause'

# (b) SAME target + dead owner -> NOT reaped (open_txn will adopt)
reset_journal
nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-same' 'target_fingerprint=fp-NEW:1' 'owner_pid=999999' 'started_at=1'
nordvpn_easy_supervise_reap_stale_journal 'fp-NEW:1'
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'a SAME-target record is not reaped (adopted later)'

# (c) foreign target + LIVE owner ($$) -> NOT reaped (owner fence / TTL reaper owns it)
reset_journal
nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-live' 'target_fingerprint=fp-OLD:1' "owner_pid=$$" 'started_at=1'
nordvpn_easy_supervise_reap_stale_journal 'fp-NEW:1'
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'a live foreign owner is not reaped'

# (d) foreign target but TERMINAL (done) -> NOT reaped
reset_journal
nordvpn_easy_journal_write_full 'phase=done' 'txn_id=T-done' 'target_fingerprint=fp-OLD:1' 'owner_pid=999999' 'started_at=1'
nordvpn_easy_supervise_reap_stale_journal 'fp-NEW:1'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a terminal record is not reaped'

# =============================================================================
# GROUP 2: open_txn -- ADOPT a same-target non-terminal record (keep txn_id, CLEAR
# fetch_done); otherwise open a FRESH transaction (new txn_id, empty fetch_done).
# =============================================================================
# adopt
reset_journal
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=T-adopt' 'target_fingerprint=fp-NEW:1' 'started_at=111' 'fetch_done=1'
nordvpn_easy_supervise_open_txn 'fp-NEW:1'
assert_eq 'T-adopt' "$(nordvpn_easy_journal_get txn_id)" 'open_txn adopts the same-target txn_id'
assert_eq '111' "$(nordvpn_easy_journal_get started_at)" 'open_txn preserves started_at on adopt'
assert_eq 'applying' "$(nordvpn_easy_journal_get phase)" 'open_txn sets phase=applying on adopt'
assert_eq '' "$(nordvpn_easy_journal_get fetch_done)" 'open_txn CLEARS fetch_done on adopt (must re-fetch before teardown)'

# fresh: terminal predecessor -> new txn
reset_journal
nordvpn_easy_journal_write_full 'phase=done' 'txn_id=T-old' 'target_fingerprint=fp-NEW:1' 'fetch_done=1'
nordvpn_easy_supervise_open_txn 'fp-NEW:1'
new_txn="$(nordvpn_easy_journal_get txn_id)"
[ -n "$new_txn" ] && [ "$new_txn" != 'T-old' ] || fail 'open_txn opens a FRESH txn after a terminal predecessor'
assert_eq '' "$(nordvpn_easy_journal_get fetch_done)" 'a fresh txn has fetch_done cleared'

# fresh: different target -> new txn
reset_journal
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=T-other' 'target_fingerprint=fp-DIFFERENT:1' 'fetch_done=1'
nordvpn_easy_supervise_open_txn 'fp-NEW:1'
new_txn2="$(nordvpn_easy_journal_get txn_id)"
[ "$new_txn2" != 'T-other' ] || fail 'open_txn opens a fresh txn for a different target (no cross-target adopt)'

# =============================================================================
# GROUP 3: _supervise_converge -- B1 gate (a FETCH failure must NOT tear down) +
# failure classification tokens. Called directly (no run_phase subshell) so the
# journal side effects are visible.
# =============================================================================
VPN_IF='wg0'
POST_RESTART_DELAY='0'
# provision-helper stubs (controllable via *_RC)
nordvpn_easy_fetch_provision_prerequisites() { printf 'fetch\n' >> "$CALL_LOG"; return "${FETCH_RC:-0}"; }
nordvpn_easy_teardown_vpn() { printf 'teardown\n' >> "$CALL_LOG"; : > "$SENTINEL"; return "${TEARDOWN_RC:-0}"; }
nordvpn_easy_configure_vpn_interface_no_bringup() { printf 'configure\n' >> "$CALL_LOG"; return "${CONFIGURE_RC:-0}"; }
nordvpn_easy_bring_up_vpn_interface() { printf 'bringup\n' >> "$CALL_LOG"; return "${BRINGUP_RC:-0}"; }
nordvpn_easy_wait_for_vpn_connectivity() { printf 'wait\n' >> "$CALL_LOG"; return "${WAIT_RC:-0}"; }
nordvpn_easy_reset_forwarded_conntrack() { printf 'reset\n' >> "$CALL_LOG"; }
nordvpn_easy_log_vpn_interface_state() { :; }

# B1: fetch fails -> teardown NEVER runs, classified network.fetch
reset_journal
FETCH_RC=1 TEARDOWN_RC=0 CONFIGURE_RC=0 BRINGUP_RC=0 WAIT_RC=0
cvg_rc=0
_supervise_converge || cvg_rc=$?
[ "$cvg_rc" -ne 0 ] || fail 'converge must fail when fetch fails'
[ ! -f "$SENTINEL" ] || fail 'B1 VIOLATION: teardown ran after a failed fetch'
assert_eq 'network.fetch' "$(nordvpn_easy_journal_get last_error)" 'a fetch failure is classified network.fetch (retryable)'

# happy path: full order fetch->teardown->configure->bringup->wait, fetch_done set
reset_journal
FETCH_RC=0 TEARDOWN_RC=0 CONFIGURE_RC=0 BRINGUP_RC=0 WAIT_RC=0
_supervise_converge || fail 'converge must succeed when every step succeeds'
assert_eq 'fetch teardown configure bringup wait reset' "$(tr '\n' ' ' < "$CALL_LOG" | sed 's/ $//')" 'converge runs the steps in order, resetting forwarded flows once the tunnel is up'
[ -f "$SENTINEL" ] || fail 'teardown must run on the happy path (fetch_done was set)'
# inc 7: converge marks the self-ifevent sentinel before bring-up.
[ -r "$NORDVPN_EASY_RUN_DIR/self-ifevent" ] || fail 'inc7: converge must mark the self-ifevent sentinel'
grep -q '^iface=wg0$' "$NORDVPN_EASY_RUN_DIR/self-ifevent" || fail 'inc7: the sentinel names the vpn interface'
se_expires="$(sed -n 's/^expires=//p' "$NORDVPN_EASY_RUN_DIR/self-ifevent")"
case "$se_expires" in ''|*[!0-9]*) fail 'inc7: the sentinel has a numeric expiry' ;; esac
[ "$se_expires" -gt "$(date +%s)" ] || fail 'inc7: the sentinel expiry is in the future'

# teardown fails -> config.* ... actually local.teardown (fail-fast), no configure
reset_journal
FETCH_RC=0 TEARDOWN_RC=1
tdrc=0
_supervise_converge || tdrc=$?
[ "$tdrc" -ne 0 ] || fail 'converge must fail when teardown fails'
assert_eq 'local.teardown' "$(nordvpn_easy_journal_get last_error)" 'a teardown failure is classified local.teardown (fail-fast)'
! grep -q '^configure$' "$CALL_LOG" || fail 'configure must not run after a teardown failure'

# configure fails -> config.configure
reset_journal
FETCH_RC=0 TEARDOWN_RC=0 CONFIGURE_RC=1
cfrc=0
_supervise_converge || cfrc=$?
[ "$cfrc" -ne 0 ] || fail 'converge must fail when configure fails'
assert_eq 'config.configure' "$(nordvpn_easy_journal_get last_error)" 'a configure failure is classified config.configure'

# wait fails -> network.connectivity (retryable)
reset_journal
FETCH_RC=0 TEARDOWN_RC=0 CONFIGURE_RC=0 BRINGUP_RC=0 WAIT_RC=1
wrc=0
_supervise_converge || wrc=$?
[ "$wrc" -ne 0 ] || fail 'converge must fail when connectivity wait fails'
assert_eq 'network.connectivity' "$(nordvpn_easy_journal_get last_error)" 'a connectivity timeout is classified network.connectivity (retryable)'
unset FETCH_RC TEARDOWN_RC CONFIGURE_RC BRINGUP_RC WAIT_RC

# =============================================================================
# GROUP 3c (status honesty): _supervise_converge stamps the honest sub_phase at
# each real sub-step boundary (fetching->tearing_down->configuring->connecting),
# a converge RETRY re-stamps fetching at the TOP, and the terminal writes drop it.
# Capture the sub_phase VISIBLE at each helper call via a capturing stub.
# =============================================================================
SUBPHASE_LOG="$TMP_DIR/subphase"
nordvpn_easy_fetch_provision_prerequisites() { printf 'fetch=%s\n' "$(nordvpn_easy_journal_get sub_phase)" >> "$SUBPHASE_LOG"; return "${FETCH_RC:-0}"; }
nordvpn_easy_teardown_vpn() { printf 'teardown=%s\n' "$(nordvpn_easy_journal_get sub_phase)" >> "$SUBPHASE_LOG"; : > "$SENTINEL"; return "${TEARDOWN_RC:-0}"; }
nordvpn_easy_configure_vpn_interface_no_bringup() { printf 'configure=%s\n' "$(nordvpn_easy_journal_get sub_phase)" >> "$SUBPHASE_LOG"; return "${CONFIGURE_RC:-0}"; }
nordvpn_easy_bring_up_vpn_interface() { printf 'bringup=%s\n' "$(nordvpn_easy_journal_get sub_phase)" >> "$SUBPHASE_LOG"; return "${BRINGUP_RC:-0}"; }
nordvpn_easy_wait_for_vpn_connectivity() { printf 'wait=%s\n' "$(nordvpn_easy_journal_get sub_phase)" >> "$SUBPHASE_LOG"; return "${WAIT_RC:-0}"; }

reset_journal
rm -f "$SUBPHASE_LOG"
FETCH_RC=0 TEARDOWN_RC=0 CONFIGURE_RC=0 BRINGUP_RC=0 WAIT_RC=0
_supervise_converge || fail 'converge must succeed (subphase group)'
assert_eq 'fetching'     "$(sed -n 's/^fetch=//p' "$SUBPHASE_LOG")"     'sub_phase is fetching when FETCH runs'
assert_eq 'tearing_down' "$(sed -n 's/^teardown=//p' "$SUBPHASE_LOG")"  'sub_phase is tearing_down when TEARDOWN runs'
assert_eq 'configuring'  "$(sed -n 's/^configure=//p' "$SUBPHASE_LOG")" 'sub_phase is configuring when CONFIGURE runs'
assert_eq 'connecting'   "$(sed -n 's/^bringup=//p' "$SUBPHASE_LOG")"   'sub_phase is connecting when BRING-UP runs'
assert_eq 'connecting'   "$(sed -n 's/^wait=//p' "$SUBPHASE_LOG")"      'sub_phase stays connecting through the connectivity wait'
assert_eq 'connecting'   "$(nordvpn_easy_journal_get sub_phase)"        'sub_phase lands on connecting after a full converge'

# A converge RETRY re-stamps fetching at the TOP, resetting a STALE sub_phase from
# a prior attempt (e.g. connecting) so the second attempt is honest from the start.
reset_journal
rm -f "$SUBPHASE_LOG"
nordvpn_easy_journal_write_full 'phase=converge' 'txn_id=T-retry' 'sub_phase=connecting'
FETCH_RC=0 TEARDOWN_RC=0 CONFIGURE_RC=0 BRINGUP_RC=0 WAIT_RC=0
_supervise_converge || fail 'converge retry must succeed'
assert_eq 'fetching' "$(sed -n 's/^fetch=//p' "$SUBPHASE_LOG")" 'a converge retry re-stamps sub_phase=fetching at the top (resets a stale connecting)'
unset FETCH_RC TEARDOWN_RC CONFIGURE_RC BRINGUP_RC WAIT_RC

# open_txn (adopt) CLEARS sub_phase so an adopted re-entry never inherits a stale
# sub_phase from a crashed predecessor.
reset_journal
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=T-sp-adopt' 'target_fingerprint=fp-NEW:1' 'started_at=222' 'sub_phase=connecting'
nordvpn_easy_supervise_open_txn 'fp-NEW:1'
assert_eq 'T-sp-adopt' "$(nordvpn_easy_journal_get txn_id)" 'open_txn adopts the same-target txn (subphase group)'
assert_eq '' "$(nordvpn_easy_journal_get sub_phase)" 'open_txn CLEARS sub_phase on adopt'

# open_txn (fresh) also leaves sub_phase empty.
reset_journal
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=T-sp-other' 'target_fingerprint=fp-DIFFERENT:1' 'sub_phase=tearing_down'
nordvpn_easy_supervise_open_txn 'fp-NEW:1'
assert_eq '' "$(nordvpn_easy_journal_get sub_phase)" 'a FRESH open_txn leaves sub_phase empty'

# journal_finish (done/failed) DROPS sub_phase via its full-document terminal write.
reset_journal
nordvpn_easy_journal_write_full 'phase=converge' 'txn_id=T-sp-fin' 'sub_phase=connecting'
nordvpn_easy_journal_finish 0 'ES'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'journal_finish(0) stamps done (subphase group)'
assert_eq '' "$(nordvpn_easy_journal_get sub_phase)" 'journal_finish(0) drops sub_phase (terminal full-document write)'
reset_journal
nordvpn_easy_journal_write_full 'phase=converge' 'txn_id=T-sp-fin2' 'sub_phase=tearing_down'
nordvpn_easy_journal_finish 1 ''
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'journal_finish(1) stamps failed (subphase group)'
assert_eq '' "$(nordvpn_easy_journal_get sub_phase)" 'journal_finish(1) drops sub_phase (terminal full-document write)'

# Restore the original GROUP 3 helper stubs (write CALL_LOG) so a later group that
# re-uses them is unaffected.
nordvpn_easy_fetch_provision_prerequisites() { printf 'fetch\n' >> "$CALL_LOG"; return "${FETCH_RC:-0}"; }
nordvpn_easy_teardown_vpn() { printf 'teardown\n' >> "$CALL_LOG"; : > "$SENTINEL"; return "${TEARDOWN_RC:-0}"; }
nordvpn_easy_configure_vpn_interface_no_bringup() { printf 'configure\n' >> "$CALL_LOG"; return "${CONFIGURE_RC:-0}"; }
nordvpn_easy_bring_up_vpn_interface() { printf 'bringup\n' >> "$CALL_LOG"; return "${BRINGUP_RC:-0}"; }
nordvpn_easy_wait_for_vpn_connectivity() { printf 'wait\n' >> "$CALL_LOG"; return "${WAIT_RC:-0}"; }

# =============================================================================
# GROUP 3b: _supervise_persist arms the kill-switch EARLY (inc 6) -- it stages
# enabled=1, commits, THEN calls ensure_vpn_firewall so the teardown->configure
# window in CONVERGE is already protected. A firewall arm failure fails the phase.
# =============================================================================
uci() { return 0; }
nordvpn_easy_fenced_uci_commit() { return 0; }
FW_ARMED="$TMP_DIR/fw-armed"
FW_RC=0
nordvpn_easy_ensure_vpn_firewall() { : > "$FW_ARMED"; return "${FW_RC:-0}"; }

reset_journal
rm -f "$FW_ARMED"
_supervise_persist || fail 'persist must succeed with the stubs'
[ -f "$FW_ARMED" ] || fail 'inc6: persist must arm the kill-switch (ensure_vpn_firewall) early'

reset_journal
rm -f "$FW_ARMED"
FW_RC=1
pf_rc=0
_supervise_persist || pf_rc=$?
[ "$pf_rc" -ne 0 ] || fail 'inc6: a kill-switch arm failure must fail persist'
assert_eq 'local.persist' "$(nordvpn_easy_journal_get last_error)" 'inc6: a firewall arm failure is classified local.persist'
FW_RC=0

# The kill-switch is armed AFTER the enabled commit: a commit failure must fail
# persist WITHOUT arming the firewall (pins the arm-after-commit order).
reset_journal
rm -f "$FW_ARMED"
nordvpn_easy_fenced_uci_commit() { return 1; }
cf_rc=0
_supervise_persist || cf_rc=$?
[ "$cf_rc" -ne 0 ] || fail 'inc6: persist must fail when the enabled commit fails'
[ ! -f "$FW_ARMED" ] || fail 'inc6: the kill-switch must NOT be armed when the enabled commit failed (arm is AFTER commit)'
nordvpn_easy_fenced_uci_commit() { return 0; }

# =============================================================================
# GROUP 4: nordvpn_easy_supervise orchestration -- the DESIRED_ENABLED gate, disable
# refusal, phase order. The phase BODIES are overridden with loggers so this exercises
# the orchestration (gate, order, journal finish), not the provision internals.
# =============================================================================
nordvpn_easy_target_identity() { printf '%s' "${TARGET:-fp-NEW:1}"; }
_supervise_validate() { printf 'validate\n' >> "$CALL_LOG"; return "${P_VALIDATE_RC:-0}"; }
_supervise_persist() { printf 'persist\n' >> "$CALL_LOG"; return "${P_PERSIST_RC:-0}"; }
_supervise_hooks() { printf 'hooks\n' >> "$CALL_LOG"; return "${P_HOOKS_RC:-0}"; }
_supervise_converge() { printf 'converge\n' >> "$CALL_LOG"; return "${P_CONVERGE_RC:-0}"; }
_supervise_verify() { printf 'verify\n' >> "$CALL_LOG"; return "${P_VERIFY_RC:-0}"; }

# disable gate: DESIRED_ENABLED=0 -> no-op, no txn, no phase body (the stop path
# handles a disable, not the supervisor).
reset_journal
DESIRED_ENABLED='0'
dis_rc=0
nordvpn_easy_supervise || dis_rc=$?
assert_eq '0' "$dis_rc" 'supervise refuses a disable apply (returns 0)'
[ ! -f "$CALL_LOG" ] || fail 'a disable apply must not run any phase (handled by the stop path)'
[ ! -f "$NORDVPN_EASY_JOURNAL_FILE" ] || fail 'a disable apply must not open a journal transaction'

# happy path: full phase order + journal done
reset_journal
DESIRED_ENABLED='1' TARGET='fp-NEW:1'
P_VALIDATE_RC=0 P_PERSIST_RC=0 P_HOOKS_RC=0 P_CONVERGE_RC=0 P_VERIFY_RC=0
nordvpn_easy_supervise || fail 'a fully-successful supervised apply must return 0'
assert_eq 'validate persist hooks converge verify' "$(tr '\n' ' ' < "$CALL_LOG" | sed 's/ $//')" 'supervise runs the phases in order'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a successful apply finishes the journal as done'

# inc 8: the terminal finish is owner-FENCED. A superseded owner (token mismatch) must
# NOT stamp the journal done at the finish site -- proves nordvpn_easy_supervise calls
# the fenced_journal_finish wrapper, not the unfenced journal_finish.
reset_journal
DESIRED_ENABLED='1' TARGET='fp-NEW:1'
mkdir -p "$LOCK_DIR"
printf '%s\n' 'someone-else' > "$LOCK_DIR/token"
NORDVPN_EASY_OWNER_TOKEN='mine'
nordvpn_easy_supervise >/dev/null 2>&1 || true
[ "$(nordvpn_easy_journal_get phase)" != 'done' ] || fail 'inc8: a superseded owner must NOT stamp the terminal journal done (fenced finish site)'
NORDVPN_EASY_OWNER_TOKEN=''
rm -f "$LOCK_DIR/token"

# hooks non-fatal: a hooks failure does NOT abort the apply
reset_journal
DESIRED_ENABLED='1' P_HOOKS_RC=1
nordvpn_easy_supervise || fail 'a hooks failure must be non-fatal (apply still succeeds)'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a hooks failure still finishes done'
grep -q '^converge$' "$CALL_LOG" || fail 'converge must still run after a non-fatal hooks failure'

# verify non-fatal: a verify failure does NOT fail the apply
reset_journal
DESIRED_ENABLED='1' P_HOOKS_RC=0 P_VERIFY_RC=1
nordvpn_easy_supervise || fail 'a verify failure must be non-fatal'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a verify failure still finishes done'

# a fatal phase (converge) fails -> journal failed, rc!=0
reset_journal
DESIRED_ENABLED='1' P_VERIFY_RC=0 P_CONVERGE_RC=1
fat_rc=0
nordvpn_easy_supervise || fat_rc=$?
[ "$fat_rc" -ne 0 ] || fail 'a converge failure must make the apply fail'
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'a fatal phase failure finishes the journal as failed'
grep -q '^verify$' "$CALL_LOG" && fail 'verify must NOT run after a converge failure' || :

# S8: the fatal epilogue must NOT clobber a human detail a phase already recorded in the
# last-error cache (the reason the LuCI Save&Apply surfaces). Pre-seed the cache, run a
# failing apply -> the detail survives.
reset_journal
printf 'supervise: provision prerequisite fetch failed\n' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
DESIRED_ENABLED='1' P_CONVERGE_RC=1
nordvpn_easy_supervise >/dev/null 2>&1 || :
grep -q 'provision prerequisite fetch failed' "$NORDVPN_EASY_LAST_ERROR_CACHE" || fail 'S8: the epilogue must not clobber a detail already in the last-error cache'
# But with an EMPTY cache the epilogue DOES record a non-generic fallback cause.
reset_journal
DESIRED_ENABLED='1' P_CONVERGE_RC=1
nordvpn_easy_supervise >/dev/null 2>&1 || :
grep -q 'convergence failed' "$NORDVPN_EASY_LAST_ERROR_CACHE" || fail 'S8: with an empty cache the epilogue records a non-generic fallback'
P_CONVERGE_RC=0

# PR #81 review: verify_public_country_selection runs inside the verifying run_phase
# subshell, so its RESOLVED_COUNTRY_CODE assignment does NOT reach the parent's
# journal_finish. The REAL _supervise_verify must instead STAMP the resolved country into
# the journal so the parent reads it back, not fall back to VPN_COUNTRY. Restore the real
# _supervise_verify (GROUP 4 above stubbed it) and drive it through run_phase.
# shellcheck disable=SC1090
. "$LIB/supervise.sh"
verify_public_country_selection() { RESOLVED_COUNTRY_CODE='MT'; return 0; }
nordvpn_easy_commit_pending_server_preference() { :; }
nordvpn_easy_mark_applied() { :; }
nordvpn_easy_config_fingerprint() { printf 'fp'; }
reset_journal
nordvpn_easy_journal_write_full 'phase=verifying' 'txn_id=T-cc'
RESOLVED_COUNTRY_CODE=''
VPN_COUNTRY='IT'
nordvpn_easy_run_phase 'verifying' 60 1 _supervise_verify >/dev/null 2>&1 || true
assert_eq '' "$RESOLVED_COUNTRY_CODE" 'the verifying subshell assignment of RESOLVED_COUNTRY_CODE does NOT leak to the parent'
assert_eq 'MT' "$(nordvpn_easy_journal_get country)" 'the real _supervise_verify stamps the resolved country into the journal (survives the run_phase subshell)'
# The parent finish reads the journal-stamped country, not the stale VPN_COUNTRY fallback
# (mirrors nordvpn_easy_supervise's read-back before fenced_journal_finish).
finish_country="$(nordvpn_easy_journal_get country 2>/dev/null || printf '')"
[ -n "$finish_country" ] || finish_country="${RESOLVED_COUNTRY_CODE:-${VPN_COUNTRY:-}}"
assert_eq 'MT' "$finish_country" 'the parent uses the journal-stamped resolved country (MT), not the VPN_COUNTRY fallback (IT)'

printf '%s\n' 'test-supervise.sh: ok'
