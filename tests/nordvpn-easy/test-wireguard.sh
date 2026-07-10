#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"

# This unit test exercises teardown/bring-up/firewall directly without taking the
# execution lock, so bypass the S7a owner fence (fenced_* wrappers) here -- the
# fence itself is covered by test-common-lock.sh.
nordvpn_easy_owner_assert() { return 0; }

assert_eq() {
	expected="$1"
	actual="$2"
	label="$3"

	if [ "$expected" != "$actual" ]; then
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "expected: $expected" >&2
		printf '%s\n' "actual:   $actual" >&2
		exit 1
	fi
}

log() { :; }

UCI_PROTO=''
UCI_PEER_SECTION=0
UCI_ENDPOINT_HOST=''
UCI_ENDPOINT_PORT=''
UCI_KEEPALIVE=''
UCI_MTU=''
UCI_STATION=''
UCI_HOSTNAME=''
UCI_PRIVATE_KEY=''
UCI_ADDRESSES=''
UCI_PEERDNS=''
UCI_DNS=''
UCI_DELEGATE=''
UCI_FORCE_LINK=''

uci() {
	case "$1" in
		-q)
			shift
			uci "$@"
			return $?
			;;
		get)
				case "$2" in
					network.wg0.proto) [ -n "$UCI_PROTO" ] || return 1; printf '%s\n' "$UCI_PROTO" ;;
					network.wg0.private_key) [ -n "$UCI_PRIVATE_KEY" ] || return 1; printf '%s\n' "$UCI_PRIVATE_KEY" ;;
					network.wg0.addresses) [ -n "$UCI_ADDRESSES" ] || return 1; printf '%s\n' "$UCI_ADDRESSES" ;;
					network.wg0.peerdns) [ -n "$UCI_PEERDNS" ] || return 1; printf '%s\n' "$UCI_PEERDNS" ;;
					network.wg0.dns) [ -n "$UCI_DNS" ] || return 1; printf '%s\n' "$UCI_DNS" ;;
					network.wg0.delegate) [ -n "$UCI_DELEGATE" ] || return 1; printf '%s\n' "$UCI_DELEGATE" ;;
					network.wg0.force_link) [ -n "$UCI_FORCE_LINK" ] || return 1; printf '%s\n' "$UCI_FORCE_LINK" ;;
					network.wg0server.endpoint_host) [ -n "$UCI_ENDPOINT_HOST" ] || return 1; printf '%s\n' "$UCI_ENDPOINT_HOST" ;;
					network.wg0server.endpoint_port) printf '%s\n' "$UCI_ENDPOINT_PORT" ;;
					network.wg0server.persistent_keepalive) printf '%s\n' "$UCI_KEEPALIVE" ;;
					network.wg0.mtu)
						[ -n "$UCI_MTU" ] || return 1
						printf '%s\n' "$UCI_MTU"
						;;
					network.wg0server.nordvpn_station)
						[ -n "$UCI_STATION" ] || return 1
					printf '%s\n' "$UCI_STATION"
					;;
				network.wg0server.nordvpn_hostname) printf '%s\n' "$UCI_HOSTNAME" ;;
				*) return 1 ;;
			esac
				return 0
				;;
			show)
				[ "$2" = 'network' ] || return 1
				[ "$UCI_PEER_SECTION" -eq 1 ] || return 0
				printf '%s\n' "network.wg0server=wireguard_wg0"
				return 0
				;;
			set)
				case "${2%%=*}" in
					network.wg0.proto) UCI_PROTO="${2#*=}" ;;
					network.wg0.private_key) UCI_PRIVATE_KEY="${2#*=}" ;;
					network.wg0.peerdns) UCI_PEERDNS="${2#*=}" ;;
					network.wg0.delegate) UCI_DELEGATE="${2#*=}" ;;
					network.wg0.force_link) UCI_FORCE_LINK="${2#*=}" ;;
					network.wg0server) UCI_PEER_SECTION=1 ;;
					network.wg0server.endpoint_host) UCI_ENDPOINT_HOST="${2#*=}" ;;
					network.wg0server.endpoint_port) UCI_ENDPOINT_PORT="${2#*=}" ;;
					network.wg0server.persistent_keepalive) UCI_KEEPALIVE="${2#*=}" ;;
					network.wg0.mtu) UCI_MTU="${2#*=}" ;;
					network.wg0server.nordvpn_station) UCI_STATION="${2#*=}" ;;
					network.wg0server.nordvpn_hostname) UCI_HOSTNAME="${2#*=}" ;;
				esac
				return 0
				;;
			add_list)
				case "${2%%=*}" in
					network.wg0.addresses)
						UCI_ADDRESSES="${UCI_ADDRESSES:+$UCI_ADDRESSES }${2#*=}"
						;;
					network.wg0.dns)
						UCI_DNS="${UCI_DNS:+$UCI_DNS }${2#*=}"
						;;
				esac
				return 0
				;;
			delete)
				case "$2" in
					network.wg0.addresses) UCI_ADDRESSES='' ;;
					network.wg0.dns) UCI_DNS='' ;;
					network.wg0.mtu) UCI_MTU='' ;;
				esac
				return 0
				;;
		*)
			return 1
			;;
	esac
}

FAKE_NOW_FILE="$TMP_DIR/fake-now"
SLEEP_CALLS=''
PING_ATTEMPTS=0
SUCCESS_ON_ATTEMPT=0

date() {
	local now_value

	if [ "${1:-}" = '+%s' ]; then
		now_value="$(cat "$FAKE_NOW_FILE" 2>/dev/null || printf '%s' '0')"
		printf '%s\n' "$now_value"
		printf '%s\n' "$((now_value + 1))" > "$FAKE_NOW_FILE"
		return 0
	fi

	return 1
}

sleep() {
	SLEEP_CALLS="${SLEEP_CALLS}${1},"
}

nordvpn_easy_ping_interface() {
	PING_ATTEMPTS=$((PING_ATTEMPTS + 1))
	[ "$SUCCESS_ON_ATTEMPT" -gt 0 ] && [ "$PING_ATTEMPTS" -ge "$SUCCESS_ON_ATTEMPT" ]
}

VPN_IF='wg0'
WAN_IF='wan'
VPN_PORT='51820'
WIREGUARD_PERSISTENT_KEEPALIVE='15'
WIREGUARD_MTU=''
VPN_ADDR='10.5.0.2/32'
VPN_DNS1='103.86.99.99'
VPN_DNS2='103.86.96.96'
POST_RESTART_DELAY='5'

UCI_PROTO='wireguard'
UCI_PEER_SECTION=0
UCI_ENDPOINT_HOST=''
if nordvpn_easy_vpn_is_configured; then
	printf '%s\n' 'FAIL: WireGuard interface without a peer section is not configured' >&2
	exit 1
fi

UCI_PEER_SECTION=1
if ! nordvpn_easy_vpn_is_configured; then
	printf '%s\n' 'FAIL: WireGuard interface with a peer section is configured' >&2
	exit 1
fi

# These two cases exercise the ping PROBE LOOP (sleep/retry accounting). On a real
# router `wg` exists and the live tunnel has a fresh handshake, so the real
# wait_for_vpn_handshake would short-circuit and the probe loop would never run
# the way these cases assume; on a host without `wg` it returns 1 and it does.
# Pin the handshake path to "not connected" so the accounting is bench-independent.
# (Subshell so the stub does not leak into the later real-handshake tests; set -e
# still propagates an inner assertion failure.)
(
	nordvpn_easy_wait_for_vpn_handshake() { return 1; }

	printf '%s\n' '100' > "$FAKE_NOW_FILE"
	SLEEP_CALLS=''
	PING_ATTEMPTS=0
	SUCCESS_ON_ATTEMPT=2
	nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "$POST_RESTART_DELAY" 'unit-test'

	assert_eq '2' "$PING_ATTEMPTS" 'wait helper exits as soon as connectivity is restored'
	assert_eq '1,' "$SLEEP_CALLS" 'wait helper sleeps only until the next successful probe'

	printf '%s\n' '200' > "$FAKE_NOW_FILE"
	SLEEP_CALLS=''
	PING_ATTEMPTS=0
	SUCCESS_ON_ATTEMPT=0
	WAIT_RC=0
	nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" '3' 'timeout-test' || WAIT_RC=$?

	assert_eq '1' "$WAIT_RC" 'wait helper fails when connectivity never returns'
	assert_eq '1,1,' "$SLEEP_CALLS" 'wait helper retries until the timeout window is exhausted'
)

# A fresh handshake must not short-circuit readiness on its own: connectivity is
# still confirmed with a ping through the interface before the tunnel is ready.
# (Subshell so the handshake stub does not leak into the later real-handshake test.)
(
	nordvpn_easy_wait_for_vpn_handshake() { return 0; }
	printf '%s\n' '300' > "$FAKE_NOW_FILE"
	PING_ATTEMPTS=0
	SUCCESS_ON_ATTEMPT=1
	nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "$POST_RESTART_DELAY" 'handshake-success-test'
	assert_eq '1' "$PING_ATTEMPTS" 'a fresh handshake still confirms connectivity with a ping before declaring ready'
)

nordvpn_easy_set_vpn_server_in_uci 'it12.nordvpn.com' 'it123' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 'IT' 'Milan' '12'

assert_eq 'it12.nordvpn.com' "$UCI_ENDPOINT_HOST" 'wireguard peer endpoint host uses hostname'
assert_eq '51820' "$UCI_ENDPOINT_PORT" 'wireguard peer endpoint port is repaired during server update'
assert_eq '15' "$UCI_KEEPALIVE" 'wireguard peer keepalive defaults to 15 seconds'
assert_eq '' "$UCI_MTU" 'empty WireGuard MTU leaves interface MTU automatic'
assert_eq 'it12.nordvpn.com' "$UCI_HOSTNAME" 'wireguard peer stores NordVPN hostname separately'
assert_eq 'it123' "$UCI_STATION" 'wireguard peer stores NordVPN station separately'
assert_eq 'it123' "$(nordvpn_easy_current_server_station)" 'current server station reads the stored station id'

UCI_STATION=''
assert_eq '' "$(nordvpn_easy_current_server_station || true)" 'current server station does not fall back to endpoint host when station metadata is missing'

# Reject corrupted/spoofed peers before they are committed.
RC=0
nordvpn_easy_set_vpn_server_in_uci 'it12.nordvpn.com' 'it123' 'PUBKEY-123' 'IT' 'Milan' '12' >/dev/null 2>&1 || RC=$?
assert_eq '1' "$RC" 'set_vpn_server rejects a non-base64 public key'
RC=0
nordvpn_easy_set_vpn_server_in_uci 'it12.nordvpn.com' 'it123' 'AAAA' 'IT' 'Milan' '12' >/dev/null 2>&1 || RC=$?
assert_eq '1' "$RC" 'set_vpn_server rejects a wrong-length public key'
RC=0
nordvpn_easy_set_vpn_server_in_uci 'bad host' 'it123' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 'IT' 'Milan' '12' >/dev/null 2>&1 || RC=$?
assert_eq '1' "$RC" 'set_vpn_server rejects an endpoint host with invalid characters'

# nordvpn_easy_valid_wireguard_key backs both the peer public key and the
# NordLynx private key (core.sh get_private_key): 43 base64 chars + '=' = 44.
WG_KEY_B43="$(printf '%043d' 0 | tr '0' 'A')"
RC=0; nordvpn_easy_valid_wireguard_key "${WG_KEY_B43}=" || RC=$?
assert_eq '0' "$RC" 'a 44-char padded base64 key validates'
RC=0; nordvpn_easy_valid_wireguard_key '' || RC=$?
assert_eq '1' "$RC" 'an empty key is rejected'
RC=0; nordvpn_easy_valid_wireguard_key 'AAAA' || RC=$?
assert_eq '1' "$RC" 'a too-short key is rejected'
RC=0; nordvpn_easy_valid_wireguard_key "${WG_KEY_B43}A" || RC=$?
assert_eq '1' "$RC" 'an unpadded 44-char key is rejected'
RC=0; nordvpn_easy_valid_wireguard_key "$(printf '%042d' 0 | tr '0' 'A')!=" || RC=$?
assert_eq '1' "$RC" 'a non-base64 key is rejected'

WIREGUARD_PERSISTENT_KEEPALIVE='10'
WIREGUARD_MTU='1420'
nordvpn_easy_apply_wireguard_transport_settings 'wg0server'

assert_eq '10' "$UCI_KEEPALIVE" 'transport repair applies configured keepalive'
assert_eq '1420' "$UCI_MTU" 'transport repair applies configured MTU'

nordvpn_easy_apply_wireguard_transport_settings 'wg0server' '443'
assert_eq '443' "$UCI_ENDPOINT_PORT" 'transport repair applies explicit endpoint port'

WIREGUARD_MTU=''
nordvpn_easy_apply_wireguard_transport_settings 'wg0server'
assert_eq '' "$UCI_MTU" 'transport repair removes MTU when automatic is selected'

IFDOWN_COUNT=0
UCI_DELETE_COUNT=0
UCI_REVERT_COUNT=0
NETWORK_RELOAD_COUNT=0
ifdown() { IFDOWN_COUNT=$((IFDOWN_COUNT + 1)); }
nordvpn_easy_vpn_link_is_present() { return 0; }
nordvpn_easy_log_vpn_interface_state() { :; }
uci() {
	case "$1" in
		show)
			if [ "$2" = 'network' ]; then
				printf '%s\n' 'network.wg0server=wireguard_wg0' 'network.legacy_peer=wireguard_wg0'
				return 0
			fi
			;;
		-q)
			shift
			case "$1" in
				delete)
					UCI_DELETE_COUNT=$((UCI_DELETE_COUNT + 1))
					return 0
					;;
				commit)
					return 0
					;;
				revert)
					UCI_REVERT_COUNT=$((UCI_REVERT_COUNT + 1))
					return 0
					;;
				get)
					case "$2" in
						network.wan.metric) return 1 ;;
					esac
					return 1
					;;
			esac
			;;
	esac
	return 0
}
NETWORK_RELOAD_COUNT_FILE="$TMP_DIR/network-reload-count"
mkdir -p "$TMP_DIR/mock-bin/etc/init.d"
cat > "$TMP_DIR/mock-bin/etc/init.d/network" <<EOF
#!/bin/sh
case "\$1" in
	reload)
		count="\$(cat "$NETWORK_RELOAD_COUNT_FILE" 2>/dev/null || printf '%s' '0')"
		printf '%s\n' "\$((count + 1))" > "$NETWORK_RELOAD_COUNT_FILE"
		exit 0
		;;
esac
exit 1
EOF
chmod +x "$TMP_DIR/mock-bin/etc/init.d/network"
NORDVPN_EASY_NETWORK_INIT="$TMP_DIR/mock-bin/etc/init.d/network"

nordvpn_easy_teardown_vpn

assert_eq '1' "$IFDOWN_COUNT" 'teardown runs ifdown when the VPN link is present'
assert_eq '4' "$UCI_DELETE_COUNT" 'teardown removes the interface and all wireguard peer sections'
assert_eq '1' "$(cat "$NETWORK_RELOAD_COUNT_FILE")" 'teardown reloads network after UCI cleanup'

# When the fence refuses the network commit (a reaped/superseded writer, i.e. this
# process HOLDS a token that no longer matches the on-disk lock), teardown discards
# the staged deletes so a later unfenced network commit cannot flush them.
UCI_REVERT_COUNT=0
INTERFACE_RESTART_DELAY=0
NORDVPN_EASY_OWNER_TOKEN='stale-token'
nordvpn_easy_owner_assert() { return 1; }
superseded_teardown_rc=0
nordvpn_easy_teardown_vpn >/dev/null 2>&1 || superseded_teardown_rc=$?
assert_eq '1' "$superseded_teardown_rc" 'teardown aborts when the fence refuses the network commit'
assert_eq '1' "$UCI_REVERT_COUNT" 'a fence-refused teardown reverts the staged network delta'
nordvpn_easy_owner_assert() { return 0; }
NORDVPN_EASY_OWNER_TOKEN=''

wg() {
	case "$1 $2 $3" in
		'show wg0 latest-handshakes')
			printf '%s\n' 'peerpub 0'
			;;
		*) return 1 ;;
	esac
}
ip() {
	case "$*" in
		'-4 route show default') printf '%s\n' 'default dev wg0 proto static scope link' ;;
		*) return 0 ;;
	esac
}

if ! nordvpn_easy_runtime_needs_provision wg0; then
	printf '%s\n' 'FAIL: runtime without handshake should require provisioning' >&2
	exit 1
fi

IFUP_COUNT=0
NETWORK_RESTART_COUNT=0
ifup() {
	IFUP_COUNT=$((IFUP_COUNT + 1))
	return 0
}
cat > "$TMP_DIR/mock-bin/etc/init.d/network" <<EOF
#!/bin/sh
case "\$1" in
	reload)
		count="\$(cat "$NETWORK_RELOAD_COUNT_FILE" 2>/dev/null || printf '%s' '0')"
		printf '%s\n' "\$((count + 1))" > "$NETWORK_RELOAD_COUNT_FILE"
		exit 0
		;;
	restart)
		printf '%s\n' '1' > "$TMP_DIR/network-restart-count"
		exit 0
		;;
esac
exit 1
EOF
chmod +x "$TMP_DIR/mock-bin/etc/init.d/network"
printf '%s\n' '0' > "$NETWORK_RELOAD_COUNT_FILE"
printf '%s\n' '0' > "$TMP_DIR/network-restart-count"

nordvpn_easy_bring_up_vpn_interface wg0

assert_eq '1' "$(cat "$NETWORK_RELOAD_COUNT_FILE")" 'bring-up reloads network once'
assert_eq '1' "$IFUP_COUNT" 'bring-up prefers ifup over full restart'
assert_eq '0' "$(cat "$TMP_DIR/network-restart-count")" 'bring-up does not restart network when ifup succeeds'

IFUP_COUNT=0
ifup() { IFUP_COUNT=$((IFUP_COUNT + 1)); return 1; }
nordvpn_easy_bring_up_vpn_interface wg0 || true
assert_eq '1' "$(cat "$TMP_DIR/network-restart-count")" 'bring-up falls back to network restart when ifup fails'

# PR #81 review: a fence-DENIED bring-up (superseded/reaped owner) must NOT escalate to an
# unfenced network restart -- it must bail (return 1) so a revoked worker cannot reload or
# restart the new owner's network stack. Distinct from the genuine ifup failure above.
printf '%s\n' '0' > "$TMP_DIR/network-restart-count"
printf '%s\n' '0' > "$NETWORK_RELOAD_COUNT_FILE"
nordvpn_easy_owner_fence_denied() { return 0; }
denied_brc=0
nordvpn_easy_bring_up_vpn_interface wg0 || denied_brc=$?
assert_eq '1' "$denied_brc" 'a fence-denied bring-up bails (return 1)'
assert_eq '0' "$(cat "$TMP_DIR/network-restart-count")" 'a fence-denied bring-up does NOT restart the network'
assert_eq '0' "$(cat "$NETWORK_RELOAD_COUNT_FILE")" 'a fence-denied bring-up bails before the unfenced network reload too'
nordvpn_easy_owner_fence_denied() { return 1; }

# Second guard (mid-flight revocation): NOT denied at the top, but denied AFTER the reload
# (e.g. the TTL reaper revoked us during bring-up so the fenced ifup is refused). The
# post-ifup guard must then bail instead of restarting. Stateful stub: denied only once
# the reload has run.
printf '%s\n' '0' > "$TMP_DIR/network-restart-count"
printf '%s\n' '0' > "$NETWORK_RELOAD_COUNT_FILE"
nordvpn_easy_owner_fence_denied() { [ "$(cat "$NETWORK_RELOAD_COUNT_FILE" 2>/dev/null)" != '0' ]; }
midflight_brc=0
nordvpn_easy_bring_up_vpn_interface wg0 || midflight_brc=$?
assert_eq '1' "$midflight_brc" 'a mid-flight fence revocation makes bring-up bail (return 1)'
assert_eq '1' "$(cat "$NETWORK_RELOAD_COUNT_FILE")" 'the reload ran (top guard passed) before the mid-flight revocation'
assert_eq '0' "$(cat "$TMP_DIR/network-restart-count")" 'a mid-flight-revoked bring-up does NOT restart the network'
nordvpn_easy_owner_fence_denied() { return 1; }

printf '%s\n' '300' > "$FAKE_NOW_FILE"
HANDSHAKE_EPOCH='295'
wg() {
	case "$1 $2 $3" in
		'show wg0 latest-handshakes')
			printf '%s\n' 'oldpeer 0'
			printf '%s\n' "peerpub $HANDSHAKE_EPOCH"
			;;
		*) return 1 ;;
	esac
}
SLEEP_CALLS=''
assert_eq "$HANDSHAKE_EPOCH" "$(nordvpn_easy_wg_handshake_epoch wg0)" 'handshake epoch helper returns the newest peer epoch'
nordvpn_easy_wait_for_vpn_handshake wg0 10 'handshake-test' || {
	printf '%s\n' 'FAIL: recent handshake should validate quickly' >&2
	exit 1
}
assert_eq '' "$SLEEP_CALLS" 'handshake wait returns without sleeping when handshake is already fresh'

printf '%s\n' 'test-wireguard.sh: ok'
