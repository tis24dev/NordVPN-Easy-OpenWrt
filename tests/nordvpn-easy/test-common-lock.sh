#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


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

now_mono="$(nordvpn_easy_uptime_seconds)"

# A live holder WITHIN the TTL is a legitimately in-flight operation: contention
# is reported and the lock is never stolen. Age is measured from the MONOTONIC
# started_mono anchor, so an NTP wall-clock step cannot fake an expiry.
mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'check' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' "$now_mono" > "$LOCK_DIR/started_mono"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0

alive_young_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || alive_young_rc=$?
assert_eq '2' "$alive_young_rc" 'a live holder within the TTL is not stolen'
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'live-within-TTL lock ownership preserved'
rm -rf "$LOCK_DIR"

# A live holder aged PAST the TTL is WEDGED: the reaper reclaims the lock
# (mv-aside + a fresh token that revokes the old holder), keyed on the MONOTONIC
# age. Safe because the S7a effect fence neutralizes the old holder if it thaws.
mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'connect' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' "$(( now_mono - 5 ))" > "$LOCK_DIR/started_mono"
printf '%s\n' 'held' > "$LOCK_DIR/state"
printf '%s\n' 'stale-owner-token' > "$LOCK_DIR/token"
LOCK_ACQUIRED=0
NORDVPN_EASY_OWNER_TOKEN=''
NORDVPN_EASY_LOCK_TTL=2

reap_mono_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || reap_mono_rc=$?
assert_eq '0' "$reap_mono_rc" 'a live holder aged past the TTL is reaped (monotonic age)'
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'reaped lock is owned by the reaper'
[ "$(cat "$LOCK_DIR/token")" != 'stale-owner-token' ] || {
	printf '%s\n' 'FAIL: reaping must mint a fresh token that revokes the old holder' >&2
	exit 1
}
unset NORDVPN_EASY_LOCK_TTL
nordvpn_easy_release_lock
rm -rf "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN=''

# Fallback: a lock written by a pre-reaper build has no started_mono, so the
# reaper measures the wall-clock age instead -- an ancient started_at is still
# reaped (bounded by the default TTL) rather than blocking forever.
mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'connect' > "$LOCK_DIR/action"
printf '%s\n' '1' > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
LOCK_ACQUIRED=0
NORDVPN_EASY_OWNER_TOKEN=''

reap_fallback_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || reap_fallback_rc=$?
assert_eq '0' "$reap_fallback_rc" 'a wedged holder with no monotonic anchor is reaped via the wall-clock fallback'
nordvpn_easy_release_lock
rm -rf "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN=''

# The TTL override is normalized so a garbage value cannot expire every holder.
assert_eq '300' "$(nordvpn_easy_lock_ttl_seconds)" 'default lock TTL is 300s'
NORDVPN_EASY_LOCK_TTL=45
assert_eq '45' "$(nordvpn_easy_lock_ttl_seconds)" 'a numeric lock TTL override is honored'
NORDVPN_EASY_LOCK_TTL='not-a-number'
assert_eq '300' "$(nordvpn_easy_lock_ttl_seconds)" 'a garbage lock TTL override falls back to 300s'
unset NORDVPN_EASY_LOCK_TTL

# The monotonic uptime anchor is a non-negative integer.
uptime_val="$(nordvpn_easy_uptime_seconds)"
case "$uptime_val" in
	''|*[!0-9]*) printf '%s\n' "FAIL: uptime_seconds must be a non-negative integer: $uptime_val" >&2; exit 1 ;;
esac

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

# --- S6 owner-token fence ---------------------------------------------------
# A fresh acquisition mints a token, persists it, and sets the in-memory owner
# token to match, so owner_assert passes and release deletes the dir.
LOCK_DIR="$TMP_DIR/lock"
LOCK_ACQUIRED=0
NORDVPN_EASY_OWNER_TOKEN=''
tok_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || tok_rc=$?
assert_eq '0' "$tok_rc" 'token-fence: fresh acquisition succeeds'
[ -f "$LOCK_DIR/token" ] || { printf '%s\n' 'FAIL: acquisition must write a token file' >&2; exit 1; }
# A real acquisition must persist the monotonic anchor the reaper keys on; without
# it every lock silently degrades to the NTP-vulnerable wall-clock fallback.
[ -f "$LOCK_DIR/started_mono" ] || { printf '%s\n' 'FAIL: acquisition must write the started_mono anchor' >&2; exit 1; }
case "$(cat "$LOCK_DIR/started_mono")" in
	''|*[!0-9]*) printf '%s\n' 'FAIL: started_mono must be a non-negative integer' >&2; exit 1 ;;
esac
[ -n "$NORDVPN_EASY_OWNER_TOKEN" ] || { printf '%s\n' 'FAIL: acquisition must set the in-memory owner token' >&2; exit 1; }
assert_eq "$NORDVPN_EASY_OWNER_TOKEN" "$(cat "$LOCK_DIR/token")" 'token-fence: on-disk token matches the minted owner token'
nordvpn_easy_owner_assert || { printf '%s\n' 'FAIL: owner_assert must pass for the legitimate holder' >&2; exit 1; }

# A superseded holder (its on-disk token was replaced by a recoverer) must NOT
# delete the live owner's dir -- the B-2 load-bearing guarantee.
printf '%s\n' 'someone-elses-token' > "$LOCK_DIR/token"
if nordvpn_easy_owner_assert; then
	printf '%s\n' 'FAIL: owner_assert must fail when the on-disk token differs' >&2
	exit 1
fi
nordvpn_easy_release_lock
[ -d "$LOCK_DIR" ] || { printf '%s\n' 'FAIL: a superseded holder must not delete the live owner lock' >&2; exit 1; }
assert_eq '0' "$LOCK_ACQUIRED" 'token-fence: a superseded release clears the local flag'
rm -rf "$LOCK_DIR"

# owner_assert fails closed when the token file is missing entirely.
mkdir -p "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN='claim:1:2'
if nordvpn_easy_owner_assert; then
	printf '%s\n' 'FAIL: owner_assert must fail when no token file exists' >&2
	exit 1
fi
rm -rf "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN=''

# Two minted tokens are distinct (the uuid claim_id is the uniqueness guarantor).
tok_a="$(nordvpn_easy_new_owner_token)"
tok_b="$(nordvpn_easy_new_owner_token)"
[ "$tok_a" != "$tok_b" ] || { printf '%s\n' 'FAIL: two minted owner tokens must differ' >&2; exit 1; }

# proc_starttime returns a number for a live pid and fails closed on a dead one.
start_self="$(nordvpn_easy_proc_starttime "$$")"
case "$start_self" in
	''|*[!0-9]*) printf '%s\n' "FAIL: proc_starttime must return a numeric start time for self: $start_self" >&2; exit 1 ;;
esac
assert_eq 'NOSTAT' "$(nordvpn_easy_proc_starttime 999999)" 'proc_starttime fails closed on a dead pid'

# Child-on-exit (LOAD-BEARING): an adopting child keeps LOCK_ACQUIRED=0 even
# though it adopts the parent's MATCHING token, so its on_exit/release must NEVER
# delete the live parent's lock. If a future edit set LOCK_ACQUIRED=1 here, the
# adopted matching token would let owner_assert pass and the child would delete
# the parent lock (B-2 in reverse) -- this test pins the invariant.
mkdir -p "$LOCK_DIR"
parent_token="$(nordvpn_easy_new_owner_token)"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'connect' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
printf '%s\n' "$parent_token" > "$LOCK_DIR/token"
LOCK_ACQUIRED=0
NORDVPN_EASY_OWNER_TOKEN=''
NORDVPN_EASY_LOCK_INHERITED=1
child_rc=0
nordvpn_easy_acquire_lock >/dev/null 2>&1 || child_rc=$?
assert_eq '0' "$child_rc" 'child adopts the inherited lock'
assert_eq '0' "$LOCK_ACQUIRED" 'child-on-exit: adopting child never takes ownership'
assert_eq "$parent_token" "$NORDVPN_EASY_OWNER_TOKEN" 'child-on-exit: child adopts the parent token from disk'
nordvpn_easy_on_exit
[ -d "$LOCK_DIR" ] || { printf '%s\n' 'FAIL: child on_exit must not delete the live parent lock' >&2; exit 1; }
assert_eq "$$" "$(cat "$LOCK_DIR/pid")" 'child-on-exit: parent lock metadata preserved'
unset NORDVPN_EASY_LOCK_INHERITED
rm -rf "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN=''

# --- S7a effect fence: the fenced_* wrappers gate the effect on ownership ----
# This is the contract that protects a reaped/superseded writer once the reaper
# (S7b) can revoke a live token: the effect runs for the legit owner and is
# refused (no side effect) when the on-disk token no longer matches.
mkdir -p "$LOCK_DIR"
printf '%s\n' 'owner-tok' > "$LOCK_DIR/token"
NORDVPN_EASY_OWNER_TOKEN='owner-tok'
FENCED_UCI_RAN=0
FENCED_IF_RAN=0
uci() { FENCED_UCI_RAN=1; }
ifdown() { FENCED_IF_RAN=1; }

nordvpn_easy_fenced_uci_commit network
assert_eq '1' "$FENCED_UCI_RAN" 'fenced_uci_commit runs the commit for the legit owner'
nordvpn_easy_fenced_ifupdown down wg0
assert_eq '1' "$FENCED_IF_RAN" 'fenced_ifupdown runs the effect for the legit owner'

# Superseded: the on-disk token was replaced by a recoverer/reaper.
printf '%s\n' 'someone-else' > "$LOCK_DIR/token"
FENCED_UCI_RAN=0
FENCED_IF_RAN=0
fenced_uci_rc=0
nordvpn_easy_fenced_uci_commit network || fenced_uci_rc=$?
assert_eq '0' "$FENCED_UCI_RAN" 'fenced_uci_commit refuses (no commit) when superseded'
[ "$fenced_uci_rc" -ne 0 ] || { printf '%s\n' 'FAIL: fenced_uci_commit must return non-zero when superseded' >&2; exit 1; }
nordvpn_easy_fenced_ifupdown down wg0 || true
assert_eq '0' "$FENCED_IF_RAN" 'fenced_ifupdown refuses the effect when superseded'

# Tokenless: a process holding NO owner token is not a lock owner at all (a
# lock-free boot-disable or the disable_runtime verb), so the effect is ALLOWED
# through even though the on-disk token does not match it. This is what lets the
# dual-use disable path be fenced without breaking its legitimate lock-free
# callers -- and pins the load-bearing "no token -> proceed" guard.
FENCED_UCI_RAN=0
NORDVPN_EASY_OWNER_TOKEN=''
nordvpn_easy_fenced_uci_commit network
assert_eq '1' "$FENCED_UCI_RAN" 'fenced_uci_commit is allowed through for a tokenless (non-owner) caller'

unset -f uci ifdown 2>/dev/null || true
rm -rf "$LOCK_DIR"
NORDVPN_EASY_OWNER_TOKEN=''

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
