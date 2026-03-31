#!/bin/sh

nordvpn_easy_vpn_is_configured() {
	[ "$(uci -q get "network.${VPN_IF}.proto" 2>/dev/null)" = 'wireguard' ]
}

nordvpn_easy_vpn_link_is_present() {
	ip link show dev "$VPN_IF" >/dev/null 2>&1
}

nordvpn_easy_log_vpn_interface_state() {
	STATE_CONTEXT="$1"
	VPN_PROTO=$(uci -q get "network.${VPN_IF}.proto" 2>/dev/null)
	VPN_DISABLED=$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)
	VPN_ENDPOINT=$(uci -q get "network.${VPN_IF}server.endpoint_host" 2>/dev/null)
	VPN_LINK_PRESENT='no'

	ip link show dev "$VPN_IF" >/dev/null 2>&1 && VPN_LINK_PRESENT='yes'

	log "Interface state [$STATE_CONTEXT]: proto=${VPN_PROTO:-absent}, disabled=${VPN_DISABLED:-0}, link_present=$VPN_LINK_PRESENT, endpoint=${VPN_ENDPOINT:-none}"
}

nordvpn_easy_recover_missing_vpn_interface() {
	log "VPN interface $VPN_IF is still not present after ${VPN_INTERFACE_PRESENT_DELAY}s - starting recovery sequence"
	log_vpn_interface_state 'missing-interface-start'

	log "Recovery step 1/3: cycling interface $VPN_IF with ifdown/ifup"
	ifdown "$VPN_IF" >/dev/null 2>&1 || true
	ifup "$VPN_IF" >/dev/null 2>&1 || true
	sleep "$VPN_INTERFACE_PRESENT_DELAY"

	if vpn_link_is_present; then
		log "Recovery step 1/3 succeeded: interface $VPN_IF is present again"
		log_vpn_interface_state 'missing-interface-after-ifup'
		return 0
	fi

	log "Recovery step 2/3: reloading network service because $VPN_IF is still not present"
	/etc/init.d/network reload || {
		log 'ERROR: NETWORK RELOAD FAILED DURING MISSING INTERFACE RECOVERY'
		return 1
	}
	sleep "$VPN_INTERFACE_PRESENT_DELAY"

	if vpn_link_is_present; then
		log "Recovery step 2/3 succeeded: interface $VPN_IF is present again"
		log_vpn_interface_state 'missing-interface-after-reload'
		return 0
	fi

	log "Recovery step 3/3: restarting network service because $VPN_IF is still not present"
	/etc/init.d/network restart || {
		log 'ERROR: NETWORK RESTART FAILED DURING MISSING INTERFACE RECOVERY'
		return 1
	}
	sleep "$VPN_INTERFACE_PRESENT_DELAY"

	if vpn_link_is_present; then
		log "Recovery step 3/3 succeeded: interface $VPN_IF is present again"
		log_vpn_interface_state 'missing-interface-after-restart'
		return 0
	fi

	log "ERROR: VPN interface $VPN_IF is still not present after the full recovery sequence"
	log_vpn_interface_state 'missing-interface-final'
	return 1
}

nordvpn_easy_ensure_vpn_interface_present() {
	if vpn_link_is_present; then
		return 0
	fi

	log "VPN interface $VPN_IF is not present, waiting ${VPN_INTERFACE_PRESENT_DELAY}s before recovery"
	log_vpn_interface_state 'missing-interface-before-wait'
	sleep "$VPN_INTERFACE_PRESENT_DELAY"

	if vpn_link_is_present; then
		log "VPN interface $VPN_IF became present during the wait window"
		log_vpn_interface_state 'missing-interface-after-wait'
		return 0
	fi

	recover_missing_vpn_interface
}

nordvpn_easy_ensure_vpn_interface_enabled() {
	[ "$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)" = '1' ] || return 0

	log "Re-enabling disabled VPN interface $VPN_IF"
	log_vpn_interface_state 'before-enable'
	uci -q delete "network.${VPN_IF}.disabled"
	uci commit network || {
		log "ERROR: COULD NOT COMMIT NETWORK CONFIGURATION WHILE ENABLING $VPN_IF"
		return 1
	}

	/etc/init.d/network reload || {
		log "ERROR: NETWORK RELOAD FAILED WHILE ENABLING $VPN_IF"
		return 1
	}

	ifup "$VPN_IF" || {
		log "ERROR: IFUP FAILED WHILE ENABLING $VPN_IF"
		return 1
	}

	log "VPN interface $VPN_IF has been re-enabled"
	log_vpn_interface_state 'after-enable'
}

nordvpn_easy_ping_interface() {
	[ -n "$1" ] || return 1
	ping -q -c 1 -W 5 "$(pick_ping_ip)" -I "$1" >/dev/null 2>&1
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

	if [ "$FIREWALL_CHANGED" -ne 1 ]; then
		log "Firewall zone for $WAN_IF already contains $VPN_IF"
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

	log "Firewall updated so zone for $WAN_IF includes $VPN_IF"
}

nordvpn_easy_set_vpn_server_in_uci() {
	[ -n "$2" ] || {
		log 'ERROR: VPN SERVER IP IS EMPTY'
		return 1
	}
	[ -n "$3" ] || {
		log "ERROR: VPN PUBLIC KEY IS EMPTY FOR $1"
		return 1
	}

	uci set "network.${VPN_IF}server.description"="$1"
	uci set "network.${VPN_IF}server.endpoint_host"="$2"
	uci set "network.${VPN_IF}server.public_key"="$3"
	uci set "network.${VPN_IF}server.nordvpn_hostname"="$1"
	uci set "network.${VPN_IF}server.nordvpn_station"="$2"
	uci set "network.${VPN_IF}server.nordvpn_country_code"="${4:-}"
	uci set "network.${VPN_IF}server.nordvpn_city"="${5:-}"
	uci set "network.${VPN_IF}server.nordvpn_load"="${6:-}"
	log "Prepared VPN peer update for server $1 ($2)"
}

nordvpn_easy_current_server_matches_recommendations() {
	CURRENT_SERVER=$(current_server_station)

	[ -n "$CURRENT_SERVER" ] || return 1

	jq -e --arg current "$CURRENT_SERVER" '
		[ .[] | select(.station == $current) ] | length > 0
	' "$SERVER_LIST_FILE" >/dev/null 2>&1
}

nordvpn_easy_apply_server_change_runtime() {
	if [ "$1" = 'reload' ]; then
		log "Cycling VPN interface $VPN_IF to apply the new peer configuration"
		ifdown "$VPN_IF" >/dev/null 2>&1 || true
		sleep "$INTERFACE_RESTART_DELAY"
		ifup "$VPN_IF" || {
			log "ERROR: IFUP FAILED AFTER CHANGING VPN SERVER ON $VPN_IF"
			return 1
		}
		log "Waiting ${POST_RESTART_DELAY}s after cycling $VPN_IF before validating VPN connectivity"
	else
		/etc/init.d/network restart || {
			log 'ERROR: NETWORK RESTART FAILED'
			return 1
		}
		log "Waiting ${POST_RESTART_DELAY}s after network restart before validating VPN connectivity"
	fi

	sleep "$POST_RESTART_DELAY"

	if ping_interface "$VPN_IF"; then
		log 'VPN connection restored'
		verify_public_country_selection
		return 0
	fi

	log 'VPN connection is not OK, trying another server...'
	return 1
}
