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

REFRESH_INIT="$TMP_DIR/init-refresh"
REFRESH_CAPTURE="$TMP_DIR/refresh-calls"
cat > "$REFRESH_INIT" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$REFRESH_CAPTURE"
exit 0
EOF
chmod 755 "$REFRESH_INIT"

REFRESH_FORCE_JSON="$(
	printf '{"force":true}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$REFRESH_INIT" \
		sh "$RPCD_SCRIPT" call refresh_countries
)"
printf '%s' "$REFRESH_FORCE_JSON" | jq -er '
	.success == true and
	.action == "refresh_countries_force"
' >/dev/null
assert_refresh_call="$(tail -n 1 "$REFRESH_CAPTURE")"
[ "$assert_refresh_call" = 'refresh_countries_force' ] || {
	printf '%s\n' 'FAIL: rpc refresh_countries force=true should invoke refresh_countries_force' >&2
	exit 1
}

REFRESH_DEFAULT_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$REFRESH_INIT" \
		sh "$RPCD_SCRIPT" call refresh_countries
)"
printf '%s' "$REFRESH_DEFAULT_JSON" | jq -er '
	.success == true and
	.action == "refresh_countries"
' >/dev/null
assert_refresh_call="$(tail -n 1 "$REFRESH_CAPTURE")"
[ "$assert_refresh_call" = 'refresh_countries' ] || {
	printf '%s\n' 'FAIL: rpc refresh_countries default should invoke refresh_countries' >&2
	exit 1
}

FAKE_INIT="$TMP_DIR/init"
RUN_DIR="$TMP_DIR/run"
mkdir -p "$RUN_DIR"
cat > "$FAKE_INIT" <<'EOF'
#!/bin/sh
case "$1" in
	diagnostics_log)
		printf '%s\n' 'diag stdout'
		printf '%s\n' 'diag stderr' >&2
		exit 7
		;;
	*)
		exit 1
		;;
esac
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

DIAG_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$FAKE_INIT" \
		sh "$RPCD_SCRIPT" call diagnostics_log
)"
printf '%s' "$DIAG_JSON" | jq -er '
	.code == 7 and
	.success == false and
	.log == "diag stdout\n" and
	.stdout == "diag stdout\n" and
	.stderr == "diag stderr\n" and
	(.message | contains("diagnostics export failed: diag stderr"))
' >/dev/null

TX_INIT="$TMP_DIR/init-transactional"
TX_CAPTURE="$TMP_DIR/transactional-calls"
LOCK_DIR="$TMP_DIR/lock"
mkdir -p "$LOCK_DIR"
cat > "$TX_INIT" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TX_CAPTURE"
case "\$1" in
	connect)
		exit 0
		;;
	check)
		exit 75
		;;
	*)
		exit 1
		;;
esac
EOF
chmod 755 "$TX_INIT"

CONNECT_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$TX_INIT" \
		sh "$RPCD_SCRIPT" call connect
)"
printf '%s' "$CONNECT_JSON" | jq -er '
	.success == true and
	.action == "connect" and
	.busy == false and
	.skipped == false
' >/dev/null
case "$(cat "$TX_CAPTURE")" in
	connect)
		;;
	*)
		printf '%s\n' 'FAIL: rpc connect should invoke the init connect transaction exactly once' >&2
		exit 1
		;;
esac

printf '%s\n' "$$" > "$LOCK_DIR/pid"
printf '%s\n' 'setup' > "$LOCK_DIR/action"
printf '%s\n' "$(date +%s)" > "$LOCK_DIR/started_at"
printf '%s\n' 'held' > "$LOCK_DIR/state"
BUSY_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$TX_INIT" \
		NORDVPN_EASY_LOCK_DIR="$LOCK_DIR" \
		sh "$RPCD_SCRIPT" call check
)"
printf '%s' "$BUSY_JSON" | jq -er '
	.success == false and
	.busy == true and
	.skipped == true and
	.reason == "operation_busy" and
	.holder_action == "setup" and
	.holder_pid != "" and
	.holder_age_seconds >= 0 and
	(.message | contains("operation busy"))
' >/dev/null

printf '%s\n' 'test-rpcd.sh: ok'
