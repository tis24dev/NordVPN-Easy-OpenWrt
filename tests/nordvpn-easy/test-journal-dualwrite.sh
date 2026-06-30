#!/bin/sh

# Covers the SHADOW dual-write wiring: the connect-apply result lifecycle in
# common.sh must mirror into the journal (begin -> applying, finish ->
# done/failed) with the correct argument order, origin, and preserved txn id.
# Exercised through the REAL result functions (not the journal helpers directly),
# which is the integration later steps are designed to trust.

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
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

NORDVPN_EASY_RUN_DIR="$TMP_DIR/run"
NORDVPN_EASY_JOURNAL_FILE="$TMP_DIR/run/journal"
RESULT_FILE="$TMP_DIR/run/connect-apply-result"
mkdir -p "$NORDVPN_EASY_RUN_DIR"

# shellcheck disable=SC1090
. "$LIB_DIR/schema.sh"
# shellcheck disable=SC1090
. "$LIB_DIR/common.sh"
# shellcheck disable=SC1090
. "$LIB_DIR/journal.sh"

# --- begin mirrors into the journal as the applying phase -------------------
nordvpn_easy_connect_apply_result_begin "$RESULT_FILE"

assert_eq 'pending' "$(_nordvpn_easy_connect_apply_result_get "$RESULT_FILE" state)" 'result file records the pending state'
assert_eq 'applying' "$(nordvpn_easy_journal_get phase)" 'result_begin dual-writes phase=applying'
assert_eq 'apply' "$(nordvpn_easy_journal_get origin)" 'result_begin records origin=apply'
assert_eq "$$" "$(nordvpn_easy_journal_get owner_pid)" 'result_begin records the owner pid'
TXN="$(nordvpn_easy_journal_get txn_id)"
assert_ne '' "$TXN" 'result_begin generates a journal txn id'

# --- a successful finish mirrors the terminal phase + rc + country -----------
nordvpn_easy_connect_apply_result_finish "$RESULT_FILE" 0 'it'

assert_eq 'success' "$(_nordvpn_easy_connect_apply_result_get "$RESULT_FILE" state)" 'result file records success'
assert_eq 'done' "$(nordvpn_easy_journal_get phase)" 'result_finish rc=0 dual-writes phase=done'
assert_eq '0' "$(nordvpn_easy_journal_get rc)" 'result_finish records rc (argument order is rc then country)'
assert_eq 'IT' "$(nordvpn_easy_journal_get country)" 'result_finish records the upper-cased country'
assert_eq "$TXN" "$(nordvpn_easy_journal_get txn_id)" 'result_finish preserves the txn id from begin'

# --- a failed finish mirrors the failed phase -------------------------------
nordvpn_easy_connect_apply_result_begin "$RESULT_FILE"
nordvpn_easy_connect_apply_result_finish "$RESULT_FILE" 1

assert_eq 'failed' "$(_nordvpn_easy_connect_apply_result_get "$RESULT_FILE" state)" 'result file records failure'
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'result_finish rc!=0 dual-writes phase=failed'
assert_eq '1' "$(nordvpn_easy_journal_get rc)" 'result_finish records the failing rc'

printf '%s\n' 'test-journal-dualwrite.sh: ok'
