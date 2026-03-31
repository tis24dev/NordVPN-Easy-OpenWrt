#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"

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

extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn "\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$INIT_SCRIPT"
}

eval "$(extract_function validate_cron_schedule)"

CRON_VALIDATION_ERROR=''
validate_cron_schedule '* * * * *'
assert_eq '' "${CRON_VALIDATION_ERROR:-}" 'wildcard schedule accepted'

CRON_VALIDATION_ERROR=''
validate_cron_schedule '1,2,5-7 * * * *'
assert_eq '' "${CRON_VALIDATION_ERROR:-}" 'lists and ranges accepted'

CRON_VALIDATION_ERROR=''
if validate_cron_schedule '50-10 * * * *'; then
	printf '%s\n' 'FAIL: inverted range should be rejected' >&2
	exit 1
fi
case "$CRON_VALIDATION_ERROR" in
	*inverted\ range*)
		;;
	*)
		printf '%s\n' "FAIL: expected inverted range diagnostic, got: ${CRON_VALIDATION_ERROR:-empty}" >&2
		exit 1
		;;
esac

CRON_VALIDATION_ERROR=''
if validate_cron_schedule '*/0 * * * *'; then
	printf '%s\n' 'FAIL: zero step should be rejected' >&2
	exit 1
fi
case "$CRON_VALIDATION_ERROR" in
	*invalid\ step*)
		;;
	*)
		printf '%s\n' "FAIL: expected invalid step diagnostic, got: ${CRON_VALIDATION_ERROR:-empty}" >&2
		exit 1
		;;
esac

CRON_VALIDATION_ERROR=''
if validate_cron_schedule '1,,2 * * * *'; then
	printf '%s\n' 'FAIL: empty token should be rejected' >&2
	exit 1
fi
case "$CRON_VALIDATION_ERROR" in
	*empty\ token*)
		;;
	*)
		printf '%s\n' "FAIL: expected empty token diagnostic, got: ${CRON_VALIDATION_ERROR:-empty}" >&2
		exit 1
		;;
esac

CRON_VALIDATION_ERROR=''
MULTILINE_SCHEDULE="$(printf '%s\n%s' '* * * * *' '* * * * *')"
if validate_cron_schedule "$MULTILINE_SCHEDULE"; then
	printf '%s\n' 'FAIL: multiline schedule should be rejected' >&2
	exit 1
fi
case "$CRON_VALIDATION_ERROR" in
	*single\ line*)
		;;
	*)
		printf '%s\n' "FAIL: expected multiline diagnostic, got: ${CRON_VALIDATION_ERROR:-empty}" >&2
		exit 1
		;;
esac

printf '%s\n' 'test-init-cron.sh: ok'
