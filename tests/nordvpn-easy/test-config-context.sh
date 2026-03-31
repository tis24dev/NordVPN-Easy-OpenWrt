#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
CONFIG_CONTEXT_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/config-context.sh"
export NORDVPN_EASY_LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="$(mktemp -d)"
UCI_DIR="$TMP_DIR/uci"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM
mkdir -p "$UCI_DIR"

set_uci_value() {
	printf '%s' "$2" > "$UCI_DIR/$1"
}

uci() {
	if [ "${1:-}" = '-q' ]; then
		shift
	fi

	case "${1:-}" in
		get)
			if [ -f "$UCI_DIR/$2" ]; then
				cat "$UCI_DIR/$2"
				return 0
			fi
			return 1
			;;
		set)
			key="${2%%=*}"
			value="${2#*=}"
			printf '%s' "$value" > "$UCI_DIR/$key"
			return 0
			;;
		delete)
			rm -f "$UCI_DIR/$2"
			return 0
			;;
		commit)
			return 0
			;;
		*)
			printf '%s\n' "FAIL: unexpected uci invocation: $*" >&2
			exit 1
			;;
	esac
}

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

set_uci_value 'nordvpn_easy.main' 'nordvpn_easy'
set_uci_value 'nordvpn_easy.main.enabled' 'yes'
set_uci_value 'nordvpn_easy.main.nordvpn_token' 'abc123'
set_uci_value 'nordvpn_easy.main.wan_if' 'wan'
set_uci_value 'nordvpn_easy.main.vpn_if' ''
set_uci_value 'nordvpn_easy.main.vpn_addr' ''
set_uci_value 'nordvpn_easy.main.server_selection_mode' 'manual'
set_uci_value 'nordvpn_easy.main.preferred_server_station' 'es123'
set_uci_value 'nordvpn_easy.main.preferred_server_hostname' 'es12.nordvpn.com'

# shellcheck disable=SC1090
. "$CONFIG_CONTEXT_LIB"

nordvpn_easy_load_service_context 'cfg_' 'nordvpn_easy' 'main'

assert_eq '1' "$cfg_enabled" 'service context normalizes enabled'
assert_eq 'wg0' "$cfg_vpn_if" 'service context defaults vpn_if'
assert_eq '10.5.0.2/32' "$cfg_vpn_addr" 'service context defaults vpn_addr'
assert_eq 'manual' "$cfg_server_selection_mode" 'service context keeps manual mode'

nordvpn_easy_export_runtime_context_from_service 'cfg_'

assert_eq '1' "$DESIRED_ENABLED" 'runtime context exports desired_enabled'
assert_eq 'wg0' "$VPN_IF" 'runtime context exports vpn_if'
assert_eq '10.5.0.2/32' "$VPN_ADDR" 'runtime context exports vpn_addr'

RUNTIME_FILE="$TMP_DIR/runtime.conf"
umask 0022
WRITTEN_OPTIONS="$(nordvpn_easy_render_runtime_config "$RUNTIME_FILE" 'cfg_')"

[ -f "$RUNTIME_FILE" ] || {
	printf '%s\n' 'FAIL: runtime config file was not created' >&2
	exit 1
}

case "$WRITTEN_OPTIONS" in
	''|*[!0-9]*)
		printf '%s\n' 'FAIL: written options count is not numeric' >&2
		exit 1
		;;
esac

[ "$WRITTEN_OPTIONS" -gt 0 ] || {
	printf '%s\n' 'FAIL: runtime config writer produced no options' >&2
	exit 1
}

assert_eq '0022' "$(umask)" 'runtime config renderer restores umask'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE" 'NORDVPN_TOKEN')" 'runtime file writes token'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE" 'VPN_IF')" 'runtime file writes vpn_if'

printf '%s\n' 'test-config-context.sh: ok'
