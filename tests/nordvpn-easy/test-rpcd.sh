#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
RPCD_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy"
ACL_FILE="$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/root/usr/share/rpcd/acl.d/luci-app-nordvpn-easy.json"
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
	.stop_vpn == {} and
	.reconnect == {} and
	.reconcile == {} and
	.refresh_countries.force == "Boolean" and
	.refresh_servers.country == "String" and
	.refresh_servers.force == "Boolean" and
	.diagnostics == {} and
	.diagnostics_summary == {}
' >/dev/null

jq -er '
	."luci-app-nordvpn-easy".write.ubus."nordvpn.easy" | index("reconcile")
' "$ACL_FILE" >/dev/null

jq -er '
	."luci-app-nordvpn-easy".write.ubus."nordvpn.easy" | index("stop_vpn")
' "$ACL_FILE" >/dev/null

jq -er '
	."luci-app-nordvpn-easy".write.ubus.uci | index("commit")
' "$ACL_FILE" >/dev/null

jq -er '
	."luci-app-nordvpn-easy".read.ubus."nordvpn.easy" | index("diagnostics_summary")
' "$ACL_FILE" >/dev/null

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
	diagnostics_summary)
		printf '%s\n' '{"generated_at":1,"vpn_if":"wg0","primary_finding":{"code":"none","message":"none detected","action":""},"findings":[]}'
		;;
	*)
		exit 1
		;;
esac
EOF
chmod 755 "$FAKE_INIT"
printf '%s\n' 'public_ip failed (rc=1)' > "$RUN_DIR/last_error"

FAKE_POLL="$TMP_DIR/public-ip-poll"
cat > "$FAKE_POLL" <<'EOF'
#!/bin/sh
printf '%s\n' 'public_ip failed (rc=1)' >&2
exit 1
EOF
chmod 755 "$FAKE_POLL"

LOOKUP_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_PUBLIC_IP_POLL_SCRIPT="$FAKE_POLL" \
		sh "$RPCD_SCRIPT" call public_ip
)"
printf '%s' "$LOOKUP_JSON" | jq -er '
	.success == false and
	.stdout == "" and
	.stderr == "public_ip failed (rc=1)\n" and
	.message == "public_ip failed (rc=1)\n"
' >/dev/null

FAKE_POLL_SILENT="$TMP_DIR/public-ip-poll-silent"
cat > "$FAKE_POLL_SILENT" <<'EOF'
#!/bin/sh
exit 2
EOF
chmod 755 "$FAKE_POLL_SILENT"

SILENT_LOOKUP_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_PUBLIC_IP_POLL_SCRIPT="$FAKE_POLL_SILENT" \
		sh "$RPCD_SCRIPT" call public_ip
)"
printf '%s' "$SILENT_LOOKUP_JSON" | jq -er \
	--arg script "$FAKE_POLL_SILENT" \
	'
	.success == false and
	.code == 2 and
	.stdout == "" and
	.stderr == "" and
	.message == ("public-ip poll script exited with code 2: " + $script)
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

SUMMARY_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$FAKE_INIT" \
		sh "$RPCD_SCRIPT" call diagnostics_summary
)"
printf '%s' "$SUMMARY_JSON" | jq -er '
	.primary_finding.code == "none" and
	(.findings | length) == 0
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
	reconcile)
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

RECONCILE_JSON="$(
	printf '{}' |
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$TX_INIT" \
		sh "$RPCD_SCRIPT" call reconcile
)"
printf '%s' "$RECONCILE_JSON" | jq -er '
	.success == true and
	.action == "reconcile" and
	.busy == false and
	.skipped == false
' >/dev/null
case "$(tail -n 1 "$TX_CAPTURE")" in
	reconcile)
		;;
	*)
		printf '%s\n' 'FAIL: rpc reconcile should invoke the init reconcile transaction exactly once' >&2
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

STATUS_BIN_DIR="$TMP_DIR/status-bin"
STATUS_INIT="$TMP_DIR/init-status"
STATUS_CAPTURE="$TMP_DIR/status-action-calls"
STATUS_RUN_DIR="$TMP_DIR/status-run"
mkdir -p "$STATUS_BIN_DIR" "$STATUS_RUN_DIR"
cat > "$STATUS_BIN_DIR/uci" <<'EOF'
#!/bin/sh
if [ "$1" = 'show' ] && [ "$2" = 'firewall' ]; then
	exit 0
fi
if [ "$1" = '-q' ] && [ "$2" = 'get' ]; then
	case "$3" in
		nordvpn_easy.main.enabled) printf '%s\n' '1' ;;
		nordvpn_easy.main.vpn_country) printf '%s\n' "${FAKE_VPN_COUNTRY:-BO}" ;;
		nordvpn_easy.main.server_selection_mode) printf '%s\n' "${FAKE_SELECTION_MODE:-auto}" ;;
		nordvpn_easy.main.vpn_if) printf '%s\n' 'wg0' ;;
		network.wg0.proto) printf '%s\n' 'wireguard' ;;
		network.wg0server.nordvpn_station) printf '%s\n' "${FAKE_CURRENT_STATION:-45.248.77.163}" ;;
		network.wg0server.nordvpn_country_code) printf '%s\n' "${FAKE_CURRENT_COUNTRY:-AU}" ;;
		network.wg0server.nordvpn_hostname) printf '%s\n' 'au742.nordvpn.com' ;;
		network.wg0server.endpoint_host) printf '%s\n' 'au742.nordvpn.com' ;;
		network.wg0server.nordvpn_city) printf '%s\n' 'Brisbane' ;;
		network.wg0server.nordvpn_load) printf '%s\n' '17' ;;
		network.wg0server.endpoint_port) printf '%s\n' '51820' ;;
		network.wg0server.persistent_keepalive) printf '%s\n' '15' ;;
		*)
			exit 1
			;;
	esac
	exit 0
fi
exit 1
EOF
STATUS_WG_CAPTURE="$TMP_DIR/status-wg-calls"
export STATUS_WG_CAPTURE
cat > "$STATUS_BIN_DIR/wg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STATUS_WG_CAPTURE"
exit 0
EOF
cat > "$STATUS_BIN_DIR/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$STATUS_BIN_DIR/uci" "$STATUS_BIN_DIR/wg" "$STATUS_BIN_DIR/logger"
cat > "$STATUS_INIT" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$STATUS_CAPTURE"
exit 0
EOF
chmod 755 "$STATUS_INIT"

STATUS_STDERR="$TMP_DIR/status-stderr"
: > "$STATUS_WG_CAPTURE"
# Crontab fixtures so recovery_cron_installed is asserted on the real detection
# logic (both branches), not merely on its JSON shape.
STATUS_CRONTAB_ABSENT="$TMP_DIR/crontab-no-marker"
STATUS_CRONTAB_PRESENT="$TMP_DIR/crontab-with-marker"
: > "$STATUS_CRONTAB_ABSENT"
printf '%s\n' '# BEGIN nordvpn-easy' '*/15 * * * * /etc/init.d/nordvpn-easy check' '# END nordvpn-easy' > "$STATUS_CRONTAB_PRESENT"
STATUS_JSON="$(
	printf '{}' |
		PATH="$STATUS_BIN_DIR:$PATH" \
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$STATUS_INIT" \
		NORDVPN_EASY_RUN_DIR="$STATUS_RUN_DIR" \
		NORDVPN_EASY_CRONTAB_PATH="$STATUS_CRONTAB_ABSENT" \
		sh "$RPCD_SCRIPT" call status 2>"$STATUS_STDERR"
)"
# Regression: the rpcd status path must load every library the status emit needs.
# runtime.sh's vpn_status path calls nordvpn_easy_wg_handshake_epoch (wireguard.sh);
# if it is not loaded, every status emit prints "... not found" on stderr.
if grep -qi 'not found' "$STATUS_STDERR"; then
	printf '%s\n' 'FAIL: rpc status emitted a missing-symbol error on stderr:' >&2
	cat "$STATUS_STDERR" >&2
	exit 1
fi
printf '%s' "$STATUS_JSON" | jq -er '
	.selected_country == "BO" and
	.current_server_country == "AU" and
	(.status_seq | type == "number") and
	(.status_seq > 0) and
	(.boot_id | type == "string" and length > 0) and
	(.recovery_cron_installed == false)
' >/dev/null
[ ! -s "$STATUS_CAPTURE" ] || {
	printf '%s\n' 'FAIL: rpc status must not run runtime actions for saved-country drift' >&2
	exit 1
}
# E-hybrid: rpc status is a single live emit -> exactly one WireGuard dump (HEAD
# emitted then wrote the cache = 2) and it must NOT write the status cache on the
# poll path (post-action writers keep the forensic snapshot; nothing reads it here).
status_dumps="$(grep -c 'dump$' "$STATUS_WG_CAPTURE" 2>/dev/null || true)"
[ "$status_dumps" = '1' ] || {
	printf '%s\n' "FAIL: rpc status must collect the WireGuard dump once, got $status_dumps" >&2
	cat "$STATUS_WG_CAPTURE" >&2
	exit 1
}
[ ! -e "$STATUS_RUN_DIR/status.json" ] || {
	printf '%s\n' 'FAIL: rpc status poll must NOT write the status cache' >&2
	exit 1
}

# recovery_cron_installed must flip to true when our managed cron block is present
# (the false branch is asserted on the first status emit above).
STATUS_CRON_JSON="$(
	printf '{}' |
		PATH="$STATUS_BIN_DIR:$PATH" \
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$STATUS_INIT" \
		NORDVPN_EASY_RUN_DIR="$STATUS_RUN_DIR" \
		NORDVPN_EASY_CRONTAB_PATH="$STATUS_CRONTAB_PRESENT" \
		sh "$RPCD_SCRIPT" call status 2>/dev/null
)"
printf '%s' "$STATUS_CRON_JSON" | jq -er '.recovery_cron_installed == true' >/dev/null || {
	printf '%s\n' 'FAIL: recovery_cron_installed must be true when the managed cron block is present' >&2
	exit 1
}

: > "$STATUS_WG_CAPTURE"
STATUS_JSON="$(
	printf '{}' |
		PATH="$STATUS_BIN_DIR:$PATH" \
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_INIT_SCRIPT="$STATUS_INIT" \
		NORDVPN_EASY_RUN_DIR="$STATUS_RUN_DIR" \
		sh "$RPCD_SCRIPT" call status
)"
[ ! -s "$STATUS_CAPTURE" ] || {
	printf '%s\n' 'FAIL: repeated rpc status must stay read-only for saved-country drift' >&2
	exit 1
}
status_dumps="$(grep -c 'dump$' "$STATUS_WG_CAPTURE" 2>/dev/null || true)"
[ "$status_dumps" = '1' ] || {
	printf '%s\n' "FAIL: repeated rpc status must collect the WireGuard dump once, got $status_dumps" >&2
	cat "$STATUS_WG_CAPTURE" >&2
	exit 1
}
[ ! -e "$STATUS_RUN_DIR/status.json" ] || {
	printf '%s\n' 'FAIL: repeated rpc status poll must NOT write the status cache' >&2
	exit 1
}

printf '%s\n' 'test-rpcd.sh: ok'
