#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


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
assert_eq '1' "$(nordvpn_easy_default kill_switch_enabled)" 'default kill switch enabled (strict no-leak)'
assert_eq '1' "$(nordvpn_easy_normalize_value enabled yes)" 'boolean normalization for yes'
assert_eq '1' "$(nordvpn_easy_normalize_value enable_hotplug '')" 'missing default-on boolean keeps default'
assert_eq '1' "$(nordvpn_easy_normalize_value enabled true)" 'boolean normalization for true'
assert_eq '1' "$(nordvpn_easy_normalize_value kill_switch_enabled true)" 'kill switch boolean normalization'
assert_eq '1' "$(nordvpn_easy_normalize_value firewall_mtu_fix true)" 'firewall MTU fix boolean normalization'
assert_eq 'manual' "$(nordvpn_easy_normalize_value server_selection_mode manual)" 'manual mode normalization'
assert_eq 'auto' "$(nordvpn_easy_normalize_value server_selection_mode broken)" 'invalid mode normalization'
# dns_mode defaults to custom (backward compatible: keep saved vpn_dns on upgrade)
assert_eq 'custom' "$(nordvpn_easy_default dns_mode)" 'default dns_mode keeps custom for existing configs'
assert_eq 'standard' "$(nordvpn_easy_normalize_value dns_mode standard)" 'standard dns_mode preserved'
assert_eq 'threat_protection' "$(nordvpn_easy_normalize_value dns_mode threat_protection)" 'threat_protection dns_mode preserved'
assert_eq 'threat_protection_family' "$(nordvpn_easy_normalize_value dns_mode threat_protection_family)" 'threat_protection_family dns_mode preserved'
assert_eq 'custom' "$(nordvpn_easy_normalize_value dns_mode nonsense)" 'invalid dns_mode falls back to custom'
# routing_mode defaults to full_tunnel: existing installs must keep the historical
# behaviour (the tunnel owns the default route) without touching their config.
assert_eq 'full_tunnel' "$(nordvpn_easy_default routing_mode)" 'default routing_mode keeps the full tunnel'
assert_eq 'policy' "$(nordvpn_easy_normalize_value routing_mode policy)" 'policy routing_mode preserved'
assert_eq 'full_tunnel' "$(nordvpn_easy_normalize_value routing_mode full_tunnel)" 'full_tunnel routing_mode preserved'
assert_eq 'full_tunnel' "$(nordvpn_easy_normalize_value routing_mode nonsense)" 'invalid routing_mode falls back to full_tunnel'
assert_eq 'full_tunnel' "$(nordvpn_easy_normalize_value routing_mode '')" 'empty routing_mode falls back to full_tunnel'
assert_eq '86400' "$(nordvpn_easy_normalize_value server_cache_ttl not-a-number)" 'invalid ttl normalization'
assert_eq '15' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive not-a-number)" 'invalid keepalive normalization'
assert_eq '0' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive 0)" 'zero keepalive disables keepalive'
assert_eq '120' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive 120)" 'maximum keepalive accepted'
# wan_if/vpn_if become UCI section names, so only the UCI identifier charset is
# accepted; anything else falls back to the safe default.
assert_eq 'wan' "$(nordvpn_easy_normalize_value wan_if wan)" 'valid wan_if preserved'
assert_eq 'wan_eth1' "$(nordvpn_easy_normalize_value wan_if wan_eth1)" 'underscore wan_if preserved'
assert_eq 'wg0' "$(nordvpn_easy_normalize_value vpn_if wg0)" 'valid vpn_if preserved'
assert_eq 'wg0' "$(nordvpn_easy_normalize_value vpn_if 'wg0.5')" 'vpn_if with a dot falls back to default'
assert_eq 'wan' "$(nordvpn_easy_normalize_value wan_if 'wan eth0')" 'wan_if with a space falls back to default'
assert_eq 'wg0' "$(nordvpn_easy_normalize_value vpn_if 'wg0;reboot')" 'vpn_if with a metacharacter falls back to default'
assert_eq 'wan' "$(nordvpn_easy_normalize_value wan_if '')" 'empty wan_if falls back to default'
assert_eq '15' "$(nordvpn_easy_normalize_value wireguard_persistent_keepalive 121)" 'out-of-range keepalive normalization'
assert_eq '1420' "$(nordvpn_easy_normalize_value wireguard_mtu 1420)" 'valid WireGuard MTU accepted'
assert_eq '' "$(nordvpn_easy_normalize_value wireguard_mtu 1279)" 'low WireGuard MTU normalizes to automatic'
assert_eq '' "$(nordvpn_easy_normalize_value wireguard_mtu 1501)" 'high WireGuard MTU normalizes to automatic'
assert_eq '30' "$(nordvpn_easy_normalize_value hotplug_debounce_seconds invalid)" 'invalid debounce normalization'
assert_eq "$NORDVPN_EASY_SCHEMA_VERSION" "$(nordvpn_easy_normalize_value config_schema_version 0)" 'schema version normalization'

# Network-shaped options are validated/canonicalized at the schema boundary.
assert_eq '51820' "$(nordvpn_easy_normalize_value vpn_port 0)" 'zero port normalizes to default'
assert_eq '51820' "$(nordvpn_easy_normalize_value vpn_port 70000)" 'out-of-range port normalizes to default'
assert_eq '1194' "$(nordvpn_easy_normalize_value vpn_port 1194)" 'valid port accepted'
assert_eq '80' "$(nordvpn_easy_normalize_value vpn_port 0080)" 'leading-zero port canonicalized'
assert_eq '86400' "$(nordvpn_easy_normalize_value server_cache_ttl 086400)" 'leading-zero uint canonicalized'
assert_eq '10.8.0.1/24' "$(nordvpn_easy_normalize_value vpn_addr 10.8.0.1/24)" 'valid vpn_addr accepted'
assert_eq '10.5.0.2/32' "$(nordvpn_easy_normalize_value vpn_addr 10.8.0.1)" 'bare IPv4 vpn_addr normalizes to default because CIDR is required'
assert_eq '10.5.0.2/32' "$(nordvpn_easy_normalize_value vpn_addr not-an-ip)" 'invalid vpn_addr normalizes to default'
assert_eq '10.5.0.2/32' "$(nordvpn_easy_normalize_value vpn_addr '')" 'empty vpn_addr normalizes to default'
assert_eq '1.1.1.1' "$(nordvpn_easy_normalize_value vpn_dns1 1.1.1.1)" 'valid dns accepted'
assert_eq '103.86.96.100' "$(nordvpn_easy_normalize_value vpn_dns1 999.1.1.1)" 'invalid dns normalizes to the aligned NordVPN default'
assert_eq '' "$(nordvpn_easy_normalize_value vpn_dns2 '')" 'empty dns stays empty'
# The DNS defaults are aligned with the NordVPN standard resolvers (verified in
# the app binary) and match the 'standard' branch of nordvpn_easy_resolve_dns_pair.
assert_eq '103.86.96.100' "$(nordvpn_easy_default vpn_dns1)" 'default DNS1 is the NordVPN standard resolver'
assert_eq '103.86.99.100' "$(nordvpn_easy_default vpn_dns2)" 'default DNS2 is the NordVPN standard resolver'
assert_eq 'US' "$(nordvpn_easy_normalize_value vpn_country us)" 'country code uppercased'
assert_eq '' "$(nordvpn_easy_normalize_value vpn_country usa)" 'invalid country normalizes to default (auto)'
assert_eq 'IT' "$(nordvpn_easy_normalize_value vpn_country IT)" 'valid country accepted'
assert_eq '*/10 * * * *' "$(nordvpn_easy_normalize_value check_cron_schedule '*/10 * * * *')" 'valid cron schedule accepted'
assert_eq '' "$(nordvpn_easy_normalize_value check_cron_schedule 'bad;rm')" 'cron schedule with invalid characters normalizes to default'

# The access token is used raw in the curl Basic-auth header; embedded CR/LF/Tab
# or surrounding spaces corrupt it and make the credentials API answer 400, so
# the token is hygiene-normalized at the schema boundary.
assert_eq 'abc123def456' "$(nordvpn_easy_normalize_value nordvpn_token abc123def456)" 'clean token passed through unchanged'
assert_eq 'abc123' "$(nordvpn_easy_normalize_value nordvpn_token '  abc123  ')" 'surrounding spaces trimmed from token'
assert_eq 'abc123' "$(nordvpn_easy_normalize_value nordvpn_token "$(printf 'abc123\r\n')")" 'trailing CR/LF stripped from token'
assert_eq 'abc123' "$(nordvpn_easy_normalize_value nordvpn_token "$(printf 'abc\r\n123')")" 'embedded CR/LF stripped from token'
assert_eq 'abc123' "$(nordvpn_easy_normalize_value nordvpn_token "$(printf 'abc\t123')")" 'embedded tab stripped from token'
assert_eq '' "$(nordvpn_easy_normalize_value nordvpn_token '')" 'empty token stays empty'

assert_eq 'NORDVPN_TOKEN' "$(nordvpn_easy_env_name nordvpn_token)" 'runtime binding maps token env name'
assert_eq 'VPN_IF' "$(nordvpn_easy_env_name vpn_if)" 'runtime binding maps vpn_if env name'
assert_eq 'FALLBACK_SERVER_STATION' "$(nordvpn_easy_env_name fallback_server_station)" 'runtime binding maps fallback station env name'
assert_eq 'WIREGUARD_PERSISTENT_KEEPALIVE' "$(nordvpn_easy_env_name wireguard_persistent_keepalive)" 'runtime binding maps keepalive env name'
assert_eq 'WIREGUARD_MTU' "$(nordvpn_easy_env_name wireguard_mtu)" 'runtime binding maps MTU env name'
assert_eq 'FIREWALL_MTU_FIX' "$(nordvpn_easy_env_name firewall_mtu_fix)" 'runtime binding maps firewall MTU fix env name'
assert_eq 'ROUTING_MODE' "$(nordvpn_easy_env_name routing_mode)" 'runtime binding maps routing mode env name'
assert_eq "$NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE" "$(nordvpn_easy_backend_payload_signature)" 'backend payload signature helper'
assert_eq "wan'\\''vpn" "$(nordvpn_easy_shell_quote "wan'vpn")" 'shell quote escapes single quotes'
eval "SHELL_QUOTE_ROUNDTRIP='$(nordvpn_easy_shell_quote "wan'vpn")'"
assert_eq "wan'vpn" "$SHELL_QUOTE_ROUNDTRIP" 'shell quote round-trips through eval'

unset NORDVPN_TOKEN
unset CHECK_CRON_SCHEDULE
SERVER_CACHE_TTL=''
WIREGUARD_PERSISTENT_KEEPALIVE=''
VPN_DNS1=''
VPN_DNS2=''
export SERVER_CACHE_TTL
export WIREGUARD_PERSISTENT_KEEPALIVE
export VPN_DNS1
export VPN_DNS2
nordvpn_easy_apply_env_defaults

assert_eq '' "${NORDVPN_TOKEN:-}" 'empty token default'
assert_eq '' "$CHECK_CRON_SCHEDULE" 'cron default disabled'
assert_eq '86400' "$SERVER_CACHE_TTL" 'environment ttl default'
assert_eq '15' "$WIREGUARD_PERSISTENT_KEEPALIVE" 'environment keepalive default'
# An install that never set a custom DNS (empty env) backfills the aligned
# NordVPN standard pair, not the legacy 103.86.99.99/103.86.96.96 resolvers.
assert_eq '103.86.96.100' "$VPN_DNS1" 'environment DNS1 default is the aligned NordVPN standard resolver'
assert_eq '103.86.99.100' "$VPN_DNS2" 'environment DNS2 default is the aligned NordVPN standard resolver'

# S9: the orchestrator flag is removed. The supervisor is the sole apply path, so there
# is no orchestrator mode reader and the defaults template no longer seeds the flag.
if command -v nordvpn_easy_orchestrator_mode >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: nordvpn_easy_orchestrator_mode must be removed (the orchestrator flag is gone)' >&2
	exit 1
fi
if grep -q 'orchestrator' "$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/share/nordvpn-easy/defaults/nordvpn_easy"; then
	printf '%s\n' 'FAIL: the defaults template must not seed an orchestrator option (the flag is removed)' >&2
	exit 1
fi

# RPC contract level getter: the build supports contract 2 (the async supervised apply
# method + its ACL + the JS callApply consumer all shipped), so the getter returns 2
# unconditionally. The old orchestrator clamp is gone.
assert_eq '2' "$(nordvpn_easy_rpc_contract_level)" 'the advertised RPC contract level is 2 (async apply method shipped)'
case "$(nordvpn_easy_rpc_contract_level)" in
	''|*[!0-9]*|0?*) printf '%s\n' 'FAIL: rpc_contract_level must be a bare non-zero-padded integer (valid JSON number)' >&2; exit 1 ;;
esac

printf '%s\n' 'test-schema.sh: ok'

# The schema is a set of PARALLEL lists (uci_options / runtime_options /
# runtime_env_keys / runtime_bindings) plus two case dispatchers. Nothing enforced
# that they stayed in sync, so a forgotten entry only surfaced at runtime. Assert it.
for schema_opt in $(nordvpn_easy_runtime_options); do
	nordvpn_easy_uci_options | grep -qx "$schema_opt" || {
		printf '%s\n' "FAIL: runtime option '$schema_opt' is missing from nordvpn_easy_uci_options" >&2
		exit 1
	}
	schema_env="$(nordvpn_easy_env_name "$schema_opt")" || {
		printf '%s\n' "FAIL: runtime option '$schema_opt' has no env name mapping" >&2
		exit 1
	}
	nordvpn_easy_runtime_env_keys | grep -qx "$schema_env" || {
		printf '%s\n' "FAIL: env key '$schema_env' is missing from nordvpn_easy_runtime_env_keys" >&2
		exit 1
	}
	nordvpn_easy_runtime_bindings | grep -qx "$schema_opt $schema_env" || {
		printf '%s\n' "FAIL: binding '$schema_opt $schema_env' is missing from nordvpn_easy_runtime_bindings" >&2
		exit 1
	}
done

for schema_opt in $(nordvpn_easy_uci_options); do
	nordvpn_easy_default "$schema_opt" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: option '$schema_opt' has no schema default" >&2
		exit 1
	}
done

printf '%s\n' 'test-schema.sh: schema lists are mutually consistent'
