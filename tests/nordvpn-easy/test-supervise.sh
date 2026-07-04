#!/bin/sh

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
NORDVPN_EASY_PHASE_BACKOFF_BASE=0
CALL_LOG="$TMP_DIR/calls"
SENTINEL="$TMP_DIR/teardown-ran"
LOCK_DIR="$TMP_DIR/lock"
mkdir -p "$LOCK_DIR"

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
	rm -f "$NORDVPN_EASY_JOURNAL_FILE" "$CALL_LOG" "$SENTINEL"
	NORDVPN_EASY_OWNER_TOKEN=''
}

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
assert_eq 'fetch teardown configure bringup wait' "$(tr '\n' ' ' < "$CALL_LOG" | sed 's/ $//')" 'converge runs the steps in order'
[ -f "$SENTINEL" ] || fail 'teardown must run on the happy path (fetch_done was set)'

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
# GROUP 4: nordvpn_easy_supervise orchestration -- the flag gate, disable refusal,
# phase order. The phase BODIES are overridden with loggers so this exercises the
# orchestration (gates, order, journal finish), not the provision internals.
# =============================================================================
nordvpn_easy_orchestrator_mode() { printf '%s' "${MODE:-legacy}"; }
nordvpn_easy_target_identity() { printf '%s' "${TARGET:-fp-NEW:1}"; }
_supervise_validate() { printf 'validate\n' >> "$CALL_LOG"; return "${P_VALIDATE_RC:-0}"; }
_supervise_persist() { printf 'persist\n' >> "$CALL_LOG"; return "${P_PERSIST_RC:-0}"; }
_supervise_hooks() { printf 'hooks\n' >> "$CALL_LOG"; return "${P_HOOKS_RC:-0}"; }
_supervise_converge() { printf 'converge\n' >> "$CALL_LOG"; return "${P_CONVERGE_RC:-0}"; }
_supervise_verify() { printf 'verify\n' >> "$CALL_LOG"; return "${P_VERIFY_RC:-0}"; }

# flag gate: legacy -> strict no-op, no phase body runs, rc 0
reset_journal
MODE='legacy' DESIRED_ENABLED='1'
sup_rc=0
nordvpn_easy_supervise || sup_rc=$?
assert_eq '0' "$sup_rc" 'supervise under orchestrator=legacy returns 0'
[ ! -f "$CALL_LOG" ] || fail 'INERTNESS: no phase body may run under orchestrator=legacy'
[ ! -f "$NORDVPN_EASY_JOURNAL_FILE" ] || fail 'INERTNESS: no journal transaction opens under legacy'

# flag gate: garbage -> legacy -> no-op
reset_journal
MODE='bogus' DESIRED_ENABLED='1'
nordvpn_easy_supervise || fail 'supervise under a garbage orchestrator value must be a benign no-op'
[ ! -f "$CALL_LOG" ] || fail 'INERTNESS: garbage orchestrator value must not run any phase'

# disable refused: supervisor + DESIRED_ENABLED=0 -> no-op, no txn
reset_journal
MODE='supervisor' DESIRED_ENABLED='0'
dis_rc=0
nordvpn_easy_supervise || dis_rc=$?
assert_eq '0' "$dis_rc" 'supervise refuses a disable apply (returns 0)'
[ ! -f "$CALL_LOG" ] || fail 'a disable apply must not run any phase (stays on legacy)'

# happy path: full phase order + journal done
reset_journal
MODE='supervisor' DESIRED_ENABLED='1' TARGET='fp-NEW:1'
P_VALIDATE_RC=0 P_PERSIST_RC=0 P_HOOKS_RC=0 P_CONVERGE_RC=0 P_VERIFY_RC=0
nordvpn_easy_supervise || fail 'a fully-successful supervised apply must return 0'
assert_eq 'validate persist hooks converge verify' "$(tr '\n' ' ' < "$CALL_LOG" | sed 's/ $//')" 'supervise runs the phases in order'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a successful apply finishes the journal as done'

# hooks non-fatal: a hooks failure does NOT abort the apply
reset_journal
MODE='supervisor' DESIRED_ENABLED='1' P_HOOKS_RC=1
nordvpn_easy_supervise || fail 'a hooks failure must be non-fatal (apply still succeeds)'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a hooks failure still finishes done'
grep -q '^converge$' "$CALL_LOG" || fail 'converge must still run after a non-fatal hooks failure'

# verify non-fatal: a verify failure does NOT fail the apply
reset_journal
MODE='supervisor' DESIRED_ENABLED='1' P_HOOKS_RC=0 P_VERIFY_RC=1
nordvpn_easy_supervise || fail 'a verify failure must be non-fatal'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'a verify failure still finishes done'

# a fatal phase (converge) fails -> journal failed, rc!=0
reset_journal
MODE='supervisor' DESIRED_ENABLED='1' P_VERIFY_RC=0 P_CONVERGE_RC=1
fat_rc=0
nordvpn_easy_supervise || fat_rc=$?
[ "$fat_rc" -ne 0 ] || fail 'a converge failure must make the apply fail'
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'a fatal phase failure finishes the journal as failed'
grep -q '^verify$' "$CALL_LOG" && fail 'verify must NOT run after a converge failure' || :

printf '%s\n' 'test-supervise.sh: ok'
