#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# routing_mode=policy leaves the system routing table to an external policy-based
# routing package (pbr): no default route from the peer, no WAN metric demotion, no
# zone-wide IPv4 kill switch -- but the VPN resolvers still have to be reachable,
# so they are pinned into the tunnel with host routes. This suite locks that
# contract down, and asserts full_tunnel is byte-for-byte the historical behaviour.

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$LIB_DIR/common.sh"
# shellcheck disable=SC1090
. "$LIB_DIR/wireguard.sh"
# shellcheck disable=SC1090
. "$LIB_DIR/actions.sh"

log() { :; }
nordvpn_easy_log_vpn_interface_state() { :; }
nordvpn_easy_log_blocker() { :; }
nordvpn_easy_owner_assert() { return 0; }

STORE="$TMP_DIR/network"
: > "$STORE"

# File-backed fake uci. Keys contain [ ] @ . so they are matched as exact strings
# (split on the first '='), never as regexes.
uci() {
	[ "${1:-}" = '-q' ] && shift
	cmd="${1:-}"; shift 2>/dev/null || true
	case "$cmd" in
		show)
			cat "$STORE" 2>/dev/null || true
			;;
		get)
			while IFS='=' read -r ek ev; do
				[ "$ek" = "$1" ] && { printf '%s\n' "$ev"; return 0; }
			done < "$STORE"
			return 1
			;;
		set)
			k="${1%%=*}"; val="${1#*=}"
			{ while IFS='=' read -r ek ev; do [ "$ek" = "$k" ] || printf '%s=%s\n' "$ek" "$ev"; done < "$STORE"; printf '%s=%s\n' "$k" "$val"; } > "$STORE.t"
			mv "$STORE.t" "$STORE"
			;;
		add_list)
			k="${1%%=*}"; val="${1#*=}"
			cur=''
			while IFS='=' read -r ek ev; do
				[ "$ek" = "$k" ] && cur="$ev"
			done < "$STORE"
			[ -n "$cur" ] && val="$cur $val"
			{ while IFS='=' read -r ek ev; do [ "$ek" = "$k" ] || printf '%s=%s\n' "$ek" "$ev"; done < "$STORE"; printf '%s=%s\n' "$k" "$val"; } > "$STORE.t"
			mv "$STORE.t" "$STORE"
			;;
		delete)
			{ while IFS='=' read -r ek ev; do
				case "$ek" in "$1"|"$1".*) continue ;; esac
				printf '%s=%s\n' "$ek" "$ev"
			done < "$STORE"; } > "$STORE.t"
			mv "$STORE.t" "$STORE"
			;;
		commit|revert) : ;;
		*) : ;;
	esac
	return 0
}

get() { uci -q get "$1" 2>/dev/null || printf '%s' '<none>'; }

fail() { printf '%s\n' "FAIL: $1" >&2; exit 1; }

# --- the two shared predicates -------------------------------------------------
ROUTING_MODE='full_tunnel'
nordvpn_easy_routing_mode_is_policy && fail 'full_tunnel must not report as policy mode'
unset ROUTING_MODE
nordvpn_easy_routing_mode_is_policy && fail 'an unset routing mode must default to full_tunnel'
ROUTING_MODE='nonsense'
nordvpn_easy_routing_mode_is_policy && fail 'only the exact value policy enables policy mode'
ROUTING_MODE='policy'
nordvpn_easy_routing_mode_is_policy || fail 'policy must report as policy mode'

KILL_SWITCH_ENABLED='1'
ROUTING_MODE='full_tunnel'
nordvpn_easy_kill_switch_is_effective || fail 'kill switch must be effective in full_tunnel mode'
ROUTING_MODE='policy'
nordvpn_easy_kill_switch_is_effective && fail 'kill switch must be inert in policy mode'
KILL_SWITCH_ENABLED='0'
ROUTING_MODE='full_tunnel'
nordvpn_easy_kill_switch_is_effective && fail 'a disabled kill switch is never effective'

# --- the local-address guard for DNS host routes -------------------------------
for local_ip in 10.0.0.1 127.0.0.1 169.254.1.1 192.168.1.1 172.16.0.1 172.20.5.5 172.31.255.254; do
	nordvpn_easy_ipv4_is_local "$local_ip" || fail "$local_ip must be treated as local"
done
for public_ip in 103.86.96.100 1.1.1.1 8.8.8.8 172.15.0.1 172.32.0.1 9.9.9.9; do
	nordvpn_easy_ipv4_is_local "$public_ip" && fail "$public_ip must NOT be treated as local"
done

# --- peer section: route_allowed_ips follows the mode, allowed_ips never does ---
nordvpn_easy_apply_wireguard_transport_settings() { return 0; }
nordvpn_easy_server_selection_is_manual() { return 1; }
nordvpn_easy_set_first_server_from_list() { return 0; }

VPN_IF='wg0'

: > "$STORE"
ROUTING_MODE='full_tunnel'
nordvpn_easy_build_wireguard_peer_section || fail 'peer section build failed in full_tunnel mode'
[ "$(get network.wg0server.route_allowed_ips)" = '1' ] || fail 'full_tunnel must set route_allowed_ips=1'
[ "$(get network.wg0server.allowed_ips)" = '0.0.0.0/0' ] || fail 'full_tunnel must keep allowed_ips=0.0.0.0/0'

: > "$STORE"
ROUTING_MODE='policy'
nordvpn_easy_build_wireguard_peer_section || fail 'peer section build failed in policy mode'
[ "$(get network.wg0server.route_allowed_ips)" = '0' ] || fail 'policy mode must set route_allowed_ips=0 so netifd installs no route'
# AllowedIPs is WireGuard cryptokey routing, not system routing: narrowing it would
# make the tunnel drop the traffic pbr steers into it.
[ "$(get network.wg0server.allowed_ips)" = '0.0.0.0/0' ] || fail 'policy mode must still keep allowed_ips=0.0.0.0/0'

# --- configure: WAN metric demotion and the VPN resolver host routes ------------
nordvpn_easy_require_core_action_helpers() { return 0; }
nordvpn_easy_fetch_provision_prerequisites() { return 0; }
nordvpn_easy_ensure_vpn_firewall() { return 0; }
nordvpn_easy_build_wireguard_peer_section() { return 0; }
nordvpn_easy_fenced_uci_commit() { return 0; }
nordvpn_easy_harden_secret_config_perms() { return 0; }

WAN_IF='wan'
VPN_ADDR='10.5.0.2/32'
VPN_PORT='51820'
PRIVATE_KEY='private-secret'
NORDVPN_EASY_PROVISION_FETCH_DONE='1'
DNS_MODE='standard'
VPN_DNS1=''
VPN_DNS2=''

: > "$STORE"
ROUTING_MODE='full_tunnel'
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed in full_tunnel mode'
[ "$(get network.wan.metric)" = '1024' ] || fail 'full_tunnel must demote the WAN metric to 1024'
[ "$(get network.nordvpn_dnsroute_1)" = '<none>' ] || fail 'full_tunnel must not create DNS host routes (the default route already covers them)'

: > "$STORE"
ROUTING_MODE='policy'
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed in policy mode'
[ "$(get network.wan.metric)" = '<none>' ] || fail 'policy mode must not demote the WAN metric'
[ "$(get network.nordvpn_dnsroute_1)" = 'route' ] || fail 'policy mode must pin the first VPN resolver into the tunnel'
[ "$(get network.nordvpn_dnsroute_1.interface)" = 'wg0' ] || fail 'DNS host route must be bound to the tunnel interface'
[ "$(get network.nordvpn_dnsroute_1.target)" = '103.86.96.100/32' ] || fail 'DNS host route must target the resolver as a /32'
[ "$(get network.nordvpn_dnsroute_2.target)" = '103.86.99.100/32' ] || fail 'the second VPN resolver must be pinned too'

# A stale metric left by an earlier full_tunnel run must be cleared on a mode switch
# (teardown only removes it on disconnect, not when the user flips the mode).
: > "$STORE"
uci set 'network.wan.metric=1024'
ROUTING_MODE='policy'
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed while clearing a stale WAN metric'
[ "$(get network.wan.metric)" = '<none>' ] || fail 'policy mode must clear a stale 1024 WAN metric demotion'

# An operator-set metric that is not ours must survive untouched.
: > "$STORE"
uci set 'network.wan.metric=42'
ROUTING_MODE='policy'
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed with a foreign WAN metric'
[ "$(get network.wan.metric)" = '42' ] || fail 'policy mode must not touch a WAN metric the app did not set'

# A LAN resolver must never be pinned into the tunnel: that would black-hole it.
: > "$STORE"
ROUTING_MODE='policy'
DNS_MODE='custom'
VPN_DNS1='192.168.1.1'
VPN_DNS2='1.1.1.1'
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed with a LAN resolver configured'
[ "$(get network.nordvpn_dnsroute_1.target)" = '1.1.1.1/32' ] || fail 'only the public resolver may be pinned into the tunnel'
[ "$(get network.nordvpn_dnsroute_2)" = '<none>' ] || fail 'the LAN resolver must not get a host route'

# --- the host routes are app-owned and rebuilt from scratch --------------------
: > "$STORE"
uci set 'network.nordvpn_dnsroute_1=route'
uci set 'network.nordvpn_dnsroute_1.target=103.86.96.100/32'
uci set 'network.nordvpn_dnsroute_7=route'
uci set 'network.other_route=route'
uci set 'network.other_route.target=10.9.0.0/24'
nordvpn_easy_remove_dns_routes
[ "$(get network.nordvpn_dnsroute_1)" = '<none>' ] || fail 'remove_dns_routes must delete app-owned route sections'
[ "$(get network.nordvpn_dnsroute_7)" = '<none>' ] || fail 'remove_dns_routes must delete every app-owned route section'
[ "$(get network.other_route.target)" = '10.9.0.0/24' ] || fail 'remove_dns_routes must leave foreign route sections alone'

# Switching back to full_tunnel must clean the policy-mode host routes away.
: > "$STORE"
ROUTING_MODE='policy'
DNS_MODE='standard'
VPN_DNS1=''
VPN_DNS2=''
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed while seeding policy-mode routes'
[ "$(get network.nordvpn_dnsroute_1)" = 'route' ] || fail 'policy mode must have seeded the host routes'
ROUTING_MODE='full_tunnel'
nordvpn_easy_configure_vpn_interface_no_bringup || fail 'configure failed switching back to full_tunnel'
[ "$(get network.nordvpn_dnsroute_1)" = '<none>' ] || fail 'switching back to full_tunnel must drop the policy-mode host routes'
[ "$(get network.wan.metric)" = '1024' ] || fail 'switching back to full_tunnel must restore the WAN metric demotion'

printf '%s\n' 'test-routing-mode.sh: ok'
