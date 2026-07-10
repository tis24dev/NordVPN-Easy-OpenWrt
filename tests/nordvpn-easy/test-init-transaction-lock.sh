#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
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

# Exercise the real runtime lock library beneath the init wrapper.
# shellcheck disable=SC1090
. "$COMMON_LIB"
eval "$(extract_function acquire_runtime_transaction_lock)"

# Globals the init wrapper reads.
RUNTIME_LOCK_DIR="$TMP_DIR/runtime-lock"
NORDVPN_EASY_RC_BUSY=75
RUNTIME_TRANSACTION_LOCK_HELD=0
LOCK_ACQUIRED=0
NORDVPN_EASY_EXIT_TRAP_INSTALLED=0

# Stubs: keep the wrapper from sourcing config-context, emitting logger noise, or
# overriding this test's own cleanup EXIT trap.
load_config_context_library() { :; }
log_service_info() { :; }
nordvpn_easy_install_exit_trap() { :; }
nordvpn_easy_log() { :; }

unset NORDVPN_EASY_LOCK_INHERITED 2>/dev/null || true

# (1) First acquisition on a free lock takes the runtime lock and hands it down.
rc=0
acquire_runtime_transaction_lock connect || rc=$?
assert_eq '0' "$rc" 'first transaction lock acquisition succeeds'
assert_eq '1' "$RUNTIME_TRANSACTION_LOCK_HELD" 'transaction lock is marked held'
assert_eq '1' "${NORDVPN_EASY_LOCK_INHERITED:-unset}" 'inheritance is handed down to child core.sh runs'
[ -d "$RUNTIME_LOCK_DIR" ] || {
	printf '%s\n' 'FAIL: first acquisition should create the runtime lock dir' >&2
	exit 1
}
assert_eq "$$" "$(cat "$RUNTIME_LOCK_DIR/pid")" 'transaction lock records this pid as holder'

# (2) Reentrant acquisition (reconcile -> connect within one process) must not
#     re-acquire: prove it by removing the lock dir and confirming the nested
#     call still succeeds without re-creating it.
rm -rf "$RUNTIME_LOCK_DIR"
rc=0
acquire_runtime_transaction_lock connect || rc=$?
assert_eq '0' "$rc" 'reentrant acquisition returns success'
[ ! -d "$RUNTIME_LOCK_DIR" ] || {
	printf '%s\n' 'FAIL: reentrant acquisition must not re-acquire the runtime lock' >&2
	exit 1
}

# (3) Contention: another live operation already owns the runtime lock, so a
#     fresh transaction must defer with RC_BUSY and take nothing.
RUNTIME_TRANSACTION_LOCK_HELD=0
LOCK_ACQUIRED=0
unset NORDVPN_EASY_LOCK_INHERITED
mkdir -p "$RUNTIME_LOCK_DIR"
printf '%s\n' "$$" > "$RUNTIME_LOCK_DIR/pid"
printf '%s\n' 'reconcile' > "$RUNTIME_LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$RUNTIME_LOCK_DIR/started_at"
printf '%s\n' 'held' > "$RUNTIME_LOCK_DIR/state"

busy_rc=0
acquire_runtime_transaction_lock connect || busy_rc=$?
assert_eq '75' "$busy_rc" 'transaction lock contention returns RC_BUSY'
assert_eq '0' "$RUNTIME_TRANSACTION_LOCK_HELD" 'contended acquisition does not mark the lock held'
assert_eq 'unset' "${NORDVPN_EASY_LOCK_INHERITED:-unset}" 'contended acquisition does not hand down inheritance'
assert_eq "$$" "$(cat "$RUNTIME_LOCK_DIR/pid")" 'contended acquisition leaves the live holder untouched'

printf '%s\n' 'test-init-transaction-lock.sh: ok'
