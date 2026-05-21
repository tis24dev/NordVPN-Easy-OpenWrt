#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"

# shellcheck disable=SC1090
. "$SCHEMA_LIB"

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

assert_eq 'auto' "$(nordvpn_easy_default server_selection_mode)" 'default server selection mode'
assert_eq '' "$(nordvpn_easy_default fallback_server_station)" 'default fallback server station'
assert_eq '86400' "$(nordvpn_easy_default server_cache_ttl)" 'default server cache ttl'
assert_eq '15' "$(nordvpn_easy_default wireguard_persistent_keepalive)" 'default WireGuard keepalive'
assert_eq '' "$(nordvpn_easy_default wireguard_mtu)" 'default WireGuard MTU is automatic'
assert_eq '1' "$(nordvpn_easy_default firewall_mtu_fix)" 'default firewall MTU fix enabled'
assert_eq '' "$(nordvpn_easy_default check_cron_schedule)" 'default cron schedule disabled'
assert_eq '30' "$(nordvpn_easy_default hotplug_debounce_seconds)" 'default hotplug debounce'
assert_eq '0' "$(nordvpn_easy_default kill_switch_enabled)" 'default kill switch disabled'
assert_eq '1' "$(nordvpn_easy_normalize_value enabled yes)" 'boolean normalization for yes'
assert_eq '1' "$(nordvpn_easy_normalize_value enable_hotplug '')" 'missing default-on boolean keeps default'
assert_eq '1' "$(nordvpn_easy_normalize_value enabled true)" 'boolean normalization for true'
assert_eq '1' "$(nordvpn_easy_normalize_value kill_switch_enabled true)" 'kill switch boolean normalization'
assert_eq '1' "$(nordvpn_easy_normalize_value firewall_mtu_fix true)" 'firewall MTU fix boolean normalization'
assert_eq 'manual' "$(nordvpn_easy_normalize_value server_selection_mode manual)" 'manual mode normalization'
assert_eq 'auto' "$(nordvpn_easy_normalize_value server_selection_mode broken)" 'invalid mode normalization'
assert_eq '86400' "$(nordvpn_easy_normalize_value server_cache_ttl not-a-number)" 'invalid ttl normalization'
assert_eq '15' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive not-a-number)" 'invalid keepalive normalization'
assert_eq '0' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive 0)" 'zero keepalive disables keepalive'
assert_eq '120' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive 120)" 'maximum keepalive accepted'
assert_eq '15' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive 121)" 'out-of-range keepalive normalization'
assert_eq '1420' "$(nordvpn_easy_normalize_value wireguard_mtu 1420)" 'valid WireGuard MTU accepted'
assert_eq '' "$(nordvpn_easy_normalize_value wireguard_mtu 1279)" 'low WireGuard MTU normalizes to automatic'
assert_eq '' "$(nordvpn_easy_normalize_value wireguard_mtu 1501)" 'high WireGuard MTU normalizes to automatic'
assert_eq '30' "$(nordvpn_easy_normalize_value hotplug_debounce_seconds invalid)" 'invalid debounce normalization'
assert_eq "$NORDVPN_EASY_SCHEMA_VERSION" "$(nordvpn_easy_normalize_value config_schema_version 0)" 'schema version normalization'
assert_eq 'NORDVPN_TOKEN' "$(nordvpn_easy_env_name nordvpn_token)" 'runtime binding maps token env name'
assert_eq 'VPN_IF' "$(nordvpn_easy_env_name vpn_if)" 'runtime binding maps vpn_if env name'
assert_eq 'FALLBACK_SERVER_STATION' "$(nordvpn_easy_env_name fallback_server_station)" 'runtime binding maps fallback station env name'
assert_eq 'WIREGUARD_PERSISTENT_KEEPALIVE' "$(nordvpn_easy_env_name wireguard_persistent_keepalive)" 'runtime binding maps keepalive env name'
assert_eq 'WIREGUARD_MTU' "$(nordvpn_easy_env_name wireguard_mtu)" 'runtime binding maps MTU env name'
assert_eq 'FIREWALL_MTU_FIX' "$(nordvpn_easy_env_name firewall_mtu_fix)" 'runtime binding maps firewall MTU fix env name'
assert_eq "$NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE" "$(nordvpn_easy_backend_payload_signature)" 'backend payload signature helper'
assert_eq "wan'\\''vpn" "$(nordvpn_easy_shell_quote "wan'vpn")" 'shell quote escapes single quotes'
eval "SHELL_QUOTE_ROUNDTRIP='$(nordvpn_easy_shell_quote "wan'vpn")'"
assert_eq "wan'vpn" "$SHELL_QUOTE_ROUNDTRIP" 'shell quote round-trips through eval'

unset NORDVPN_TOKEN
unset CHECK_CRON_SCHEDULE
SERVER_CACHE_TTL=''
WIREGUARD_PERSISTENT_KEEPALIVE=''
export SERVER_CACHE_TTL
export WIREGUARD_PERSISTENT_KEEPALIVE
nordvpn_easy_apply_env_defaults

assert_eq '' "${NORDVPN_TOKEN:-}" 'empty token default'
assert_eq '' "$CHECK_CRON_SCHEDULE" 'cron default disabled'
assert_eq '86400' "$SERVER_CACHE_TTL" 'environment ttl default'
assert_eq '15' "$WIREGUARD_PERSISTENT_KEEPALIVE" 'environment keepalive default'

printf '%s\n' 'test-schema.sh: ok'
