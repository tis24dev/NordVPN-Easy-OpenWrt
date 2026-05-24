#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
HANDSHAKE_EPOCH="$(date +%s)"
DIAG_TMP="$(mktemp -d)"
ORIGINAL_PATH="$PATH"

cleanup() {
	rm -rf "$DIAG_TMP"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"
# shellcheck disable=SC1090
. "$DIAGNOSTICS_LIB"

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

assert_contains() {
	needle="$1"
	haystack="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*) ;;
		*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "missing: $needle" >&2
			exit 1
			;;
	esac
}

pick_ping_ip() {
	printf '%s\n' '1.1.1.1'
}

nordvpn_easy_resolve_wan_device() {
	WAN_DEVICE='eth0'
	return 0
}

VPN_IF='wg0'
WAN_IF='wan'
NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'
SERVER_LIST_FILE="$DIAG_TMP/nordvpn-server-list.json"
COUNTRIES_CACHE_FILE="$DIAG_TMP/nordvpn-countries.json"
COUNTRIES_CACHE_TS_FILE="$DIAG_TMP/nordvpn-countries.timestamp"
NORDVPN_EASY_LAST_ERROR_CACHE="$DIAG_TMP/last_error"
NORDVPN_EASY_CONNECT_APPLY_RESULT="$DIAG_TMP/connect-apply-result"
NORDVPN_EASY_CONNECT_APPLY_GUARD="$DIAG_TMP/connect-apply-guard"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="$DIAG_TMP/public_verification"

printf '%s\n' '[{"station":"hk270"}]' > "$SERVER_LIST_FILE"
printf '%s\n' '[{"code":"HK","name":"Hong Kong"}]' > "$COUNTRIES_CACHE_FILE"
date +%s > "$COUNTRIES_CACHE_TS_FILE"

emit_scenario_json() {
	nordvpn_easy_emit_diagnostics_summary_json wg0
}

primary_code() {
	printf '%s' "$1" | jq -r '.primary_finding.code'
}

findings_codes() {
	printf '%s' "$1" | jq -r '.findings[].code' | tr '\n' ' '
}

install_ping_mock() {
	local exit_code="$1"

	printf '%s\n' '#!/bin/sh' 'exit '"$exit_code" > "$DIAG_TMP/ping"
	chmod +x "$DIAG_TMP/ping"
	PATH="$DIAG_TMP:$PATH"
	export PATH
}

install_nslookup_mock() {
	local exit_code="$1"

	printf '%s\n' '#!/bin/sh' 'exit '"$exit_code" > "$DIAG_TMP/nslookup"
	chmod +x "$DIAG_TMP/nslookup"
	PATH="$DIAG_TMP:$PATH"
	export PATH
}

restore_path_mock() {
	PATH="$ORIGINAL_PATH"
	export PATH
}

assert_scenario_primary() {
	local expected="$1"
	local label="$2"
	local json
	local err_file

	err_file="$DIAG_TMP/emit.err"
	: >"$err_file"
	set +e
	json="$(emit_scenario_json 2>>"$err_file")"
	emit_rc=$?
	set -e
	if [ "$emit_rc" -ne 0 ] || [ -z "$json" ]; then
		printf '%s\n' "FAIL: $label (emit_scenario_json failed, rc=$emit_rc)" >&2
		cat "$err_file" >&2
		exit 1
	fi
	assert_eq "$expected" "$(primary_code "$json")" "$label"
	printf '%s' "$json"
}

assert_scenario_includes() {
	local json="$1"
	local code="$2"
	local label="$3"

	assert_contains "$code" "$(findings_codes "$json")" "$label"
}

uci_complete() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'wireguard' ;;
		'get network.wg0.disabled') printf '%s\n' '0' ;;
		'get network.wg0.private_key') printf '%s\n' 'private-secret' ;;
		'get network.wg0.addresses') printf '%s\n' '10.5.0.2/32' ;;
		'get network.wg0.peerdns') printf '%s\n' '0' ;;
		'get network.wg0.delegate') printf '%s\n' '0' ;;
		'get network.wg0.force_link') printf '%s\n' '1' ;;
		'get network.wg0server.endpoint_host') printf '%s\n' 'hk270.nordvpn.com' ;;
		'get network.wg0server.public_key') printf '%s\n' 'peer-public-key' ;;
		'get network.wg0server.allowed_ips') printf '%s\n' '0.0.0.0/0' ;;
		'get network.wg0server.route_allowed_ips') printf '%s\n' '1' ;;
		'get network.wg0server.nordvpn_country_code') printf '%s\n' 'HK' ;;
		'get network.wg0server.nordvpn_station') printf '%s\n' '185.225.234.11' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.vpn_country') printf '%s\n' '' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' '' ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '0' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network')
			printf '%s\n' 'network.wg0=interface'
			printf '%s\n' 'network.wg0server=wireguard_wg0'
			;;
		*) return 1 ;;
	esac
}

wg_blackhole() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t0\t0\t1184\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*)
			return 1
			;;
	esac
}

wg_no_handshake() {
	wg_blackhole "$@"
}

wg_no_peers() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' 'private\tpublic\t51820\t'
			;;
		'show wg0 peers')
			return 0
			;;
		*)
			return 1
			;;
	esac
}

wg_connected() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t${HANDSHAKE_EPOCH}\t4096\t4096\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*)
			return 1
			;;
	esac
}

ip_blackhole() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' 'default proto static scope link' ;;
		'route show default') printf '%s\n' 'default dev wg0 proto static scope link' ;;
		*) return 0 ;;
	esac
}

ip_healthy() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' '10.5.0.2/32 proto kernel scope link src 10.5.0.2' ;;
		'route show default') printf '%s\n' 'default dev eth0 proto static' ;;
		*) return 0 ;;
	esac
}

ip_link_down() {
	case "$*" in
		'link show dev wg0') return 1 ;;
		*) return 0 ;;
	esac
}

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}

wg() {
	wg_blackhole "$@"
}

ip() {
	ip_blackhole "$@"
}

# --- Integration scenarios (blackhole, kill switch, healthy) ---

SUMMARY="$(nordvpn_easy_diagnostics_print_health_summary wg0)"

assert_eq 'routing.blackhole_default_via_vpn' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^probable_issue_code=//p')" \
	'blackhole scenario selects routing finding first'
assert_contains 'routing.blackhole_default_via_vpn' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^probable_issues=//p')" \
	'blackhole scenario lists routing finding'
assert_eq 'yes' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^routing_blackhole_risk=//p')" \
	'blackhole scenario flags routing risk'
assert_eq 'stuck_tunnel_suspected' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^transfer_asymmetry=//p')" \
	'blackhole scenario flags asymmetric transfer'

BLACKHOLE_JSON="$(emit_scenario_json)"
assert_eq 'routing.blackhole_default_via_vpn' \
	"$(primary_code "$BLACKHOLE_JSON")" \
	'summary json exposes primary finding code'
assert_contains 'runtime.no_handshake' "$(findings_codes "$BLACKHOLE_JSON")" \
	'summary json includes no_handshake with blackhole'
assert_contains 'runtime.stuck_tunnel' "$(findings_codes "$BLACKHOLE_JSON")" \
	'summary json includes stuck_tunnel with blackhole'
assert_eq 'yes' \
	"$(printf '%s' "$BLACKHOLE_JSON" | jq -r '.connectivity.routing_blackhole_risk')" \
	'summary json includes connectivity assessment'

wg() { wg_blackhole "$@"; }
ip() { ip_blackhole "$@"; }
uci_kill_switch() {
	case "$*" in
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '1' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_kill_switch "$@"
}
PRIORITY_JSON="$(emit_scenario_json)"
assert_eq 'routing.blackhole_default_via_vpn' \
	"$(primary_code "$PRIORITY_JSON")" \
	'routing blackhole stays primary over kill switch and handshake findings'
assert_eq 'critical' \
	"$(printf '%s' "$PRIORITY_JSON" | jq -r '.primary_finding.severity')" \
	'primary finding exposes severity in summary json'
assert_contains 'operational.kill_switch_active' "$(findings_codes "$PRIORITY_JSON")" \
	'kill switch finding is still listed with blackhole present'

KILL_SWITCH_JSON="$(emit_scenario_json)"
assert_eq 'true' \
	"$(printf '%s' "$KILL_SWITCH_JSON" | jq -r '.health.kill_switch_enabled')" \
	'kill switch scenario exposes kill_switch_enabled in summary json'
assert_contains 'operational.kill_switch_active' "$(findings_codes "$KILL_SWITCH_JSON")" \
	'kill switch scenario lists kill switch finding when tunnel is down'

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }

HEALTHY_SUMMARY="$(nordvpn_easy_diagnostics_print_health_summary wg0)"

assert_eq 'none' \
	"$(printf '%s\n' "$HEALTHY_SUMMARY" | sed -n 's/^probable_issue_code=//p')" \
	'connected scenario reports no primary finding'
assert_eq 'yes' \
	"$(printf '%s\n' "$HEALTHY_SUMMARY" | sed -n 's/^wireguard_connected=//p')" \
	'connected scenario reports wireguard connected'
assert_eq 'no' \
	"$(printf '%s\n' "$HEALTHY_SUMMARY" | sed -n 's/^routing_blackhole_risk=//p')" \
	'connected scenario has no routing blackhole risk'

HEALTHY_JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$HEALTHY_JSON")" \
	'healthy summary json reports no primary finding'
assert_eq 'true' \
	"$(printf '%s' "$HEALTHY_JSON" | jq -r '.health.wireguard_connected')" \
	'healthy summary json reports wireguard connected'

# --- Per-issue-code scenarios ---
# Covers: config.interface_incomplete, config.peer_missing, config.peer_incomplete,
# config.not_wireguard, service.enabled_mismatch, routing.blackhole_default_via_vpn,
# runtime.no_handshake, runtime.stuck_tunnel, runtime.endpoint_unreachable,
# operational.kill_switch_active, connectivity.wan_down, connectivity.dns_failure,
# operational.api_cache_missing, operational.last_error, selection.drift,
# runtime.no_peers, runtime.link_down

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_interface_incomplete() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'wireguard' ;;
		'get network.wg0.disabled') printf '%s\n' '0' ;;
		'get network.wg0.force_link') printf '%s\n' '1' ;;
		'get network.wg0server.endpoint_host') printf '%s\n' 'hk270.nordvpn.com' ;;
		'get network.wg0server.public_key') printf '%s\n' 'peer-public-key' ;;
		'get network.wg0server.allowed_ips') printf '%s\n' '0.0.0.0/0' ;;
		'get network.wg0server.route_allowed_ips') printf '%s\n' '1' ;;
		'get network.wg0server.nordvpn_country_code') printf '%s\n' 'HK' ;;
		'get network.wg0server.nordvpn_station') printf '%s\n' '185.225.234.11' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network')
			printf '%s\n' 'network.wg0=interface'
			printf '%s\n' 'network.wg0server=wireguard_wg0'
			;;
		*) return 1 ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_interface_incomplete "$@"
}
JSON="$(assert_scenario_primary 'config.interface_incomplete' 'config.interface_incomplete is primary')"
assert_scenario_includes "$JSON" 'config.interface_incomplete' \
	'config.interface_incomplete appears in findings'

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_peer_missing() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'wireguard' ;;
		'get network.wg0.disabled') printf '%s\n' '0' ;;
		'get network.wg0.private_key') printf '%s\n' 'private-secret' ;;
		'get network.wg0.addresses') printf '%s\n' '10.5.0.2/32' ;;
		'get network.wg0.peerdns') printf '%s\n' '0' ;;
		'get network.wg0.delegate') printf '%s\n' '0' ;;
		'get network.wg0.force_link') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network') printf '%s\n' 'network.wg0=interface' ;;
		*) return 1 ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_peer_missing "$@"
}
JSON="$(assert_scenario_primary 'config.peer_missing' 'config.peer_missing is primary')"
assert_scenario_includes "$JSON" 'config.peer_missing' 'config.peer_missing appears in findings'

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_peer_incomplete() {
	case "$*" in
		'get network.wg0server.public_key') return 1 ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_peer_incomplete "$@"
}
JSON="$(assert_scenario_primary 'config.peer_incomplete' 'config.peer_incomplete is primary')"
assert_scenario_includes "$JSON" 'config.peer_incomplete' 'config.peer_incomplete appears in findings'

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_enabled_mismatch() {
	case "$*" in
		'get network.wg0.disabled') printf '%s\n' '1' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_enabled_mismatch "$@"
}
JSON="$(assert_scenario_primary 'service.enabled_mismatch' 'service.enabled_mismatch is primary')"
assert_scenario_includes "$JSON" 'service.enabled_mismatch' \
	'service.enabled_mismatch appears in findings'

wg() { wg_no_handshake "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(assert_scenario_primary 'runtime.no_handshake' 'runtime.no_handshake is primary without blackhole route')"
assert_scenario_includes "$JSON" 'runtime.no_handshake' 'runtime.no_handshake appears in findings'
assert_scenario_includes "$JSON" 'runtime.stuck_tunnel' \
	'runtime.stuck_tunnel is listed with asymmetric transfer'

NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='1'
wg() { wg_no_handshake "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
install_ping_mock_endpoint_fail() {
	printf '%s\n' '#!/bin/sh' \
		'case "$*" in' \
		'	*185.225.234.11*) exit 1 ;;' \
		'	*) exit 0 ;;' \
		'esac' > "$DIAG_TMP/ping"
	chmod +x "$DIAG_TMP/ping"
	PATH="$DIAG_TMP:$ORIGINAL_PATH"
	export PATH
}
install_ping_mock_endpoint_fail
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "Address 1: 1.2.3.4"' 'exit 0' > "$DIAG_TMP/nslookup"
chmod +x "$DIAG_TMP/nslookup"
PATH="$DIAG_TMP:$ORIGINAL_PATH"
export PATH
JSON="$(assert_scenario_primary 'runtime.endpoint_unreachable' 'runtime.endpoint_unreachable is primary when endpoint ping fails')"
assert_scenario_includes "$JSON" 'runtime.endpoint_unreachable' \
	'runtime.endpoint_unreachable appears in findings'
restore_path_mock
NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'

NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='1'
wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
install_ping_mock 1
JSON="$(assert_scenario_primary 'connectivity.wan_down' 'connectivity.wan_down is primary when WAN probe fails')"
assert_scenario_includes "$JSON" 'connectivity.wan_down' 'connectivity.wan_down appears in findings'
restore_path_mock
NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'

NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='1'
wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
install_ping_mock 0
install_nslookup_mock 1
JSON="$(assert_scenario_primary 'connectivity.dns_failure' 'connectivity.dns_failure is primary when API DNS fails')"
assert_scenario_includes "$JSON" 'connectivity.dns_failure' 'connectivity.dns_failure appears in findings'
restore_path_mock
NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'

rm -f "$SERVER_LIST_FILE"
printf '%s\n' 'public_ip failed (rc=1)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(assert_scenario_primary 'operational.api_cache_missing' 'operational.api_cache_missing is primary')"
assert_scenario_includes "$JSON" 'operational.api_cache_missing' \
	'operational.api_cache_missing appears in findings'
printf '%s\n' '[{"station":"hk270"}]' > "$SERVER_LIST_FILE"

printf '%s\n' 'rotate failed (rc=2)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(assert_scenario_primary 'operational.last_error' 'operational.last_error is primary when no higher-priority issue matches')"
assert_scenario_includes "$JSON" 'operational.last_error' 'operational.last_error appears in findings'
: > "$NORDVPN_EASY_LAST_ERROR_CACHE"

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_country_drift() {
	case "$*" in
		'get nordvpn_easy.main.vpn_country') printf '%s\n' 'IT' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_country_drift "$@"
}
JSON="$(assert_scenario_primary 'selection.drift' 'selection.drift is primary for country mismatch')"
assert_scenario_includes "$JSON" 'selection.drift' 'selection.drift appears in findings for country mismatch'

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_manual_drift() {
	case "$*" in
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'manual' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' 'it123' ;;
		'get network.wg0server.nordvpn_station') printf '%s\n' 'hk270' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_manual_drift "$@"
}
JSON="$(assert_scenario_primary 'selection.drift' 'selection.drift is primary for manual preferred-server mismatch')"
assert_scenario_includes "$JSON" 'selection.drift' \
	'selection.drift appears in findings for manual preferred-server mismatch'

wg() { wg_no_peers "$@"; }
ip() { ip_healthy "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(assert_scenario_primary 'runtime.no_peers' 'runtime.no_peers is primary when link exists without peers')"
assert_scenario_includes "$JSON" 'runtime.no_peers' 'runtime.no_peers appears in findings'

wg() { wg_connected "$@"; }
ip() { ip_link_down "$@"; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(assert_scenario_primary 'runtime.link_down' 'runtime.link_down is primary when VPN link is absent')"
assert_scenario_includes "$JSON" 'runtime.link_down' 'runtime.link_down appears in findings'

nordvpn_easy_connect_apply_result_begin "$NORDVPN_EASY_CONNECT_APPLY_RESULT"
JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$JSON")" \
	'runtime.link_down is suppressed during pending connect_apply'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "runtime.link_down")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: runtime.link_down should not appear during pending connect_apply' >&2
	exit 1
fi
rm -f "$NORDVPN_EASY_CONNECT_APPLY_RESULT"

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_not_wireguard() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'openvpn' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_not_wireguard "$@"
}
JSON="$(assert_scenario_primary 'config.not_wireguard' 'config.not_wireguard is primary for non-WireGuard proto')"
assert_scenario_includes "$JSON" 'config.not_wireguard' 'config.not_wireguard appears in findings'

assert_eq '2001:db8::1' "$(nordvpn_easy_diagnostics_endpoint_host '[2001:db8::1]:51820')" 'bracketed IPv6 endpoint host extraction'
assert_eq 'hk270.nordvpn.com' "$(nordvpn_easy_diagnostics_endpoint_host 'hk270.nordvpn.com:51820')" 'host:port endpoint host extraction'

printf '%s\n' 'test-diagnostics.sh: ok'
