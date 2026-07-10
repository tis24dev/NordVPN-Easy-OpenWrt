#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
# apply_crontab_block was extracted to a shared library (S7 inc 5c).
HOOKS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/hooks.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

assert_eq() {
	expected="$1"
	actual="$2"
	label="$3"

	if [ "$expected" != "$actual" ]; then
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "expected: $expected" >&2
		printf '%s\n' "actual:   $actual" >&2
		exit 1
	fi
}

assert_file_has_line() {
	grep -Fx "$1" "$2" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "missing line: $1" >&2
		exit 1
	}
}

assert_file_missing_line() {
	if [ -f "$2" ] && grep -Fx "$1" "$2" >/dev/null 2>&1; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "unexpected line: $1" >&2
		exit 1
	fi
}

extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn "\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "${2:-$INIT_SCRIPT}"
}

eval "$(extract_function apply_crontab_block "$HOOKS_LIB")"

CRONTAB_PATH="$TMP_DIR/crontabs/root"
CRON_PATH="$TMP_DIR/cron.d/nordvpn-easy"
CRON_BLOCK_BEGIN='# BEGIN nordvpn-easy'
CRON_BLOCK_END='# END nordvpn-easy'
LINE1='*/15 * * * * NORDVPN_EASY_BUSY_IS_OK=1 /etc/init.d/nordvpn-easy check'
LINE2='*/30 * * * * NORDVPN_EASY_BUSY_IS_OK=1 /etc/init.d/nordvpn-easy check'
FOREIGN='5 4 * * * /usr/bin/other-app-job'

log_service_error() { :; }

# --- Install into an absent crontab ----------------------------------------
RC=0
apply_crontab_block "$LINE1" || RC=$?
assert_eq '0' "$RC" 'installing the block into an absent crontab reports a change'
assert_file_has_line "$CRON_BLOCK_BEGIN" "$CRONTAB_PATH" 'crontab gains our begin marker'
assert_file_has_line "$LINE1" "$CRONTAB_PATH" 'crontab gains our cron line'
assert_file_has_line "$CRON_BLOCK_END" "$CRONTAB_PATH" 'crontab gains our end marker'

# --- Re-applying the same line is a no-op ----------------------------------
RC=0
apply_crontab_block "$LINE1" || RC=$?
assert_eq '2' "$RC" 're-applying the identical block reports no change'

# --- Updating the line replaces our block, no duplicate ---------------------
RC=0
apply_crontab_block "$LINE2" || RC=$?
assert_eq '0' "$RC" 'changing the schedule reports a change'
assert_file_has_line "$LINE2" "$CRONTAB_PATH" 'crontab carries the updated cron line'
assert_file_missing_line "$LINE1" "$CRONTAB_PATH" 'the previous cron line is removed (no duplicate block)'
BEGIN_COUNT="$(grep -Fxc "$CRON_BLOCK_BEGIN" "$CRONTAB_PATH" 2>/dev/null || printf '0')"
assert_eq '1' "$BEGIN_COUNT" 'exactly one managed block exists after an update'

# --- A foreign cron line is preserved across our edits ----------------------
printf '%s\n' "$FOREIGN" > "$CRONTAB_PATH"
{
	printf '%s\n' "$CRON_BLOCK_BEGIN"
	printf '%s\n' "$LINE1"
	printf '%s\n' "$CRON_BLOCK_END"
} >> "$CRONTAB_PATH"

RC=0
apply_crontab_block "$LINE2" || RC=$?
assert_eq '0' "$RC" 'updating alongside a foreign cron reports a change'
assert_file_has_line "$FOREIGN" "$CRONTAB_PATH" 'a foreign cron line is preserved when we update our block'
assert_file_has_line "$LINE2" "$CRONTAB_PATH" 'our updated line is present alongside the foreign cron'

# --- Removing our block keeps the foreign cron ------------------------------
RC=0
apply_crontab_block '' || RC=$?
assert_eq '0' "$RC" 'removing our block reports a change'
assert_file_has_line "$FOREIGN" "$CRONTAB_PATH" 'removing our block leaves the foreign cron intact'
assert_file_missing_line "$CRON_BLOCK_BEGIN" "$CRONTAB_PATH" 'our begin marker is gone after removal'

# --- Removing our block when it is the only content drops the crontab --------
{
	printf '%s\n' "$CRON_BLOCK_BEGIN"
	printf '%s\n' "$LINE1"
	printf '%s\n' "$CRON_BLOCK_END"
} > "$CRONTAB_PATH"

RC=0
apply_crontab_block '' || RC=$?
assert_eq '0' "$RC" 'removing our only block reports a change'
[ ! -f "$CRONTAB_PATH" ] || {
	printf '%s\n' 'FAIL: an otherwise-empty crontab should be removed, not left empty' >&2
	exit 1
}

# --- The legacy /etc/cron.d hook is retired -------------------------------
mkdir -p "$(dirname "$CRON_PATH")"
printf '%s\n' 'stale legacy cron.d hook' > "$CRON_PATH"
RC=0
apply_crontab_block "$LINE1" || RC=$?
assert_eq '0' "$RC" 'installing the block reports a change'
[ ! -f "$CRON_PATH" ] || {
	printf '%s\n' 'FAIL: the legacy /etc/cron.d hook should be removed' >&2
	exit 1
}

# --- Mismatched markers (missing END) must NOT truncate the shared crontab -----
# The removal awk clears its skip flag only at the END marker; a missing END would
# otherwise drop every line after BEGIN, deleting unrelated root cron. The guard must
# refuse (RC=1) and leave the original file byte-for-byte intact. (PR #81 review.)
FOREIGN2='30 3 * * * /usr/bin/keep-me-safe'
{
	printf '%s\n' "$FOREIGN2"
	printf '%s\n' "$CRON_BLOCK_BEGIN"
	printf '%s\n' "$LINE1"
	# NOTE: no END marker on purpose (corruption)
	printf '%s\n' '15 4 * * * /usr/bin/also-keep-me'
} > "$CRONTAB_PATH"
BEFORE_HASH="$(cksum "$CRONTAB_PATH")"
RC=0
apply_crontab_block "$LINE2" || RC=$?
assert_eq '1' "$RC" 'mismatched markers make apply_crontab_block refuse (RC=1)'
assert_eq "$BEFORE_HASH" "$(cksum "$CRONTAB_PATH")" 'the crontab is left byte-for-byte unchanged on mismatched markers'
assert_file_has_line "$FOREIGN2" "$CRONTAB_PATH" 'the foreign cron before BEGIN is preserved'
assert_file_has_line '15 4 * * * /usr/bin/also-keep-me' "$CRONTAB_PATH" 'the line after the missing END is NOT dropped'

printf '%s\n' 'test-init-crontab-block.sh: ok'
