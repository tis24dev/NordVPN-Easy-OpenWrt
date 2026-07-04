#!/bin/sh

# S7 increment 5d: nordvpn_easy_check_once reaps a FOREIGN stale supervise journal
# record at its head, but ONLY under orchestrator=supervisor. Under legacy (the
# default) the gate short-circuits before any journal access (inertness). Uses the
# REAL nordvpn_easy_supervise_reap_stale_journal; the rest of check_once is stubbed
# so it returns early right after the head reap.

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

NORDVPN_EASY_JOURNAL_FILE="$TMP_DIR/journal"
VPN_IF='wg0'

# shellcheck disable=SC1090
. "$LIB/journal.sh"
# shellcheck disable=SC1090
. "$LIB/common.sh"
# shellcheck disable=SC1090
. "$LIB/supervise.sh"
# shellcheck disable=SC1090
. "$LIB/actions.sh"

# Quiet + short-circuit stubs so check_once returns right after the head reap.
nordvpn_easy_log() { :; }
log() { :; }
nordvpn_easy_log_phase() { :; }
nordvpn_easy_ping_interface() { return 0; }   # health-check "passes" -> early return
nordvpn_easy_check_once_finish() { :; }
nordvpn_easy_target_identity() { printf '%s' 'fp-NEW:1'; }
nordvpn_easy_orchestrator_mode() { printf '%s' "${MODE:-legacy}"; }

seed_foreign_record() {
	rm -f "$NORDVPN_EASY_JOURNAL_FILE"
	NORDVPN_EASY_OWNER_TOKEN=''
	nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-foreign' 'target_fingerprint=fp-OLD:1' 'owner_pid=999999' 'started_at=1'
}

# --- legacy: the reap gate short-circuits; the foreign record is NOT reaped -------
seed_foreign_record
MODE='legacy'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'under orchestrator=legacy check_once must NOT reap the journal (inert)'

# --- supervisor: the foreign stale record is reaped at the head ------------------
seed_foreign_record
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'under orchestrator=supervisor check_once reaps a foreign stale record at head'
assert_eq 'local.reaped_stale' "$(nordvpn_easy_journal_get last_error)" 'the reaped record carries the reaped_stale cause'

# --- supervisor + SAME-target crashed record: left for the re-drive (not reaped) --
seed_same_target() {
	rm -f "$NORDVPN_EASY_JOURNAL_FILE"
	NORDVPN_EASY_OWNER_TOKEN=''
	nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-same' 'target_fingerprint=fp-NEW:1' 'owner_pid=999999' 'started_at=1'
}
seed_same_target
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'check_once does NOT reap a SAME-target record (left for the re-drive)'

printf '%s\n' 'test-supervise-check-reap.sh: ok'
