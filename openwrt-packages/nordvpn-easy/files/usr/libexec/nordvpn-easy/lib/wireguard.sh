#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

nordvpn_easy_find_firewall_zone_section_by_name() {
	# Resolve a firewall zone SECTION from its zone NAME (the inverse of reading
	# .name off a section). lan_zones_forwarding_to yields names; the dhcp mapping
	# needs the section to read its .network list.
	local target_name="$1" section=''
	[ -n "$target_name" ] || return 1
	for section in $(uci show firewall 2>/dev/null | awk -F= '$2=="zone"{print $1}'); do
		[ "$(uci -q get "${section}.name" 2>/dev/null)" = "$target_name" ] && {
			printf '%s\n' "$section"
			return 0
		}
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

# odhcpd init script; the tests stub it so the reload is observable/no-op.
NORDVPN_EASY_ODHCPD_INIT="${NORDVPN_EASY_ODHCPD_INIT:-/etc/init.d/odhcpd}"

# Marker (tmpfs) recording that an odhcpd reload FAILED and must be retried. Used
# SYMMETRICALLY by both the withdraw and the restore paths.
# WITHDRAW: a reload failure otherwise never retries -- on the next healthy pass the
# section is already ra=disabled so RA_CHANGED stays 0 and the reload is skipped,
# leaving odhcpd still advertising v6 though the config says withdrawn. The next
# withdraw pass checks this marker BEFORE the RA_CHANGED no-op and retries.
# RESTORE (FIX 2): a restore-time reload failure leaves flash=ra restored but
# running-odhcpd still ra=disabled; the marker is kept (not deleted) and the next
# restore pass re-attempts the reload at its start, re-syncing odhcpd to the
# restored config even while the VPN stays down. Overridable so the test can point
# it at a scratch path.
NORDVPN_EASY_RA_RELOAD_PENDING="${NORDVPN_EASY_RA_RELOAD_PENDING:-/tmp/nordvpn-easy.ra-reload-pending}"

# ---------------------------------------------------------------------------
# IPv6 RA withdrawal while a v4-only full-tunnel exit is active.
#
# The v6 kill-switch rule (nordvpn_ks6_*) only makes LAN->WAN IPv6 unreachable;
# it does NOT stop the router still advertising the ISP-delegated prefix + a v6
# default route to the LAN. Clients therefore keep a global IPv6, prefer it per
# RFC6724, try v6 first and hit the block -> per-connection timeouts. To fix the
# *source* of that preference we actively WITHDRAW native IPv6 on each LAN that
# egresses to WAN by setting the dhcp section's `ra` option to 'disabled' (and
# `dhcpv6=disabled` to stop handing out DHCPv6 addresses/prefixes).
#
# For a SERVER-mode LAN section ra=disabled is odhcpd's designed GRACEFUL-WITHDRAW
# path, not a silent stop: on reload odhcpd runs the interface's shutdown path
# (router_setup_interface disable branch: timer_rs.cb=NULL -> valid_addr_cnt=0)
# and emits a FINAL Router Advertisement carrying router lifetime 0 AND
# zero-lifetime prefixes. That single RA immediately withdraws the v6 DEFAULT
# ROUTE and DEPRECATES already-assigned client GUAs (preferred/valid lifetime 0),
# so clients stop sourcing new connections from them and fall back to IPv4 instead
# of waiting for the old lifetimes to expire. This guaranteed outcome
# (default-route withdrawal + GUA deprecation) is version-stable router-native
# behavior for SERVER mode (verified in odhcpd router.c router_setup_interface
# lines 93-100 + line 698), PROVIDED ra_default is not left >=2: router.c lines
# 701-705 force default_route/valid_prefix from ra_default regardless of the
# shutdown guard, so we also zero ra_default during the withdrawal (see
# nordvpn_easy_ra_deprecate_dhcp_section). It is NOT a port of Windscribe's
# per-host gai.conf IPv4-precedence hack.
#
# ra=disabled is applied UNIFORMLY to every WAN-forwarding LAN section regardless of
# its mode. What ra=disabled resolves to differs by mode: a SERVER-mode section (and
# a downstream HYBRID that resolves to server) originates the graceful final RA
# above; a pure RELAY section (and a hybrid that resolves to relay) simply stops
# relaying and the LAN relies on the ks6 REJECT plus natural expiry of the upstream
# RA lifetimes. Which one a HYBRID section resolves to is a RUNTIME property of
# odhcpd (config.c lines 2206-2213: a downstream ra=hybrid becomes MODE_SERVER or
# MODE_RELAY depending on whether the master interface is itself in relay mode),
# NOT determinable from the UCI config we read -- so we do not classify it and make
# no per-section final-RA claim. The final-RA guarantee therefore is NOT universal
# across all odhcpd modes.
#
# NOTE: keeping ra=server with a zeroed ra_lifetime does NOT work here: with
# ra=server odhcpd computes the router lifetime as calc_ra_lifetime()
# (max_preferred_lifetime) and only floors it to 0 when BOTH default_route and
# valid_prefix are false; in a dual-stack LAN default_route is forced true by the
# upstream route (parse_routes) and valid_prefix true by the LAN GUA (router.c
# line 807), so the router lifetime never reaches 0 and the v6 default route is
# re-affirmed. ra=disabled is the only reliable withdrawal.
#
# The dhcp.* sections are USER-owned, so every value we touch is SNAPSHOT into an
# app-owned, flash-persistent nordvpn_easy.* section BEFORE mutation and restored
# on teardown. The snapshot lives in flash (not tmpfs) so a crash/reboot with RA
# suppressed can still be restored. Restore is fenced (commit), idempotent (no
# snapshot left => no-op) and crash-safe (a killed/superseded writer can never
# leave LAN IPv6 permanently off: the snapshot survives for the next run).
# ---------------------------------------------------------------------------

# The dhcp.* options we mutate / snapshot. Both are SCALAR: ra=disabled runs
# odhcpd's graceful-withdraw path (final RA with router lifetime 0 + zero-lifetime
# prefixes), and dhcpv6=disabled stops DHCPv6 address/prefix assignment.
NORDVPN_EASY_RA_DHCP_OPTIONS='ra dhcpv6 ra_default'

# Snapshot section name for a given dhcp section (app-owned, flash-persistent).
# Only NAMED dhcp sections are ever snapshotted (see nordvpn_easy_ra_dhcp_section_is_anonymous
# + the anonymous-skip in the withdrawal), and a named uci id is already a valid
# section-name char set. We still map every char outside [A-Za-z0-9_] to '_' as a
# belt-and-suspenders guard so the name is always valid and deterministic (the same
# dhcp id always derives the same snapshot name, so the idempotency check still
# matches). The dhcp id round-trips VERBATIM via the snapshot's .dhcp_section VALUE
# (a value, not a name), which is the ONLY thing restore mutates -- named ids are
# stable, so verbatim restore is exactly 1:1.
nordvpn_easy_ra_snapshot_section() {
	printf 'nordvpn_ra6_snap_%s' "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_]/_/g')"
}

# True when a dhcp section id is ANONYMOUS, i.e. the uci extended-syntax positional
# form `@dhcp[N]` (LuCI names guest/IoT/VLAN pools this way when the user gives no
# section name). An anonymous id is POSITIONAL: it has no stable identity to snapshot
# and restore against -- adding/removing a `config dhcp` pool ahead of it shifts its
# index, so the same value can later name a DIFFERENT section. We therefore never
# withdraw/snapshot anonymous pools (they rely on the ks6 REJECT instead, a
# deliberate documented limitation); only NAMED sections (stable ids) are handled.
# Detect the extended form by its unambiguous markers: a leading '@' or an embedded
# '['. A named id never contains either.
nordvpn_easy_ra_dhcp_section_is_anonymous() {
	case "${1:-}" in
		@*|*'['*) return 0 ;;
		*) return 1 ;;
	esac
}

# True when the exit is a v4-only full-tunnel: peer AllowedIPs has 0.0.0.0/0 and
# NO ::/0, and the interface carries no v6 tunnel address. Only then is native
# LAN IPv6 a dead end that must be withdrawn; a dual-stack tunnel keeps v6.
nordvpn_easy_tunnel_is_v4_only_full() {
	local vpn_if="${1:-$VPN_IF}"
	local peer_section='' allowed_ip='' addr='' has_v4_default=0

	peer_section="$(nordvpn_easy_wireguard_peer_section_name "$vpn_if" 2>/dev/null)" || return 1

	for allowed_ip in $(uci -q get "network.${peer_section}.allowed_ips" 2>/dev/null); do
		case "$allowed_ip" in
			::/0) return 1 ;;              # dual-stack tunnel: keep native v6
			0.0.0.0/0) has_v4_default=1 ;;
		esac
	done
	[ "$has_v4_default" = '1' ] || return 1

	# A v6 tunnel address means the tunnel itself carries IPv6; not v4-only.
	for addr in $(uci -q get "network.${vpn_if}.addresses" 2>/dev/null) \
		"$(uci -q get "network.${vpn_if}.ip6addr" 2>/dev/null)"; do
		case "$addr" in
			*:*) return 1 ;;
		esac
	done

	return 0
}

# True when WAN actually has a delegated IPv6 prefix (so there is native v6 to
# withdraw). No-op on a v4-only ISP. Prefer ubus (authoritative on the WAN6
# interface's prefix delegation); fall back to a global v6 address/route on the
# WAN device ONLY when ubus/jq are unavailable or produced no parseable answer.
# Best-effort: on an unclear result we return 1 (do NOT touch RA).
nordvpn_easy_wan_has_delegated_prefix() {
	local wan_if="${WAN_IF:-wan}" wan6_if="${1:-}" prefixes='' dev=''
	local ubus_status='' ubus_authoritative=0

	if command -v ubus >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
		# The delegation usually lands on the wan6 alias; probe the explicit
		# candidate first, then the base WAN interface. ubus+jq are mandatory deps
		# (Makefile DEPENDS +jq +rpcd), so this branch is AUTHORITATIVE: when it
		# actually parsed a numeric prefix count for a probed interface and the count
		# is 0, there is genuinely no delegated prefix and we return 1 -- we must NOT
		# fall through to the GUA address scan, which returns 0 on an IA_NA-only WAN
		# (a global GUA but no PD) and would fire the withdrawal on a config with no
		# LAN prefix to withdraw.
		for wan6_if in "${wan6_if:-${wan_if}6}" "$wan_if"; do
			[ -n "$wan6_if" ] || continue
			# Capture the raw ubus status separately from the jq parse so an empty /
			# unparseable ubus reply (interface absent, ubus error) does NOT masquerade
			# as an authoritative length-0 result.
			ubus_status="$(ubus call "network.interface.${wan6_if}" status 2>/dev/null || printf '')"
			[ -n "$ubus_status" ] || continue
			prefixes="$(printf '%s' "$ubus_status" |
				jq -er '(."ipv6-prefix" // []) | length' 2>/dev/null)" || continue
			case "$prefixes" in
				''|*[!0-9]*) continue ;;
			esac
			# This probe RAN and authoritatively parsed a numeric length for this
			# interface.
			ubus_authoritative=1
			[ "$prefixes" -gt 0 ] && return 0
		done
		# ubus/jq were available and at least one probed interface authoritatively
		# parsed a length, all of which were 0: there is no delegated prefix. Do NOT
		# consult the address-scan fallback (which would false-positive on a no-PD
		# GUA-only WAN).
		[ "$ubus_authoritative" = '1' ] && return 1
	fi

	# Fallback: a global-scope IPv6 on the WAN device is a strong signal the ISP
	# delegated us v6. Reached ONLY when ubus or jq is unavailable, or the ubus
	# probe produced empty/unparseable output for every candidate (the authoritative
	# probe did not run). resolve_wan_device populates WAN_DEVICE.
	if nordvpn_easy_resolve_wan_device >/dev/null 2>&1 && [ -n "${WAN_DEVICE:-}" ]; then
		dev="$WAN_DEVICE"
		if ip -6 addr show dev "$dev" scope global 2>/dev/null | grep -q 'inet6 '; then
			return 0
		fi
	fi

	return 1
}

# FIX 2: True when at least one WAN-forwarding LAN dhcp section is ra=relay or
# ra=hybrid. A relaying/hybrid downstream implies the ISP is supplying native v6
# to the LAN regardless of whether the router itself holds a DHCPv6-PD, so there
# IS native LAN v6 to withdraw even when nordvpn_easy_wan_has_delegated_prefix
# returns 1 (e.g. odhcpd relay with authoritative ubus ipv6-prefix length 0: PD is
# 0 but the LAN clients still get relayed native v6 and hit the v6 kill-switch).
# Reuses the SAME zone->dhcp mapping as the withdrawal (lan_zones_forwarding_to +
# find_firewall_zone_section_by_name + dhcp_sections_for_zone) under the same
# `set -f` glob guard, so it cannot drift from what the withdrawal actually
# touches. This does NOT reintroduce the IA_NA-only-GUA false positive: that concern
# is a server-mode LAN on a GUA-only WAN, where no LAN section is relay/hybrid.
nordvpn_easy_lan_has_relayed_ipv6() {
	local wan_if="${WAN_IF:-wan}" wan_zone_section='' wan_zone_name=''
	local lan_zone='' zone_section='' dhcp_section='' ra=''

	command -v uci >/dev/null 2>&1 || return 1
	command -v nordvpn_easy_lan_zones_forwarding_to >/dev/null 2>&1 || return 1

	wan_zone_section="$(nordvpn_easy_find_firewall_zone_section "$wan_if" 2>/dev/null)" || return 1
	wan_zone_name="$(uci -q get "${wan_zone_section}.name" 2>/dev/null)"
	[ -n "$wan_zone_name" ] || return 1

	# Disable globbing across the zone/dhcp iteration exactly like the runtime twin
	# nordvpn_easy_withdraw_lan_ipv6: nordvpn_easy_dhcp_sections_for_zone can emit an
	# ANONYMOUS id like @dhcp[0] whose '[' ']' would otherwise be pathname-expanded by
	# the unquoted `$(...)` word-split. Restored on EVERY exit path below (the
	# relay/hybrid hit and the loop-end return 1) so it never leaks to the caller.
	set -f
	for lan_zone in $(nordvpn_easy_lan_zones_forwarding_to "$wan_zone_name"); do
		zone_section="$(nordvpn_easy_find_firewall_zone_section_by_name "$lan_zone" 2>/dev/null)" || continue
		for dhcp_section in $(nordvpn_easy_dhcp_sections_for_zone "$zone_section"); do
			ra="$(uci -q get "dhcp.${dhcp_section}.ra" 2>/dev/null || printf '')"
			case "$ra" in
				relay|hybrid)
					set +f
					return 0
					;;
			esac
		done
	done
	set +f

	return 1
}

# Snapshot one dhcp section's current RA-related options into a flash-persistent
# app-owned section, then set the withdrawing values. Idempotent: if a snapshot
# for this section already exists we do NOT re-snapshot (so a second up-pass or a
# superseded re-run cannot overwrite the true original with our own values).
# Marks NORDVPN_EASY_RA_CHANGED=1 ONLY when something actually changed (a fresh
# snapshot, or a real ra/dhcpv6 mutation) so a steady-state re-pass with the LAN
# already at ra=disabled does NOT re-commit or reload odhcpd.
nordvpn_easy_ra_deprecate_dhcp_section() {
	local dhcp_section="$1"
	local snap_section='' opt='' cur='' live_ra='' snap_had_ra=''

	[ -n "$dhcp_section" ] || return 0
	snap_section="$(nordvpn_easy_ra_snapshot_section "$dhcp_section")"

	# Only snapshot the FIRST time we deprecate this section. A pre-existing
	# snapshot means we already own the original; re-reading now would capture our
	# own withdrawn values and make restore a no-op (permanent v6 loss). This is the
	# crash-safe invariant: the snapshot is written once, before any mutation.
	#
	# TRUST/REUSE an existing snapshot only when it is genuinely ours AND complete:
	# the live dhcp.<sec>.ra is still the withdrawn sentinel 'disabled' AND the
	# snapshot carries its had_ra marker (proof it was fully recorded; orig_ra is
	# absent by design when the original ra was unset, so had_ra -- always written --
	# is the integrity proxy). A snapshot present while the live ra is NOT 'disabled'
	# is a STALE ORPHAN: restore commits the dhcp restore before deleting the
	# snapshot (they are fenced separately), so a crash between those two commits, or
	# a user editing dhcp.<sec>.ra afterwards, leaves the snapshot pointing at a
	# pre-crash/pre-edit original. Reusing it would later re-apply that stale value.
	# Treat it as stale: delete the orphan and re-snapshot the CURRENT real values
	# before mutating. Fail-closed on the delete so we never mutate ra=disabled while
	# an unrecoverable/stale snapshot lingers.
	if uci -q get "nordvpn_easy.${snap_section}" >/dev/null 2>&1; then
		live_ra="$(uci -q get "dhcp.${dhcp_section}.ra" 2>/dev/null || printf '')"
		snap_had_ra="$(uci -q get "nordvpn_easy.${snap_section}.had_ra" 2>/dev/null || printf '')"
		if [ "$live_ra" != 'disabled' ] || [ -z "$snap_had_ra" ]; then
			uci -q delete "nordvpn_easy.${snap_section}" || return 1
			NORDVPN_EASY_RA_CHANGED=1
		fi
	fi

	if ! uci -q get "nordvpn_easy.${snap_section}" >/dev/null 2>&1; then
		# FAIL CLOSED: rc-check every snapshot write. If the snapshot cannot be
		# recorded (e.g. an invalid/read-only section) we return 1 so the caller
		# reverts BOTH nordvpn_easy and dhcp and never commits ra=disabled without a
		# recoverable snapshot -- otherwise the withdrawal would persist with no way
		# to restore native v6.
		uci set "nordvpn_easy.${snap_section}=nordvpn_ra6_snapshot" || return 1
		# The dhcp id is stored VERBATIM and is the ONLY restore anchor. Only NAMED
		# sections reach here (the withdrawal skips anonymous @dhcp[N] pools), and a
		# named id is stable across `config dhcp` add/remove, so verbatim restore is
		# exactly 1:1: two named sections serving one interface each restore their own
		# id, and a stale snapshot can never re-resolve onto an unrelated live section.
		# Fail-closed like the rest.
		uci set "nordvpn_easy.${snap_section}.dhcp_section=${dhcp_section}" || return 1
		for opt in $NORDVPN_EASY_RA_DHCP_OPTIONS; do
			if cur="$(uci -q get "dhcp.${dhcp_section}.${opt}" 2>/dev/null)"; then
				uci set "nordvpn_easy.${snap_section}.orig_${opt}=${cur}" || return 1
				uci set "nordvpn_easy.${snap_section}.had_${opt}=1" || return 1
			else
				uci set "nordvpn_easy.${snap_section}.had_${opt}=0" || return 1
			fi
		done
		NORDVPN_EASY_RA_CHANGED=1
	fi

	# Withdrawing RA: ra=disabled makes odhcpd emit a FINAL RA (router lifetime 0 +
	# zero-lifetime prefixes) on reload, which withdraws the v6 default route and
	# deprecates already-assigned client GUAs. dhcpv6=disabled stops DHCPv6
	# address/prefix assignment. ra_default=0 is forced too: odhcpd router.c
	# lines 701-705 derive default_route/valid_prefix straight from ra_default
	# INDEPENDENTLY of the shutdown guard, so a user-set ra_default>=2 would make
	# even the shutdown RA carry a nonzero router lifetime and re-affirm the v6
	# default route -- zeroing it keeps the final RA on the lifetime-0 path. It is
	# snapshotted (had_ra_default) and restored/deleted on teardown like the rest.
	# set_uci_option_if_changed raises NORDVPN_EASY_UCI_CHANGED only on a real value
	# change; propagate that to NORDVPN_EASY_RA_CHANGED so an already-withdrawn
	# section is a true no-op.
	NORDVPN_EASY_UCI_CHANGED=0
	nordvpn_easy_set_uci_option_if_changed "dhcp.${dhcp_section}.ra" 'disabled' || return 1
	nordvpn_easy_set_uci_option_if_changed "dhcp.${dhcp_section}.dhcpv6" 'disabled' || return 1
	nordvpn_easy_set_uci_option_if_changed "dhcp.${dhcp_section}.ra_default" '0' || return 1
	[ "${NORDVPN_EASY_UCI_CHANGED:-0}" = '1' ] && NORDVPN_EASY_RA_CHANGED=1
	return 0
}

# Restore one snapshot section back onto its dhcp section, then delete the
# snapshot. Idempotent: a missing snapshot is a no-op. Restores each option to
# its captured value, or DELETES it when it was originally absent (had_*=0), so a
# value we introduced (e.g. ra_default) never lingers.
#
# Restore targets the stored VERBATIM .dhcp_section id ONLY. Only NAMED sections are
# ever snapshotted (the withdrawal skips anonymous @dhcp[N] pools), and a named id is
# stable, so verbatim restore is exactly 1:1 -- no interface re-resolution, which was
# ambiguous when two `config dhcp` sections serve one interface (both re-resolved to
# the FIRST match, leaving the second permanently ra=disabled) or when a stale
# snapshot re-resolved onto an unrelated live section (clobbering it).
nordvpn_easy_ra_restore_dhcp_section() {
	local snap_section="$1"
	local dhcp_section='' opt='' had='' orig=''

	[ -n "$snap_section" ] || return 0
	uci -q get "nordvpn_easy.${snap_section}" >/dev/null 2>&1 || return 0

	dhcp_section="$(uci -q get "nordvpn_easy.${snap_section}.dhcp_section" 2>/dev/null)"

	# RESTORE-TIME GC of an orphan snapshot: if the stored dhcp section was DELETED
	# while the VPN was up (its id no longer exists in the live dhcp config), do NOT
	# recreate a phantom section -- skip the option restore and just drop the
	# snapshot below. `uci -q get dhcp.<id>` returning the section type proves the
	# section is live; a failure means it is gone.
	if [ -n "$dhcp_section" ] && uci -q get "dhcp.${dhcp_section}" >/dev/null 2>&1; then
		for opt in $NORDVPN_EASY_RA_DHCP_OPTIONS; do
			had="$(uci -q get "nordvpn_easy.${snap_section}.had_${opt}" 2>/dev/null || printf '0')"
			if [ "$had" = '1' ]; then
				orig="$(uci -q get "nordvpn_easy.${snap_section}.orig_${opt}" 2>/dev/null || printf '')"
				nordvpn_easy_set_uci_option_if_changed "dhcp.${dhcp_section}.${opt}" "$orig" || return 1
			else
				nordvpn_easy_delete_uci_option_if_present "dhcp.${dhcp_section}.${opt}" || return 1
			fi
		done
	fi

	uci -q delete "nordvpn_easy.${snap_section}" || true
	NORDVPN_EASY_RA_CHANGED=1
	return 0
}

# Resolve a firewall zone -> its network interface(s) -> the dhcp section(s) that
# serve those networks. A dhcp section's own name is usually the interface name,
# but the authoritative link is its `interface` option, so match on that (handles
# bridges, VLANs and multi-network zones where the dhcp section name differs).
nordvpn_easy_dhcp_sections_for_zone() {
	local zone_section="$1" znet='' dhcp_section='' dhcp_if=''
	[ -n "$zone_section" ] || return 0

	# `set -f` for the producer (kept INSIDE the `| sort -u` pipe subshell so it can
	# never leak globbing state to the caller): an ANONYMOUS dhcp id like @dhcp[0]
	# contains glob metacharacters ('[', ']'), and the unquoted `$(uci ...)` /
	# `$(uci show dhcp ...)` word-splits below would pathname-expand it against the
	# cwd. Disabling globbing keeps such ids intact.
	{
		set -f
		for znet in $(uci -q get "${zone_section}.network" 2>/dev/null); do
			[ -n "$znet" ] || continue
			# $znet holds NETWORK names; skip only the VPN network. (The old branch also
			# excluded the VPN ZONE name, which is never a network and would only wrongly
			# skip a LAN network literally named after the zone.)
			case "$znet" in "${VPN_IF:-}") continue ;; esac
			for dhcp_section in $(uci show dhcp 2>/dev/null | awk -F= '$2=="dhcp"{print $1}' | sed 's/^dhcp\.//'); do
				dhcp_if="$(uci -q get "dhcp.${dhcp_section}.interface" 2>/dev/null)"
				[ -n "$dhcp_if" ] || dhcp_if="$dhcp_section"
				[ "$dhcp_if" = "$znet" ] && printf '%s\n' "$dhcp_section"
			done
		done
	} | sort -u
}

# PRIMARY entry point (up path): withdraw native LAN IPv6 while a v4-only
# full-tunnel exit is active AND there is native LAN v6 to withdraw (the WAN has a
# delegated v6 prefix OR a WAN-forwarding LAN is ra=relay/hybrid, FIX 2 Gate 2).
# Strict no-op otherwise. Wired into ensure_vpn_firewall so it shares the same
# up lifecycle (and the same execution lock / owner fence). Reloads odhcpd (never
# restarts network/firewall) so admin SSH/LuCI is never dropped.
nordvpn_easy_withdraw_lan_ipv6() {
	local wan_zone_section='' wan_zone_name='' lan_zone='' zone_section=''
	local dhcp_section='' any=0 ra_enabled='' anon_skipped=0

	# Gate 0: master safety valve. The withdrawal mutates USER-owned dhcp.* on the
	# LAN; if it ever misbehaves on a given odhcpd build, an operator can disable it
	# without a rebuild via env (NORDVPN_EASY_RA_WITHDRAW_ENABLED=0) or uci
	# (nordvpn_easy.main.ipv6_ra_withdraw=0), and the ks6 REJECT alone keeps v6
	# leak-safe. Default on. Turning the valve off also RESTORES any withdrawal we
	# already applied, so disabling actively brings native v6 back instead of
	# leaving ra=disabled committed until the next teardown.
	# '|| true' keeps the command substitution's exit status from propagating to
	# the assignment (uci -q get of an absent option returns 1), which would abort
	# a set -e caller before the gate even runs.
	ra_enabled="${NORDVPN_EASY_RA_WITHDRAW_ENABLED:-$(uci -q get nordvpn_easy.main.ipv6_ra_withdraw 2>/dev/null || true)}"
	if [ "${ra_enabled:-1}" = '0' ]; then
		log "runtime: IPv6 RA withdrawal disabled by config (ks6 REJECT still prevents v6 leaks)"
		if command -v nordvpn_easy_restore_lan_ipv6 >/dev/null 2>&1; then
			nordvpn_easy_restore_lan_ipv6 || log 'WARNING: could not restore native LAN IPv6 after RA withdrawal was disabled'
		fi
		return 0
	fi

	# Gate 1: only for a v4-only full-tunnel exit.
	if ! nordvpn_easy_tunnel_is_v4_only_full "$VPN_IF"; then
		log "runtime: IPv6 RA withdrawal skipped for ${VPN_IF} (exit is not a v4-only full-tunnel)"
		return 0
	fi
	# Gate 2 (FIX 2): only when there is native LAN v6 to withdraw. That is EITHER
	# the ISP delegated the router a v6 prefix (wan_has_delegated_prefix), OR a
	# WAN-forwarding LAN section is ra=relay/hybrid (the ISP relays native v6 to the
	# LAN even with no router-held PD; ubus reports prefix length 0 there, so the
	# delegated-prefix check alone would wrongly skip and leave those clients on the
	# v6 kill-switch). Either signal means there is native v6 the LAN would otherwise
	# keep sourcing from.
	if ! nordvpn_easy_wan_has_delegated_prefix && ! nordvpn_easy_lan_has_relayed_ipv6; then
		log "runtime: IPv6 RA withdrawal skipped for ${VPN_IF} (no delegated IPv6 prefix on WAN and no relaying/hybrid LAN; v4-only ISP)"
		return 0
	fi

	wan_zone_section="$(nordvpn_easy_find_firewall_zone_section "$WAN_IF" 2>/dev/null)" || return 0
	wan_zone_name="$(uci -q get "${wan_zone_section}.name" 2>/dev/null)"
	[ -n "$wan_zone_name" ] || return 0

	NORDVPN_EASY_RA_CHANGED=0
	# Disable globbing across the zone/dhcp iteration: nordvpn_easy_dhcp_sections_for_zone
	# can emit an anonymous id like @dhcp[0] whose '[' ']' would otherwise be
	# pathname-expanded by the unquoted `$(...)` word-split. Cleared on every exit
	# path below (loop end and the in-loop error return) so it never leaks.
	set -f
	for lan_zone in $(nordvpn_easy_lan_zones_forwarding_to "$wan_zone_name"); do
		zone_section="$(nordvpn_easy_find_firewall_zone_section_by_name "$lan_zone" 2>/dev/null)" || continue
		for dhcp_section in $(nordvpn_easy_dhcp_sections_for_zone "$zone_section"); do
			# Skip ANONYMOUS @dhcp[N] pools: a positional id has no stable identity to
			# snapshot/restore against (adding/removing a `config dhcp` pool ahead of it
			# shifts its index), so we never withdraw it. It relies on the ks6 REJECT
			# (leak-safe fast-fail) instead -- a deliberate, documented limitation. Only
			# NAMED sections (stable ids) are withdrawn+snapshotted. Note the skip once
			# (logged after the loop) rather than spamming a line per anonymous section.
			if nordvpn_easy_ra_dhcp_section_is_anonymous "$dhcp_section"; then
				anon_skipped=1
				continue
			fi
			any=1
			nordvpn_easy_ra_deprecate_dhcp_section "$dhcp_section" || {
				set +f
				uci -q revert nordvpn_easy 2>/dev/null || true
				uci -q revert dhcp 2>/dev/null || true
				log 'ERROR: COULD NOT STAGE IPv6 RA WITHDRAWAL'
				return 1
			}
		done
	done
	set +f

	[ "$anon_skipped" = '1' ] && log "runtime: IPv6 RA withdrawal does not touch anonymous WAN-forwarding dhcp pools (no stable id to snapshot/restore); they rely on the ks6 REJECT to stay leak-safe"

	[ "$any" = '1' ] || {
		log "runtime: IPv6 RA withdrawal found no NAMED LAN dhcp section forwarding to WAN; nothing to do"
		return 0
	}

	# Retry a previously-failed reload: a withdraw whose odhcpd reload failed leaves
	# the config at ra=disabled (RA_CHANGED=0 on the next pass) but odhcpd still
	# advertising. This runs BEFORE the RA_CHANGED no-op so a healthy steady-state
	# tick re-attempts the reload; on success it clears the marker (and logs
	# recovery), on the success path there is no per-tick churn.
	if [ -e "${NORDVPN_EASY_RA_RELOAD_PENDING}" ]; then
		if "${NORDVPN_EASY_ODHCPD_INIT:-/etc/init.d/odhcpd}" reload >/dev/null 2>&1; then
			rm -f "${NORDVPN_EASY_RA_RELOAD_PENDING}" 2>/dev/null || true
			log "runtime: retried a previously-failed odhcpd reload for the IPv6 RA withdrawal; odhcpd is now in sync"
		else
			log 'WARNING: ODHCPD RELOAD RETRY FAILED AFTER IPv6 RA WITHDRAWAL (will retry on the next healthy pass)'
		fi
	fi

	[ "${NORDVPN_EASY_RA_CHANGED:-0}" = '1' ] || {
		log "runtime: IPv6 RA withdrawal already applied for ${VPN_IF} (idempotent no-op)"
		return 0
	}

	# Fenced commit: a superseded/reaped writer must not persist RA changes over
	# the new owner. The snapshot is written to flash BEFORE this commit only in
	# the same staged transaction, so a refused commit reverts BOTH the snapshot
	# and the dhcp mutation together (no orphan snapshot, no orphan withdrawal).
	nordvpn_easy_fenced_uci_commit nordvpn_easy || {
		uci -q revert nordvpn_easy 2>/dev/null || true
		uci -q revert dhcp 2>/dev/null || true
		log 'ERROR: COULD NOT COMMIT IPv6 RA SNAPSHOT'
		return 1
	}
	nordvpn_easy_fenced_uci_commit dhcp || {
		uci -q revert dhcp 2>/dev/null || true
		# Snapshot already committed; restore path will find it and undo cleanly.
		log 'ERROR: COULD NOT COMMIT IPv6 RA WITHDRAWAL'
		return 1
	}
	nordvpn_easy_harden_secret_config_perms nordvpn_easy

	# reload, not restart: reload re-reads the RA/DHCPv6 config in place; a restart
	# is unnecessary and network/firewall restarts would drop admin sessions. On a
	# reload FAILURE drop a pending-reload marker so the next healthy pass retries
	# (see the marker block above); on SUCCESS clear any stale marker.
	if ! "${NORDVPN_EASY_ODHCPD_INIT:-/etc/init.d/odhcpd}" reload >/dev/null 2>&1; then
		touch "${NORDVPN_EASY_RA_RELOAD_PENDING}" 2>/dev/null || true
		log 'WARNING: ODHCPD RELOAD FAILED AFTER IPv6 RA WITHDRAWAL (snapshot kept for restore; reload will be retried on the next healthy pass)'
	else
		rm -f "${NORDVPN_EASY_RA_RELOAD_PENDING}" 2>/dev/null || true
	fi
	# FIX 3a: one honest, mode-agnostic summary. Whether a given section's ra=disabled
	# resolves to a graceful final RA is a RUNTIME property of odhcpd we do not
	# introspect (a downstream ra=hybrid resolves to MODE_SERVER or MODE_RELAY at
	# runtime depending on the master's mode, odhcpd config.c 2206-2213), so we make no
	# per-section claim: state both outcomes that CAN apply and let the reader map it.
	log "runtime: withdrew native LAN IPv6 (ra=disabled) while ${VPN_IF} carries a v4-only full-tunnel: server-mode LANs get a final RA with router lifetime 0 + deprecated prefixes; relay/hybrid LANs stop relaying and rely on the ks6 REJECT plus upstream RA-lifetime expiry"
	return 0
}

# Restore entry point (down/teardown path): replay every RA snapshot back onto
# its dhcp section and drop the snapshots. Idempotent + crash-safe: with no
# snapshots left it is a pure no-op, so it is safe on every disconnect, on boot
# and on uninstall, and a killed/superseded prior writer can never leave LAN IPv6
# permanently off. Reloads odhcpd (never restarts network/firewall).
nordvpn_easy_restore_lan_ipv6() {
	local snap_section='' any=0

	NORDVPN_EASY_RA_CHANGED=0

	# FIX 2: restore-side reload retry. A PRIOR restore whose odhcpd reload failed
	# leaves flash=ra restored but running-odhcpd still at ra=disabled, with this
	# marker set. Re-attempt the reload here (even on a pure no-op pass with no
	# snapshots left) so a later restore call re-syncs odhcpd to the already-restored
	# config while the VPN stays DOWN; clear the marker only on success.
	if [ -e "${NORDVPN_EASY_RA_RELOAD_PENDING}" ]; then
		if "${NORDVPN_EASY_ODHCPD_INIT:-/etc/init.d/odhcpd}" reload >/dev/null 2>&1; then
			rm -f "${NORDVPN_EASY_RA_RELOAD_PENDING}" 2>/dev/null || true
			nordvpn_easy_log_phase 'runtime' 'retried a previously-failed odhcpd reload on the restore path; odhcpd is now in sync with the restored native LAN IPv6'
		else
			nordvpn_easy_log_blocker 'runtime' 'odhcpd reload retry failed on the restore path (will retry on the next teardown pass)'
		fi
	fi

	for snap_section in $(uci show nordvpn_easy 2>/dev/null |
		sed -n 's/^nordvpn_easy\.\(nordvpn_ra6_snap_[A-Za-z0-9_]*\)=nordvpn_ra6_snapshot$/\1/p' | sort -u); do
		any=1
		nordvpn_easy_ra_restore_dhcp_section "$snap_section" || {
			uci -q revert nordvpn_easy 2>/dev/null || true
			uci -q revert dhcp 2>/dev/null || true
			# This runs on the disconnect/disable teardown path, reachable from
			# init.d disable WITHOUT core.sh where bare `log` is undefined; use the
			# common.sh loggers (available via config-context).
			nordvpn_easy_log_blocker 'runtime' 'could not stage IPv6 RA restore'
			return 1
		}
	done

	[ "$any" = '1' ] || return 0
	[ "${NORDVPN_EASY_RA_CHANGED:-0}" = '1' ] || return 0

	# Fenced commit: a superseded/reaped teardown must not strip a NEW owner's RA
	# withdrawal. The revert restores the staged deletes so the snapshot survives
	# for the legitimate owner -- never leaving LAN v6 permanently disabled.
	nordvpn_easy_fenced_uci_commit dhcp || {
		uci -q revert dhcp 2>/dev/null || true
		uci -q revert nordvpn_easy 2>/dev/null || true
		return 1
	}
	nordvpn_easy_fenced_uci_commit nordvpn_easy || {
		uci -q revert nordvpn_easy 2>/dev/null || true
		return 1
	}
	nordvpn_easy_harden_secret_config_perms nordvpn_easy

	# FIX 2: SYMMETRIC with the withdraw path. The flash config is now ra=restored,
	# but odhcpd is still running the ra=disabled config until this reload lands. On
	# reload FAILURE the running odhcpd stays out of sync (native v6 withdrawn at
	# runtime though the config restored it), so KEEP/SET the pending marker and
	# WARN, and DO NOT delete it -- a later restore pass (start-retry above) re-syncs
	# odhcpd even while the VPN stays down. Only clear the marker on SUCCESS.
	if "${NORDVPN_EASY_ODHCPD_INIT:-/etc/init.d/odhcpd}" reload >/dev/null 2>&1; then
		rm -f "${NORDVPN_EASY_RA_RELOAD_PENDING}" 2>/dev/null || true
		nordvpn_easy_log_phase 'runtime' 'restored native LAN IPv6 (RA/DHCPv6 snapshot replayed) after VPN teardown'
	else
		touch "${NORDVPN_EASY_RA_RELOAD_PENDING}" 2>/dev/null || true
		nordvpn_easy_log_blocker 'runtime' 'odhcpd reload failed on the restore path (config restored native LAN IPv6 but running odhcpd is still out of sync; reload will be retried on the next teardown pass)'
	fi
	return 0
}

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
	# always block its IPv6 to WAN (NordLynx is IPv4-only, so IPv6 can only leak),
	# and -- when the kill switch is strict -- drop its IPv4 to WAN so a dropped
	# tunnel cannot fall back to the bare WAN and leak. When the tunnel is up the
	# default route is via wg0 (the VPN zone) so this never matches.
	#
	# The v6 block is REJECT, not DROP: fw4 lowers a proto=all family=ipv6 REJECT
	# to `jump handle_reject`, which for non-TCP emits an ICMPv6 Destination
	# Unreachable (port-unreachable by default, per firewall @defaults
	# any_reject_code; operator-overridable), so a client trying v6 first fails
	# over to v4 in milliseconds instead of hanging until a per-socket timeout on a
	# silent DROP. It is leak-safe (nothing egresses to WAN), keeps ICMPv6 usable
	# on the LAN (so PMTUD still works), and pairs with the RA withdrawal above
	# that removes the v6 default route in the first place. This is a router-native
	# substitute for Windscribe's non-portable gai.conf trick, not a port of it.
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
		uci set "firewall.nordvpn_ks6_${idx}.target=REJECT"

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

	# NOTE: native LAN IPv6 withdrawal is NOT done here. ensure_vpn_firewall runs
	# BEFORE the v4-only peer is committed and the tunnel is brought up, so the
	# v4-only-full-tunnel gate would not yet see the final peer. withdraw_lan_ipv6
	# is instead invoked at each tunnel-up point (supervise/connect_fresh/provision)
	# right after the forwarded-conntrack reset, where the exit shape is committed.
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
