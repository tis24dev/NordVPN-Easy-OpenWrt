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

printf '%s\n' 'test-common-temp.sh: ok'
