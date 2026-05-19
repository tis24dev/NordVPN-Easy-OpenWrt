#!/bin/sh
# shellcheck disable=SC2153

nordvpn_easy_vpn_interface_has_wireguard_proto() {
	local vpn_if="${1:-$VPN_IF}"

	[ "$(uci -q get "network.${vpn_if}.proto" 2>/dev/null)" = 'wireguard' ]
}

nordvpn_easy_vpn_has_peer_section() {
	local vpn_if="${1:-$VPN_IF}"

	nordvpn_easy_wireguard_peer_section_name "$vpn_if" >/dev/null 2>&1
}

nordvpn_easy_vpn_is_configured() {
	local vpn_if="${1:-$VPN_IF}"

	nordvpn_easy_vpn_interface_has_wireguard_proto "$vpn_if" || return 1
	nordvpn_easy_vpn_has_peer_section "$vpn_if"
}

nordvpn_easy_vpn_link_is_present() {
	ip link show dev "$VPN_IF" >/dev/null 2>&1
}

nordvpn_easy_log_vpn_interface_state() {
	STATE_CONTEXT="$1"
	VPN_PROTO=$(uci -q get "network.${VPN_IF}.proto" 2>/dev/null)
	VPN_DISABLED=$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)
	VPN_ENDPOINT=$(uci -q get "network.${VPN_IF}server.endpoint_host" 2>/dev/null)
	VPN_ENDPOINT_PORT=$(uci -q get "network.${VPN_IF}server.endpoint_port" 2>/dev/null)
	VPN_KEEPALIVE=$(uci -q get "network.${VPN_IF}server.persistent_keepalive" 2>/dev/null)
	VPN_MTU=$(uci -q get "network.${VPN_IF}.mtu" 2>/dev/null)
	VPN_MTU_FIX='unknown'
	VPN_LINK_PRESENT='no'

	ip link show dev "$VPN_IF" >/dev/null 2>&1 && VPN_LINK_PRESENT='yes'
	if VPN_FIREWALL_ZONE="$(nordvpn_easy_find_firewall_zone_section "$VPN_IF" 2>/dev/null)"; then
		VPN_MTU_FIX=$(uci -q get "${VPN_FIREWALL_ZONE}.mtu_fix" 2>/dev/null)
	fi

	log "runtime: interface state [$STATE_CONTEXT]: proto=${VPN_PROTO:-absent}, disabled=${VPN_DISABLED:-0}, link_present=$VPN_LINK_PRESENT, endpoint=${VPN_ENDPOINT:-none}, endpoint_port=${VPN_ENDPOINT_PORT:-${VPN_PORT:-unset}}, keepalive=${VPN_KEEPALIVE:-${WIREGUARD_PERSISTENT_KEEPALIVE:-15}}, mtu=${VPN_MTU:-auto}, mtu_fix=${VPN_MTU_FIX:-unset}"
}

nordvpn_easy_immediate_vpn_shutdown() {
	log "apply: stopping VPN interface $VPN_IF before server change"

	if nordvpn_easy_vpn_link_is_present; then
		ifdown "$VPN_IF" >/dev/null 2>&1 || true
		if command -v wg >/dev/null 2>&1 &&
			wg show "$VPN_IF" >/dev/null 2>&1; then
			ip link del dev "$VPN_IF" >/dev/null 2>&1 || true
		fi
	elif nordvpn_easy_vpn_is_configured; then
		ifdown "$VPN_IF" >/dev/null 2>&1 || true
	fi

	return 0
}

nordvpn_easy_teardown_vpn() {
	local peer_section="${VPN_IF}server"
	local wan_metric=''
	local wireguard_peer_type="wireguard_${VPN_IF}"
	local section=''

	log "apply: tearing down VPN interface $VPN_IF before provisioning"
	nordvpn_easy_log_vpn_interface_state 'before-teardown'

	if nordvpn_easy_vpn_link_is_present; then
		ifdown "$VPN_IF" >/dev/null 2>&1 || true
		sleep "${INTERFACE_RESTART_DELAY:-2}"
	fi

	while IFS= read -r section; do
		[ -n "$section" ] || continue
		uci -q delete "network.${section}" || true
	done <<EOF
$(uci show network 2>/dev/null | awk -F '[.=]' -v target="$wireguard_peer_type" '
	$1 == "network" && $3 == target {
		print $2
	}
')
EOF

	uci -q delete "network.${VPN_IF}" || true
	uci -q delete "network.${peer_section}" || true

	wan_metric="$(uci -q get "network.${WAN_IF}.metric" 2>/dev/null || true)"
	[ "$wan_metric" = '1024' ] && uci -q delete "network.${WAN_IF}.metric" || true

	uci commit network || {
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "could not commit network configuration while tearing down $VPN_IF"
		return 1
	}

	"${NORDVPN_EASY_NETWORK_INIT:-/etc/init.d/network}" reload >/dev/null 2>&1 || {
		log 'ERROR: NETWORK RELOAD FAILED DURING VPN TEARDOWN'
		return 1
	}

	log "apply: VPN interface $VPN_IF removed from runtime and UCI"
	nordvpn_easy_log_vpn_interface_state 'after-teardown'
}

nordvpn_easy_default_route_uses_vpn() {
	local vpn_if="${1:-$VPN_IF}"

	ip -4 route show default 2>/dev/null | grep -q "dev ${vpn_if}[[:space:]]"
}

nordvpn_easy_wg_handshake_epoch() {
	local vpn_if="${1:-$VPN_IF}"
	local epoch=''

	epoch="$(wg show "$vpn_if" latest-handshakes 2>/dev/null | awk 'NR==1 { print $2 }')"
	case "$epoch" in
		''|*[!0-9]*)
			printf '%s\n' '0'
			;;
		*)
			printf '%s\n' "$epoch"
			;;
	esac
}

nordvpn_easy_runtime_needs_provision() {
	local vpn_if="${1:-$VPN_IF}"
	local handshake_epoch='0'

	nordvpn_easy_vpn_link_is_present || return 0

	handshake_epoch="$(nordvpn_easy_wg_handshake_epoch "$vpn_if")"
	if [ "$handshake_epoch" = '0' ]; then
		return 0
	fi

	if nordvpn_easy_default_route_uses_vpn "$vpn_if" && ! nordvpn_easy_handshake_epoch_indicates_connection "$handshake_epoch"; then
		return 0
	fi

	return 1
}

nordvpn_easy_ping_interface() {
	[ -n "$1" ] || return 1
	ping -q -c 1 -W 5 "$(pick_ping_ip)" -I "$1" >/dev/null 2>&1
}

nordvpn_easy_wait_for_vpn_connectivity() {
	local vpn_if="${1:-$VPN_IF}"
	local wait_timeout="${2:-$POST_RESTART_DELAY}"
	local wait_context="${3:-runtime validation}"
	local wait_timeout_label=''
	local start_ts='0'
	local now_ts='0'
	local elapsed='unknown'
	local deadline='0'

	case "$wait_timeout" in
		''|*[!0-9]*)
			wait_timeout=0
			;;
	esac

	if [ "$wait_timeout" -le 0 ]; then
		nordvpn_easy_ping_interface "$vpn_if"
		return $?
	fi

	wait_timeout_label="$wait_timeout"

	start_ts="$(date +%s 2>/dev/null || printf '%s' '0')"
	case "$start_ts" in
		''|*[!0-9]*)
			start_ts='0'
			;;
	esac

	if [ "$start_ts" -gt 0 ]; then
		deadline=$((start_ts + wait_timeout))
	fi

	log "apply: waiting up to ${wait_timeout}s for VPN connectivity on $vpn_if after ${wait_context}"

	while :; do
		if nordvpn_easy_ping_interface "$vpn_if"; then
			now_ts="$(date +%s 2>/dev/null || printf '%s' '0')"
			case "$now_ts" in
				''|*[!0-9]*)
					elapsed='unknown'
					;;
				*)
					if [ "$start_ts" -gt 0 ]; then
						elapsed=$((now_ts - start_ts))
						[ "$elapsed" -lt 0 ] && elapsed=0
					fi
					;;
			esac

			log "apply: VPN connectivity validated on $vpn_if after ${elapsed}s"
			return 0
		fi

		if [ "$deadline" -gt 0 ]; then
			now_ts="$(date +%s 2>/dev/null || printf '%s' '0')"
			case "$now_ts" in
				''|*[!0-9]*)
					deadline='0'
					;;
				*)
					[ "$now_ts" -ge "$deadline" ] && break
					;;
			esac
		else
			wait_timeout=$((wait_timeout - 1))
			[ "$wait_timeout" -le 0 ] && break
		fi

		sleep 1
	done

	log "apply: VPN connectivity did not validate on $vpn_if within ${wait_timeout_label}s after ${wait_context}"
	return 1
}

nordvpn_easy_resolve_wan_device() {
	WAN_DEVICE=''

	if command -v ubus >/dev/null 2>&1; then
		WAN_DEVICE=$(ubus call "network.interface.${WAN_IF}" status 2>/dev/null | jq -er '.l3_device // .device // empty' 2>/dev/null)
		[ -n "$WAN_DEVICE" ] && return 0
	fi

	WAN_DEVICE=$(uci -q get "network.${WAN_IF}.device" 2>/dev/null)
	[ -n "$WAN_DEVICE" ] && return 0

	WAN_DEVICE=$(uci -q get "network.${WAN_IF}.ifname" 2>/dev/null)
	[ -n "$WAN_DEVICE" ] && return 0

	if ip link show dev "$WAN_IF" >/dev/null 2>&1; then
		WAN_DEVICE="$WAN_IF"
		return 0
	fi

	log "ERROR: COULD NOT RESOLVE DEVICE FOR $WAN_IF"
	return 1
}

nordvpn_easy_ping_wan() {
	resolve_wan_device || return 1
	ping_interface "$WAN_DEVICE"
}

nordvpn_easy_find_firewall_zone_section() {
	TARGET_NETWORK="$1"

	for FIREWALL_SECTION in $(uci show firewall | awk -F= '$2=="zone"{ print $1 }'); do
		ZONE_NETWORKS=$(uci -q get "${FIREWALL_SECTION}.network" 2>/dev/null)

		for ZONE_NETWORK in $ZONE_NETWORKS; do
			[ "$ZONE_NETWORK" = "$TARGET_NETWORK" ] && {
				printf '%s\n' "$FIREWALL_SECTION"
				return 0
			}
		done
	done

	return 1
}

nordvpn_easy_set_uci_option_if_changed() {
	local key="$1"
	local value="$2"
	local current=''

	current="$(uci -q get "$key" 2>/dev/null || true)"
	[ "$current" = "$value" ] && return 0

	uci set "${key}=${value}" || return 1
	NORDVPN_EASY_UCI_CHANGED=1
}

nordvpn_easy_delete_uci_option_if_present() {
	local key="$1"

	uci -q get "$key" >/dev/null 2>&1 || return 0
	uci -q delete "$key" || return 1
	NORDVPN_EASY_UCI_CHANGED=1
}

nordvpn_easy_set_uci_list_if_changed() {
	local key="$1"
	local current=''
	local expected=''
	local value=''

	shift
	current="$(uci -q get "$key" 2>/dev/null || true)"
	expected="$*"
	[ "$current" = "$expected" ] && return 0

	uci -q delete "$key" 2>/dev/null || true
	for value in "$@"; do
		[ -n "$value" ] || continue
		uci add_list "${key}=${value}" || return 1
	done
	NORDVPN_EASY_UCI_CHANGED=1
}

nordvpn_easy_wireguard_keepalive_value() {
	case "${WIREGUARD_PERSISTENT_KEEPALIVE:-15}" in
		''|*[!0-9]*)
			printf '%s\n' '15'
			;;
		*)
			if [ "$WIREGUARD_PERSISTENT_KEEPALIVE" -le 120 ]; then
				printf '%s\n' "$WIREGUARD_PERSISTENT_KEEPALIVE"
			else
				printf '%s\n' '15'
			fi
			;;
	esac
}

nordvpn_easy_wireguard_mtu_value() {
	case "${WIREGUARD_MTU:-}" in
		'')
			printf '%s\n' ''
			;;
		*[!0-9]*)
			printf '%s\n' ''
			;;
		*)
			if [ "$WIREGUARD_MTU" -ge 1280 ] && [ "$WIREGUARD_MTU" -le 1500 ]; then
				printf '%s\n' "$WIREGUARD_MTU"
			else
				printf '%s\n' ''
			fi
			;;
	esac
}

nordvpn_easy_apply_wireguard_transport_settings() {
	local peer_section="${1:-${VPN_IF}server}"
	local endpoint_port="${2:-${VPN_PORT:-51820}}"
	local keepalive=''
	local mtu=''

	# Read by actions.sh after transport settings are applied.
	# shellcheck disable=SC2034
	NORDVPN_EASY_UCI_CHANGED=0

	nordvpn_easy_set_uci_option_if_changed "network.${peer_section}.endpoint_port" "$endpoint_port" || return 1

	keepalive="$(nordvpn_easy_wireguard_keepalive_value)"
	nordvpn_easy_set_uci_option_if_changed "network.${peer_section}.persistent_keepalive" "$keepalive" || return 1

	mtu="$(nordvpn_easy_wireguard_mtu_value)"
	if [ -n "$mtu" ]; then
		nordvpn_easy_set_uci_option_if_changed "network.${VPN_IF}.mtu" "$mtu" || return 1
	else
		nordvpn_easy_delete_uci_option_if_present "network.${VPN_IF}.mtu" || return 1
	fi
}

nordvpn_easy_ensure_vpn_in_wan_zone() {
	WAN_ZONE=$(find_firewall_zone_section "$WAN_IF") || {
		log "ERROR: FIREWALL ZONE FOR $WAN_IF NOT FOUND"
		return 1
	}

	FIREWALL_CHANGED=0

	for FIREWALL_SECTION in $(uci show firewall | awk -F= '$2=="zone"{ print $1 }'); do
		[ "$FIREWALL_SECTION" = "$WAN_ZONE" ] && continue

		ZONE_NETWORKS=$(uci -q get "${FIREWALL_SECTION}.network" 2>/dev/null)
		for ZONE_NETWORK in $ZONE_NETWORKS; do
			[ "$ZONE_NETWORK" = "$VPN_IF" ] || continue
			uci -q del_list "${FIREWALL_SECTION}.network"="$VPN_IF"
			FIREWALL_CHANGED=1
			break
		done
	done

	ZONE_HAS_VPN=0
	ZONE_NETWORKS=$(uci -q get "${WAN_ZONE}.network" 2>/dev/null)

	for ZONE_NETWORK in $ZONE_NETWORKS; do
		[ "$ZONE_NETWORK" = "$VPN_IF" ] && {
			ZONE_HAS_VPN=1
			break
		}
	done

	if [ "$ZONE_HAS_VPN" -ne 1 ]; then
		uci add_list "${WAN_ZONE}.network"="$VPN_IF"
		FIREWALL_CHANGED=1
	fi

	CURRENT_MTU_FIX=$(uci -q get "${WAN_ZONE}.mtu_fix" 2>/dev/null || true)
	if [ "${FIREWALL_MTU_FIX:-1}" = '1' ]; then
		if [ "$CURRENT_MTU_FIX" != '1' ]; then
			uci set "${WAN_ZONE}.mtu_fix=1"
			FIREWALL_CHANGED=1
		fi
	elif [ "$CURRENT_MTU_FIX" != '0' ]; then
		uci set "${WAN_ZONE}.mtu_fix=0"
		FIREWALL_CHANGED=1
	fi

	if [ "$FIREWALL_CHANGED" -ne 1 ]; then
		log "runtime: firewall zone for $WAN_IF already contains $VPN_IF with mtu_fix=${CURRENT_MTU_FIX:-unset}"
		return 0
	fi

	uci commit firewall || {
		log 'ERROR: COULD NOT COMMIT FIREWALL CONFIGURATION'
		return 1
	}

	/etc/init.d/firewall restart || {
		log 'ERROR: FIREWALL RESTART FAILED'
		return 1
	}

	log "runtime: firewall updated so zone for $WAN_IF includes $VPN_IF with mtu_fix=${FIREWALL_MTU_FIX:-1}"
}

nordvpn_easy_set_vpn_server_in_uci() {
	[ -n "$1" ] || {
		log 'ERROR: VPN SERVER HOSTNAME IS EMPTY'
		return 1
	}
	[ -n "$2" ] || {
		log "ERROR: VPN SERVER STATION IS EMPTY FOR $1"
		return 1
	}
	[ -n "$3" ] || {
		log "ERROR: VPN PUBLIC KEY IS EMPTY FOR $1"
		return 1
	}

	uci set "network.${VPN_IF}server.description"="$1"
	uci set "network.${VPN_IF}server.endpoint_host"="$1"
	uci set "network.${VPN_IF}server.public_key"="$3"
	uci set "network.${VPN_IF}server.nordvpn_hostname"="$1"
	uci set "network.${VPN_IF}server.nordvpn_station"="$2"
	uci set "network.${VPN_IF}server.nordvpn_country_code"="${4:-}"
	uci set "network.${VPN_IF}server.nordvpn_city"="${5:-}"
	uci set "network.${VPN_IF}server.nordvpn_load"="${6:-}"
	nordvpn_easy_apply_wireguard_transport_settings "${VPN_IF}server" || return 1
	log "apply: prepared VPN peer update for server $1 ($2)"
}

