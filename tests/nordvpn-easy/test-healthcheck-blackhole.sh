#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
ACTIONS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh"

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"
# shellcheck disable=SC1090
. "$DIAGNOSTICS_LIB"
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

VPN_IF='wg0'
SERVER_LIST_FILE='/tmp/nordvpn-easy-test-healthcheck-server-list.json'
INTERFACE_RESTART_DELAY=0
IFDOWN_COUNT=0
PING_COUNT=0
PING_FAIL_UNTIL=0
SERVER_SELECTION_MODE='auto'
FAILURE_RETRY_DELAY=1
SERVER_ROTATE_THRESHOLD=99
INTERFACE_RESTART_THRESHOLD=99
MAX_INTERFACE_RESTARTS=0

log() { :; }
ifdown() { IFDOWN_COUNT=$((IFDOWN_COUNT + 1)); }
nordvpn_easy_ping_interface() {
	PING_COUNT=$((PING_COUNT + 1))
	[ "$PING_COUNT" -gt "$PING_FAIL_UNTIL" ]
}
nordvpn_easy_ping_wan() { return 0; }
nordvpn_easy_reconcile_explicit_server_selection_drift() { return 0; }
nordvpn_easy_get_servers_list() { return 0; }
nordvpn_easy_server_selection_is_manual() { return 1; }

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

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}

wg() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t0\t0\t1184\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*) return 1 ;;
	esac
}

ip() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' 'default proto static scope link' ;;
		'route show default') printf '%s\n' 'default dev wg0 proto static scope link' ;;
		*) return 0 ;;
	esac
}

NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'

if nordvpn_easy_try_clear_routing_blackhole wg0 test; then
	:
else
	printf '%s\n' 'FAIL: blackhole helper should detect routing blackhole' >&2
	exit 1
fi

assert_eq '1' "$IFDOWN_COUNT" 'blackhole helper runs ifdown on the VPN interface'

IFDOWN_COUNT=0
nordvpn_easy_diagnostics_reset_state
wg() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t$(date +%s)\t4096\t4096\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*) return 1 ;;
	esac
}
ip() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' '10.5.0.2/32 proto kernel scope link src 10.5.0.2' ;;
		'route show default') printf '%s\n' 'default dev eth0 proto static' ;;
		*) return 0 ;;
	esac
}

if nordvpn_easy_try_clear_routing_blackhole wg0 test; then
	printf '%s\n' 'FAIL: healthy routing should not trigger blackhole recovery' >&2
	exit 1
fi

assert_eq '0' "$IFDOWN_COUNT" 'healthy routing does not run ifdown'

IFDOWN_COUNT=0
PING_COUNT=0
wg() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t0\t0\t1184\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*) return 1 ;;
	esac
}
ip() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' 'default proto static scope link' ;;
		'route show default') printf '%s\n' 'default dev wg0 proto static scope link' ;;
		*) return 0 ;;
	esac
}

nordvpn_easy_check_once

assert_eq '1' "$IFDOWN_COUNT" 'health check clears routing blackhole before ping recovery'
assert_eq '1' "$PING_COUNT" 'health check continues after blackhole recovery'

printf '%s\n' 'test-healthcheck-blackhole.sh: ok'
