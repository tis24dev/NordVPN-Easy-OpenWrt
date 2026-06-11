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
ip() { ip_link_down "$@"; }
nordvpn_easy_runtime_configured() { return 1; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(emit_scenario_json)"
assert_eq 'operational.apply_incomplete' "$(primary_code "$JSON")" \
	'operational.apply_incomplete is primary when VPN is enabled without configured runtime'
assert_scenario_includes "$JSON" 'operational.apply_incomplete' \
	'operational.apply_incomplete appears in findings'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "runtime.link_down")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: runtime.link_down should not duplicate apply_incomplete orphan state' >&2
	exit 1
fi

wg() { wg_connected "$@"; }
ip() { ip_link_down "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
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

DIAG_CONNECT_APPLY_PENDING='no'
DIAG_OPERATION_LOCK_STATE='held'
DIAG_OPERATION_LOCK_ACTION='reconnect'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: held reconnect should suppress transient diagnostics' >&2
	exit 1
}
DIAG_OPERATION_LOCK_STATE='stale_recovered'
DIAG_OPERATION_LOCK_ACTION='reconcile'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: stale-recovered reconcile should suppress transient diagnostics' >&2
	exit 1
}

uci_wg0_no_peer() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'wireguard' ;;
		'get network.wg0.disabled') printf '%s\n' '0' ;;
		'get network.wg0.private_key') printf '%s\n' 'private-secret' ;;
		'get network.wg0.addresses') printf '%s\n' '10.5.0.2/32' ;;
		'get network.wg0.peerdns') printf '%s\n' '0' ;;
		'get network.wg0.delegate') printf '%s\n' '0' ;;
		'get network.wg0.force_link') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.vpn_country') printf '%s\n' '' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' '' ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '0' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network')
			printf '%s\n' 'network.wg0=interface'
			;;
		*) return 1 ;;
	esac
}

wg() { wg_no_peers "$@"; }
ip() { ip_healthy "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_wg0_no_peer "$@"
}
: >"$NORDVPN_EASY_CONNECT_APPLY_GUARD"
JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$JSON")" \
	'config.peer_missing is suppressed during connect_apply when guard is active'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "config.peer_missing")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: config.peer_missing should not appear during connect_apply guard' >&2
	exit 1
fi
rm -f "$NORDVPN_EASY_CONNECT_APPLY_GUARD"

wg() { wg_no_peers "$@"; }
ip() { ip_healthy "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
uci_wg0_absent() {
	case "$*" in
		'get network.wg0.proto') return 1 ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.vpn_country') printf '%s\n' 'DE' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' '' ;;
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '0' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network') return 0 ;;
		*) return 1 ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_wg0_absent "$@"
}
: >"$NORDVPN_EASY_CONNECT_APPLY_GUARD"
JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$JSON")" \
	'config.not_wireguard is suppressed during connect_apply when wg0 is torn down'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "config.not_wireguard")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: config.not_wireguard should not appear during connect_apply guard' >&2
	exit 1
fi
rm -f "$NORDVPN_EASY_CONNECT_APPLY_GUARD"

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
