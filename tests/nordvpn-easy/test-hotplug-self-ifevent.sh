#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# S7 increment 7: the generated hotplug hook skips an interface event the supervisor
# generated itself. The supervisor writes RUN_DIR/self-ifevent (iface + a wall-clock
# expiry) around its bring-up; while that sentinel names THIS interface and has not
# expired, the ifup is the supervisor's own and the hook exits early -- BEFORE writing
# the debounce stamp and before running the health-check. This test generates the real
# hook (install_hotplug_hook), patches its hardcoded RUN_DIR/LOCK_DIR to temp paths,
# and drives it with ACTION/INTERFACE. Detection: the self-ifevent skip returns BEFORE
# the debounce stamp is written, so the stamp file's presence == "did NOT self-skip".

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
HOOKS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/hooks.sh"
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

# Generate the real hotplug hook via install_hotplug_hook, then redirect its hardcoded
# RUN_DIR (/tmp/run/nordvpn-easy) and LOCK_DIR (/tmp/nordvpn-easy.lock) to temp paths.
(
	# install_hotplug_hook mkdir's the real /etc/hotplug.d/iface (root-owned; fails for
	# a non-root test), so disable set -e -- the hook is still written to HOTPLUG_PATH.
	set +e
	# shellcheck disable=SC1090
	. "$HOOKS_LIB"
	nordvpn_easy_shell_quote() { printf '%s' "$1"; }
	log_service_info() { :; }
	log_service_error() { :; }
	cfg_enabled=1
	cfg_enable_hotplug=1
	cfg_wan_if='wan'
	cfg_vpn_if='wg0'
	cfg_hotplug_debounce_seconds=30
	SERVICE_NAME='nordvpn-easy'
	HOTPLUG_PATH="$TMP_DIR/hotplug.orig"
	install_hotplug_hook 1 >/dev/null 2>&1
	:
)
[ -f "$TMP_DIR/hotplug.orig" ] || { printf '%s\n' 'FAIL: could not generate the hotplug hook' >&2; exit 1; }
RUN="$TMP_DIR/run"
LOCK="$TMP_DIR/lock"
sed "s#/tmp/run/nordvpn-easy#$RUN#g; s#/tmp/nordvpn-easy.lock#$LOCK#g" "$TMP_DIR/hotplug.orig" > "$TMP_DIR/hotplug"
mkdir -p "$RUN" "$LOCK"
STAMP="$RUN/hotplug.last"
SELF="$RUN/self-ifevent"

# A live, busy lock so a non-self ifup exits at the lock-busy check (AFTER the stamp)
# instead of falling through to the real /etc/init.d check.
printf '%s\n' "$$" > "$LOCK/pid"
printf '%s\n' 'supervise' > "$LOCK/action"
printf '%s\n' '0' > "$LOCK/started_at"

run_hook() { # ACTION INTERFACE
	rm -f "$STAMP"
	env -i ACTION="$1" INTERFACE="$2" PATH="$PATH" sh "$TMP_DIR/hotplug" >/dev/null 2>&1 || true
}
stamped() { [ -f "$STAMP" ] && printf 'yes' || printf 'no'; }

NOW="$(date +%s)"

# (a) matching sentinel, future expiry -> SELF-SKIP (returns before the stamp)
printf 'iface=wg0\nexpires=%s\ntarget_fingerprint=fp\n' "$((NOW + 60))" > "$SELF"
run_hook ifup wg0
assert_eq 'no' "$(stamped)" 'inc7: a matching, unexpired self-ifevent skips before the debounce stamp'

# same for ifupdate (also a self-generated event)
printf 'iface=wg0\nexpires=%s\n' "$((NOW + 60))" > "$SELF"
run_hook ifupdate wg0
assert_eq 'no' "$(stamped)" 'inc7: ifupdate is also skipped by a matching self-ifevent'

# (b) EXPIRED sentinel -> does NOT self-skip (falls through -> stamp written)
printf 'iface=wg0\nexpires=%s\n' "$((NOW - 60))" > "$SELF"
run_hook ifup wg0
assert_eq 'yes' "$(stamped)" 'inc7: an EXPIRED self-ifevent does not skip'

# (c) sentinel for a DIFFERENT interface -> does NOT skip this interface
printf 'iface=wan\nexpires=%s\n' "$((NOW + 60))" > "$SELF"
run_hook ifup wg0
assert_eq 'yes' "$(stamped)" 'inc7: a self-ifevent for another interface does not skip this one'

# (d) no sentinel -> normal handling (stamp written, then lock-busy exit)
rm -f "$SELF"
run_hook ifup wg0
assert_eq 'yes' "$(stamped)" 'inc7: with no sentinel the hook handles the event normally'

printf '%s\n' 'test-hotplug-self-ifevent.sh: ok'
