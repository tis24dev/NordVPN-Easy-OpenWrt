#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


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
reconcile() {
	printf '%s\n' "${RUN_CORE_ACTION_FAILURE_LOG_MODE:-unset}" > "$SOFT_FAIL_MODE_CAPTURE"
	log_service_info 'reconcile requested; synchronizing runtime with saved config'
	return 1
}

start >"$START_OUTPUT_FILE"

grep -q 'reconcile requested; synchronizing runtime with saved config' "$START_LOG_FILE" || {
	printf '%s\n' 'FAIL: start should run the reconcile command path at boot' >&2
	exit 1
}
assert_eq 'info' "$(cat "$SOFT_FAIL_MODE_CAPTURE")" 'start downgrades initial reconcile failures to info logging'
assert_eq '' "$(cat "$START_OUTPUT_FILE")" 'start does not emit retryable reconcile failure to stdout'
assert_eq '' "${RUN_CORE_ACTION_FAILURE_LOG_MODE}" 'start restores previous failure log mode'

grep -q 'initial reconcile failed; hooks are installed and future cron/hotplug runs will retry' "$START_LOG_FILE" || {
	printf '%s\n' 'FAIL: start should log retryable initial reconcile failure' >&2
	exit 1
}

printf '%s\n' 'test-init-start-soft-fail.sh: ok'
