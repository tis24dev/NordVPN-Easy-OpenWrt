#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"

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
