#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"

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

log() { :; }

UCI_ENDPOINT_HOST=''
UCI_STATION=''
UCI_HOSTNAME=''

uci() {
	case "$1" in
		-q)
			shift
			uci "$@"
			return $?
			;;
		get)
			case "$2" in
				network.wg0server.endpoint_host) printf '%s\n' "$UCI_ENDPOINT_HOST" ;;
				network.wg0server.nordvpn_station)
					[ -n "$UCI_STATION" ] || return 1
					printf '%s\n' "$UCI_STATION"
					;;
				network.wg0server.nordvpn_hostname) printf '%s\n' "$UCI_HOSTNAME" ;;
				*) return 1 ;;
			esac
			return 0
			;;
		set)
			case "${2%%=*}" in
				network.wg0server.endpoint_host) UCI_ENDPOINT_HOST="${2#*=}" ;;
				network.wg0server.nordvpn_station) UCI_STATION="${2#*=}" ;;
				network.wg0server.nordvpn_hostname) UCI_HOSTNAME="${2#*=}" ;;
			esac
			return 0
			;;
		*)
			return 1
			;;
	esac
}

FAKE_NOW_FILE="$TMP_DIR/fake-now"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=0

date() {
	local now_value

	if [ "${1:-}" = '+%s' ]; then
		now_value="$(cat "$FAKE_NOW_FILE" 2>/dev/null || printf '%s' '0')"
		printf '%s\n' "$now_value"
		printf '%s\n' "$((now_value + 1))" > "$FAKE_NOW_FILE"
		return 0
	fi

	return 1
}

sleep() {
	SLEEP_CALLS="${SLEEP_CALLS}${1},"
}

nordvpn_easy_ping_interface() {
	PING_ATTEMPTS=$((PING_ATTEMPTS + 1))
	[ "$SUCCESS_ON_ATTEMPT" -gt 0 ] && [ "$PING_ATTEMPTS" -ge "$SUCCESS_ON_ATTEMPT" ]
}

VPN_IF='wg0'
POST_RESTART_DELAY='5'

printf '%s\n' '100' > "$FAKE_NOW_FILE"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=2
nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "$POST_RESTART_DELAY" 'unit-test'

assert_eq '2' "$PING_ATTEMPTS" 'wait helper exits as soon as connectivity is restored'
assert_eq '1,' "$SLEEP_CALLS" 'wait helper sleeps only until the next successful probe'

printf '%s\n' '200' > "$FAKE_NOW_FILE"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=0
WAIT_RC=0
nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" '3' 'timeout-test' || WAIT_RC=$?

assert_eq '1' "$WAIT_RC" 'wait helper fails when connectivity never returns'
assert_eq '1,1,' "$SLEEP_CALLS" 'wait helper retries until the timeout window is exhausted'

nordvpn_easy_set_vpn_server_in_uci 'it12.nordvpn.com' 'it123' 'PUBKEY-123' 'IT' 'Milan' '12'

assert_eq 'it12.nordvpn.com' "$UCI_ENDPOINT_HOST" 'wireguard peer endpoint host uses hostname'
assert_eq 'it12.nordvpn.com' "$UCI_HOSTNAME" 'wireguard peer stores NordVPN hostname separately'
assert_eq 'it123' "$UCI_STATION" 'wireguard peer stores NordVPN station separately'
assert_eq 'it123' "$(nordvpn_easy_current_server_station)" 'current server station reads the stored station id'

UCI_STATION=''
assert_eq '' "$(nordvpn_easy_current_server_station || true)" 'current server station does not fall back to endpoint host when station metadata is missing'

printf '%s\n' 'test-wireguard.sh: ok'
