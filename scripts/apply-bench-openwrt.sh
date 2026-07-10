#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Lab benchmark: stop_vpn + country change + start_connect + poll (Save & Apply backend path).
set -eu

BENCH_LOG='/tmp/run/nordvpn-easy/apply-bench.log'
START_CONNECT_LOG='/tmp/run/nordvpn-easy/start-connect.log'
POLL_SECONDS=3
TIMEOUT_SECONDS=300

mkdir -p /tmp/run/nordvpn-easy
: >"$BENCH_LOG"

log_line() {
	printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date)" "$*" | tee -a "$BENCH_LOG"
}

read_status_field() {
	local field="$1"
	ubus call nordvpn.easy status 2>/dev/null | jsonfilter -e "@.${field}" 2>/dev/null || true
}

T0="$(date +%s)"
log_line '=== apply bench start ==='

WAIT=0
while [ "$WAIT" -lt 60 ]; do
	OP_STATUS="$(read_status_field operation_status)"
	LOCK_ACTION="$(read_status_field operation_lock_action)"
	if [ "$OP_STATUS" = 'idle' ] && [ -z "$LOCK_ACTION" ]; then
		break
	fi
	log_line "waiting for idle lock (op=$OP_STATUS lock=$LOCK_ACTION)"
	sleep 2
	WAIT=$((WAIT + 2))
done

OLD_COUNTRY="$(uci -q get nordvpn_easy.main.vpn_country 2>/dev/null || true)"
case "$OLD_COUNTRY" in
	GE) NEW_COUNTRY='NL' ;;
	NL) NEW_COUNTRY='GE' ;;
	*) NEW_COUNTRY='NL' ;;
esac
log_line "target country switch: ${OLD_COUNTRY:-?} -> $NEW_COUNTRY"

log_line 'phase: stop_vpn'
T_STOP0="$(date +%s)"
/etc/init.d/nordvpn-easy stop_vpn >>"$BENCH_LOG" 2>&1
T_STOP1="$(date +%s)"
log_line "stop_vpn finished in $((T_STOP1 - T_STOP0))s"

uci set "nordvpn_easy.main.vpn_country=$NEW_COUNTRY"
uci commit nordvpn_easy
log_line 'uci committed new vpn_country'

: >"$START_CONNECT_LOG" 2>/dev/null || true
log_line 'phase: start_connect (async)'
T_DISPATCH0="$(date +%s)"
ubus call nordvpn.easy start_connect >>"$BENCH_LOG" 2>&1
T_DISPATCH1="$(date +%s)"
log_line "start_connect ubus returned in $((T_DISPATCH1 - T_DISPATCH0))s"

log_line 'phase: poll status until connected + idle (or connect_apply success)'
T_POLL0="$(date +%s)"
T_APPLY_DONE=''
while :; do
	NOW="$(date +%s)"
	ELAPSED=$((NOW - T0))
	if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
		log_line "TIMEOUT after ${ELAPSED}s"
		exit 124
	fi

	STATE="$(read_status_field state)"
	VPN_STATUS="$(read_status_field vpn_status)"
	OP_STATUS="$(read_status_field operation_status)"
	LOCK_ACTION="$(read_status_field operation_lock_action)"
	SELECTED="$(read_status_field selected_country)"
	CONNECTED="$(read_status_field connected)"
	APPLY_FINISHED="$(read_status_field connect_apply_finished)"
	APPLY_SUCCESS="$(read_status_field connect_apply_success)"
	APPLY_COUNTRY="$(read_status_field connect_apply_country)"

	log_line "poll t=${ELAPSED}s state=$STATE vpn=$VPN_STATUS op=$OP_STATUS lock=$LOCK_ACTION country=$SELECTED connected=$CONNECTED apply_done=$APPLY_FINISHED apply_ok=$APPLY_SUCCESS apply_country=$APPLY_COUNTRY"

	if [ -z "$T_APPLY_DONE" ] && [ "$APPLY_FINISHED" = 'true' ] && [ "$APPLY_SUCCESS" = 'true' ] && [ "$APPLY_COUNTRY" = "$NEW_COUNTRY" ]; then
		T_APPLY_DONE="$NOW"
		log_line "connect_apply converged in $((T_APPLY_DONE - T0))s (stop=$((T_STOP1 - T_STOP0))s dispatch=$((T_DISPATCH1 - T_DISPATCH0))s apply_bg=$((T_APPLY_DONE - T_DISPATCH1))s)"
	fi

	if [ "$CONNECTED" = 'true' ] && [ "$SELECTED" = "$NEW_COUNTRY" ] && [ "$VPN_STATUS" = 'active' ] && [ "$OP_STATUS" = 'idle' ]; then
		T_DONE="$NOW"
		log_line "vpn_active converged in $((T_DONE - T0))s (stop=$((T_STOP1 - T_STOP0))s dispatch=$((T_DISPATCH1 - T_DISPATCH0))s connect_bg=$((T_DONE - T_DISPATCH1))s apply_marker=${T_APPLY_DONE:-na})"
		break
	fi

	sleep "$POLL_SECONDS"
done

log_line '=== phase4 markers (syslog) ==='
MARK_TS="$T0"
logread 2>/dev/null | grep -E 'nordvpn-easy|nordvpn-easy-hotplug' | grep -E 'cached setup config|using cached setup config|hook unchanged|during connect apply|install_hooks requested|stop_vpn requested|connect requested|setup requested|core action .setup.|core action .stop_vpn.|start_connect background' >>"$BENCH_LOG" || true

log_line '=== start-connect.log ==='
[ -f "$START_CONNECT_LOG" ] && cat "$START_CONNECT_LOG" >>"$BENCH_LOG" || log_line '(no start-connect.log)'

log_line '=== bench complete ==='
cat "$BENCH_LOG"
