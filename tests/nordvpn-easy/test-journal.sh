#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
JOURNAL_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/journal.sh"
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
assert_eq '1' "$(nordvpn_easy_journal_get schema)" 'journal stamps schema version'
assert_ne '' "$(nordvpn_easy_journal_get status_seq)" 'journal stamps status_seq'

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

printf '%s\n' 'test-journal.sh: ok'
