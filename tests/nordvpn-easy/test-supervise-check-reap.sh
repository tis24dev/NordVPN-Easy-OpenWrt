#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# nordvpn_easy_check_once reaps a FOREIGN stale supervise journal record at its head.
# S9: the reap is unconditional (gated only on `command -v` of the reaper), the
# orchestrator flag is gone. Uses the REAL nordvpn_easy_supervise_reap_stale_journal;
# the rest of check_once is stubbed so it returns early right after the head reap.

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
# This test isolates the head REAP wiring; stub the re-drive so a same-target
# crashed record does not actually get re-driven here (the re-drive itself is covered
# by test-supervise-reaper.sh).
nordvpn_easy_supervise() { :; }

seed_foreign_record() {
	rm -f "$NORDVPN_EASY_JOURNAL_FILE"
	NORDVPN_EASY_OWNER_TOKEN=''
	nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-foreign' 'target_fingerprint=fp-OLD:1' 'owner_pid=999999' 'started_at=1'
}

# --- the foreign stale record is reaped at the head (unconditionally) ------------
seed_foreign_record
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'failed' "$(nordvpn_easy_journal_get phase)" 'check_once reaps a foreign stale record at head'
assert_eq 'local.reaped_stale' "$(nordvpn_easy_journal_get last_error)" 'the reaped record carries the reaped_stale cause'

# --- supervisor + SAME-target crashed record: the 5d reap LEAVES it (inc 8 re-drives
# it instead -- stubbed here; see test-supervise-reaper.sh) --------------------------
seed_same_target() {
	rm -f "$NORDVPN_EASY_JOURNAL_FILE"
	NORDVPN_EASY_OWNER_TOKEN=''
	nordvpn_easy_journal_write_full 'phase=configure' 'txn_id=T-same' 'target_fingerprint=fp-NEW:1' 'owner_pid=999999' 'started_at=1'
}
seed_same_target
nordvpn_easy_check_once >/dev/null 2>&1 || true
assert_eq 'configure' "$(nordvpn_easy_journal_get phase)" 'check_once does NOT reap a SAME-target record (left for the re-drive)'

printf '%s\n' 'test-supervise-check-reap.sh: ok'
