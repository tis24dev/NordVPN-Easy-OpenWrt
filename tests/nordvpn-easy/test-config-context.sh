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

assert_file_has_line() {
	expected_line="$1"
	file_path="$2"
	label="$3"

	grep -Fx "$expected_line" "$file_path" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "missing line: $expected_line" >&2
		exit 1
	}
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
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE" 'WAN_IF')" 'runtime file writes wan_if'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE" 'VPN_IF')" 'runtime file writes vpn_if'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE" 'VPN_ADDR')" 'runtime file writes vpn_addr'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE" 'VPN_PORT')" 'runtime file writes vpn_port'
assert_file_has_line "NORDVPN_TOKEN='abc123'" "$RUNTIME_FILE" 'runtime file contains exact token key'
assert_file_has_line "WAN_IF='wan'" "$RUNTIME_FILE" 'runtime file contains exact wan_if key'
assert_file_has_line "VPN_IF='wg0'" "$RUNTIME_FILE" 'runtime file contains exact vpn_if key'
assert_file_has_line "VPN_ADDR='10.5.0.2/32'" "$RUNTIME_FILE" 'runtime file contains exact vpn_addr key'
assert_file_has_line "VPN_PORT='51820'" "$RUNTIME_FILE" 'runtime file contains exact vpn_port key'

RUNTIME_TOKEN="$(
	(
		# shellcheck disable=SC1090
		. "$RUNTIME_FILE"
		printf '%s' "$NORDVPN_TOKEN"
	)
)"
RUNTIME_WAN_IF="$(
	(
		# shellcheck disable=SC1090
		. "$RUNTIME_FILE"
		printf '%s' "$WAN_IF"
	)
)"
RUNTIME_VPN_IF="$(
	(
		# shellcheck disable=SC1090
		. "$RUNTIME_FILE"
		printf '%s' "$VPN_IF"
	)
)"
RUNTIME_VPN_ADDR="$(
	(
		# shellcheck disable=SC1090
		. "$RUNTIME_FILE"
		printf '%s' "$VPN_ADDR"
	)
)"
RUNTIME_VPN_PORT="$(
	(
		# shellcheck disable=SC1090
		. "$RUNTIME_FILE"
		printf '%s' "$VPN_PORT"
	)
)"

assert_eq 'abc123' "$RUNTIME_TOKEN" 'runtime file round-trips token'
assert_eq 'wan' "$RUNTIME_WAN_IF" 'runtime file round-trips wan_if'
assert_eq 'wg0' "$RUNTIME_VPN_IF" 'runtime file round-trips vpn_if'
assert_eq '10.5.0.2/32' "$RUNTIME_VPN_ADDR" 'runtime file round-trips vpn_addr'
assert_eq '51820' "$RUNTIME_VPN_PORT" 'runtime file round-trips vpn_port'

nordvpn_easy_validate_runtime_config "$RUNTIME_FILE" 'cfg_'
assert_eq 'ok' "$NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS" 'runtime config validation succeeds'

RUNTIME_FILE_RESULTVAR="$TMP_DIR/runtime-resultvar.conf"
nordvpn_easy_render_runtime_config "$RUNTIME_FILE_RESULTVAR" 'cfg_' WRITTEN_OPTIONS_RV

[ -f "$RUNTIME_FILE_RESULTVAR" ] || {
	printf '%s\n' 'FAIL: runtime config file (result_var) was not created' >&2
	exit 1
}

case "$WRITTEN_OPTIONS_RV" in
	''|*[!0-9]*)
		printf '%s\n' 'FAIL: written options count (result_var) is not numeric' >&2
		exit 1
		;;
esac

[ "$WRITTEN_OPTIONS_RV" -gt 0 ] || {
	printf '%s\n' 'FAIL: runtime config writer (result_var) produced no options' >&2
	exit 1
}

assert_eq "$WRITTEN_OPTIONS" "$WRITTEN_OPTIONS_RV" 'result_var returns same count as stdout path'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE_RESULTVAR" 'NORDVPN_TOKEN')" 'result_var file writes token'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE_RESULTVAR" 'WAN_IF')" 'result_var file writes wan_if'
assert_eq 'present' "$(nordvpn_easy_runtime_file_key_state "$RUNTIME_FILE_RESULTVAR" 'VPN_IF')" 'result_var file writes vpn_if'
nordvpn_easy_validate_runtime_config "$RUNTIME_FILE_RESULTVAR" 'cfg_'
assert_eq 'ok' "$NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS" 'result_var render validates'

INVALID_RUNTIME_FILE="$TMP_DIR/runtime-invalid.conf"
awk '
	{
		if ($0 ~ /^NORDVPN_TOKEN=/) {
			sub(/^NORDVPN_TOKEN=/, "nordvpn_token=")
		}
		print
	}
' "$RUNTIME_FILE" > "$INVALID_RUNTIME_FILE"

INVALID_RC=0
nordvpn_easy_validate_runtime_config "$INVALID_RUNTIME_FILE" 'cfg_' || INVALID_RC=$?
assert_eq '1' "$INVALID_RC" 'invalid runtime config fails validation'
assert_eq 'failed' "$NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS" 'invalid runtime config reports failed status'
case "$NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR" in
	*'NORDVPN_TOKEN'*)
		;;
	*)
		printf '%s\n' "FAIL: invalid runtime config error should reference missing token key: $NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR" >&2
		exit 1
		;;
esac

if command -v busybox >/dev/null 2>&1; then
	BUSYBOX_RESULT="$(
		busybox ash <<EOF
set -eu
ROOT_DIR='$ROOT_DIR'
export NORDVPN_EASY_LIB_DIR="\$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="\$(mktemp -d)"
UCI_DIR="\$TMP_DIR/uci"
mkdir -p "\$UCI_DIR"

cleanup() {
	rm -rf "\$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

set_uci_value() {
	printf '%s' "\$2" > "\$UCI_DIR/\$1"
}

uci() {
	if [ "\${1:-}" = '-q' ]; then
		shift
	fi

	case "\${1:-}" in
		get)
			if [ -f "\$UCI_DIR/\$2" ]; then
				cat "\$UCI_DIR/\$2"
				return 0
			fi
			return 1
			;;
		set)
			key="\${2%%=*}"
			value="\${2#*=}"
			printf '%s' "\$value" > "\$UCI_DIR/\$key"
			return 0
			;;
		delete)
			rm -f "\$UCI_DIR/\$2"
			return 0
			;;
		commit)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

. "\$NORDVPN_EASY_LIB_DIR/config-context.sh"

set_uci_value 'nordvpn_easy.main' 'nordvpn_easy'
set_uci_value 'nordvpn_easy.main.enabled' 'yes'
set_uci_value 'nordvpn_easy.main.nordvpn_token' 'abc123'
set_uci_value 'nordvpn_easy.main.wan_if' 'wan'
set_uci_value 'nordvpn_easy.main.vpn_if' ''

nordvpn_easy_load_service_context 'cfg_' 'nordvpn_easy' 'main'
RUNTIME_FILE="\$TMP_DIR/runtime-busybox.conf"
WRITTEN_OPTIONS="\$(nordvpn_easy_render_runtime_config "\$RUNTIME_FILE" 'cfg_')"
[ "\$(nordvpn_easy_runtime_file_key_state "\$RUNTIME_FILE" 'NORDVPN_TOKEN')" = 'present' ]
[ "\$(nordvpn_easy_runtime_file_key_state "\$RUNTIME_FILE" 'WAN_IF')" = 'present' ]
[ "\$(nordvpn_easy_runtime_file_key_state "\$RUNTIME_FILE" 'VPN_IF')" = 'present' ]
nordvpn_easy_validate_runtime_config "\$RUNTIME_FILE" 'cfg_'
[ "\$NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS" = 'ok' ]
case "\$WRITTEN_OPTIONS" in
	''|*[!0-9]*) exit 1 ;;
esac
printf '%s\n' 'busybox-ok'
EOF
	)"
	assert_eq 'busybox-ok' "$BUSYBOX_RESULT" 'busybox ash render path remains valid'
fi

printf '%s\n' 'test-config-context.sh: ok'
