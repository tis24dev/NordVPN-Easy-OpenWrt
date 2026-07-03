#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
JOURNAL_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/journal.sh"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "expected: $1" >&2
		printf '%s\n' "actual:   $2" >&2
		exit 1
	fi
}

assert_ne() {
	if [ "$1" = "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "both values: $1" >&2
		exit 1
	fi
}

NORDVPN_EASY_JOURNAL_FILE="$TMP_DIR/journal"

# shellcheck disable=SC1090
. "$JOURNAL_LIB"
# common.sh provides fenced_journal_set + owner_fence_denied (exercised below).
# shellcheck disable=SC1090
. "$COMMON_LIB"
nordvpn_easy_log() { :; }

# --- status_seq is a non-decreasing numeric stamp (10ms resolution) ---------
# Two reads inside the same 10ms tick are EQUAL by design; assert monotonicity
# (>=), not strict increase, and that the stamp is a plausible uptime value.
SEQ1="$(nordvpn_easy_journal_next_seq)"
SEQ2="$(nordvpn_easy_journal_next_seq)"
case "$SEQ1" in ''|*[!0-9]*) printf '%s\n' "FAIL: seq is not numeric: $SEQ1" >&2; exit 1 ;; esac
[ "$SEQ1" -gt 0 ] || { printf '%s\n' "FAIL: seq must be a positive uptime stamp: $SEQ1" >&2; exit 1; }
[ "$SEQ2" -ge "$SEQ1" ] || {
	printf '%s\n' "FAIL: status_seq must not decrease ($SEQ1 -> $SEQ2)" >&2
	exit 1
}

# --- write_full / get round-trips and stamps schema/seq ---------------------
nordvpn_easy_journal_write_full 'phase=applying' 'txn_id=abc123' 'origin=test'
assert_eq 'applying' "$(nordvpn_easy_journal_get phase)" 'journal round-trips phase'
assert_eq 'abc123' "$(nordvpn_easy_journal_get txn_id)" 'journal round-trips txn_id'
assert_eq '2' "$(nordvpn_easy_journal_get schema)" 'journal stamps schema version 2 (supervisor fields)'
assert_ne '' "$(nordvpn_easy_journal_get status_seq)" 'journal stamps status_seq'

# --- write_full is a pass-through: the supervisor phase-record fields round-trip -
nordvpn_easy_journal_write_full \
	'phase=configure' \
	'target_fingerprint=fp-deadbeef' \
	'phase_attempt=2' \
	'phase_deadline=1770000123' \
	'fetch_done=1' \
	'last_error=network.timeout'
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'journal round-trips a supervisor phase'
assert_eq 'fp-deadbeef' "$(nordvpn_easy_journal_get target_fingerprint)" 'journal round-trips target_fingerprint'
assert_eq '2' "$(nordvpn_easy_journal_get phase_attempt)" 'journal round-trips phase_attempt'
assert_eq '1770000123' "$(nordvpn_easy_journal_get phase_deadline)" 'journal round-trips phase_deadline'
assert_eq '1' "$(nordvpn_easy_journal_get fetch_done)" 'journal round-trips fetch_done'
assert_eq 'network.timeout' "$(nordvpn_easy_journal_get last_error)" 'journal round-trips last_error'

# --- journal_set MERGES: it updates the given fields and preserves the rest -----
nordvpn_easy_journal_write_full 'phase=validate' 'txn_id=merge-txn' 'origin=test' 'started_at=111' 'target_fingerprint=fp-1'
nordvpn_easy_journal_set 'phase=configure' 'phase_attempt=3'
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'journal_set updates the phase'
assert_eq '3' "$(nordvpn_easy_journal_get phase_attempt)" 'journal_set adds a new field'
assert_eq 'merge-txn' "$(nordvpn_easy_journal_get txn_id)" 'journal_set PRESERVES the txn id'
assert_eq '111' "$(nordvpn_easy_journal_get started_at)" 'journal_set preserves started_at'
assert_eq 'fp-1' "$(nordvpn_easy_journal_get target_fingerprint)" 'journal_set preserves the other fields'
assert_eq '2' "$(nordvpn_easy_journal_get schema)" 'journal_set re-stamps the schema'
assert_eq '1' "$(grep -c '^phase=' "$NORDVPN_EASY_JOURNAL_FILE")" 'journal_set does not duplicate an overwritten key'

PERMS="$(ls -l "$NORDVPN_EASY_JOURNAL_FILE" 2>/dev/null | cut -c1-10)"
assert_eq '-rw-------' "$PERMS" 'journal file is mode 0600'

# --- begin sets the applying phase and a transaction identity ---------------
rm -f "$NORDVPN_EASY_JOURNAL_FILE"
nordvpn_easy_journal_begin apply
assert_eq 'applying' "$(nordvpn_easy_journal_get phase)" 'begin sets phase=applying'
assert_eq "$$" "$(nordvpn_easy_journal_get owner_pid)" 'begin records the owner pid'
TXN1="$(nordvpn_easy_journal_get txn_id)"
STARTED1="$(nordvpn_easy_journal_get started_at)"
assert_ne '' "$TXN1" 'begin generates a transaction id'

# --- begin is idempotent while applying: txn identity is preserved ----------
nordvpn_easy_journal_begin apply
assert_eq "$TXN1" "$(nordvpn_easy_journal_get txn_id)" 're-begin while applying preserves the txn id'
assert_eq "$STARTED1" "$(nordvpn_easy_journal_get started_at)" 're-begin while applying preserves started_at'

# --- finish records a terminal phase and rc ---------------------------------
nordvpn_easy_journal_finish 0 'it'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'finish rc=0 sets phase=done'
assert_eq '0' "$(nordvpn_easy_journal_get rc)" 'finish records rc'
assert_eq 'IT' "$(nordvpn_easy_journal_get country)" 'finish upper-cases the country'
assert_eq "$TXN1" "$(nordvpn_easy_journal_get txn_id)" 'finish preserves the txn id from begin'

nordvpn_easy_journal_finish 1
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'finish rc!=0 sets phase=failed'

# --- a fresh begin after a terminal phase starts a new transaction ----------
nordvpn_easy_journal_begin apply
assert_ne "$TXN1" "$(nordvpn_easy_journal_get txn_id)" 'begin after a terminal phase starts a new txn'

# --- boot_id is exposed (constant per boot) ---------------------------------
BOOT_ID="$(nordvpn_easy_journal_boot_id)"
assert_eq "$BOOT_ID" "$(nordvpn_easy_journal_boot_id)" 'boot_id is stable within a process'

# --- fenced_journal_set: the owner-fenced journal writer (common.sh). It is
# exercised here but NOT wired into any legacy journal write -- journal_begin/
# finish deliberately stay on the unfenced path. A legit lock owner writes; a
# superseded owner refuses and leaves the journal intact (the supervisor uses this
# so a reaped worker cannot clobber the new owner's journal).
LOCK_DIR="$TMP_DIR/lock"
mkdir -p "$LOCK_DIR"
printf '%s\n' 'jtok' > "$LOCK_DIR/token"
NORDVPN_EASY_OWNER_TOKEN='jtok'
rm -f "$NORDVPN_EASY_JOURNAL_FILE"
nordvpn_easy_fenced_journal_set 'phase=applying' 'target_fingerprint=fp-owned'
assert_eq 'fp-owned' "$(nordvpn_easy_journal_get target_fingerprint)" 'fenced_journal_set writes for the legit lock owner'

printf '%s\n' 'someone-else' > "$LOCK_DIR/token"
fenced_journal_rc=0
nordvpn_easy_fenced_journal_set 'phase=done' 'target_fingerprint=fp-stolen' || fenced_journal_rc=$?
[ "$fenced_journal_rc" -ne 0 ] || { printf '%s\n' 'FAIL: fenced_journal_set must refuse when superseded' >&2; exit 1; }
assert_eq 'fp-owned' "$(nordvpn_easy_journal_get target_fingerprint)" 'a superseded fenced_journal_set does not overwrite the journal'
NORDVPN_EASY_OWNER_TOKEN=''

printf '%s\n' 'test-journal.sh: ok'
