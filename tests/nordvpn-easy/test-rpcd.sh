#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
RPCD_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

LIST_JSON="$(NORDVPN_EASY_LIB_DIR="$LIB_DIR" sh "$RPCD_SCRIPT" list)"

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

UNKNOWN_JSON="$(printf '{}' | NORDVPN_EASY_LIB_DIR="$LIB_DIR" sh "$RPCD_SCRIPT" call unknown)"
printf '%s' "$UNKNOWN_JSON" | jq -er '
	.success == false and
	.message == "unknown method: unknown"
' >/dev/null

FAKE_INIT="$TMP_DIR/init"
RUN_DIR="$TMP_DIR/run"
mkdir -p "$RUN_DIR"
cat > "$FAKE_INIT" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$FAKE_INIT"
printf '%s\n' 'public_ip failed (rc=1)' > "$RUN_DIR/last_error"

LOOKUP_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$FAKE_INIT" \
		NORDVPN_EASY_RUN_DIR="$RUN_DIR" \
		sh "$RPCD_SCRIPT" call public_ip
)"
printf '%s' "$LOOKUP_JSON" | jq -er '
	.success == false and
	.stdout == "" and
	.stderr == "public_ip failed (rc=1)" and
	.message == "public_ip failed (rc=1)"
' >/dev/null

printf '%s\n' 'test-rpcd.sh: ok'
