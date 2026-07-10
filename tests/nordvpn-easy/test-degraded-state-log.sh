#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
TMP_DIR="$(mktemp -d)"
LOGGER_FILE="$TMP_DIR/syslog.log"
ENTERPRISE_STATE_CACHE="$TMP_DIR/enterprise_state_last"
DIAGNOSTICS_HISTORY="$TMP_DIR/diagnostics_history.log"
SERVER_LIST_FILE="$TMP_DIR/nordvpn-server-list.json"
COUNTRIES_CACHE_FILE="$TMP_DIR/nordvpn-countries.json"
COUNTRIES_CACHE_TS_FILE="$TMP_DIR/nordvpn-countries.timestamp"

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

count_lines_matching() {
	pattern="$1"
	file="$2"
	local count='0'

	count="$(grep -c "$pattern" "$file" 2>/dev/null || true)"
	printf '%s' "${count:-0}"
}

logger() {
	printf '%s\n' "$*" >> "$LOGGER_FILE"
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

wg_no_handshake() {
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

ip_healthy() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' '10.5.0.2/32 proto kernel scope link src 10.5.0.2' ;;
		'route show default') printf '%s\n' 'default dev eth0 proto static' ;;
		*) return 0 ;;
	esac
}

VPN_IF='wg0'
WAN_IF='wan'
NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'
NORDVPN_EASY_ENTERPRISE_STATE_CACHE="$ENTERPRISE_STATE_CACHE"
NORDVPN_EASY_DIAGNOSTICS_HISTORY="$DIAGNOSTICS_HISTORY"
printf '%s\n' '[{"station":"hk270"}]' > "$SERVER_LIST_FILE"
printf '%s\n' '[{"code":"HK","name":"Hong Kong"}]' > "$COUNTRIES_CACHE_FILE"
date +%s > "$COUNTRIES_CACHE_TS_FILE"

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
wg() { wg_no_handshake "$@"; }
ip() { ip_healthy "$@"; }

: >"$LOGGER_FILE"
nordvpn_easy_log_enterprise_state_if_degraded wg0 healthcheck

assert_contains \
	'healthcheck: VPN state degraded: probable_issue_code=runtime.no_handshake' \
	"$(cat "$LOGGER_FILE")" \
	'first transition to degraded logs probable_issue_code to syslog'
assert_eq 'degraded' \
	"$(sed -n 's/^enterprise_state=//p' "$ENTERPRISE_STATE_CACHE" | sed -n '1p')" \
	'enterprise state snapshot cache records degraded'
assert_eq 'runtime.no_handshake' \
	"$(sed -n 's/^probable_issue_code=//p' "$ENTERPRISE_STATE_CACHE" | sed -n '1p')" \
	'enterprise state snapshot cache records probable issue code'
assert_contains 'degraded_since=' "$(cat "$ENTERPRISE_STATE_CACHE")" \
	'enterprise state snapshot cache records degraded_since'
assert_contains 'entered_degraded' "$(cat "$DIAGNOSTICS_HISTORY")" \
	'diagnostics history records degraded transition'

nordvpn_easy_log_enterprise_state_if_degraded wg0 healthcheck

assert_eq '1' \
	"$(count_lines_matching 'VPN state degraded:' "$LOGGER_FILE")" \
	'staying degraded does not emit another degraded transition log'

HANDSHAKE_EPOCH="$(date +%s)"
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
		*) return 1 ;;
	esac
}

: >"$LOGGER_FILE"
wg() { wg_connected "$@"; }

nordvpn_easy_log_enterprise_state_if_degraded wg0 healthcheck

assert_contains 'VPN state recovered:' "$(cat "$LOGGER_FILE")" \
	'recovery from degraded is logged to syslog'
assert_contains 'recovered' "$(cat "$DIAGNOSTICS_HISTORY")" \
	'diagnostics history records recovery transition'

printf 'enterprise_state=connected\nprobable_issue_code=none\ndegraded_since=0\n' > "$ENTERPRISE_STATE_CACHE"
: >"$LOGGER_FILE"
wg() { wg_connected "$@"; }

nordvpn_easy_log_enterprise_state_if_degraded wg0 healthcheck

assert_eq '0' \
	"$(count_lines_matching 'VPN state degraded:' "$LOGGER_FILE")" \
	'healthy runtime does not log a degraded transition'

printf 'enterprise_state=connected\nprobable_issue_code=none\n' > "$ENTERPRISE_STATE_CACHE"
: >"$LOGGER_FILE"
wg() { wg_no_handshake "$@"; }

nordvpn_easy_log_enterprise_state_if_degraded wg0 healthcheck

assert_eq '1' \
	"$(count_lines_matching 'VPN state degraded:' "$LOGGER_FILE")" \
	'degraded transition is logged again after recovering to connected'

printf '%s\n' 'test-degraded-state-log.sh: ok'
