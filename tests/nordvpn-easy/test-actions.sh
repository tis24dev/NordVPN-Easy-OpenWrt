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

RESOLVED_COUNTRY_CODE='IT'
nordvpn_easy_server_list_cache_is_usable || {
	printf '%s\n' 'FAIL: recommended server cache should be usable for its country' >&2
	exit 1
}
RESOLVED_COUNTRY_CODE='HK'
if nordvpn_easy_server_list_cache_is_usable; then
	printf '%s\n' 'FAIL: recommended server cache should not be reused for a different country' >&2
	exit 1
fi
RESOLVED_COUNTRY_CODE=''

VPN_COUNTRY='IT'
VPN_IF='wg0'
VPN_CONFIGURED_RC=0
SERVER_RECOMMENDATIONS_URL_BASE='https://example.invalid/recommendations'
CURRENT_SERVER_VALUE='it0'
CURRENT_COUNTRY_VALUE='IT'
COMMIT_NETWORK_COUNT=0
COMMIT_PREF_COUNT=0
APPLY_COUNT=0
APPLY_FAIL_UNTIL=0
COMMIT_PREF_FAIL_UNTIL=0
LAST_SET_SERVER=''
SET_SEQUENCE=''
LAST_SET_PUBLIC_KEY=''
SAVED_PREFERENCE=''
IFDOWN_COUNT=0
IFUP_COUNT=0
WAIT_COUNT=0
VERIFY_COUNT=0
PREFERRED_SERVER_HOSTNAME='it12.nordvpn.com'
PREFERRED_SERVER_STATION='it123'
FALLBACK_SERVER_STATION=''
PING_FAIL_UNTIL=0
PING_COUNT=0
POST_RESTART_DELAY=10

log() { :; }
fetch_server_catalog() { return 0; }
nordvpn_easy_require_manual_server_preference() { return 0; }
nordvpn_easy_current_server_station() { printf '%s\n' "$CURRENT_SERVER_VALUE"; }
nordvpn_easy_current_server_country() { printf '%s\n' "$CURRENT_COUNTRY_VALUE"; }
nordvpn_easy_set_vpn_server_in_uci() { LAST_SET_SERVER="$1|$2"; LAST_SET_PUBLIC_KEY="$3"; SET_SEQUENCE="${SET_SEQUENCE}$1|$2;"; return 0; }
nordvpn_easy_set_server_preference_in_uci() { SAVED_PREFERENCE="$1|$2"; }
nordvpn_easy_ping_interface() {
	PING_COUNT=$((PING_COUNT + 1))
	[ "$PING_COUNT" -gt "$PING_FAIL_UNTIL" ]
}
nordvpn_easy_ping_wan() { return 0; }
CACHED_VPN_COUNTRY="$VPN_COUNTRY"
VPN_COUNTRY=''
CURL_CALL_COUNT=0
# shellcheck disable=SC2317
curl() {
	CURL_CALL_COUNT=$((CURL_CALL_COUNT + 1))
	printf '%s\n' 'curl: (28) Operation timed out' >&2
	return 28
}

nordvpn_easy_get_servers_list || {
	printf '%s\n' 'FAIL: server list refresh should fall back to the existing cache after API failure' >&2
	exit 1
}

assert_eq '1' "$CURL_CALL_COUNT" 'server list refresh attempts API before cache fallback'
assert_eq 'it123' "$(jq -r '.[0].station' "$SERVER_LIST_FILE")" 'server list cache is kept when API fails'
unset -f curl 2>/dev/null || true
VPN_COUNTRY="$CACHED_VPN_COUNTRY"

nordvpn_easy_get_servers_list() { return 0; }
nordvpn_easy_server_selection_is_manual() { [ "${SERVER_SELECTION_MODE:-auto}" = 'manual' ]; }
nordvpn_easy_vpn_is_configured() { return "$VPN_CONFIGURED_RC"; }
nordvpn_easy_log_vpn_interface_state() { :; }
sleep() { :; }
ifdown() { IFDOWN_COUNT=$((IFDOWN_COUNT + 1)); }
ifup() { IFUP_COUNT=$((IFUP_COUNT + 1)); }
nordvpn_easy_wait_for_vpn_connectivity() { WAIT_COUNT=$((WAIT_COUNT + 1)); return 0; }
verify_public_country_selection() { VERIFY_COUNT=$((VERIFY_COUNT + 1)); return 0; }

FETCH_COUNT=0
CONFIGURE_COUNT=0
PUBLIC_VERIFICATION_WRITES=0
nordvpn_easy_fetch_provision_prerequisites() { FETCH_COUNT=$((FETCH_COUNT + 1)); return 0; }
nordvpn_easy_configure_vpn_interface() { CONFIGURE_COUNT=$((CONFIGURE_COUNT + 1)); return 0; }
nordvpn_easy_public_verification_write() { PUBLIC_VERIFICATION_WRITES=$((PUBLIC_VERIFICATION_WRITES + 1)); return 0; }
nordvpn_easy_provision_vpn_connect_apply

assert_eq '1' "$FETCH_COUNT" 'connect_apply fetches provisioning prerequisites'
assert_eq '1' "$CONFIGURE_COUNT" 'connect_apply configures WireGuard'
assert_eq '1' "$WAIT_COUNT" 'connect_apply waits for WireGuard/runtime readiness'
assert_eq '0' "$VERIFY_COUNT" 'connect_apply does not block on public IP verification'
assert_eq '1' "$PUBLIC_VERIFICATION_WRITES" 'connect_apply marks public verification pending'

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

NORDVPN_EASY_ROTATE_EXCLUDE_STATION='it123'
NORDVPN_EASY_PROVISION_MODE='rotate'
LAST_SET_SERVER=''
nordvpn_easy_set_first_server_from_list
assert_eq 'it45.nordvpn.com|it456' "$LAST_SET_SERVER" 'rotate mode skips the current recommended station'

COUNTRIES_CACHE_FILE="$TMP_DIR/countries-bz-only.json"
COUNTRIES_CACHE_TS_FILE="$TMP_DIR/countries-bz-only.timestamp"
jq -n '[{ "id": 22, "name": "Belize", "code": "BZ" }]' > "$COUNTRIES_CACHE_FILE"
date +%s > "$COUNTRIES_CACHE_TS_FILE"
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_NAME=''
RESOLVED_COUNTRY_CODE=''
RESOLVED_COUNTRY_QUERY=''

# Exercise the REAL resolve_country_filter / valid_country_code from core.sh
# (extracted, not a drifting copy) so a production regression is caught here.
CORE_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"
PUBLIC_IP_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/public-ip.sh"
extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn " ?\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$2"
}
eval "$(extract_function nordvpn_easy_public_ip_valid_country_code "$PUBLIC_IP_LIB")"
eval "$(extract_function valid_country_code "$CORE_SCRIPT")"
eval "$(extract_function resolve_country_filter "$CORE_SCRIPT")"
# The cache is pre-seeded above; stub the fetch + logging so resolution reads the
# seeded cache directly and stays quiet.
refresh_countries_cache() { return 0; }
log() { :; }

# A country present in the cache resolves to its API id.
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_QUERY=''
resolve_country_filter 'BZ' || {
	printf '%s\n' 'FAIL: BZ should resolve from the country cache' >&2
	exit 1
}
[ "$RESOLVED_COUNTRY_ID" = '22' ] && [ "$RESOLVED_COUNTRY_CODE" = 'BZ' ] || {
	printf '%s\n' "FAIL: BZ should resolve to id 22 (got id=${RESOLVED_COUNTRY_ID:-unset})" >&2
	exit 1
}

# A valid country code absent from a readable cache soft-resolves (filter by
# code) instead of failing the whole operation.
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_QUERY=''
resolve_country_filter 'EC' || {
	printf '%s\n' 'FAIL: EC should soft-resolve when missing from country cache' >&2
	exit 1
}
[ -z "$RESOLVED_COUNTRY_ID" ] && [ "$RESOLVED_COUNTRY_CODE" = 'EC' ] || {
	printf '%s\n' 'FAIL: soft resolve should keep EC code without API country id' >&2
	exit 1
}

# An unparseable cache also soft-resolves a valid code (jq fails, not empty).
printf '%s' 'not json{' > "$COUNTRIES_CACHE_FILE"
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_QUERY=''
resolve_country_filter 'EC' || {
	printf '%s\n' 'FAIL: EC should soft-resolve when the country cache is unparseable' >&2
	exit 1
}
[ -z "$RESOLVED_COUNTRY_ID" ] && [ "$RESOLVED_COUNTRY_CODE" = 'EC' ] || {
	printf '%s\n' 'FAIL: soft resolve should keep EC code when the cache is unparseable' >&2
	exit 1
}

# An invalid (not two-letter-uppercase) query is a hard not-found.
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_QUERY=''
invalid_rc=0
resolve_country_filter 'zz' || invalid_rc=$?
[ "$invalid_rc" -ne 0 ] || {
	printf '%s\n' 'FAIL: an invalid country query must not resolve' >&2
	exit 1
}

# Restore a valid cache for the remaining tests.
jq -n '[{ "id": 22, "name": "Belize", "code": "BZ" }]' > "$COUNTRIES_CACHE_FILE"

RESOLVED_COUNTRY_CODE='IT'
nordvpn_easy_set_first_server_from_list || {
	printf '%s\n' 'FAIL: server list filter should select IT entry' >&2
	exit 1
}
[ "$COUNTRY_CODE" = 'IT' ] || {
	printf '%s\n' "FAIL: expected IT server after country filter, got ${COUNTRY_CODE:-unset}" >&2
	exit 1
}

PROVISION_COUNT=0
CHECK_COUNT=0
refresh_countries_cache() { return 0; }
resolve_country_filter() { return 0; }
nordvpn_easy_provision_vpn() { PROVISION_COUNT=$((PROVISION_COUNT + 1)); return 0; }
nordvpn_easy_check_once_finish() { :; }

nordvpn_easy_reconcile_action

assert_eq '1' "$PROVISION_COUNT" 'reconcile reprovisions the VPN from saved settings'

PING_COUNT=0
PING_FAIL_UNTIL=1
PROVISION_COUNT=0
FAILURE_RETRY_DELAY=0
nordvpn_easy_runtime_needs_provision() { return 0; }

nordvpn_easy_check_once

assert_eq '1' "$PROVISION_COUNT" 'health check reprovisions when the runtime is degraded'

printf '%s\n' 'test-actions.sh: ok'
