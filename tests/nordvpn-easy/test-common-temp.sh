#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
ORIG_PATH="${PATH:-}"

cleanup() {
	PATH="$ORIG_PATH"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"

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

nordvpn_easy_log() { :; }
LOCK_ACQUIRED=0

umask 0022
INITIAL_UMASK="$(umask)"
nordvpn_easy_mktemp_dir 'unit-test' TEMP_WORKSPACE
[ -d "$TEMP_WORKSPACE" ] || {
	printf '%s\n' 'FAIL: secure temp workspace was not created' >&2
	exit 1
}
assert_eq "$INITIAL_UMASK" "$(umask)" 'mktemp helper restores umask'

TEMP_FILE="$(nordvpn_easy_temp_file_path "$TEMP_WORKSPACE" 'payload.txt')"
printf '%s\n' 'payload' > "$TEMP_FILE"
[ -f "$TEMP_FILE" ] || {
	printf '%s\n' 'FAIL: temp file path did not resolve inside workspace' >&2
	exit 1
}

nordvpn_easy_cleanup_temp_paths
[ ! -d "$TEMP_WORKSPACE" ] || {
	printf '%s\n' 'FAIL: registered temp workspace was not cleaned up' >&2
	exit 1
}

# shellcheck disable=SC2123
PATH='/nonexistent'
mktemp_rc=0
nordvpn_easy_mktemp_dir 'missing-mktemp' >/dev/null 2>&1 || mktemp_rc=$?
assert_eq '1' "$mktemp_rc" 'missing mktemp reports blocker'
PATH="$ORIG_PATH"

SANITIZED="$(
	printf "%s\n" \
		"nordvpn_easy.main.nordvpn_token='token-secret'" \
		"network.wg0.private_key='private-secret'" \
		"network.wg0.preshared_key='psk-secret'" \
		'{"nordlynx_private_key":"nordlynx-secret","access_token":"access-secret"}' \
		'Authorization: Bearer bearer-secret' |
		nordvpn_easy_sanitize_diagnostics_stream
)"

case "$SANITIZED" in
	*token-secret*|*private-secret*|*psk-secret*|*nordlynx-secret*|*access-secret*|*bearer-secret*)
		printf '%s\n' 'FAIL: diagnostics sanitizer leaked a secret' >&2
		exit 1
		;;
esac

case "$SANITIZED" in
	*'***REDACTED***'*)
		;;
	*)
		printf '%s\n' 'FAIL: diagnostics sanitizer did not redact sensitive values' >&2
		exit 1
		;;
esac

assert_eq 'HTTP error response' "$(nordvpn_easy_curl_rc_meaning 22)" 'curl rc 22 is explained'

VPN_IF='wg0'
WIREGUARD_PERSISTENT_KEEPALIVE='15'
WIREGUARD_MTU='1420'
FIREWALL_MTU_FIX='1'

nordvpn_easy_emit_status_json() {
	printf '%s\n' '{"wireguard_persistent_keepalive":15,"wireguard_mtu":"1420","firewall_mtu_fix":true}'
}

nordvpn_easy_find_firewall_zone_section() {
	[ "$1" = 'wg0' ] || return 1
	printf '%s\n' 'firewall.@zone[1]'
}

wg() {
	if [ "$1" = 'show' ] && [ "$2" = 'wg0' ] && [ "${3:-}" = 'peers' ]; then
		printf '%s\n' 'peer-public-key'
		return 0
	fi
	printf '%s\n' 'interface: wg0'
	printf '%s\n' '  public key: public-only'
}

uci() {
	if [ "$1" = '-q' ]; then
		shift
		uci "$@"
		return $?
	fi

	case "$*" in
		'get network.wg0.proto')
			printf '%s\n' 'wireguard'
			;;
		'get network.wg0.disabled')
			printf '%s\n' '0'
			;;
		'get network.wg0.private_key')
			printf '%s\n' 'private-secret'
			;;
		'get network.wg0server.endpoint_host')
			printf '%s\n' 'it12.nordvpn.com'
			;;
		'get network.wg0server.public_key')
			printf '%s\n' 'public-only'
			;;
		'get network.wg0server.allowed_ips')
			printf '%s\n' '0.0.0.0/0'
			;;
		'get network.wg0server.route_allowed_ips')
			printf '%s\n' '1'
			;;
		'show network')
			printf "%s\n" "network.wg0server=wireguard_wg0"
			;;
		'show nordvpn_easy')
			printf "%s\n" "nordvpn_easy.main.nordvpn_token='token-secret'"
			;;
		'show network.wg0')
			printf "%s\n" "network.wg0.private_key='private-secret'"
			printf "%s\n" "network.wg0.mtu='1420'"
			;;
		'show network.wg0server')
			printf "%s\n" "network.wg0server.persistent_keepalive='15'"
			;;
		'show firewall.@zone[1]')
			printf "%s\n" "firewall.@zone[1].network='wan wg0'"
			printf "%s\n" "firewall.@zone[1].mtu_fix='1'"
			;;
		*)
			return 1
			;;
	esac
}

ip() {
	printf '%s\n' "$*"
}

logread() {
	printf "%s\n" "user.notice nordvpn-easy: token:token-secret"
}

DIAGNOSTICS_OUTPUT="$(nordvpn_easy_export_diagnostics_log 'nordvpn-easy')"

case "$DIAGNOSTICS_OUTPUT" in
	*'WireGuard status'*'persistent_keepalive'*'mtu_fix'*)
		;;
	*)
		printf '%s\n' 'FAIL: diagnostics export should include WireGuard and firewall transport state' >&2
		exit 1
		;;
esac

case "$DIAGNOSTICS_OUTPUT" in
	*'Health summary'*'peer_section_found=yes'*'required_peer_keys_missing=none'*'probable_issue=none detected'*)
		;;
	*)
		printf '%s\n' 'FAIL: diagnostics export should include a useful health summary' >&2
		exit 1
		;;
esac

case "$DIAGNOSTICS_OUTPUT" in
	*token-secret*|*private-secret*)
		printf '%s\n' 'FAIL: diagnostics export leaked a secret' >&2
		exit 1
		;;
esac

printf '%s\n' 'test-common-temp.sh: ok'
