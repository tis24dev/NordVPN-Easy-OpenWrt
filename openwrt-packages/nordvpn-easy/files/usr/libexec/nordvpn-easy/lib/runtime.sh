#!/bin/sh

NORDVPN_EASY_RUN_DIR="${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}"
NORDVPN_EASY_STATUS_CACHE="${NORDVPN_EASY_STATUS_CACHE:-$NORDVPN_EASY_RUN_DIR/status.json}"
NORDVPN_EASY_PUBLIC_IP_CACHE="${NORDVPN_EASY_PUBLIC_IP_CACHE:-$NORDVPN_EASY_RUN_DIR/public_ip}"
NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="${NORDVPN_EASY_PUBLIC_COUNTRY_CACHE:-$NORDVPN_EASY_RUN_DIR/public_country}"
NORDVPN_EASY_LAST_ERROR_CACHE="${NORDVPN_EASY_LAST_ERROR_CACHE:-$NORDVPN_EASY_RUN_DIR/last_error}"

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

nordvpn_easy_handshake_epoch_indicates_connection() {
	local epoch="$1"
	local now diff

	case "$epoch" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$epoch" -gt 0 ] || return 1
	now="$(date +%s 2>/dev/null)"
	case "$now" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	diff=$((now - epoch))
	[ "$diff" -lt 0 ] && diff=0
	[ "$diff" -le 7200 ]
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
	printf '%s\n' "$1" | awk '
		NR == 2 {
			endpoint = ($3 != "" && $3 != "(none)") ? $3 : "N/A"
			handshake = ($5 ~ /^[0-9]+$/) ? $5 : 0
			rx = ($6 ~ /^[0-9]+$/) ? $6 : 0
			tx = ($7 ~ /^[0-9]+$/) ? $7 : 0
			printf "%s\t%s\t%s\t%s\n", endpoint, handshake, rx, tx
			found = 1
			exit
		}
		END {
			if (!found)
				printf "N/A\t0\t0\t0\n"
		}
		'
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

nordvpn_easy_peer_section_name() {
	local vpn_if="${1:-$VPN_IF}"
	local peer_section=''

	if uci -q get "network.${vpn_if}server.endpoint_host" >/dev/null 2>&1; then
		printf '%s\n' "${vpn_if}server"
		return 0
	fi

	peer_section="$(
		uci show network 2>/dev/null | awk -F '[.=]' -v target="wireguard_${vpn_if}" '
			$1 == "network" && $3 == target {
				print $2
				exit
			}
		'
	)"
	[ -n "$peer_section" ] || return 1
	printf '%s\n' "$peer_section"
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

	if command -v ifstatus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		if ifstatus "$vpn_if" 2>/dev/null | jq -er '.up == true' >/dev/null 2>&1; then
			printf '%s\n' 'active'
			return 0
		fi
	fi

	if ip link show dev "$vpn_if" >/dev/null 2>&1; then
		printf '%s\n' 'active'
		return 0
	fi

	case "$operation" in
		busy:setup|busy:check|busy:rotate)
			printf '%s\n' 'starting'
			;;
		busy:disable_runtime)
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
	local wg_dump=''
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
	local public_country_cached=''
	local last_error=''

	nordvpn_easy_load_lock_metadata "${LOCK_DIR:-/tmp/nordvpn-easy.lock}"
	operation="$(nordvpn_easy_operation_status_from_loaded_lock)"
	operation_lock_state="$OPERATION_LOCK_STATE"
	operation_lock_pid="$OPERATION_LOCK_PID"
	operation_lock_action="$OPERATION_LOCK_ACTION"
	operation_lock_age_seconds="$OPERATION_LOCK_AGE_SECONDS"
	vpn_state="$(nordvpn_easy_vpn_status_value "$desired_enabled" "$VPN_IF" "$operation")"

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
	wg_dump="$(wg show "$VPN_IF" dump 2>/dev/null)"

	if [ -n "$wg_dump" ]; then
		IFS="$(printf '\t')" read -r endpoint latest_handshake_epoch transfer_rx_bytes transfer_tx_bytes <<EOF
$(nordvpn_easy_parse_wg_dump_peer "$wg_dump")
EOF

		latest_handshake="$(nordvpn_easy_humanize_handshake_age "$latest_handshake_epoch")"
		handshake_age_seconds="$(nordvpn_easy_handshake_age_seconds "$latest_handshake_epoch")"
		transfer_rx="$(nordvpn_easy_format_human_bytes "$transfer_rx_bytes")"
		transfer_tx="$(nordvpn_easy_format_human_bytes "$transfer_tx_bytes")"

		if nordvpn_easy_handshake_epoch_indicates_connection "$latest_handshake_epoch"; then
			connected='true'
		fi
	fi

	if [ "$desired_enabled" != '1' ] || [ "$interface_disabled" = 'true' ]; then
		enterprise_state='disabled'
	elif [ "$operation" = 'idle' ] && [ "$connected" = 'true' ]; then
		enterprise_state='connected'
	elif [ "$operation" = 'idle' ] && [ "$runtime_configured" = 'true' ]; then
		enterprise_state='degraded'
	elif [ "$operation" = 'idle' ]; then
		enterprise_state='idle'
	else
		case "$operation" in
			busy:check)
				enterprise_state='recovering'
				;;
			busy:setup|busy:rotate)
				enterprise_state='connecting'
				;;
			busy:disable_runtime)
				enterprise_state='disabled'
				;;
			*)
				enterprise_state='recovering'
				;;
		esac
	fi

	[ -r "$NORDVPN_EASY_PUBLIC_IP_CACHE" ] && public_ip_cached="$(sed -n '1p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null)"
	[ -r "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" ] && public_country_cached="$(sed -n '1p' "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" 2>/dev/null)"
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
  "public_country_cached": "$(nordvpn_easy_json_escape "$public_country_cached")",
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

nordvpn_easy_emit_cached_status_json() {
	local cache_file="${1:-$NORDVPN_EASY_STATUS_CACHE}"

	if [ -s "$cache_file" ]; then
		cat "$cache_file"
		return 0
	fi

	nordvpn_easy_emit_status_json
}
