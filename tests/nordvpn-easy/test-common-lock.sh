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

# A fresh pid-less lock (within the grace window) is treated as contention: a
# creator may legitimately still be mid-write between mkdir and the metadata.
mkdir -p "$LOCK_DIR"
printf '%s\n' 'missing-pid-action' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0

missing_pid_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || missing_pid_rc=$?
assert_eq '2' "$missing_pid_rc" 'fresh missing-pid lock is treated as contention'
[ -d "$LOCK_DIR" ] || {
	printf '%s\n' 'FAIL: lock directory should remain when pid metadata is missing' >&2
	exit 1
}
rm -rf "$LOCK_DIR"

# An aged pid-less lock (a crash between mkdir and the metadata write) can never
# gain a live owner, so it is recovered instead of blocking every future
# operation forever while status reports the runtime as idle.
mkdir -p "$LOCK_DIR"
printf '%s\n' 'aged-missing-pid' > "$LOCK_DIR/action"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0

aged_pidless_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || aged_pidless_rc=$?
assert_eq '0' "$aged_pidless_rc" 'aged pid-less lock is recovered, not a permanent block'
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'recovered pid-less lock is owned by the recoverer'
nordvpn_easy_release_lock
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

# --- Bounded-wait acquire (nordvpn_easy_acquire_lock wrapper) ---------------
# Deliberate apply actions (connect/reconnect) wait briefly for a TRANSIENT lock
# holder instead of aborting busy. Drive the wrapper with a stubbed try function
# so we test the retry/terminate logic without real lock timing.
TRY_CALLS=0

# Default (no wait window) must stay fail-fast: exactly one try, busy passed
# straight through.
_nordvpn_easy_try_acquire_lock() { TRY_CALLS=$((TRY_CALLS + 1)); return 2; }
TRY_CALLS=0
ff_rc=0
NORDVPN_EASY_LOCK_WAIT_SECONDS=0 nordvpn_easy_acquire_lock >/dev/null 2>&1 || ff_rc=$?
assert_eq '2' "$ff_rc" 'default acquire is fail-fast on contention'
assert_eq '1' "$TRY_CALLS" 'fail-fast acquire tries exactly once (no retry)'

# A transient holder that releases: try returns busy twice, then success. The
# wrapper must retry and acquire (the country-change fix).
TRY_CALLS=0
_nordvpn_easy_try_acquire_lock() {
	TRY_CALLS=$((TRY_CALLS + 1))
	[ "$TRY_CALLS" -ge 3 ] && return 0
	return 2
}
wait_rc=0
NORDVPN_EASY_LOCK_WAIT_SECONDS=5 NORDVPN_EASY_LOCK_WAIT_INTERVAL=1 \
	nordvpn_easy_acquire_lock >/dev/null 2>&1 || wait_rc=$?
assert_eq '0' "$wait_rc" 'bounded wait acquires once a transient holder releases'
assert_eq '3' "$TRY_CALLS" 'bounded wait retries until the lock frees'

# A hard error (rc 1) is terminal: never retried.
TRY_CALLS=0
_nordvpn_easy_try_acquire_lock() { TRY_CALLS=$((TRY_CALLS + 1)); return 1; }
hard_rc=0
NORDVPN_EASY_LOCK_WAIT_SECONDS=5 nordvpn_easy_acquire_lock >/dev/null 2>&1 || hard_rc=$?
assert_eq '1' "$hard_rc" 'bounded wait surfaces a hard error immediately'
assert_eq '1' "$TRY_CALLS" 'bounded wait does not retry a hard error'

# A holder that never releases: the wait must TERMINATE (return busy), never hang.
TRY_CALLS=0
_nordvpn_easy_try_acquire_lock() { TRY_CALLS=$((TRY_CALLS + 1)); return 2; }
stuck_rc=0
NORDVPN_EASY_LOCK_WAIT_SECONDS=2 NORDVPN_EASY_LOCK_WAIT_INTERVAL=1 \
	nordvpn_easy_acquire_lock >/dev/null 2>&1 || stuck_rc=$?
assert_eq '2' "$stuck_rc" 'bounded wait gives up busy when the holder never releases'
[ "$TRY_CALLS" -ge 2 ] || {
	printf '%s\n' 'FAIL: bounded wait should retry at least once before giving up' >&2
	exit 1
}
[ "$TRY_CALLS" -le 10 ] || {
	printf '%s\n' 'FAIL: bounded wait iteration cap did not bound the retries' >&2
	exit 1
}

printf '%s\n' 'test-common-lock.sh: ok'
