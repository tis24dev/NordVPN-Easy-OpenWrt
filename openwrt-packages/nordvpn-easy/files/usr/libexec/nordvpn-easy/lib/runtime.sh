#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


NORDVPN_EASY_RUN_DIR="${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}"
NORDVPN_EASY_STATUS_CACHE="${NORDVPN_EASY_STATUS_CACHE:-$NORDVPN_EASY_RUN_DIR/status.json}"
NORDVPN_EASY_PUBLIC_IP_CACHE="${NORDVPN_EASY_PUBLIC_IP_CACHE:-$NORDVPN_EASY_RUN_DIR/public_ip}"
NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="${NORDVPN_EASY_PUBLIC_COUNTRY_CACHE:-$NORDVPN_EASY_RUN_DIR/public_country}"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="${NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE:-$NORDVPN_EASY_RUN_DIR/public_verification}"
NORDVPN_EASY_LAST_ERROR_CACHE="${NORDVPN_EASY_LAST_ERROR_CACHE:-$NORDVPN_EASY_RUN_DIR/last_error}"
NORDVPN_EASY_ENTERPRISE_STATE_CACHE="${NORDVPN_EASY_ENTERPRISE_STATE_CACHE:-$NORDVPN_EASY_RUN_DIR/enterprise_state_last}"
NORDVPN_EASY_DIAGNOSTICS_HISTORY="${NORDVPN_EASY_DIAGNOSTICS_HISTORY:-$NORDVPN_EASY_RUN_DIR/diagnostics_history.log}"

nordvpn_easy_pluralize_time_unit() {
	local value="$1"
	local singular="$2"
	local plural="$3"

	if [ "$value" -eq 1 ]; then
		printf '%s %s' "$value" "$singular"
	else
		printf '%s %s' "$value" "$plural"
	fi
}

nordvpn_easy_format_relative_age() {
	local total_seconds="$1"
	local days hours minutes seconds output=''

	case "$total_seconds" in
		''|*[!0-9]*)
			total_seconds=0
			;;
	esac

	days=$((total_seconds / 86400))
	hours=$(((total_seconds % 86400) / 3600))
	minutes=$(((total_seconds % 3600) / 60))
	seconds=$((total_seconds % 60))

	if [ "$days" -gt 0 ]; then
		output="$(nordvpn_easy_pluralize_time_unit "$days" 'day' 'days')"
		[ "$hours" -gt 0 ] && output="$output, $(nordvpn_easy_pluralize_time_unit "$hours" 'hour' 'hours')"
	elif [ "$hours" -gt 0 ]; then
		output="$(nordvpn_easy_pluralize_time_unit "$hours" 'hour' 'hours')"
		[ "$minutes" -gt 0 ] && output="$output, $(nordvpn_easy_pluralize_time_unit "$minutes" 'minute' 'minutes')"
	elif [ "$minutes" -gt 0 ]; then
		output="$(nordvpn_easy_pluralize_time_unit "$minutes" 'minute' 'minutes')"
		[ "$seconds" -gt 0 ] && output="$output, $(nordvpn_easy_pluralize_time_unit "$seconds" 'second' 'seconds')"
	else
		output="$(nordvpn_easy_pluralize_time_unit "$seconds" 'second' 'seconds')"
	fi

	printf '%s ago\n' "$output"
}

nordvpn_easy_humanize_handshake_age() {
	local epoch="$1"
	local now diff

	case "$epoch" in
		''|*[!0-9]*)
			printf '%s\n' 'Never'
			return 0
			;;
	esac

	[ "$epoch" -gt 0 ] || {
		printf '%s\n' 'Never'
		return 0
	}

	now="$(date +%s 2>/dev/null)"
	case "$now" in
		''|*[!0-9]*)
			printf '%s\n' 'Unknown'
			return 0
			;;
	esac

	diff=$((now - epoch))
	[ "$diff" -lt 0 ] && diff=0
	nordvpn_easy_format_relative_age "$diff"
}

nordvpn_easy_format_human_bytes() {
	local bytes="$1"

	case "$bytes" in
		''|*[!0-9]*)
			bytes=0
			;;
	esac

	awk -v bytes="$bytes" '
		BEGIN {
			split("B KiB MiB GiB TiB PiB", units, " ")
			size = bytes + 0
			unit = 1
			while (size >= 1024 && unit < 6) {
				size /= 1024
				unit++
			}

			if (unit == 1)
				printf "%.0f %s\n", size, units[unit]
			else
				printf "%.2f %s\n", size, units[unit]
		}
	'
}

nordvpn_easy_parse_wg_dump_peer() {
	# Line 1 of `wg show dump` is the interface; lines 2+ are peers. Rather than
	# hard-coding the first peer (NR==2), pick the peer with the newest handshake
	# so a leftover/extra peer cannot shadow the active server, and emit the N/A
	# sentinel when there are no peer lines at all.
	printf '%s\n' "$1" | awk '
		NR == 1 { next }
		NF == 0 { next }
		{
			hs = ($5 ~ /^[0-9]+$/) ? $5 : 0
			if (!found || hs > best_hs) {
				best_hs = hs
				endpoint = ($3 != "" && $3 != "(none)") ? $3 : "N/A"
				handshake = hs
				rx = ($6 ~ /^[0-9]+$/) ? $6 : 0
				tx = ($7 ~ /^[0-9]+$/) ? $7 : 0
				found = 1
			}
		}
		END {
			if (found)
				printf "%s\t%s\t%s\t%s\n", endpoint, handshake, rx, tx
			else
				printf "N/A\t0\t0\t0\n"
		}
		'
}

# Populated by nordvpn_easy_collect_wireguard_runtime_snapshot (single source for status JSON and diagnostics).
NORDVPN_EASY_WG_RT_VPN_IF=''
NORDVPN_EASY_WG_RT_LINK_PRESENT='unknown'
NORDVPN_EASY_WG_RT_ROUTES_COUNT='0'
NORDVPN_EASY_WG_RT_PEER_COUNT='0'
NORDVPN_EASY_WG_RT_ENDPOINT='N/A'
NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH='0'
NORDVPN_EASY_WG_RT_HANDSHAKE='Never'
NORDVPN_EASY_WG_RT_HANDSHAKE_AGE_SECONDS='0'
NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES='0'
NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES='0'
NORDVPN_EASY_WG_RT_TRANSFER_RX='0 B'
NORDVPN_EASY_WG_RT_TRANSFER_TX='0 B'
NORDVPN_EASY_WG_RT_CONNECTED='no'
NORDVPN_EASY_WG_RT_TRANSFER_ASYMMETRY='none'

nordvpn_easy_truthy() {
	case "$1" in
		1|true|yes|on)
			return 0
			;;
	esac

	return 1
}

nordvpn_easy_wg_runtime_non_negative_int() {
	case "$1" in
		''|*[!0-9]*)
			printf '%s\n' '0'
			;;
		*)
			printf '%s\n' "$1"
			;;
	esac
}

nordvpn_easy_collect_wireguard_runtime_snapshot() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"
	local wg_dump=''

	NORDVPN_EASY_WG_RT_VPN_IF="$vpn_if"
	NORDVPN_EASY_WG_RT_LINK_PRESENT='unknown'
	NORDVPN_EASY_WG_RT_ROUTES_COUNT='0'
	NORDVPN_EASY_WG_RT_PEER_COUNT='0'
	NORDVPN_EASY_WG_RT_ENDPOINT='N/A'
	NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH='0'
	NORDVPN_EASY_WG_RT_HANDSHAKE='Never'
	NORDVPN_EASY_WG_RT_HANDSHAKE_AGE_SECONDS='0'
	NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES='0'
	NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES='0'
	NORDVPN_EASY_WG_RT_TRANSFER_RX='0 B'
	NORDVPN_EASY_WG_RT_TRANSFER_TX='0 B'
	NORDVPN_EASY_WG_RT_CONNECTED='no'
	NORDVPN_EASY_WG_RT_TRANSFER_ASYMMETRY='none'

	if command -v ip >/dev/null 2>&1; then
		if ip link show dev "$vpn_if" >/dev/null 2>&1; then
			NORDVPN_EASY_WG_RT_LINK_PRESENT='yes'
		else
			NORDVPN_EASY_WG_RT_LINK_PRESENT='no'
		fi
		NORDVPN_EASY_WG_RT_ROUTES_COUNT="$(ip route show dev "$vpn_if" 2>/dev/null | awk 'END { print NR + 0 }')"
	fi

	if command -v wg >/dev/null 2>&1; then
		NORDVPN_EASY_WG_RT_PEER_COUNT="$(wg show "$vpn_if" peers 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')"
		wg_dump="$(wg show "$vpn_if" dump 2>/dev/null)"
		if [ -n "$wg_dump" ]; then
			IFS="$(printf '\t')" read -r NORDVPN_EASY_WG_RT_ENDPOINT NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH \
				NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES <<EOF
$(nordvpn_easy_parse_wg_dump_peer "$wg_dump")
EOF
		fi
	fi

	NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES="$(nordvpn_easy_wg_runtime_non_negative_int "$NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES")"
	NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES="$(nordvpn_easy_wg_runtime_non_negative_int "$NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES")"
	NORDVPN_EASY_WG_RT_HANDSHAKE="$(nordvpn_easy_humanize_handshake_age "$NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH")"
	NORDVPN_EASY_WG_RT_HANDSHAKE_AGE_SECONDS="$(nordvpn_easy_handshake_age_seconds "$NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH")"
	NORDVPN_EASY_WG_RT_TRANSFER_RX="$(nordvpn_easy_format_human_bytes "$NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES")"
	NORDVPN_EASY_WG_RT_TRANSFER_TX="$(nordvpn_easy_format_human_bytes "$NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES")"

	if nordvpn_easy_handshake_epoch_indicates_connection "$NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH"; then
		NORDVPN_EASY_WG_RT_CONNECTED='yes'
	fi

	if [ "$NORDVPN_EASY_WG_RT_CONNECTED" != 'yes' ] &&
		[ "$NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES" -eq 0 ] &&
		[ "$NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES" -gt 0 ]; then
		NORDVPN_EASY_WG_RT_TRANSFER_ASYMMETRY='stuck_tunnel_suspected'
	fi
}

nordvpn_easy_wg_connected_json() {
	if nordvpn_easy_truthy "$NORDVPN_EASY_WG_RT_CONNECTED"; then
		printf '%s' 'true'
	else
		printf '%s' 'false'
	fi
}

nordvpn_easy_enterprise_state_value() {
	local desired_enabled="$1"
	local interface_disabled="$2"
	local runtime_configured="$3"
	local connected="$4"
	local operation="$5"
	# Status honesty: the supervised apply's honest sub-phase. Only consulted for
	# operation=='busy:supervise' (below), so legacy callers passing 5 args are
	# byte-identical.
	local sub_phase="${6:-}"

	if ! nordvpn_easy_truthy "$desired_enabled"; then
		printf '%s\n' 'disabled'
		return 0
	fi

	if nordvpn_easy_truthy "$interface_disabled"; then
		printf '%s\n' 'disabled'
		return 0
	fi

	if [ "$operation" = 'idle' ]; then
		if nordvpn_easy_truthy "$connected"; then
			printf '%s\n' 'connected'
			return 0
		fi

		# enabled=1 must never surface as idle while the tunnel is down
		printf '%s\n' 'degraded'
		return 0
	fi

	case "$operation" in
		busy:check)
			printf '%s\n' 'recovering'
			;;
		busy:setup|busy:rotate)
			printf '%s\n' 'connecting'
			;;
		busy:disable_runtime)
			printf '%s\n' 'disabled'
			;;
		busy:supervise)
			# A supervised apply is a clean rebuild, not recovery: map the honest
			# sub_phase to a directional state. fetching/'' keep the old 'recovering'
			# default (the old tunnel is still up, no direction yet).
			case "$sub_phase" in
				tearing_down)
					printf '%s\n' 'disconnecting'
					;;
				configuring|connecting|verifying)
					printf '%s\n' 'connecting'
					;;
				*)
					printf '%s\n' 'recovering'
					;;
			esac
			;;
		*)
			printf '%s\n' 'recovering'
			;;
	esac
}

nordvpn_easy_handshake_age_seconds() {
	local epoch="$1"
	local now diff

	case "$epoch" in
		''|*[!0-9]*)
			printf '%s\n' '0'
			return 0
			;;
	esac

	[ "$epoch" -gt 0 ] || {
		printf '%s\n' '0'
		return 0
	}

	now="$(date +%s 2>/dev/null || printf '%s' '0')"
	case "$now" in
		''|*[!0-9]*|0)
			printf '%s\n' '0'
			return 0
			;;
	esac

	diff=$((now - epoch))
	[ "$diff" -lt 0 ] && diff=0
	printf '%s\n' "$diff"
}

nordvpn_easy_status_firewall_mtu_fix() {
	local vpn_if="${1:-$VPN_IF}"
	local section=''
	local networks=''
	local network=''
	local mtu_fix=''

	for section in $(uci show firewall 2>/dev/null | awk -F= '$2=="zone"{ print $1 }'); do
		networks="$(uci -q get "${section}.network" 2>/dev/null || true)"
		for network in $networks; do
			[ "$network" = "$vpn_if" ] || continue
			mtu_fix="$(uci -q get "${section}.mtu_fix" 2>/dev/null || true)"
			[ "$mtu_fix" = '1' ] && printf '%s\n' 'true' || printf '%s\n' 'false'
			return 0
		done
	done

	[ "${FIREWALL_MTU_FIX:-1}" = '1' ] && printf '%s\n' 'true' || printf '%s\n' 'false'
}

nordvpn_easy_operation_status_value() {
	local lock_dir="${1:-$LOCK_DIR}"
	nordvpn_easy_load_lock_metadata "$lock_dir"
	nordvpn_easy_operation_status_from_loaded_lock
}

nordvpn_easy_operation_status_from_loaded_lock() {
	if [ "$OPERATION_LOCK_STATE" = 'none' ]; then
		printf '%s\n' 'idle'
	elif [ -n "$OPERATION_LOCK_ACTION" ]; then
		printf 'busy:%s\n' "$OPERATION_LOCK_ACTION"
	else
		printf '%s\n' 'busy'
	fi
}

nordvpn_easy_load_lock_metadata() {
	local lock_dir="${1:-$LOCK_DIR}"
	local lock_pid_file="${lock_dir}/pid"
	local lock_action_file="${lock_dir}/action"
	local lock_state_file="${lock_dir}/state"
	local lock_started_at_file="${lock_dir}/started_at"
	local lock_pid=''
	local lock_state=''
	local lock_started_at=''

	OPERATION_LOCK_STATE='none'
	OPERATION_LOCK_PID=''
	OPERATION_LOCK_ACTION=''
	OPERATION_LOCK_AGE_SECONDS='0'

	[ -f "$lock_pid_file" ] || return 0

	lock_pid="$(cat "$lock_pid_file" 2>/dev/null)"
	case "$lock_pid" in
		''|*[!0-9]*)
			return 0
			;;
	esac

	if ! kill -0 "$lock_pid" 2>/dev/null; then
		return 0
	fi

	lock_state="$(cat "$lock_state_file" 2>/dev/null)"
	lock_started_at="$(cat "$lock_started_at_file" 2>/dev/null)"

	case "$lock_state" in
		stale_recovered)
			OPERATION_LOCK_STATE='stale_recovered'
			;;
		*)
			OPERATION_LOCK_STATE='held'
			;;
	esac

	OPERATION_LOCK_PID="$lock_pid"
	OPERATION_LOCK_ACTION="$(cat "$lock_action_file" 2>/dev/null)"
	OPERATION_LOCK_AGE_SECONDS="$(nordvpn_easy_lock_age_seconds "$lock_dir" "$lock_started_at")"
}

nordvpn_easy_runtime_configured() {
	local vpn_if="${1:-$VPN_IF}"

	[ "$(uci -q get "network.${vpn_if}.proto" 2>/dev/null)" = 'wireguard' ] || return 1
	nordvpn_easy_peer_section_name "$vpn_if" >/dev/null 2>&1
}

nordvpn_easy_vpn_status_value() {
	local desired_enabled="${1:-${DESIRED_ENABLED:-0}}"
	local vpn_if="${2:-$VPN_IF}"
	local operation="${3:-}"
	# Status honesty: the supervised apply's honest sub-phase. Only consulted when
	# operation=='busy:supervise' (below), so legacy callers passing 3 args are
	# byte-identical. Empty ('' / fetching / verifying) falls through to the
	# unchanged live handshake/ifstatus detection.
	local sub_phase="${4:-}"
	local handshake_epoch='0'
	local ifstatus_json=''

	[ -n "$operation" ] || operation="$(nordvpn_easy_operation_status_value "${LOCK_DIR:-/tmp/nordvpn-easy.lock}")"

	case "$desired_enabled" in
		1|true|yes|on) ;;
		*)
			printf '%s\n' 'inactive'
			return 0
			;;
	esac

	if [ "$(uci -q get "network.${vpn_if}.disabled" 2>/dev/null)" = '1' ]; then
		if [ "$operation" = 'busy:disable_runtime' ]; then
			printf '%s\n' 'stopping'
		else
			printf '%s\n' 'inactive'
		fi
		return 0
	fi

	# Status honesty: during a supervised apply the lock action stays the opaque
	# 'supervise' the whole rebuild, so derive the honest transitional state from the
	# supervisor's own sub_phase. Gated on busy:supervise so every legacy/diagnostics/
	# recovery path below is byte-identical. tearing_down/configuring force the honest
	# transitional value; connecting shows 'active' ONLY on a FRESH handshake (never a
	# premature Connected from ifstatus.up alone), else 'starting'. fetching/verifying/''
	# fall through to the UNCHANGED live detection (the OLD tunnel honestly reads active
	# during fetch).
	if [ "$operation" = 'busy:supervise' ]; then
		case "$sub_phase" in
			tearing_down)
				printf '%s\n' 'stopping'
				return 0
				;;
			configuring)
				printf '%s\n' 'configuring'
				return 0
				;;
			connecting)
				handshake_epoch="$(nordvpn_easy_wg_handshake_epoch "$vpn_if")"
				if nordvpn_easy_handshake_epoch_indicates_connection "$handshake_epoch" &&
					ip link show dev "$vpn_if" >/dev/null 2>&1; then
					printf '%s\n' 'active'
				else
					printf '%s\n' 'starting'
				fi
				return 0
				;;
		esac
	fi

	if ! nordvpn_easy_runtime_configured "$vpn_if"; then
		case "$operation" in
			busy:setup|busy:check|busy:rotate)
				printf '%s\n' 'starting'
				;;
			*)
				printf '%s\n' 'inactive'
				;;
		esac
		return 0
	fi

	handshake_epoch="$(nordvpn_easy_wg_handshake_epoch "$vpn_if")"
	if nordvpn_easy_handshake_epoch_indicates_connection "$handshake_epoch" &&
		ip link show dev "$vpn_if" >/dev/null 2>&1; then
		printf '%s\n' 'active'
		return 0
	fi

	if command -v ifstatus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		# Empty ifstatus output (interface unknown to netifd, e.g. mid-teardown or
		# a wg device created outside netifd) must NOT count as 'up': on jq <= 1.6
		# `printf '' | jq -er '.up == true'` exits 0, which would falsely report
		# 'active' during the exact transitional window this block guards. Only
		# consult jq when ifstatus actually produced JSON.
		# `|| true` keeps a failed ifstatus probe from aborting under `set -e`:
		# the assignment inherits the command's exit status, and ifstatus exits
		# non-zero when the interface is unknown to netifd.
		ifstatus_json="$(ifstatus "$vpn_if" 2>/dev/null || true)"
		if [ -n "$ifstatus_json" ] && printf '%s' "$ifstatus_json" | jq -er '.up == true' >/dev/null 2>&1; then
			printf '%s\n' 'active'
			return 0
		fi
	fi

	# A present interface alone does not mean the VPN session is alive: during a
	# teardown the wg device can still exist (even with a sub-180s handshake) while
	# traffic is already going out unprotected. Only a fresh handshake or a netifd
	# 'up' interface (both handled above) counts as 'active'; otherwise report the
	# honest transitional/inactive state for the operation in flight.
	case "$operation" in
		busy:setup|busy:check|busy:rotate|busy:reconnect|busy:reconcile)
			printf '%s\n' 'starting'
			;;
		busy:stop_vpn|busy:disable_runtime)
			printf '%s\n' 'stopping'
			;;
		*)
			printf '%s\n' 'inactive'
			;;
	esac
}

nordvpn_easy_emit_status_json() {
	local desired_enabled="${DESIRED_ENABLED:-0}"
	local updated_at='0'
	local operation=''
	local vpn_state=''
	local enterprise_state=''
	local interface_disabled='false'
	local runtime_configured='false'
	local operation_lock_state='none'
	local operation_lock_pid=''
	local operation_lock_action=''
	local operation_lock_age_seconds='0'
	local peer_section=''
	local endpoint='N/A'
	local endpoint_port="${VPN_PORT:-51820}"
	local wireguard_keepalive="${WIREGUARD_PERSISTENT_KEEPALIVE:-15}"
	local wireguard_mtu="${WIREGUARD_MTU:-}"
	local firewall_mtu_fix='false'
	local latest_handshake='Never'
	local latest_handshake_epoch='0'
	local handshake_age_seconds='0'
	local transfer_rx='0 B'
	local transfer_rx_bytes='0'
	local transfer_tx='0 B'
	local transfer_tx_bytes='0'
	local connected='false'
	local current_hostname=''
	local current_station=''
	local current_city=''
	local current_country=''
	local current_load=''
	local preferred_hostname="${PREFERRED_SERVER_HOSTNAME:-}"
	local preferred_station="${PREFERRED_SERVER_STATION:-}"
	local public_ip_cached=''
	local public_ip_detected_at='0'
	local public_ip_detected_at_iso=''
	local public_ip_source=''
	local public_country_cached=''
	local public_verification_status='unknown'
	local public_verification_checked_at='0'
	local last_error=''
	local recovery_cron_installed='false'
	local config_fingerprint=''
	local applied_fingerprint=''
	local runtime_token=''
	local applied_current='false'
	local status_seq='0'
	local boot_id=''
	local journal_phase=''
	local journal_sub_phase=''
	local journal_txn_id=''
	local journal_started_at='0'
	local rpc_contract_level='1'

	nordvpn_easy_load_lock_metadata "${LOCK_DIR:-/tmp/nordvpn-easy.lock}"
	operation="$(nordvpn_easy_operation_status_from_loaded_lock)"
	operation_lock_state="$OPERATION_LOCK_STATE"
	operation_lock_pid="$OPERATION_LOCK_PID"
	operation_lock_action="$OPERATION_LOCK_ACTION"
	operation_lock_age_seconds="$OPERATION_LOCK_AGE_SECONDS"
	# Status honesty: read the supervisor's honest sub_phase ONLY during a supervised
	# apply (operation=='busy:supervise') and only when the journal getter is sourced.
	# Otherwise it stays '' so the emitted journal_sub_phase is empty and vpn_status/
	# enterprise_state derivation is byte-identical for every other caller/path.
	if [ "$operation" = 'busy:supervise' ] && command -v nordvpn_easy_journal_get >/dev/null 2>&1; then
		journal_sub_phase="$(nordvpn_easy_journal_get sub_phase 2>/dev/null || printf '')"
	fi
	vpn_state="$(nordvpn_easy_vpn_status_value "$desired_enabled" "$VPN_IF" "$operation" "$journal_sub_phase")"

	if [ "$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)" = '1' ]; then
		interface_disabled='true'
	fi

	if nordvpn_easy_runtime_configured "$VPN_IF"; then
		runtime_configured='true'
		peer_section="$(nordvpn_easy_peer_section_name "$VPN_IF")"
	fi

	if [ -n "$peer_section" ]; then
		current_hostname="$(uci -q get "network.${peer_section}.nordvpn_hostname" 2>/dev/null || true)"
		current_station="$(uci -q get "network.${peer_section}.nordvpn_station" 2>/dev/null || true)"
		current_city="$(uci -q get "network.${peer_section}.nordvpn_city" 2>/dev/null || true)"
		current_country="$(uci -q get "network.${peer_section}.nordvpn_country_code" 2>/dev/null || true)"
		current_load="$(uci -q get "network.${peer_section}.nordvpn_load" 2>/dev/null || true)"
		endpoint_port="$(uci -q get "network.${peer_section}.endpoint_port" 2>/dev/null || printf '%s' "$endpoint_port")"
		wireguard_keepalive="$(uci -q get "network.${peer_section}.persistent_keepalive" 2>/dev/null || printf '%s' "$wireguard_keepalive")"
		wireguard_mtu="$(uci -q get "network.${VPN_IF}.mtu" 2>/dev/null || printf '%s' "$wireguard_mtu")"

		[ -n "$current_hostname" ] || current_hostname="$(uci -q get "network.${peer_section}.description" 2>/dev/null || true)"
	fi

	updated_at="$(date +%s 2>/dev/null || printf '%s' '0')"
	firewall_mtu_fix="$(nordvpn_easy_status_firewall_mtu_fix "$VPN_IF")"
	nordvpn_easy_collect_wireguard_runtime_snapshot "$VPN_IF"
	endpoint="$NORDVPN_EASY_WG_RT_ENDPOINT"
	latest_handshake="$NORDVPN_EASY_WG_RT_HANDSHAKE"
	latest_handshake_epoch="$NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH"
	handshake_age_seconds="$NORDVPN_EASY_WG_RT_HANDSHAKE_AGE_SECONDS"
	transfer_rx="$NORDVPN_EASY_WG_RT_TRANSFER_RX"
	transfer_rx_bytes="$NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES"
	transfer_tx="$NORDVPN_EASY_WG_RT_TRANSFER_TX"
	transfer_tx_bytes="$NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES"
	connected="$(nordvpn_easy_wg_connected_json)"
	enterprise_state="$(nordvpn_easy_enterprise_state_value \
		"$desired_enabled" \
		"$interface_disabled" \
		"$runtime_configured" \
		"$NORDVPN_EASY_WG_RT_CONNECTED" \
		"$operation" \
		"$journal_sub_phase")"

	if [ -r "$NORDVPN_EASY_PUBLIC_IP_CACHE" ]; then
		public_ip_cached="$(sed -n 's/^ip=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
		public_ip_detected_at="$(sed -n 's/^detected_at=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
		public_ip_detected_at_iso="$(sed -n 's/^detected_at_iso=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
		public_ip_source="$(sed -n 's/^source=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
	fi
	case "$public_ip_detected_at" in
		''|*[!0-9]*)
			public_ip_detected_at='0'
			;;
	esac
	[ -r "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" ] && public_country_cached="$(sed -n '1p' "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" 2>/dev/null)"
	if [ -r "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" ]; then
		public_verification_status="$(sed -n 's/^status=//p' "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" 2>/dev/null | sed -n '1p')"
		public_verification_checked_at="$(sed -n 's/^checked_at=//p' "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" 2>/dev/null | sed -n '1p')"
	fi
	case "$public_verification_status" in
		ok|pending|failed|mismatch|unknown)
			;;
		*)
			public_verification_status='unknown'
			;;
	esac
	case "$public_verification_checked_at" in
		''|*[!0-9]*)
			public_verification_checked_at='0'
			;;
	esac
	[ -r "$NORDVPN_EASY_LAST_ERROR_CACHE" ] && last_error="$(sed -n '1p' "$NORDVPN_EASY_LAST_ERROR_CACHE" 2>/dev/null)"

	case "$wireguard_keepalive" in
		''|*[!0-9]*)
			wireguard_keepalive="${WIREGUARD_PERSISTENT_KEEPALIVE:-15}"
			;;
	esac
	case "$wireguard_keepalive" in
		''|*[!0-9]*)
			wireguard_keepalive='15'
			;;
	esac

	# Reflect whether our managed recovery cron block is present in the shared root
	# crontab (BusyBox crond reads /etc/crontabs/root, never /etc/cron.d). The
	# marker must match the CRON_BLOCK_BEGIN written by the init service.
	if grep -Fxq '# BEGIN nordvpn-easy' "${NORDVPN_EASY_CRONTAB_PATH:-/etc/crontabs/root}" 2>/dev/null; then
		recovery_cron_installed='true'
	fi

	# Config-identity fields (additive, observability only). config_fingerprint is
	# the desired-config identity; applied_fingerprint the last one provisioned;
	# applied_current is true when the live runtime is caught up to the desired
	# config. Empty when the fingerprint hasher is unavailable.
	if command -v nordvpn_easy_config_fingerprint >/dev/null 2>&1; then
		config_fingerprint="$(nordvpn_easy_config_fingerprint 2>/dev/null || printf '')"
		applied_fingerprint="$(nordvpn_easy_applied_fingerprint 2>/dev/null || printf '')"
		runtime_token="$(nordvpn_easy_runtime_token_value 2>/dev/null || printf '')"
		if [ -n "$config_fingerprint" ] && [ "$config_fingerprint" = "$applied_fingerprint" ]; then
			applied_current='true'
		fi
	fi

	# Ordering stamps and shadow journal phase (additive). status_seq + boot_id let
	# the LuCI poller discard out-of-order status responses; journal_phase/txn_id
	# expose the (not yet authoritative) apply transaction.
	if command -v nordvpn_easy_journal_next_seq >/dev/null 2>&1; then
		status_seq="$(nordvpn_easy_journal_next_seq 2>/dev/null || printf '0')"
		boot_id="$(nordvpn_easy_journal_boot_id 2>/dev/null || printf '')"
		journal_phase="$(nordvpn_easy_journal_get phase 2>/dev/null || printf '')"
		journal_txn_id="$(nordvpn_easy_journal_get txn_id 2>/dev/null || printf '')"
		# When the transaction opened (router epoch). The JS supervised poll uses it as a
		# freshness gate: a 'done' whose txn STARTED AFTER the apply's first poll is this
		# apply's result even if the poll never caught a non-terminal phase (an instant/
		# mocked converge); a stale leftover 'done' keeps its older started_at and is not
		# accepted.
		journal_started_at="$(nordvpn_easy_journal_get started_at 2>/dev/null || printf '0')"
	fi
	case "$status_seq" in
		''|*[!0-9]*) status_seq='0' ;;
	esac
	case "$journal_started_at" in
		''|*[!0-9]*) journal_started_at='0' ;;
	esac

	# The RPC contract level the emitted status advertises (constant 2). Defaults to 1
	# if the getter is somehow unsourced, so a client never sees a spurious high level.
	if command -v nordvpn_easy_rpc_contract_level >/dev/null 2>&1; then
		rpc_contract_level="$(nordvpn_easy_rpc_contract_level 2>/dev/null || printf '1')"
	fi
	case "$rpc_contract_level" in
		''|*[!0-9]*) rpc_contract_level='1' ;;
	esac

	cat <<EOF
{
  "updated_at": $updated_at,
  "state": "$(nordvpn_easy_json_escape "$enterprise_state")",
  "desired_enabled": $([ "$desired_enabled" = '1' ] && printf '%s' 'true' || printf '%s' 'false'),
  "enabled": $([ "$desired_enabled" = '1' ] && printf '%s' 'true' || printf '%s' 'false'),
  "runtime_disabled": $interface_disabled,
  "interface_disabled": $interface_disabled,
  "runtime_configured": $runtime_configured,
  "server_selection_mode": "$(nordvpn_easy_json_escape "${SERVER_SELECTION_MODE:-auto}")",
  "kill_switch_enabled": $([ "${KILL_SWITCH_ENABLED:-0}" = '1' ] && printf '%s' 'true' || printf '%s' 'false'),
  "recovery_cron_installed": $recovery_cron_installed,
  "config_fingerprint": "$(nordvpn_easy_json_escape "$config_fingerprint")",
  "applied_fingerprint": "$(nordvpn_easy_json_escape "$applied_fingerprint")",
  "runtime_token": "$(nordvpn_easy_json_escape "$runtime_token")",
  "applied_current": $applied_current,
  "status_seq": $status_seq,
  "boot_id": "$(nordvpn_easy_json_escape "$boot_id")",
  "journal_phase": "$(nordvpn_easy_json_escape "$journal_phase")",
  "journal_sub_phase": "$(nordvpn_easy_json_escape "$journal_sub_phase")",
  "journal_txn_id": "$(nordvpn_easy_json_escape "$journal_txn_id")",
  "journal_started_at": $journal_started_at,
  "rpc_contract_level": $rpc_contract_level,
  "selected_country": "$(nordvpn_easy_json_escape "${VPN_COUNTRY:-}")",
  "interface": "$(nordvpn_easy_json_escape "${VPN_IF:-}")",
  "vpn_status": "$(nordvpn_easy_json_escape "$vpn_state")",
  "operation_status": "$(nordvpn_easy_json_escape "$operation")",
  "operation_lock_state": "$(nordvpn_easy_json_escape "$operation_lock_state")",
  "operation_lock_pid": "$(nordvpn_easy_json_escape "$operation_lock_pid")",
  "operation_lock_action": "$(nordvpn_easy_json_escape "$operation_lock_action")",
  "operation_lock_age_seconds": $operation_lock_age_seconds,
  "connected": $connected,
  "endpoint": "$(nordvpn_easy_json_escape "$endpoint")",
  "endpoint_port": "$(nordvpn_easy_json_escape "$endpoint_port")",
  "wireguard_persistent_keepalive": $wireguard_keepalive,
  "wireguard_mtu": "$(nordvpn_easy_json_escape "$wireguard_mtu")",
  "firewall_mtu_fix": $firewall_mtu_fix,
  "latest_handshake": "$(nordvpn_easy_json_escape "$latest_handshake")",
  "latest_handshake_epoch": $latest_handshake_epoch,
  "handshake_age_seconds": $handshake_age_seconds,
  "transfer_rx": "$(nordvpn_easy_json_escape "$transfer_rx")",
  "transfer_rx_bytes": $transfer_rx_bytes,
  "transfer_tx": "$(nordvpn_easy_json_escape "$transfer_tx")",
  "transfer_tx_bytes": $transfer_tx_bytes,
  "public_ip_cached": "$(nordvpn_easy_json_escape "$public_ip_cached")",
  "public_ip_detected_at": $public_ip_detected_at,
  "public_ip_detected_at_iso": "$(nordvpn_easy_json_escape "$public_ip_detected_at_iso")",
  "public_ip_source": "$(nordvpn_easy_json_escape "$public_ip_source")",
  "public_country_cached": "$(nordvpn_easy_json_escape "$public_country_cached")",
  "public_verification_status": "$(nordvpn_easy_json_escape "$public_verification_status")",
  "public_verification_checked_at": $public_verification_checked_at,
  "last_error": "$(nordvpn_easy_json_escape "$last_error")",
  "current_server_hostname": "$(nordvpn_easy_json_escape "$current_hostname")",
  "current_server_station": "$(nordvpn_easy_json_escape "$current_station")",
  "current_server_city": "$(nordvpn_easy_json_escape "$current_city")",
  "current_server_country": "$(nordvpn_easy_json_escape "$current_country")",
  "current_server_load": "$(nordvpn_easy_json_escape "$current_load")",
  "preferred_server_hostname": "$(nordvpn_easy_json_escape "$preferred_hostname")",
  "preferred_server_station": "$(nordvpn_easy_json_escape "$preferred_station")"
}
EOF
}

nordvpn_easy_write_status_cache() {
	local cache_file="${1:-$NORDVPN_EASY_STATUS_CACHE}"
	local cache_dir cache_tmp

	cache_dir="$(dirname "$cache_file")"
	mkdir -p "$cache_dir" || return 1
	cache_tmp="${cache_file}.$$"

	nordvpn_easy_emit_status_json > "$cache_tmp" || {
		rm -f "$cache_tmp"
		return 1
	}

	mv "$cache_tmp" "$cache_file"
}
