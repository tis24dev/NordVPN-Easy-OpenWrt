#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
ORIG_PATH="${PATH:-}"
HANDSHAKE_EPOCH="$(date +%s)"

cleanup() {
	PATH="$ORIG_PATH"
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

nordvpn_easy_resolve_wan_device() {
	WAN_DEVICE='eth0'
	return 0
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

LAST_ERROR_MESSAGE=''
NORDVPN_EASY_LAST_ERROR_RECORDED=0
nordvpn_easy_record_last_error() {
	LAST_ERROR_MESSAGE="$*"
	NORDVPN_EASY_LAST_ERROR_RECORDED=1
}

nordvpn_easy_log_blocker 'runtime' 'specific blocker message'
assert_eq 'specific blocker message' "$LAST_ERROR_MESSAGE" 'blocker records the first last error'
assert_eq '1' "$NORDVPN_EASY_LAST_ERROR_RECORDED" 'blocker marks last error as recorded'
nordvpn_easy_log_blocker 'runtime' 'generic blocker message'
assert_eq 'specific blocker message' "$LAST_ERROR_MESSAGE" 'later blockers do not overwrite a recorded last error'

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
	if [ "$1" = 'show' ] && [ "$2" = 'wg0' ] && [ "${3:-}" = 'dump' ]; then
		printf '%b\n' \
			'private\tpublic\t51820\t' \
			"peer-public-key\tpsk\tit12.nordvpn.com:51820\t10.5.0.2/32\t${HANDSHAKE_EPOCH}\t2048\t4096\t15"
		return 0
	fi
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
		'get network.wg0.addresses')
			printf '%s\n' '10.5.0.2/32'
			;;
		'get network.wg0.peerdns')
			printf '%s\n' '0'
			;;
		'get network.wg0.delegate')
			printf '%s\n' '0'
			;;
		'get network.wg0.force_link')
			printf '%s\n' '1'
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
		'get nordvpn_easy.main.server_selection_mode')
			printf '%s\n' 'auto'
			;;
		'get nordvpn_easy.main.enabled')
			printf '%s\n' '1'
			;;
		'get nordvpn_easy.main.wan_if')
			printf '%s\n' 'wan'
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
			printf '%s\n' "$*"
			;;
	esac
}

logread() {
	printf "%s\n" "user.notice nordvpn-easy: token:token-secret"
}

DIAGNOSTICS_OUTPUT="$(nordvpn_easy_export_diagnostics_log 'nordvpn-easy')"

assert_diagnostics_contains() {
	needle="$1"
	message="$2"

	case "$DIAGNOSTICS_OUTPUT" in
		*"$needle"*)
			;;
		*)
			printf '%s\n' "$message" >&2
			exit 1
			;;
	esac
}

case "$DIAGNOSTICS_OUTPUT" in
	*'WireGuard status'*'persistent_keepalive'*'mtu_fix'*)
		;;
	*)
		printf '%s\n' 'FAIL: diagnostics export should include WireGuard and firewall transport state' >&2
		exit 1
		;;
esac

assert_diagnostics_contains 'Health summary' 'FAIL: diagnostics export should include a useful health summary'
assert_diagnostics_contains 'convention_peer_section=wg0server' 'FAIL: diagnostics export should include a useful health summary'
assert_diagnostics_contains 'peer_section_found=yes' 'FAIL: diagnostics export should include a useful health summary'
assert_diagnostics_contains 'required_interface_keys_missing=none' 'FAIL: diagnostics export should include a useful health summary'
assert_diagnostics_contains 'required_peer_keys_missing=none' 'FAIL: diagnostics export should include a useful health summary'
assert_diagnostics_contains 'probable_issue_code=none' 'FAIL: diagnostics export should include probable issue code'
assert_diagnostics_contains 'Connectivity assessment' 'FAIL: diagnostics export should include connectivity assessment'
assert_diagnostics_contains 'Runtime caches & locks' 'FAIL: diagnostics export should include runtime caches section'
assert_diagnostics_contains 'wireguard_connected=yes' 'FAIL: diagnostics export should report wireguard connected on healthy fixture'

case "$DIAGNOSTICS_OUTPUT" in
	*token-secret*|*private-secret*)
		printf '%s\n' 'FAIL: diagnostics export leaked a secret' >&2
		exit 1
		;;
esac

printf '%s\n' 'test-common-temp.sh: ok'
