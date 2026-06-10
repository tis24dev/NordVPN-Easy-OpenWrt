#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"

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

ACTION='server_catalog'
LOCK_DIR="$TMP_DIR/lock"
LOCK_ACQUIRED=0
NORDVPN_EASY_EXIT_TRAP_INSTALLED=0
nordvpn_easy_install_exit_trap() { :; }

nordvpn_easy_log() { :; }

first_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || first_rc=$?
assert_eq '0' "$first_rc" 'first lock acquisition'

second_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || second_rc=$?
assert_eq '2' "$second_rc" 'second acquisition reports contention'

nordvpn_easy_release_lock
[ ! -d "$LOCK_DIR" ] || {
	printf '%s\n' 'FAIL: lock directory was not removed' >&2
	exit 1
}

mkdir -p "$LOCK_DIR"
printf '%s\n' '999999' > "$LOCK_DIR/pid"
printf '%s\n' 'stale' > "$LOCK_DIR/action"
LOCK_ACQUIRED=0

stale_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || stale_rc=$?
assert_eq '0' "$stale_rc" 'stale lock recovery'
nordvpn_easy_release_lock

mkdir -p "$LOCK_DIR"
printf '%s\n' 'missing-pid-action' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0

missing_pid_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || missing_pid_rc=$?
assert_eq '2' "$missing_pid_rc" 'missing pid metadata is treated as contention'
[ -d "$LOCK_DIR" ] || {
	printf '%s\n' 'FAIL: lock directory should remain when pid metadata is missing' >&2
	exit 1
}
rm -rf "$LOCK_DIR"

mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'check' > "$LOCK_DIR/action"
printf '%s\n' '1' > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0

alive_old_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || alive_old_rc=$?
assert_eq '2' "$alive_old_rc" 'alive lock is never stolen even when old'
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'alive lock ownership preserved'
rm -rf "$LOCK_DIR"

# Inherited lock: a parent transaction holds the lock and hands it down to a
# child core.sh via NORDVPN_EASY_LOCK_INHERITED. The child adopts the live
# holder's lock without taking ownership and must never remove it on release.
mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'connect' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0
NORDVPN_EASY_LOCK_INHERITED=1

inherit_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || inherit_rc=$?
assert_eq '0' "$inherit_rc" 'inherited lock with a live holder is adopted'
assert_eq '0' "$LOCK_ACQUIRED" 'adopting an inherited lock does not take ownership'

nordvpn_easy_release_lock
[ -d "$LOCK_DIR" ] || {
	printf '%s\n' 'FAIL: a non-owner release must not remove the inherited lock' >&2
	exit 1
}
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'inherited lock holder metadata preserved'
rm -rf "$LOCK_DIR"

# Inherited but the recorded holder is gone: fall through to a real acquisition
# so the child is never left running unprotected.
mkdir -p "$LOCK_DIR"
printf '%s\n' '999999' > "$LOCK_DIR/pid"
printf '%s\n' 'connect' > "$LOCK_DIR/action"
LOCK_ACQUIRED=0
NORDVPN_EASY_LOCK_INHERITED=1

fallthrough_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || fallthrough_rc=$?
assert_eq '0' "$fallthrough_rc" 'inherited-but-dead lock falls through to a direct acquisition'
assert_eq '1' "$LOCK_ACQUIRED" 'fallthrough acquisition takes ownership'
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'fallthrough acquisition records this pid'
nordvpn_easy_release_lock
unset NORDVPN_EASY_LOCK_INHERITED

printf '%s\n' 'test-common-lock.sh: ok'
