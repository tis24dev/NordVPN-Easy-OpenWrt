#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"

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

printf '%s\n' 'test-runtime.sh: ok'
