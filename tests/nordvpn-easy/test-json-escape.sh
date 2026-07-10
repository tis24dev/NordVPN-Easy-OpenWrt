#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# Guards nordvpn_easy_json_escape against the single-line regression: a
# slurp-then-substitute sed leaves a lone line UNescaped (at EOF `N` auto-prints
# before the s/// commands run), so a single-line value with a " or \ would
# break JSON.parse of the whole status document.

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"

# shellcheck disable=SC1090
. "$COMMON_LIB"

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "expected: $1" >&2
		printf '%s\n' "actual:   $2" >&2
		exit 1
	fi
}

# Escaping must produce a JSON-parseable string value. jq -e fails on invalid JSON.
assert_json_roundtrips() {
	input="$1"
	label="$2"
	escaped="$(nordvpn_easy_json_escape "$input")"
	decoded="$(printf '{"x":"%s"}' "$escaped" | jq -er '.x' 2>/dev/null)" || {
		printf '%s\n' "FAIL: $label (escaped value is not valid JSON): [$escaped]" >&2
		exit 1
	}
	assert_eq "$input" "$decoded" "$label (round-trips through JSON)"
}

# Single-line values with the characters JSON requires escaped -- the regression.
assert_json_roundtrips 'Error: "foo" failed' 'single-line value with double quotes'
assert_json_roundtrips 'path C:\temp' 'single-line value with a backslash'
assert_json_roundtrips 'a"b\c' 'single-line value with both quote and backslash'
assert_json_roundtrips 'plain-token' 'single-line value with no special characters'
assert_json_roundtrips '' 'empty value'

# Multi-line values must still be escaped and joined with \n.
MULTILINE="$(printf 'line1 "q"\nline2 \\ x')"
assert_json_roundtrips "$MULTILINE" 'multi-line value with quotes and backslash'

# A backslash must become exactly two characters in the escaped form.
assert_eq 'a\\b' "$(nordvpn_easy_json_escape 'a\b')" 'a single backslash is doubled'
assert_eq 'say \"hi\"' "$(nordvpn_easy_json_escape 'say "hi"')" 'double quotes are backslash-escaped'

# Control characters (PR #81 review): JSON forbids raw 0x00-0x1F in strings. A TAB (e.g.
# in a curl/API-derived last_error) must be escaped to \t and other C0 bytes stripped, so
# one bad byte can never break JSON.parse of the whole status document.
assert_eq 'a\tb' "$(nordvpn_easy_json_escape "$(printf 'a\tb')")" 'a TAB is escaped to backslash-t'
assert_eq 'ab' "$(nordvpn_easy_json_escape "$(printf 'a\001b')")" 'a raw 0x01 control byte is stripped'
assert_eq 'mix\tend' "$(nordvpn_easy_json_escape "$(printf 'mix\t\001\002end')")" 'TAB escaped and other C0 bytes stripped in one value'
assert_json_roundtrips "$(printf 'tab\there')" 'a value with a TAB stays valid JSON and round-trips'
# The clean fast path must still pass a plain value through unchanged (zero-fork).
assert_eq 'simple-abc-123' "$(nordvpn_easy_json_escape 'simple-abc-123')" 'clean value passes the fast path unchanged'

printf '%s\n' 'test-json-escape.sh: ok'
