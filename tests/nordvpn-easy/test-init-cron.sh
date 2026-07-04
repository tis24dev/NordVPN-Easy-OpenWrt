#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
# The cron/hotplug installers were extracted to a shared library (S7 inc 5c); the
# cron helpers this test exercises now live there, not in the init script.
HOOKS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/hooks.sh"

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
	' "${2:-$INIT_SCRIPT}"
}

eval "$(extract_function validate_cron_schedule "$HOOKS_LIB")"
eval "$(extract_function normalize_cron_minute_field "$HOOKS_LIB")"
eval "$(extract_function normalize_cron_schedule "$HOOKS_LIB")"

CRON_VALIDATION_ERROR=''
validate_cron_schedule '* * * * *'
assert_eq '' "${CRON_VALIDATION_ERROR:-}" 'wildcard schedule accepted'
assert_eq '*/5 * * * *' "$(normalize_cron_schedule '* * * * *')" 'wildcard schedule normalized to 5-minute minimum'
assert_eq '*/5 * * * *' "$(normalize_cron_schedule '*/4 * * * *')" 'fast stepped schedule normalized to 5-minute minimum'
assert_eq '*/10 * * * *' "$(normalize_cron_schedule '*/10 * * * *')" '10-minute schedule preserved'
assert_eq '*/5 * * * *' "$(normalize_cron_schedule '0-4 * * * *')" 'dense minute range throttled to 5-minute floor'
assert_eq '*/5 * * * *' "$(normalize_cron_schedule '0,1,2,3,4 * * * *')" 'dense minute list throttled to 5-minute floor'
assert_eq '0,15,30,45 * * * *' "$(normalize_cron_schedule '0,15,30,45 * * * *')" 'sparse minute list preserved'
assert_eq '*/10 5 * * 1' "$(normalize_cron_schedule '*/10 5 * * 1')" 'non-minute fields preserved'

CRON_VALIDATION_ERROR=''
validate_cron_schedule '1,2,5-7 * * * *'
assert_eq '' "${CRON_VALIDATION_ERROR:-}" 'lists and ranges accepted'

CRON_VALIDATION_ERROR=''
validate_cron_schedule '0-30/5 * * * *'
assert_eq '' "${CRON_VALIDATION_ERROR:-}" 'range with step accepted'

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

# The generated cron command must skip when a connect-apply transaction is in
# progress (so cron 'check' cannot interleave the client-driven Save & Apply
# window) and stay busy-tolerant otherwise.
eval "$(extract_function write_desired_cron_hook_to "$HOOKS_LIB")"
SERVICE_NAME='nordvpn-easy'
CONNECT_APPLY_GUARD='/tmp/run/nordvpn-easy/connect-apply-guard'
cfg_enabled=1
cfg_check_cron_schedule='*/10 * * * *'
CRON_OUT="$(mktemp)"
write_desired_cron_hook_to "$CRON_OUT" 1
CRON_LINE="$(cat "$CRON_OUT")"
rm -f "$CRON_OUT"
case "$CRON_LINE" in
	*"[ -f $CONNECT_APPLY_GUARD ] ||"*"NORDVPN_EASY_BUSY_IS_OK=1 /etc/init.d/$SERVICE_NAME check"*)
		;;
	*)
		printf '%s\n' "FAIL: cron command should skip on the connect-apply guard and stay busy-tolerant: $CRON_LINE" >&2
		exit 1
		;;
esac

printf '%s\n' 'test-init-cron.sh: ok'
