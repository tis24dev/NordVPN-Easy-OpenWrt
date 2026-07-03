#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
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
. "$WIREGUARD_LIB"
# shellcheck disable=SC1090
. "$DIAGNOSTICS_LIB"

pick_ping_ip() {
	printf '%s\n' '1.1.1.1'
}

NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'

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

WG_DUMP="$(printf '%b\n' \
	'private\tpublic\t51820\tfwmark' \
	'peerpub\tpsk\tit12.nordvpn.com:51820\t10.5.0.2/32\t1711796400\t2048\t4096\t25')"

PARSED="$(nordvpn_easy_parse_wg_dump_peer "$WG_DUMP")"

assert_eq "$(printf 'it12.nordvpn.com:51820\t1711796400\t2048\t4096')" "$PARSED" 'wg dump parsing'
assert_eq 'Never' "$(nordvpn_easy_humanize_handshake_age 0)" 'zero handshake age'
assert_eq '2.00 KiB' "$(nordvpn_easy_format_human_bytes 2048)" 'byte formatting'

LOCK_DIR="$TMP_DIR/lock"
mkdir -p "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'check' > "$LOCK_DIR/action"
printf '%s\n' 'stale_recovered' > "$LOCK_DIR/state"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"

assert_eq 'busy:check' "$(nordvpn_easy_operation_status_value "$LOCK_DIR")" 'operation status uses lock metadata'

nordvpn_easy_load_lock_metadata "$LOCK_DIR"
assert_eq 'stale_recovered' "$OPERATION_LOCK_STATE" 'lock metadata preserves recovered state'
assert_eq "$$" "$OPERATION_LOCK_PID" 'lock metadata exposes pid'
assert_eq 'check' "$OPERATION_LOCK_ACTION" 'lock metadata exposes action'
assert_eq 'busy:check' "$(nordvpn_easy_operation_status_from_loaded_lock)" 'operation snapshot uses already loaded metadata'

DESIRED_ENABLED=1
VPN_IF='wg0'
SERVER_SELECTION_MODE='auto'
KILL_SWITCH_ENABLED='1'
WIREGUARD_PERSISTENT_KEEPALIVE='15'
WIREGUARD_MTU=''
FIREWALL_MTU_FIX='1'
VPN_COUNTRY='ES'
PREFERRED_SERVER_HOSTNAME=''
PREFERRED_SERVER_STATION=''
WAN_IF='wan'

uci() {
	case "$1" in
		-q)
			shift
			uci "$@"
			return $?
			;;
		get)
				case "$2" in
					network.wg0.disabled) printf '%s\n' '0' ;;
					network.wg0.proto) printf '%s\n' 'wireguard' ;;
					network.wg0.mtu) printf '%s\n' '1420' ;;
					network.wg0server.endpoint_host) printf '%s\n' 'es12.nordvpn.com' ;;
					network.wg0server.endpoint_port) printf '%s\n' '51820' ;;
					network.wg0server.persistent_keepalive) printf '%s\n' '15' ;;
					network.wg0server.nordvpn_hostname) printf '%s\n' 'es12.nordvpn.com' ;;
				network.wg0server.nordvpn_station) printf '%s\n' 'es123' ;;
				network.wg0server.nordvpn_city) printf '%s\n' 'Madrid' ;;
				network.wg0server.nordvpn_country_code) printf '%s\n' 'ES' ;;
				network.wg0server.nordvpn_load) printf '%s\n' '42' ;;
				*) return 1 ;;
			esac
			;;
		show)
			printf '%s\n' "network.wg0server=wireguard_wg0"
			printf '%s\n' "network.wg0.proto='wireguard'"
			return 0
			;;
		*)
			return 1
			;;
	esac
}

ifstatus() {
	return 1
}

ip() {
	[ "$1" = 'link' ] && [ "$2" = 'show' ] && [ "$3" = 'dev' ] && [ "$4" = 'wg0' ]
}

wg() {
	return 0
}

assert_eq 'wireguard' "$(uci get network.wg0.proto)" 'uci fixture exposes current vpn proto'

NORDVPN_EASY_PUBLIC_IP_CACHE="$TMP_DIR/public_ip"
NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="$TMP_DIR/public_country"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="$TMP_DIR/public_verification"
{
	printf '%s\n' 'ip=198.51.100.10'
	printf '%s\n' 'detected_at=1770000000'
	printf '%s\n' 'detected_at_iso=2026-02-01T00:00:00Z'
	printf '%s\n' 'source=https://ifconfig.me/ip'
} > "$NORDVPN_EASY_PUBLIC_IP_CACHE"
printf '%s\n' 'ES' > "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE"
{
	printf '%s\n' 'status=ok'
	printf '%s\n' 'checked_at=1770000002'
	printf '%s\n' 'expected_country=ES'
	printf '%s\n' 'actual_country=ES'
} > "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE"

STATUS_JSON="$(nordvpn_easy_emit_status_json)"

assert_eq 'stale_recovered' "$(printf '%s' "$STATUS_JSON" | jq -r '.operation_lock_state')" 'status json exposes lock state'
assert_eq "$$" "$(printf '%s' "$STATUS_JSON" | jq -r '.operation_lock_pid')" 'status json exposes lock pid'
assert_eq 'check' "$(printf '%s' "$STATUS_JSON" | jq -r '.operation_lock_action')" 'status json exposes lock action'
assert_eq 'recovering' "$(printf '%s' "$STATUS_JSON" | jq -r '.state')" 'status json derives enterprise state from busy check'
assert_eq 'true' "$(printf '%s' "$STATUS_JSON" | jq -r '.kill_switch_enabled')" 'status json exposes kill switch flag'
assert_eq '51820' "$(printf '%s' "$STATUS_JSON" | jq -r '.endpoint_port')" 'status json exposes endpoint port'
assert_eq '15' "$(printf '%s' "$STATUS_JSON" | jq -r '.wireguard_persistent_keepalive')" 'status json exposes WireGuard keepalive'
assert_eq '1420' "$(printf '%s' "$STATUS_JSON" | jq -r '.wireguard_mtu')" 'status json exposes WireGuard MTU'
assert_eq 'true' "$(printf '%s' "$STATUS_JSON" | jq -r '.firewall_mtu_fix')" 'status json exposes firewall MTU fix'
assert_eq '0' "$(printf '%s' "$STATUS_JSON" | jq -r '.handshake_age_seconds')" 'status json exposes handshake age seconds'
assert_eq 'false' "$(printf '%s' "$STATUS_JSON" | jq -r '.runtime_disabled')" 'status json keeps runtime disabled false'
assert_eq 'starting' "$(printf '%s' "$STATUS_JSON" | jq -r '.vpn_status')" 'a present link with no fresh handshake and a failed ifstatus probe is not reported active'
assert_eq '198.51.100.10' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_ip_cached')" 'status json exposes structured public IP cache value'
assert_eq '1770000000' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_ip_detected_at')" 'status json exposes public IP detection timestamp'
assert_eq '2026-02-01T00:00:00Z' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_ip_detected_at_iso')" 'status json exposes public IP detection time'
assert_eq 'https://ifconfig.me/ip' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_ip_source')" 'status json exposes public IP lookup source'
assert_eq 'ok' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_verification_status')" 'status json exposes public verification status'
assert_eq '1770000002' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_verification_checked_at')" 'status json exposes public verification timestamp'
# Capability probe (S7 increment 2): the backend advertises its RPC contract level
# so the LuCI client can gate the supervised apply path on >= 2. Level 1 = legacy.
assert_eq '1' "$(printf '%s' "$STATUS_JSON" | jq -r '.rpc_contract_level')" 'status json advertises the RPC contract level (1 = legacy-only)'
assert_eq 'number' "$(printf '%s' "$STATUS_JSON" | jq -r '.rpc_contract_level | type')" 'rpc_contract_level is a JSON number so the client compares it numerically'
assert_eq '0' "$(nordvpn_easy_wg_runtime_non_negative_int 'not-a-number')" 'non-numeric epoch sanitizes to zero'
assert_eq '1770000000' "$(nordvpn_easy_wg_runtime_non_negative_int '1770000000')" 'numeric epoch is preserved'

# vpn_status no longer reports 'active' from a bare present interface: with no
# fresh handshake (stubbed wg has none) and a failed ifstatus probe, a teardown
# reports 'stopping' and an idle configured interface reports 'inactive'.
assert_eq 'stopping' "$(nordvpn_easy_vpn_status_value 1 wg0 'busy:stop_vpn')" 'a teardown with no fresh handshake reports stopping, not active'
assert_eq 'inactive' "$(nordvpn_easy_vpn_status_value 1 wg0 'idle')" 'a configured interface with no fresh handshake and no operation reports inactive, not active'
{
	printf '%s\n' 'ip=198.51.100.10'
	printf '%s\n' 'detected_at=not-a-number'
	printf '%s\n' 'detected_at_iso=2026-02-01T00:00:00Z'
	printf '%s\n' 'source=https://ifconfig.me/ip'
} > "$NORDVPN_EASY_PUBLIC_IP_CACHE"
CORRUPT_STATUS_JSON="$(nordvpn_easy_emit_status_json)"
assert_eq '0' "$(printf '%s' "$CORRUPT_STATUS_JSON" | jq -r '.public_ip_detected_at')" 'status json sanitizes corrupt public IP cache timestamp'
assert_eq 'ES' "$(printf '%s' "$STATUS_JSON" | jq -r '.public_country_cached')" 'status json exposes cached public country'
assert_eq 'wg0server' "$(nordvpn_easy_peer_section_name 'wg0')" 'peer section lookup falls back to exact section match'

uci_missing_station() {
	case "$1" in
		-q)
			shift
			uci_missing_station "$@"
			return $?
			;;
		get)
				case "$2" in
					network.wg0.disabled) printf '%s\n' '0' ;;
					network.wg0.proto) printf '%s\n' 'wireguard' ;;
					network.wg0server.endpoint_host) printf '%s\n' 'es12.nordvpn.com' ;;
					network.wg0server.endpoint_port) printf '%s\n' '51820' ;;
					network.wg0server.persistent_keepalive) printf '%s\n' '15' ;;
					network.wg0server.nordvpn_hostname) printf '%s\n' 'es12.nordvpn.com' ;;
				network.wg0server.nordvpn_station) return 1 ;;
				network.wg0server.nordvpn_city) printf '%s\n' 'Madrid' ;;
				network.wg0server.nordvpn_country_code) printf '%s\n' 'ES' ;;
				network.wg0server.nordvpn_load) printf '%s\n' '42' ;;
				*) return 1 ;;
			esac
			;;
		show)
			printf '%s\n' "network.wg0server=wireguard_wg0"
			printf '%s\n' "network.wg0.proto='wireguard'"
			return 0
			;;
		*)
			return 1
			;;
	esac
}

uci() {
	uci_missing_station "$@"
}

MISSING_STATION_RC=0
uci get network.wg0server.nordvpn_station >/dev/null 2>&1 || MISSING_STATION_RC=$?
assert_eq '1' "$MISSING_STATION_RC" 'missing-station fixture omits station metadata'

STATUS_JSON_MISSING_STATION="$(nordvpn_easy_emit_status_json)"

assert_eq '' "$(printf '%s' "$STATUS_JSON_MISSING_STATION" | jq -r '.current_server_station')" 'status json does not expose endpoint hostname as station when station metadata is missing'

DIAG_SUMMARY="$(nordvpn_easy_print_diagnostics_health_summary wg0)"

assert_eq 'private_key,addresses,peerdns,delegate,force_link' "$(printf '%s\n' "$DIAG_SUMMARY" | sed -n 's/^required_interface_keys_missing=//p')" 'diagnostics report incomplete WireGuard interface keys separately'
assert_eq 'wireguard interface is incomplete (private_key,addresses,peerdns,delegate,force_link)' "$(printf '%s\n' "$DIAG_SUMMARY" | sed -n 's/^probable_issue=//p')" 'diagnostics prioritize incomplete interface before runtime peer symptoms'
assert_eq 'config.interface_incomplete' "$(printf '%s\n' "$DIAG_SUMMARY" | sed -n 's/^probable_issue_code=//p')" 'diagnostics expose machine-readable issue code'

HANDSHAKE_EPOCH="$(date +%s)"
WG_SNAPSHOT_DUMP="$(printf '%b\n' \
	'private\tpublic\t51820\t' \
	"peerpub\tpsk\tes12.nordvpn.com:51820\t10.5.0.2/32\t${HANDSHAKE_EPOCH}\t2048\t4096\t15")"

wg() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' "$WG_SNAPSHOT_DUMP"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*)
			return 1
			;;
	esac
}

ip() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' '10.5.0.2/32 proto kernel scope link src 10.5.0.2' ;;
		*) return 1 ;;
	esac
}

nordvpn_easy_collect_wireguard_runtime_snapshot wg0

assert_eq 'yes' "$NORDVPN_EASY_WG_RT_CONNECTED" 'wireguard snapshot marks connected when handshake is recent'
assert_eq 'es12.nordvpn.com:51820' "$NORDVPN_EASY_WG_RT_ENDPOINT" 'wireguard snapshot exposes endpoint from wg dump'
assert_eq '2048' "$NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES" 'wireguard snapshot exposes rx bytes'
assert_eq '4096' "$NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES" 'wireguard snapshot exposes tx bytes'
assert_eq 'none' "$NORDVPN_EASY_WG_RT_TRANSFER_ASYMMETRY" 'connected snapshot has no transfer asymmetry'
assert_eq 'connected' "$(nordvpn_easy_enterprise_state_value 1 0 yes yes idle)" 'enterprise state helper treats connected idle runtime as connected'
assert_eq 'degraded' "$(nordvpn_easy_enterprise_state_value 1 0 no no idle)" 'enabled idle runtime without configuration is degraded not idle'
assert_eq 'degraded' "$(nordvpn_easy_enterprise_state_value 1 0 yes no idle)" 'enabled idle runtime without connection is degraded not idle'

rm -rf "$LOCK_DIR"

LOCK_DIR="$TMP_DIR/lock"

SNAPSHOT_STATUS_JSON="$(nordvpn_easy_emit_status_json)"

assert_eq 'true' "$(printf '%s' "$SNAPSHOT_STATUS_JSON" | jq -r '.connected')" 'status json uses wireguard snapshot for connected flag'
assert_eq "$HANDSHAKE_EPOCH" "$(printf '%s' "$SNAPSHOT_STATUS_JSON" | jq -r '.latest_handshake_epoch')" 'status json uses wireguard snapshot handshake epoch'
assert_eq 'connected' "$(printf '%s' "$SNAPSHOT_STATUS_JSON" | jq -r '.state')" 'status json uses shared enterprise state helper when tunnel is up'

printf '%s\n' 'test-runtime.sh: ok'
