#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
RPCD_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"

LIST_JSON="$(NORDVPN_EASY_LIB_DIR="$LIB_DIR" "$RPCD_SCRIPT" list)"

printf '%s' "$LIST_JSON" | jq -er '
	.status == {} and
	.connect == {} and
	.disconnect == {} and
	.reconnect == {} and
	.refresh_countries.force == "Boolean" and
	.refresh_servers.country == "String" and
	.refresh_servers.force == "Boolean" and
	.diagnostics == {}
' >/dev/null

UNKNOWN_JSON="$(printf '{}' | NORDVPN_EASY_LIB_DIR="$LIB_DIR" "$RPCD_SCRIPT" call unknown)"
printf '%s' "$UNKNOWN_JSON" | jq -er '
	.success == false and
	.message == "unknown method: unknown"
' >/dev/null

printf '%s\n' 'test-rpcd.sh: ok'
