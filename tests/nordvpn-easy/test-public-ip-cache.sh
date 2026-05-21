#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
PUBLIC_IP_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/public-ip.sh"

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

printf '%s\n' 'test-public-ip-cache.sh: ok'
