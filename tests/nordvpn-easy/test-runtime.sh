#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

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
				network.wg0server.endpoint_host) printf '%s\n' 'es12.nordvpn.com' ;;
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

STATUS_JSON="$(nordvpn_easy_emit_status_json)"

assert_eq 'stale_recovered' "$(printf '%s' "$STATUS_JSON" | jq -r '.operation_lock_state')" 'status json exposes lock state'
assert_eq "$$" "$(printf '%s' "$STATUS_JSON" | jq -r '.operation_lock_pid')" 'status json exposes lock pid'
assert_eq 'check' "$(printf '%s' "$STATUS_JSON" | jq -r '.operation_lock_action')" 'status json exposes lock action'
assert_eq 'false' "$(printf '%s' "$STATUS_JSON" | jq -r '.runtime_disabled')" 'status json keeps runtime disabled false'
assert_eq 'active' "$(printf '%s' "$STATUS_JSON" | jq -r '.vpn_status')" 'status json falls back to ip link when ifstatus probe fails'
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

printf '%s\n' 'test-runtime.sh: ok'
