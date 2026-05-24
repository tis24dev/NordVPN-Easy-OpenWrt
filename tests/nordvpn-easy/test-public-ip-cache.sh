#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
PUBLIC_IP_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/public-ip.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"
# shellcheck disable=SC1090
. "$PUBLIC_IP_LIB"

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

assert_valid_ip() {
	ip="$1"
	label="$2"

	if ! nordvpn_easy_public_ip_valid_ip "$ip"; then
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "expected valid IP: $ip" >&2
		exit 1
	fi
}

assert_invalid_ip() {
	ip="$1"
	label="$2"

	if nordvpn_easy_public_ip_valid_ip "$ip"; then
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "expected invalid IP: $ip" >&2
		exit 1
	fi
}

emit_public_ip_cache_snapshot_fixture() {
	cat <<EOF
{
  "ip": "$(nordvpn_easy_json_escape "$PUBLIC_IP")",
  "changed": $([ "${PUBLIC_IP_CHANGED:-0}" = '1' ] && printf '%s' 'true' || printf '%s' 'false'),
  "detected_at": $(nordvpn_easy_wg_runtime_non_negative_int "${PUBLIC_IP_DETECTED_AT:-0}"),
  "detected_at_iso": "$(nordvpn_easy_json_escape "$PUBLIC_IP_DETECTED_AT_ISO")",
  "source": "$(nordvpn_easy_json_escape "$PUBLIC_IP_SOURCE")",
  "country": "$(nordvpn_easy_json_escape "$PUBLIC_COUNTRY")"
}
EOF
}

assert_valid_ip '203.0.113.9' 'public IP validator accepts IPv4'
assert_invalid_ip '256.0.0.1' 'public IP validator rejects IPv4 octet above 255'
assert_invalid_ip '999.999.999.999' 'public IP validator rejects invalid IPv4 octets'
assert_valid_ip '2001:db8:85a3:0:0:8a2e:370:7334' 'public IP validator accepts full IPv6'
assert_valid_ip '2001:db8::1' 'public IP validator accepts compressed IPv6'
assert_valid_ip '::1' 'public IP validator accepts loopback IPv6'
assert_valid_ip '::' 'public IP validator accepts unspecified IPv6'
assert_valid_ip 'fe80::' 'public IP validator accepts trailing IPv6 compression'
assert_invalid_ip '::::' 'public IP validator rejects repeated colon noise'
assert_invalid_ip '12345::1' 'public IP validator rejects overlong IPv6 group'
assert_invalid_ip '2001:db8::1::2' 'public IP validator rejects multiple IPv6 compression markers'
assert_invalid_ip 'g001:db8::1' 'public IP validator rejects non-hex IPv6 group'
assert_invalid_ip '1:2:3:4:5:6:7' 'public IP validator rejects short uncompressed IPv6'

PUBLIC_IP='203.0.113.9'
PUBLIC_IP_CHANGED='0'
PUBLIC_IP_DETECTED_AT='not-a-number'
PUBLIC_IP_DETECTED_AT_ISO='2026-02-01T00:00:00Z'
PUBLIC_IP_SOURCE='https://example.test/ip'
PUBLIC_COUNTRY='US'

SNAPSHOT_JSON="$(emit_public_ip_cache_snapshot_fixture)"

assert_eq '0' "$(printf '%s' "$SNAPSHOT_JSON" | jq -r '.detected_at')" \
	'public IP snapshot emits numeric detected_at for corrupt cache input'
assert_eq '203.0.113.9' "$(printf '%s' "$SNAPSHOT_JSON" | jq -r '.ip')" \
	'public IP snapshot keeps IP field'

PUBLIC_IP_DETECTED_AT='1770000001'
SNAPSHOT_JSON="$(emit_public_ip_cache_snapshot_fixture)"
assert_eq '1770000001' "$(printf '%s' "$SNAPSHOT_JSON" | jq -r '.detected_at')" \
	'public IP snapshot preserves valid detected_at epoch'

NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="$TMP_DIR/public_country_changed"
NORDVPN_EASY_LAST_ERROR_CACHE="$TMP_DIR/last_error_country_changed"
COUNTRY_LOOKUP_CALLS="$TMP_DIR/country_lookup_calls"
PUBLIC_IP='198.51.100.9'
PUBLIC_IP_CHANGED='1'
nordvpn_easy_lookup_public_country_by_ip() {
	printf '%s\n' "$1" >> "$COUNTRY_LOOKUP_CALLS"
	printf '%s\n' 'CH'
}
nordvpn_easy_refresh_public_country_cache
assert_eq '198.51.100.9' "$(sed -n '1p' "$COUNTRY_LOOKUP_CALLS")" \
	'public country check uses the current public IP result when the IP changes'
assert_eq 'CH' "$(sed -n '1p' "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE")" \
	'public country check stores lookup result after IP change'

: > "$COUNTRY_LOOKUP_CALLS"
PUBLIC_COUNTRY=''
PUBLIC_IP_CHANGED='0'
nordvpn_easy_refresh_public_country_cache
assert_eq '' "$(sed -n '1p' "$COUNTRY_LOOKUP_CALLS")" \
	'public country check reuses cached country when public IP is unchanged'
assert_eq 'CH' "$PUBLIC_COUNTRY" \
	'cached public country is reused for unchanged public IP'
unset -f nordvpn_easy_lookup_public_country_by_ip 2>/dev/null || true
# shellcheck disable=SC1090
. "$PUBLIC_IP_LIB"

NORDVPN_EASY_PUBLIC_IP_CACHE="$TMP_DIR/public_ip_endpoint_order"
NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="$TMP_DIR/public_country_endpoint_order"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="$TMP_DIR/public_verification_endpoint_order"
{
	printf '%s\n' 'ip=198.51.100.1'
	printf '%s\n' 'detected_at=1770000000'
	printf '%s\n' 'detected_at_iso=2026-02-01T00:00:00Z'
	printf '%s\n' 'source=https://icanhazip.com'
} > "$NORDVPN_EASY_PUBLIC_IP_CACHE"
CURL_URLS_FILE="$TMP_DIR/curl_urls_endpoint_order"
curl() {
	last_arg=''
	for arg in "$@"; do
		last_arg="$arg"
	done
	printf '%s\n' "$last_arg" >> "$CURL_URLS_FILE"
	printf '%s\n' '198.51.100.9'
	return 0
}
nordvpn_easy_detect_public_ip
assert_eq 'https://icanhazip.com' "$(sed -n '1p' "$CURL_URLS_FILE")" \
	'public IP detection tries the last successful endpoint first'
unset -f curl 2>/dev/null || true

NORDVPN_EASY_PUBLIC_IP_CACHE="$TMP_DIR/public_ip_failure"
NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="$TMP_DIR/public_country_failure"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="$TMP_DIR/public_verification_failure"
NORDVPN_EASY_LAST_ERROR_CACHE="$TMP_DIR/last_error_failure"
printf '%s\n' 'keep-runtime-error' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
curl() {
	return 28
}
nordvpn_easy_run_public_ip_check quiet >/dev/null 2>&1 || true
assert_eq 'keep-runtime-error' "$(sed -n '1p' "$NORDVPN_EASY_LAST_ERROR_CACHE")" \
	'failed public IP poll does not overwrite runtime last_error'
assert_eq 'failed' "$(sed -n 's/^status=//p' "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE")" \
	'failed public IP poll records public verification status'
unset -f curl 2>/dev/null || true

printf '%s\n' 'test-public-ip-cache.sh: ok'
