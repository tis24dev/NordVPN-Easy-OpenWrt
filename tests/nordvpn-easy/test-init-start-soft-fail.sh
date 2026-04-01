#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
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

extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn "\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$INIT_SCRIPT"
}

eval "$(extract_function start)"

cfg_enabled=1
RUN_CORE_ACTION_FAILURE_LOG_MODE=''
SOFT_FAIL_MODE_CAPTURE="$TMP_DIR/failure-mode.txt"
START_OUTPUT_FILE="$TMP_DIR/start-output.txt"
START_LOG_FILE="$TMP_DIR/start-log.txt"

load_service_config() { :; }
disable_vpn_runtime() { :; }
install_hooks() { :; }
log_service_info() { printf '%s\n' "$1" >> "$START_LOG_FILE"; }
run_core_action() {
	printf '%s\n' "${RUN_CORE_ACTION_FAILURE_LOG_MODE:-unset}" > "$SOFT_FAIL_MODE_CAPTURE"
	return 1
}

start >"$START_OUTPUT_FILE"

assert_eq 'info' "$(cat "$SOFT_FAIL_MODE_CAPTURE")" 'start downgrades initial check failures to info logging'
assert_eq '' "$(cat "$START_OUTPUT_FILE")" 'start does not emit retryable check failure to stdout'
assert_eq '' "${RUN_CORE_ACTION_FAILURE_LOG_MODE}" 'start restores previous failure log mode'

grep -q 'initial check failed; hooks are installed and future cron/hotplug runs will retry' "$START_LOG_FILE" || {
	printf '%s\n' 'FAIL: start should log retryable initial check failure' >&2
	exit 1
}

printf '%s\n' 'test-init-start-soft-fail.sh: ok'
