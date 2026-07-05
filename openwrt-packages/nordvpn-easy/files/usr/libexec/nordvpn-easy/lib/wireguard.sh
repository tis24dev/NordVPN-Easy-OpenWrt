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
		nordvpn_easy_fenced_ifupdown down "$VPN_IF" >/dev/null 2>&1 || true
		if command -v wg >/dev/null 2>&1 &&
			wg show "$VPN_IF" >/dev/null 2>&1; then
			nordvpn_easy_fenced_ip_link_del "$VPN_IF" >/dev/null 2>&1 || true
		fi
	elif nordvpn_easy_vpn_is_configured; then
		nordvpn_easy_fenced_ifupdown down "$VPN_IF" >/dev/null 2>&1 || true
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
		nordvpn_easy_fenced_ifupdown down "$VPN_IF" >/dev/null 2>&1 || true
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

	nordvpn_easy_fenced_uci_commit network || {
		# Discard the staged deletes so a superseded (reaped) writer whose commit
		# the fence refused cannot leave them for a later unfenced network commit
		# to flush; also cleans up after a genuine commit failure.
		uci -q revert network 2>/dev/null || true
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "could not commit network configuration while tearing down $VPN_IF"
		return 1
	}
	nordvpn_easy_harden_secret_config_perms network

	if ! "${NORDVPN_EASY_NETWORK_INIT:-/etc/init.d/network}" reload >/dev/null 2>&1; then
		log 'WARNING: NETWORK RELOAD FAILED DURING VPN TEARDOWN; retrying then restarting network'
		sleep "${INTERFACE_RESTART_DELAY:-2}"
		"${NORDVPN_EASY_NETWORK_INIT:-/etc/init.d/network}" reload >/dev/null 2>&1 ||
			"${NORDVPN_EASY_NETWORK_INIT:-/etc/init.d/network}" restart >/dev/null 2>&1 || true

		# UCI no longer references the interface; make sure the kernel device is
		# gone so a failed reload cannot leave a live wg device behind with its
		# config stripped (a split runtime/config state).
		if nordvpn_easy_vpn_link_is_present; then
			nordvpn_easy_fenced_ip_link_del "$VPN_IF" 2>/dev/null || true
		fi
		if nordvpn_easy_vpn_link_is_present; then
			nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "VPN interface $VPN_IF is still present after teardown reload/restart fallback"
			return 1
		fi
	fi

	log "apply: VPN interface $VPN_IF removed from runtime and UCI"
	nordvpn_easy_log_vpn_interface_state 'after-teardown'
}

nordvpn_easy_default_route_uses_vpn() {
	local vpn_if="${1:-$VPN_IF}"

	# Check both families: a broken tunnel can hold the IPv6 default route too,
	# which an IPv4-only check would miss and leave auto-recovery blind.
	ip -4 route show default 2>/dev/null | grep -q "dev ${vpn_if}[[:space:]]" && return 0
	ip -6 route show default 2>/dev/null | grep -q "dev ${vpn_if}[[:space:]]"
}

nordvpn_easy_wg_handshake_epoch() {
	local vpn_if="${1:-$VPN_IF}"
	local epoch=''

	epoch="$(wg show "$vpn_if" latest-handshakes 2>/dev/null | awk '
		$2 ~ /^[0-9]+$/ && $2 > max { max = $2 }
		END { if (max != "") print max }
	')"
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

nordvpn_easy_bring_up_vpn_interface() {
	local vpn_if="${1:-$VPN_IF}"
	local network_init="${NORDVPN_EASY_NETWORK_INIT:-/etc/init.d/network}"

	[ -n "$vpn_if" ] || return 1

	# A superseded/reaped owner (its token no longer matches the on-disk lock) must
	# NOT touch the new owner's runtime: bail before the unfenced network reload so a
	# revoked worker cannot reload/restart the network stack out from under the owner
	# that replaced it. The legitimate owner (token matches) and tokenless boot/CLI
	# callers (no token held) are unaffected -- owner_fence_denied is true only when a
	# token is held AND differs from disk.
	if command -v nordvpn_easy_owner_fence_denied >/dev/null 2>&1 && nordvpn_easy_owner_fence_denied; then
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "apply: bring-up of $vpn_if refused (superseded/reaped owner); skipping network reload/restart"
		return 1
	fi

	log "apply: reloading network and bringing up $vpn_if"
	"$network_init" reload || {
		log 'ERROR: NETWORK RELOAD FAILED'
		return 1
	}

	if nordvpn_easy_fenced_ifupdown up "$vpn_if" >/dev/null 2>&1; then
		return 0
	fi

	# fenced_ifupdown returns nonzero for BOTH a genuine ifup failure AND a fence
	# DENIAL (superseded owner). Only a genuine failure should escalate to the
	# aggressive unfenced `network restart`; a denial means we lost the lock mid-flight
	# (e.g. the TTL reaper revoked us), so bail instead of restarting the new owner's
	# network stack (which would drop conntrack + every forwarded session).
	if command -v nordvpn_easy_owner_fence_denied >/dev/null 2>&1 && nordvpn_easy_owner_fence_denied; then
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "apply: ifup $vpn_if refused (superseded/reaped owner); skipping network restart"
		return 1
	fi

	log "apply: ifup $vpn_if failed; falling back to full network restart"
	"$network_init" restart || {
		log 'ERROR: NETWORK RESTART FAILED'
		return 1
	}
	return 0
}

nordvpn_easy_wait_for_vpn_handshake() {
	local vpn_if="${1:-$VPN_IF}"
	local wait_timeout="${2:-0}"
	local wait_context="${3:-runtime validation}"
	local start_ts='0'
	local now_ts='0'
	local deadline='0'
	local elapsed='unknown'
	local handshake_epoch='0'

	case "$wait_timeout" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$wait_timeout" -gt 0 ] || return 1
	command -v wg >/dev/null 2>&1 || return 1

	start_ts="$(date +%s 2>/dev/null || printf '%s' '0')"
	case "$start_ts" in
		''|*[!0-9]*)
			start_ts='0'
			;;
		*)
			deadline=$((start_ts + wait_timeout))
			;;
	esac

	log "apply: waiting up to ${wait_timeout}s for WireGuard handshake on $vpn_if after ${wait_context}"

	while :; do
		handshake_epoch="$(nordvpn_easy_wg_handshake_epoch "$vpn_if")"
		if nordvpn_easy_handshake_epoch_indicates_connection "$handshake_epoch"; then
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
			log "apply: WireGuard handshake validated on $vpn_if after ${elapsed}s"
			return 0
		fi

		if [ "$deadline" -gt 0 ]; then
			now_ts="$(date +%s 2>/dev/null || printf '%s' '0')"
			case "$now_ts" in
				''|*[!0-9]*)
					break
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

	return 1
}

nordvpn_easy_wait_for_vpn_connectivity() {
	local vpn_if="${1:-$VPN_IF}"
	local wait_timeout="${2:-$POST_RESTART_DELAY}"
	local wait_context="${3:-runtime validation}"
	local wait_timeout_label=''
	local handshake_wait_max=''
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

	handshake_wait_max="${NORDVPN_EASY_HANDSHAKE_WAIT_MAX:-25}"
	case "$handshake_wait_max" in
		''|*[!0-9]*)
			handshake_wait_max='25'
			;;
	esac
	if [ "$wait_timeout" -lt "$handshake_wait_max" ]; then
		handshake_wait_max="$wait_timeout"
	fi

	if [ "$handshake_wait_max" -gt 0 ] &&
		nordvpn_easy_wait_for_vpn_handshake "$vpn_if" "$handshake_wait_max" "$wait_context"; then
		# A fresh handshake means the tunnel established (keys exchanged), but it
		# does not prove the 0.0.0.0/0 route and firewall path actually carry
		# traffic. Confirm real connectivity through the interface before declaring
		# it ready; if routing has not settled yet, fall through to the probe loop
		# instead of falsely reporting connected on the handshake alone.
		if nordvpn_easy_ping_interface "$vpn_if"; then
			log "apply: VPN handshake and connectivity validated on $vpn_if after ${wait_context}"
			return 0
		fi
		log "apply: $vpn_if handshake is up but traffic is not routing yet; verifying connectivity"
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

NORDVPN_EASY_FW_ZONE_SECTION="${NORDVPN_EASY_FW_ZONE_SECTION:-nordvpn_vpn}"
NORDVPN_EASY_FW_ZONE_NAME="${NORDVPN_EASY_FW_ZONE_NAME:-nordvpn}"

nordvpn_easy_lan_zones_forwarding_to() {
	# Echo the source zone names that forward to the given destination zone name
	# (the LAN-side zones whose internet egress must be steered through the VPN).
	local dest_zone="$1" section dest src
	[ -n "$dest_zone" ] || return 0
	for section in $(uci show firewall 2>/dev/null | awk -F= '$2=="forwarding"{print $1}'); do
		dest="$(uci -q get "${section}.dest" 2>/dev/null)"
		[ "$dest" = "$dest_zone" ] || continue
		src="$(uci -q get "${section}.src" 2>/dev/null)"
		case "$src" in ''|"$NORDVPN_EASY_FW_ZONE_NAME") continue ;; esac
		printf '%s\n' "$src"
	done | sort -u
}

nordvpn_easy_ensure_vpn_firewall() {
	local wan_zone_section wan_zone_name kill_switch mtu_fix_value lan_zone idx=0
	local fw_zone znet

	wan_zone_section="$(nordvpn_easy_find_firewall_zone_section "$WAN_IF")" || {
		log "ERROR: FIREWALL ZONE FOR $WAN_IF NOT FOUND"
		return 1
	}
	wan_zone_name="$(uci -q get "${wan_zone_section}.name" 2>/dev/null)"
	[ -n "$wan_zone_name" ] || {
		log "ERROR: WAN FIREWALL ZONE $wan_zone_section HAS NO NAME"
		return 1
	}

	kill_switch=0
	[ "${KILL_SWITCH_ENABLED:-1}" = '1' ] && kill_switch=1
	mtu_fix_value=0
	[ "${FIREWALL_MTU_FIX:-1}" = '1' ] && mtu_fix_value=1

	# Rebuild the app-owned firewall objects from a clean slate (idempotent), then
	# move VPN_IF out of every other zone (it used to live in the WAN zone).
	nordvpn_easy_remove_app_firewall_sections
	for fw_zone in $(uci show firewall 2>/dev/null | awk -F= '$2=="zone"{print $1}'); do
		for znet in $(uci -q get "${fw_zone}.network" 2>/dev/null); do
			[ "$znet" = "$VPN_IF" ] && uci -q del_list "${fw_zone}.network"="$VPN_IF"
		done
	done

	# Dedicated VPN zone: keeping wg0 out of the WAN zone is what lets the kill
	# switch drop lan->WAN without also dropping the legitimate lan->wg0 traffic.
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}=zone"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.name=${NORDVPN_EASY_FW_ZONE_NAME}"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.network=${VPN_IF}"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.masq=1"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.mtu_fix=${mtu_fix_value}"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.input=REJECT"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.output=ACCEPT"
	uci set "firewall.${NORDVPN_EASY_FW_ZONE_SECTION}.forward=REJECT"

	# For every LAN-side zone that forwards to WAN: allow it to the VPN zone,
	# always drop its IPv6 to WAN (NordLynx is IPv4-only, so IPv6 can only leak),
	# and -- when the kill switch is strict -- drop its IPv4 to WAN so a dropped
	# tunnel cannot fall back to the bare WAN and leak. When the tunnel is up the
	# default route is via wg0 (the VPN zone) so this never matches.
	for lan_zone in $(nordvpn_easy_lan_zones_forwarding_to "$wan_zone_name"); do
		idx=$((idx + 1))

		uci set "firewall.nordvpn_fwd_${idx}=forwarding"
		uci set "firewall.nordvpn_fwd_${idx}.src=${lan_zone}"
		uci set "firewall.nordvpn_fwd_${idx}.dest=${NORDVPN_EASY_FW_ZONE_NAME}"

		uci set "firewall.nordvpn_ks6_${idx}=rule"
		uci set "firewall.nordvpn_ks6_${idx}.name=nordvpn-killswitch-v6-${idx}"
		uci set "firewall.nordvpn_ks6_${idx}.src=${lan_zone}"
		uci set "firewall.nordvpn_ks6_${idx}.dest=${wan_zone_name}"
		uci set "firewall.nordvpn_ks6_${idx}.family=ipv6"
		uci set "firewall.nordvpn_ks6_${idx}.proto=all"
		uci set "firewall.nordvpn_ks6_${idx}.target=DROP"

		[ "$kill_switch" = '1' ] || continue
		uci set "firewall.nordvpn_ks4_${idx}=rule"
		uci set "firewall.nordvpn_ks4_${idx}.name=nordvpn-killswitch-v4-${idx}"
		uci set "firewall.nordvpn_ks4_${idx}.src=${lan_zone}"
		uci set "firewall.nordvpn_ks4_${idx}.dest=${wan_zone_name}"
		uci set "firewall.nordvpn_ks4_${idx}.family=ipv4"
		uci set "firewall.nordvpn_ks4_${idx}.proto=all"
		uci set "firewall.nordvpn_ks4_${idx}.target=DROP"
	done

	nordvpn_easy_fenced_uci_commit firewall || {
		# Discard the staged zone/forwarding/killswitch edits so a superseded
		# (reaped) writer whose commit the fence refused cannot leave them for a
		# later unfenced firewall commit to flush; also cleans up a genuine failure.
		uci -q revert firewall 2>/dev/null || true
		log 'ERROR: COULD NOT COMMIT FIREWALL CONFIGURATION'
		return 1
	}

	# reload, not restart: restart flushes conntrack and drops every forwarded
	# session (including the admin's LuCI/SSH); reload applies the ruleset in place.
	"${NORDVPN_EASY_FIREWALL_INIT:-/etc/init.d/firewall}" reload || {
		log 'ERROR: FIREWALL RELOAD FAILED'
		return 1
	}

	log "runtime: VPN firewall zone ${NORDVPN_EASY_FW_ZONE_NAME} ready for ${VPN_IF} (kill_switch=${kill_switch}, mtu_fix=${mtu_fix_value})"
}

# Reset the forwarded connections that were pinned to the previous exit so they
# re-establish through the freshly-connected tunnel, mirroring the official
# NordVPN app which resets pre-existing connections on connect (libtelio
# FeatureFirewall neptunResetConns). A `firewall reload` deliberately keeps
# conntrack intact (so it never drops the admin's own sessions), but that also
# leaves a LAN->internet flow that was masqueraded out the WAN with a stale NAT
# binding once the default route moves to ${VPN_IF}: it then hangs (packets go
# into the tunnel with the old WAN source and are dropped by the peer) instead
# of promptly re-routing, and with the kill switch off it can keep egressing the
# bare WAN. Deleting only the source-NATed (forwarded, internet-bound) flows
# fixes both: lan->router and router-local sessions are never source-NATed, so
# the admin's SSH/LuCI session is left untouched.
#
# Best-effort: conntrack-tools may be trimmed from a custom image, so a missing
# tool degrades to a no-op (the stale flows re-establish on their own timeout)
# rather than failing the apply. NORDVPN_EASY_CONNTRACK lets the tests stub it.
nordvpn_easy_reset_forwarded_conntrack() {
	local conntrack_bin="${NORDVPN_EASY_CONNTRACK:-conntrack}"
	local deleted

	if ! command -v "$conntrack_bin" >/dev/null 2>&1; then
		log "runtime: conntrack tool unavailable; skipping forwarded-flow reset on ${VPN_IF} (stale sessions will re-establish on timeout)"
		return 0
	fi

	# `conntrack -D` prints one line per deleted flow to stdout and a summary to
	# stderr, and exits non-zero when nothing matched; none of that is fatal here.
	deleted="$("$conntrack_bin" -D --src-nat 2>/dev/null | grep -c . 2>/dev/null || true)"
	log "runtime: reset ${deleted:-0} forwarded connection(s) to re-establish through ${VPN_IF}"
	return 0
}

nordvpn_easy_set_vpn_server_in_uci() {
	local public_key="$3"

	[ -n "$1" ] || {
		log 'ERROR: VPN SERVER HOSTNAME IS EMPTY'
		return 1
	}
	[ -n "$2" ] || {
		log "ERROR: VPN SERVER STATION IS EMPTY FOR $1"
		return 1
	}
	[ -n "$public_key" ] || {
		log "ERROR: VPN PUBLIC KEY IS EMPTY FOR $1"
		return 1
	}

	# Reject a corrupted or spoofed peer before committing it: a WireGuard public
	# key is 32 bytes => 43 base64 chars plus '=' padding, and the endpoint host
	# must be a plain DNS name. A bad key otherwise only surfaced as a generic
	# no-handshake failure much later.
	if ! nordvpn_easy_valid_wireguard_key "$public_key"; then
		log "ERROR: VPN PUBLIC KEY FOR $1 IS NOT A VALID WIREGUARD KEY (length=${#public_key}, want 44 base64 chars)"
		return 1
	fi
	case "$1" in
		*[!A-Za-z0-9.-]*)
			log "ERROR: VPN ENDPOINT HOST $1 CONTAINS INVALID CHARACTERS"
			return 1
			;;
	esac

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
