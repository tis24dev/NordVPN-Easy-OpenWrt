#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"

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

log() { :; }

FAKE_NOW_FILE="$TMP_DIR/fake-now"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=0
IFDOWN_CALLS=0
IFUP_CALLS=0
VERIFY_CALLS=0
VERIFY_ARGS=''
VERIFY_RETURN=0

date() {
	local now_value

	if [ "${1:-}" = '+%s' ]; then
		now_value="$(cat "$FAKE_NOW_FILE" 2>/dev/null || printf '%s' '0')"
		printf '%s\n' "$now_value"
		printf '%s\n' "$((now_value + 1))" > "$FAKE_NOW_FILE"
		return 0
	fi

	return 1
}

sleep() {
	SLEEP_CALLS="${SLEEP_CALLS}${1},"
}

ifdown() {
	IFDOWN_CALLS=$((IFDOWN_CALLS + 1))
	return 0
}

ifup() {
	IFUP_CALLS=$((IFUP_CALLS + 1))
	return 0
}

nordvpn_easy_ping_interface() {
	PING_ATTEMPTS=$((PING_ATTEMPTS + 1))
	[ "$SUCCESS_ON_ATTEMPT" -gt 0 ] && [ "$PING_ATTEMPTS" -ge "$SUCCESS_ON_ATTEMPT" ]
}

verify_public_country_selection() {
	VERIFY_CALLS=$((VERIFY_CALLS + 1))
	VERIFY_ARGS="${VERIFY_ARGS}${1:-0},"
	[ "$VERIFY_RETURN" -eq 0 ]
}

VPN_IF='wg0'
POST_RESTART_DELAY='5'
INTERFACE_RESTART_DELAY='1'

printf '%s\n' '100' > "$FAKE_NOW_FILE"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=2
nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "$POST_RESTART_DELAY" 'unit-test'

assert_eq '2' "$PING_ATTEMPTS" 'wait helper exits as soon as connectivity is restored'
assert_eq '1,' "$SLEEP_CALLS" 'wait helper sleeps only until the next successful probe'

printf '%s\n' '200' > "$FAKE_NOW_FILE"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=0
WAIT_RC=0
nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" '3' 'timeout-test' || WAIT_RC=$?

assert_eq '1' "$WAIT_RC" 'wait helper fails when connectivity never returns'
assert_eq '1,1,' "$SLEEP_CALLS" 'wait helper retries until the timeout window is exhausted'

printf '%s\n' '300' > "$FAKE_NOW_FILE"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=1
IFDOWN_CALLS=0
IFUP_CALLS=0
VERIFY_CALLS=0
VERIFY_ARGS=''
VERIFY_RETURN=1
VPN_COUNTRY='IT'
APPLY_RC=0
nordvpn_easy_apply_server_change_runtime reload || APPLY_RC=$?

assert_eq '1' "$APPLY_RC" 'runtime apply fails when strict public-country verification mismatches'
assert_eq '1' "$IFDOWN_CALLS" 'runtime apply cycles the interface before strict verification'
assert_eq '1' "$IFUP_CALLS" 'runtime apply brings the interface back up before strict verification'
assert_eq '1' "$VERIFY_CALLS" 'runtime apply verifies public country after connectivity is restored'
assert_eq '1,' "$VERIFY_ARGS" 'runtime apply requests strict public-country verification when a country is selected'

printf '%s\n' '400' > "$FAKE_NOW_FILE"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=1
VERIFY_CALLS=0
VERIFY_ARGS=''
VERIFY_RETURN=0
VPN_COUNTRY=''
APPLY_RC=0
nordvpn_easy_apply_server_change_runtime reload || APPLY_RC=$?

assert_eq '0' "$APPLY_RC" 'runtime apply succeeds with automatic country selection when connectivity is restored'
assert_eq '1' "$VERIFY_CALLS" 'runtime apply still records public-country verification in automatic mode'
assert_eq '0,' "$VERIFY_ARGS" 'runtime apply uses non-strict verification when no country is selected'

printf '%s\n' 'test-wireguard.sh: ok'
