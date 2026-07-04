#!/bin/sh

# S7 increment 8: journal-authoritative in-flight recovery. nordvpn_easy_check_once,
# under orchestrator=supervisor, RE-DRIVES a crashed apply -- a SAME-target,
# non-terminal journal record whose owner_pid is dead -- by invoking the supervisor
# (which ADOPTS the record and completes it). A FOREIGN record is reaped (5d), not
# re-driven; a live-owner or terminal record is left. journal_finish becomes
# owner-fenced for the supervisor (nordvpn_easy_fenced_journal_finish). The re-drive is
# loop-safe (a persistently failing apply ends FAILED = terminal, never re-driven) and
# cannot double-apply (single held lock + owner fence). Uses a COUNTING supervise stub
# that exercises the REAL open_txn ADOPT + a real terminal finish.

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

# Quiet + short-circuit stubs so check_once reaches the reap+re-drive head.
nordvpn_easy_log() { :; }
log() { :; }
nordvpn_easy_log_phase() { :; }
nordvpn_easy_log_blocker() { :; }
nordvpn_easy_ping_interface() { return 0; }
nordvpn_easy_check_once_finish() { :; }
nordvpn_easy_target_identity() { printf '%s' 'fp-NEW:1'; }
nordvpn_easy_orchestrator_mode() { printf '%s' "${MODE:-legacy}"; }

# Counting re-drive stub: exercises the REAL open_txn (ADOPT keeps txn_id, clears
# fetch_done) then a real terminal finish, so "journal reaches done" is observable.
SUPERVISE_CALLS=0
REDRIVE_FETCH_DONE_AFTER_OPEN='unset'
nordvpn_easy_supervise() {
	SUPERVISE_CALLS=$((SUPERVISE_CALLS + 1))
	nordvpn_easy_supervise_open_txn "$(nordvpn_easy_target_identity)"
	# Capture fetch_done AFTER open_txn but BEFORE the terminal finish (journal_finish's
	# full write drops fetch_done, which would otherwise mask whether open_txn cleared it).
	REDRIVE_FETCH_DONE_AFTER_OPEN="$(nordvpn_easy_journal_get fetch_done)"
	nordvpn_easy_journal_finish 0 'IT'
}

seed() { # phase txn target owner_pid [fetch_done]
	rm -f "$NORDVPN_EASY_JOURNAL_FILE"
	NORDVPN_EASY_OWNER_TOKEN=''
	nordvpn_easy_journal_write_full "phase=$1" "txn_id=$2" "target_fingerprint=$3" "owner_pid=$4" 'started_at=1' "fetch_done=${5:-}"
}

# --- Case A: CRASHED same-target dead-owner -> RE-DRIVE ------------------------
SUPERVISE_CALLS=0
seed 'converge' 'T-crash' 'fp-NEW:1' '999999' '1'
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq '1' "$SUPERVISE_CALLS" 'A: a crashed same-target apply is re-driven'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'A: the re-drive completes the journal (done)'
assert_eq 'T-crash' "$(nordvpn_easy_journal_get txn_id)" 'A: open_txn ADOPTED the record (txn_id preserved, no fork)'
assert_eq '' "$REDRIVE_FETCH_DONE_AFTER_OPEN" 'A: open_txn cleared fetch_done on adopt (checked before the finish)'

# --- Case B: FOREIGN dead-owner -> reaped (5d), NOT re-driven ------------------
SUPERVISE_CALLS=0
seed 'configure' 'T-foreign' 'fp-OLD:1' '999999'
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'B: a foreign record is reaped to failed'
assert_eq 'local.reaped_stale' "$(nordvpn_easy_journal_get last_error)" 'B: the reaped record carries the reaped_stale cause'
assert_eq '0' "$SUPERVISE_CALLS" 'B: a foreign record is NOT re-driven'

# --- Case C: LIVE-owner same-target -> neither reaped nor re-driven ------------
SUPERVISE_CALLS=0
seed 'converge' 'T-live' 'fp-NEW:1' "$$"
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'converge' "$(nordvpn_easy_journal_get phase)" 'C: a live-owner record is left untouched'
assert_eq '0' "$SUPERVISE_CALLS" 'C: a live-owner record is not re-driven'

# --- Case D: TERMINAL same-target -> neither (loop-safety anchor) --------------
for term in 'done' 'failed'; do
	SUPERVISE_CALLS=0
	seed "$term" 'T-term' 'fp-NEW:1' '999999'
	MODE='supervisor'
	nordvpn_easy_check_once >/dev/null 2>&1 || true
	assert_eq "$term" "$(nordvpn_easy_journal_get phase)" "D: a terminal ($term) record is left untouched"
	assert_eq '0' "$SUPERVISE_CALLS" "D: a terminal ($term) record is NOT re-driven (loop-safe)"
done

# --- Case E: INERTNESS under legacy -------------------------------------------
SUPERVISE_CALLS=0
seed 'converge' 'T-legacy' 'fp-NEW:1' '999999'
MODE='legacy'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'converge' "$(nordvpn_easy_journal_get phase)" 'E: under legacy check_once does not touch the journal'
assert_eq '0' "$SUPERVISE_CALLS" 'E: under legacy the re-drive never fires'

# --- Case F: fenced_journal_finish -- refuse superseded, accept owner/tokenless -
LOCK_DIR="$TMP_DIR/lock"
mkdir -p "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN='mytoken'
printf '%s\n' 'someone-else' > "$LOCK_DIR/token"   # supersession: on-disk != ours
rm -f "$NORDVPN_EASY_JOURNAL_FILE"
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=T-fence' 'origin=supervise' 'started_at=1'
frc=0
nordvpn_easy_fenced_journal_finish 0 'IT' || frc=$?
[ "$frc" -ne 0 ] || { printf '%s\n' 'FAIL: F: a superseded owner must refuse the finish' >&2; exit 1; }
assert_eq 'applying' "$(nordvpn_easy_journal_get phase)" 'F: a refused finish leaves the journal unchanged'
printf '%s\n' 'mytoken' > "$LOCK_DIR/token"        # we own the lock now
nordvpn_easy_fenced_journal_finish 0 'IT' >/dev/null 2>&1 || { printf '%s\n' 'FAIL: F: the legit owner must finish' >&2; exit 1; }
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'F: the legit owner finishes (done)'
NORDVPN_EASY_OWNER_TOKEN=''                          # tokenless (if-claimed) passes through
rm -f "$NORDVPN_EASY_JOURNAL_FILE"
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=T-tokenless' 'started_at=1'
nordvpn_easy_fenced_journal_finish 1 '' >/dev/null 2>&1 || { printf '%s\n' 'FAIL: F: a tokenless caller must be allowed through' >&2; exit 1; }
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'F: a tokenless finish proceeds'

# --- Case G: re-drive is IDEMPOTENT (running twice converges once) -------------
SUPERVISE_CALLS=0
seed 'converge' 'T-idem' 'fp-NEW:1' '999999' '1'
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq '1' "$SUPERVISE_CALLS" 'G: first check re-drives once'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'G: first check completes the journal'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq '1' "$SUPERVISE_CALLS" 'G: second check does NOT re-drive again (record is now terminal)'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'G: the journal stays done'

# --- Case H: the re-drive's SAME-target clause is load-bearing on its own ------
# With the 5d reap stubbed to a no-op, a FOREIGN (target-mismatch) non-terminal
# dead-owner record must STILL NOT be re-driven -- the same-target equality clause
# alone blocks it (in Case B that guarantee otherwise comes from the reap stamping the
# record terminal first, so this isolates the predicate clause).
nordvpn_easy_supervise_reap_stale_journal() { :; }
SUPERVISE_CALLS=0
seed 'converge' 'T-foreign2' 'fp-OLD:1' '999999'
MODE='supervisor'
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq '0' "$SUPERVISE_CALLS" 'H: a foreign record is NOT re-driven even with the reap stubbed (same-target clause is load-bearing)'
assert_eq 'converge' "$(nordvpn_easy_journal_get phase)" 'H: the foreign record is left non-terminal (reap stubbed, re-drive skipped)'

printf '%s\n' 'test-supervise-reaper.sh: ok'
