#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
CATALOG_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/catalog.sh"
ACTIONS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh"
FIXTURE="$ROOT_DIR/tests/nordvpn-easy/fixtures/nordvpn-api-servers.json"
TMP_DIR="$(mktemp -d)"
SERVER_LIST_FILE="$TMP_DIR/recommendations.json"
SERVER_CATALOG_FILE="$TMP_DIR/catalog.json"
FIRST_SERVER_LIST_FILE="$TMP_DIR/first-server.json"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$CATALOG_LIB"
# shellcheck disable=SC1090
. "$ACTIONS_LIB"

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

jq '. + [{
	"hostname": "it77.nordvpn.com",
	"station": "it777",
	"load": 77,
	"status": "online",
	"locations": [{
		"country": {
			"code": "IT",
			"name": "Italy",
			"city": { "name": "Naples" }
		}
	}],
	"technologies": [{
		"identifier": "wireguard_udp",
		"metadata": [{ "name": "public_key", "value": "PUBKEY-777" }]
	}]
}]' "$FIXTURE" > "$SERVER_LIST_FILE"

nordvpn_easy_build_server_catalog_json 237 IT Italy < "$SERVER_LIST_FILE" > "$SERVER_CATALOG_FILE"

VPN_COUNTRY='IT'
VPN_IF='wg0'
SERVER_RECOMMENDATIONS_URL_BASE='https://example.invalid/recommendations'
CURRENT_SERVER_VALUE='it0'
COMMIT_NETWORK_COUNT=0
COMMIT_PREF_COUNT=0
APPLY_COUNT=0
APPLY_FAIL_UNTIL=0
COMMIT_PREF_FAIL_UNTIL=0
LAST_SET_SERVER=''
SET_SEQUENCE=''
LAST_SET_PUBLIC_KEY=''
SAVED_PREFERENCE=''
PREFERRED_SERVER_HOSTNAME='it12.nordvpn.com'
PREFERRED_SERVER_STATION='it123'
FALLBACK_SERVER_STATION=''
PING_FAIL_UNTIL=0
PING_COUNT=0

log() { :; }
fetch_server_catalog() { return 0; }
nordvpn_easy_require_manual_server_preference() { return 0; }
nordvpn_easy_current_server_station() { printf '%s\n' "$CURRENT_SERVER_VALUE"; }
nordvpn_easy_set_vpn_server_in_uci() { LAST_SET_SERVER="$1|$2"; LAST_SET_PUBLIC_KEY="$3"; SET_SEQUENCE="${SET_SEQUENCE}$1|$2;"; return 0; }
nordvpn_easy_set_server_preference_in_uci() { SAVED_PREFERENCE="$1|$2"; }
nordvpn_easy_ping_interface() {
	PING_COUNT=$((PING_COUNT + 1))
	[ "$PING_COUNT" -gt "$PING_FAIL_UNTIL" ]
}
nordvpn_easy_ping_wan() { return 0; }
nordvpn_easy_get_servers_list() { return 0; }
nordvpn_easy_server_selection_is_manual() { [ "${SERVER_SELECTION_MODE:-auto}" = 'manual' ]; }
nordvpn_easy_vpn_is_configured() { return 0; }
nordvpn_easy_preferred_server_matches_current() { return 1; }
nordvpn_easy_apply_server_change_runtime() {
	APPLY_COUNT=$((APPLY_COUNT + 1))
	if [ "$APPLY_COUNT" -le "$APPLY_FAIL_UNTIL" ]; then
		return 1
	fi
	return 0
}

uci() {
	if [ "$1" = 'commit' ] && [ "$2" = 'network' ]; then
		COMMIT_NETWORK_COUNT=$((COMMIT_NETWORK_COUNT + 1))
		return 0
	fi

	if [ "$1" = 'commit' ] && [ "$2" = 'nordvpn_easy' ]; then
		COMMIT_PREF_COUNT=$((COMMIT_PREF_COUNT + 1))
		if [ "$COMMIT_PREF_COUNT" -le "$COMMIT_PREF_FAIL_UNTIL" ]; then
			return 1
		fi
		return 0
	fi

	return 0
}

jq '.[0].technologies = [
	{
		"identifier": "openvpn_udp",
		"metadata": [{ "name": "public_key", "value": "WRONG-KEY" }]
	},
	{
		"identifier": "wireguard_udp",
		"metadata": [{ "name": "public_key", "value": "RIGHT-KEY" }]
	}
]' "$FIXTURE" > "$FIRST_SERVER_LIST_FILE"

SERVER_LIST_FILE="$FIRST_SERVER_LIST_FILE"
LAST_SET_SERVER=''
LAST_SET_PUBLIC_KEY=''

nordvpn_easy_set_first_server_from_list

assert_eq 'it12.nordvpn.com|it123' "$LAST_SET_SERVER" 'first recommended server uses first list entry'
assert_eq 'RIGHT-KEY' "$LAST_SET_PUBLIC_KEY" 'first recommended server uses WireGuard public key'

SERVER_LIST_FILE="$TMP_DIR/recommendations.json"

APPLY_FAIL_UNTIL=1
APPLY_COUNT=0
COMMIT_NETWORK_COUNT=0
LAST_SET_SERVER=''

nordvpn_easy_change_vpn_server reload

assert_eq '2' "$APPLY_COUNT" 'recommended rotation retries next candidate after apply failure'
assert_eq '2' "$COMMIT_NETWORK_COUNT" 'recommended rotation commits each tried candidate'
assert_eq 'it45.nordvpn.com|it456' "$LAST_SET_SERVER" 'recommended rotation lands on second candidate'

APPLY_FAIL_UNTIL=0
APPLY_COUNT=0
COMMIT_NETWORK_COUNT=0
COMMIT_PREF_COUNT=0
COMMIT_PREF_FAIL_UNTIL=1
LAST_SET_SERVER=''
SAVED_PREFERENCE=''
LAST_SET_PUBLIC_KEY=''

nordvpn_easy_change_manual_server reload

assert_eq '1' "$COMMIT_PREF_COUNT" 'manual rotation does not retry after preference commit failure once runtime apply succeeded'
assert_eq '1' "$APPLY_COUNT" 'manual rotation keeps the first successful runtime apply'
assert_eq 'it12.nordvpn.com|it123' "$SAVED_PREFERENCE" 'manual rotation keeps the applied server preference even when commit warns'
assert_eq 'it12.nordvpn.com' "$PREFERRED_SERVER_HOSTNAME" 'manual hostname updated in environment'
assert_eq 'it123' "$PREFERRED_SERVER_STATION" 'manual station updated in environment'

APPLY_FAIL_UNTIL=1
APPLY_COUNT=0
COMMIT_NETWORK_COUNT=0
COMMIT_PREF_COUNT=0
COMMIT_PREF_FAIL_UNTIL=0
LAST_SET_SERVER=''
SET_SEQUENCE=''
SAVED_PREFERENCE=''
PREFERRED_SERVER_HOSTNAME='it12.nordvpn.com'
PREFERRED_SERVER_STATION='it123'
FALLBACK_SERVER_STATION='it456'

nordvpn_easy_change_to_preferred_server reload

assert_eq '2' "$COMMIT_NETWORK_COUNT" 'preferred server apply retries with configured fallback after runtime failure'
assert_eq '1' "$COMMIT_PREF_COUNT" 'fallback promotion commits the new preferred server once'
assert_eq '2' "$APPLY_COUNT" 'fallback promotion performs a second runtime apply'
assert_eq 'it12.nordvpn.com|it123;it45.nordvpn.com|it456;' "$SET_SEQUENCE" 'fallback promotion tries the preferred server before the fallback server'
assert_eq 'it45.nordvpn.com|it456' "$LAST_SET_SERVER" 'fallback promotion lands on the configured fallback server'
assert_eq 'it45.nordvpn.com|it456' "$SAVED_PREFERENCE" 'fallback promotion updates the preferred server in UCI'
assert_eq 'it45.nordvpn.com' "$PREFERRED_SERVER_HOSTNAME" 'fallback promotion updates the preferred hostname in environment'
assert_eq 'it456' "$PREFERRED_SERVER_STATION" 'fallback promotion updates the preferred station in environment'

nordvpn_easy_try_configured_fallback_server() {
	TRY_FALLBACK_COUNT=$((TRY_FALLBACK_COUNT + 1))
	return 0
}

sleep() { :; }
ifdown() { :; }
ifup() { :; }

TRY_FALLBACK_COUNT=0
PING_COUNT=0
PING_FAIL_UNTIL=99
SERVER_SELECTION_MODE='manual'
FALLBACK_SERVER_STATION='it456'
FAILURE_RETRY_DELAY=1
SERVER_ROTATE_THRESHOLD=2
INTERFACE_RESTART_THRESHOLD=10
MAX_INTERFACE_RESTARTS=0
INTERFACE_RESTART_DELAY=1
POST_RESTART_DELAY=10

nordvpn_easy_check_once

assert_eq '1' "$TRY_FALLBACK_COUNT" 'manual health check tries the configured fallback server at the rotation threshold'

printf '%s\n' 'test-actions.sh: ok'
