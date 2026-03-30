#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
CATALOG_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/catalog.sh"
FIXTURE="$ROOT_DIR/tests/nordvpn-easy/fixtures/nordvpn-api-servers.json"
TMP_DIR="$(mktemp -d)"
CATALOG_JSON="$TMP_DIR/catalog.json"
TS_FILE="$TMP_DIR/catalog.timestamp"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$CATALOG_LIB"

assert_jq() {
	filter="$1"
	file="$2"
	label="$3"

	if ! jq -er "$filter" "$file" >/dev/null 2>&1; then
		printf '%s\n' "FAIL: $label" >&2
		jq '.' "$file" >&2
		exit 1
	fi
}

nordvpn_easy_build_server_catalog_json 237 IT Italy < "$FIXTURE" > "$CATALOG_JSON"

assert_jq '.country_id == 237' "$CATALOG_JSON" 'country id preserved'
assert_jq '.country_code == "IT"' "$CATALOG_JSON" 'country code preserved'
assert_jq '.servers | length == 2' "$CATALOG_JSON" 'offline and invalid servers filtered out'
assert_jq '.servers[0].hostname == "it12.nordvpn.com"' "$CATALOG_JSON" 'servers sorted by load'
assert_jq '.servers[1].station == "it456"' "$CATALOG_JSON" 'station exported'

nordvpn_easy_server_catalog_has_servers "$CATALOG_JSON"

TSV_OUTPUT="$(nordvpn_easy_server_catalog_candidates_tsv "$CATALOG_JSON")"
printf '%s\n' "$TSV_OUTPUT" | grep -F 'it12.nordvpn.com' >/dev/null
printf '%s\n' "$TSV_OUTPUT" | grep -F 'PUBKEY-456' >/dev/null

printf '%s\n' '1711796400' > "$TS_FILE"
nordvpn_easy_emit_server_catalog_json "$CATALOG_JSON" "$TS_FILE" 3600 > "$TMP_DIR/catalog-emitted.json"

assert_jq '.cached_at == 1711796400' "$TMP_DIR/catalog-emitted.json" 'cached_at metadata emitted'
assert_jq '.cache_ttl == 3600' "$TMP_DIR/catalog-emitted.json" 'cache ttl metadata emitted'

printf '%s\n' 'test-catalog-fixtures.sh: ok'
