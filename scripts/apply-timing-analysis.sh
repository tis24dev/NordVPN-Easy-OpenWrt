#!/bin/sh
# Timestamped Save & Apply backend analysis (run on OpenWrt).
set -eu

OUT='/tmp/run/nordvpn-easy/apply-timing-analysis.log'
mkdir -p /tmp/run/nordvpn-easy
: >"$OUT"

ts() { date '+%s'; }
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OUT"; }

read_field() {
	ubus call nordvpn.easy status 2>/dev/null | jsonfilter -e "@.${1}" 2>/dev/null || true
}

wait_idle() {
	local w=0
	while [ "$w" -lt 90 ]; do
		local op lock
		op="$(read_field operation_status)"
		lock="$(read_field operation_lock_state)"
		[ "$op" = 'idle' ] && [ "$lock" != 'held' ] && return 0
		sleep 2
		w=$((w + 2))
	done
	return 1
}

OLD="$(uci -q get nordvpn_easy.main.vpn_country 2>/dev/null || true)"
case "$OLD" in
	BG) NEW='RO' ;;
	RO) NEW='BG' ;;
	GE) NEW='NL' ;;
	NL) NEW='GE' ;;
	*) NEW='BG' ;;
esac

log "=== timing analysis start old=$OLD new=$NEW ==="
log "uci delays: post_restart=$(uci -q get nordvpn_easy.main.post_restart_delay) iface_restart=$(uci -q get nordvpn_easy.main.interface_restart_delay)"

wait_idle || log "WARN: not idle before start"

T0="$(ts)"
log "MARK t0 stop_vpn_begin"
/etc/init.d/nordvpn-easy stop_vpn >>"$OUT" 2>&1
T1="$(ts)"
log "MARK t1 stop_vpn_end duration=$((T1 - T0))s"

uci set "nordvpn_easy.main.vpn_country=$NEW"
uci commit nordvpn_easy
T2="$(ts)"
log "MARK t2 uci_committed delta=$((T2 - T1))s"

log "MARK t3 start_connect_begin"
ubus call nordvpn.easy start_connect >>"$OUT" 2>&1
T3="$(ts)"
log "MARK t4 start_connect_returned delta=$((T3 - T2))s"

TARGET_COUNTRY="$NEW"
POLL=0
while [ "$POLL" -lt 120 ]; do
	sleep 3
	POLL=$((POLL + 3))
	NOW="$(ts)"
	STATE="$(read_field state)"
	VPN="$(read_field vpn_status)"
	OP="$(read_field operation_status)"
	LOCK="$(read_field operation_lock_state)"
	LOCK_ACT="$(read_field operation_lock_action)"
	SEL="$(read_field selected_country)"
	CUR="$(read_field current_server_country)"
	CONN="$(read_field connected)"

	log "POLL t=$((NOW - T0))s state=$STATE vpn=$VPN op=$OP lock=$LOCK/$LOCK_ACT sel=$SEL cur=$CUR conn=$CONN"

	if [ "$CONN" = 'true' ] && [ "$VPN" = 'active' ] && [ "$OP" = 'idle' ] && [ "$LOCK" != 'held' ]; then
		case "$SEL" in
			"$TARGET_COUNTRY") ;;
			*) continue ;;
		esac
		T_DONE="$NOW"
		log "MARK t_done converged total=$((T_DONE - T0))s connect_phase=$((T_DONE - T3))s"
		break
	fi
done

log "=== syslog slice (this run) ==="
logread 2>/dev/null | grep -E 'nordvpn-easy' | grep -E 'MARK|apply:|service:|core action|Private key|network restart|VPN connectivity|geolocat|install_hooks|hook unchanged|cached setup|using cached|during connect apply' | tail -80 >>"$OUT" || true

log "=== core duration lines ==="
logread 2>/dev/null | grep -E "core action '(stop_vpn|setup)' completed" | tail -6 >>"$OUT" || true

log "=== analysis written to $OUT ==="
cat "$OUT"
