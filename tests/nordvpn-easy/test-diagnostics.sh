#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
HANDSHAKE_EPOCH="$(date +%s)"

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
SERVER_LIST_FILE='/tmp/nordvpn-easy-test-diagnostics-server-list.json'
COUNTRIES_CACHE_FILE='/tmp/nordvpn-easy-test-diagnostics-countries.json'
COUNTRIES_CACHE_TS_FILE='/tmp/nordvpn-easy-test-diagnostics-countries.timestamp'

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
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network')
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

ip_blackhole() {
	case "$*" in
		'link show dev wg0')
			return 0
			;;
		'route show dev wg0')
			printf '%s\n' 'default proto static scope link'
			;;
		'route show default')
			printf '%s\n' 'default dev wg0 proto static scope link'
			;;
		*)
			return 0
			;;
	esac
}

uci() {
	if [ "$1" = '-q' ]; then
		shift
		uci "$@"
		return $?
	fi

	uci_complete "$@"
}

wg() {
	wg_blackhole "$@"
}

ip() {
	ip_blackhole "$@"
}

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

BLACKHOLE_JSON="$(nordvpn_easy_emit_diagnostics_summary_json wg0)"
assert_eq 'routing.blackhole_default_via_vpn' \
	"$(printf '%s' "$BLACKHOLE_JSON" | jq -r '.primary_finding.code')" \
	'summary json exposes primary finding code'
assert_contains 'runtime.no_handshake' \
	"$(printf '%s' "$BLACKHOLE_JSON" | jq -r '.findings[].code' | tr '\n' ' ')" \
	'summary json includes secondary findings'
assert_eq 'yes' \
	"$(printf '%s' "$BLACKHOLE_JSON" | jq -r '.connectivity.routing_blackhole_risk')" \
	'summary json includes connectivity assessment'

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

ip_healthy() {
	case "$*" in
		'link show dev wg0')
			return 0
			;;
		'route show dev wg0')
			printf '%s\n' '10.5.0.2/32 proto kernel scope link src 10.5.0.2'
			;;
		'route show default')
			printf '%s\n' 'default dev eth0 proto static'
			;;
		*)
			return 0
			;;
	esac
}

wg() {
	wg_connected "$@"
}

ip() {
	ip_healthy "$@"
}

nordvpn_easy_diagnostics_reset_state
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

nordvpn_easy_diagnostics_reset_state
wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
HEALTHY_JSON="$(nordvpn_easy_emit_diagnostics_summary_json wg0)"
assert_eq 'none' \
	"$(printf '%s' "$HEALTHY_JSON" | jq -r '.primary_finding.code')" \
	'healthy summary json reports no primary finding'
assert_eq 'true' \
	"$(printf '%s' "$HEALTHY_JSON" | jq -r '.health.wireguard_connected')" \
	'healthy summary json reports wireguard connected'

printf '%s\n' 'test-diagnostics.sh: ok'
