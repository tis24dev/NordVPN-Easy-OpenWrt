#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


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

# Exercise the helpers directly without taking the execution lock: bypass the
# S7a owner fence so fenced_uci_commit just commits.
nordvpn_easy_owner_assert() { return 0; }

log() { :; }

STORE="$TMP_DIR/uci"           # package.section.option=value, one per line
: > "$STORE"
SNAPSHOT="$TMP_DIR/uci.snapshot"
RELOAD_MARK="$TMP_DIR/odhcpd-reload"
: > "$RELOAD_MARK"

# Keep the FIX 3 pending-reload marker inside the scratch dir so the suite never
# touches (or is influenced by) the real /tmp default path. Individual FIX 3
# assertions below still override this per-call for clarity.
NORDVPN_EASY_RA_RELOAD_PENDING="$TMP_DIR/ra-reload-pending-default"
export NORDVPN_EASY_RA_RELOAD_PENDING

# Multi-package file-backed fake uci. Keys are matched by exact string on the
# first '='. `show <pkg>` prints every line whose key starts with "<pkg>.".
uci() {
	[ "${1:-}" = '-q' ] && shift
	cmd="${1:-}"; shift 2>/dev/null || true
	case "$cmd" in
		show)
			pkg="${1:-}"
			if [ -z "$pkg" ]; then cat "$STORE"; return 0; fi
			while IFS='=' read -r ek ev; do
				case "$ek" in "$pkg".*) printf '%s=%s\n' "$ek" "$ev" ;; esac
			done < "$STORE"
			;;
		get)
			while IFS='=' read -r ek ev; do
				[ "$ek" = "$1" ] && { printf '%s\n' "$ev"; return 0; }
			done < "$STORE"
			return 1
			;;
		set)
			k="${1%%=*}"; val="${1#*=}"
			# FIX 2b fail-closed harness: when armed, refuse to write nordvpn_easy.*
			# (models a read-only/invalid snapshot section) so the withdrawal must
			# abort before committing ra=disabled.
			if [ "${FAIL_SNAPSHOT_SET:-0}" = '1' ]; then
				case "$k" in nordvpn_easy.*) return 1 ;; esac
			fi
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
		commit)
			# committing clears the "staged" baseline: future reverts have nothing
			# to roll back to until the next mutation snapshot.
			cp "$STORE" "$SNAPSHOT" 2>/dev/null || true
			;;
		revert)
			# discard staged (uncommitted) mutations by restoring the pre-mutation
			# snapshot, matching real uci revert semantics.
			[ -f "$SNAPSHOT" ] && cp "$SNAPSHOT" "$STORE"
			;;
		*) : ;;
	esac
	return 0
}

# odhcpd init stub that records the reload verb.
cat > "$TMP_DIR/odhcpd-init" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$RELOAD_MARK"
exit 0
EOF
chmod +x "$TMP_DIR/odhcpd-init"

# Gate helpers are stubbed to the interesting (v4-only full-tunnel + delegated
# prefix) case; the gates themselves are unit-tested separately below.
nordvpn_easy_tunnel_is_v4_only_full() { return 0; }
nordvpn_easy_wan_has_delegated_prefix() { return 0; }
nordvpn_easy_harden_secret_config_perms() { :; }

get() { uci -q get "$1" 2>/dev/null || printf '%s' '<none>'; }

seed() {
	: > "$RELOAD_MARK"
	cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=relay
dhcp.lan.dhcpv6=server
EOF
}

run_withdraw() {
	# Snapshot the pre-transaction state so the fake uci `revert` can roll the
	# staged mutations back exactly as real uci does.
	cp "$STORE" "$SNAPSHOT"
	VPN_IF='wg0' WAN_IF='wan' \
		NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init" \
		nordvpn_easy_withdraw_lan_ipv6
}
run_restore() {
	cp "$STORE" "$SNAPSHOT"
	VPN_IF='wg0' WAN_IF='wan' \
		NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init" \
		nordvpn_easy_restore_lan_ipv6
}

# --- withdraw snapshots originals and sets ra=disabled (final-RA withdrawal) ----
seed
run_withdraw

# ra=disabled is odhcpd's graceful-withdraw path (final RA with router lifetime 0
# + zero-lifetime prefixes); dhcpv6=disabled stops DHCPv6 assignment; ra_default=0
# keeps the shutdown RA on the lifetime-0 path even if a user set ra_default>=2
# (odhcpd router.c 701-705 force default_route/valid_prefix from ra_default). Only
# these three SCALAR options are mutated (no list-typed ra_flags, no interval knobs).
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: ra not set to disabled (graceful-withdraw path)' >&2; exit 1; }
[ "$(get dhcp.lan.dhcpv6)" = 'disabled' ] || { echo 'FAIL: dhcpv6 not disabled' >&2; exit 1; }
[ "$(get dhcp.lan.ra_default)" = '0' ] || { echo 'FAIL: ra_default must be forced to 0 so a user ra_default>=2 cannot re-affirm the v6 default route in the shutdown RA' >&2; exit 1; }
# no stray ra_* knobs from the old mechanism must be introduced.
[ "$(get dhcp.lan.ra_lifetime)" = '<none>' ] || { echo 'FAIL: ra_lifetime must NOT be set by the new mechanism' >&2; exit 1; }
[ "$(get dhcp.lan.ra_management)" = '<none>' ] || { echo 'FAIL: ra_management must NOT be set by the new mechanism' >&2; exit 1; }
# snapshot captured the ORIGINAL values, not the mutated ones, for ra + dhcpv6 + ra_default.
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)" = 'relay' ] || { echo 'FAIL: snapshot did not capture original ra' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.had_ra)" = '1' ] || { echo 'FAIL: snapshot had_ra flag' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_dhcpv6)" = 'server' ] || { echo 'FAIL: snapshot did not capture original dhcpv6' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6)" = '1' ] || { echo 'FAIL: snapshot had_dhcpv6 flag' >&2; exit 1; }
# ra_default was originally absent, so it is snapshotted as had=0 and restore DELETES the forced 0.
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_default)" = '0' ] || { echo 'FAIL: snapshot must record ra_default as originally-absent (had=0)' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_flags)" = '<none>' ] || { echo 'FAIL: snapshot must NOT record the removed list-typed ra_flags option' >&2; exit 1; }
grep -q 'reload' "$RELOAD_MARK" || { echo 'FAIL: odhcpd was not reloaded on withdraw' >&2; exit 1; }
grep -q 'restart' "$RELOAD_MARK" && { echo 'FAIL: odhcpd must be RELOADED, never restarted' >&2; exit 1; }

# --- withdraw is idempotent: a second pass does not re-snapshot, re-commit or ---
# --- reload (steady-state must be a true no-op, FIX 11) ------------------------
before="$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)"
: > "$RELOAD_MARK"
run_withdraw
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)" = "$before" ] || { echo 'FAIL: second withdraw overwrote the original snapshot' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: idempotent withdraw changed state' >&2; exit 1; }
[ -s "$RELOAD_MARK" ] && { echo 'FAIL: an already-withdrawn steady-state pass must NOT reload odhcpd' >&2; exit 1; }

# --- FIX 1b: turning the master toggle OFF restores a prior withdrawal --------
# After a withdrawal is applied, a withdraw call with the toggle off must RESTORE
# native v6 (bring the valve down = undo), not leave ra=disabled committed.
seed
run_withdraw
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: setup for toggle-off restore did not withdraw' >&2; exit 1; }
: > "$RELOAD_MARK"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_RA_WITHDRAW_ENABLED='0' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init" \
	nordvpn_easy_withdraw_lan_ipv6
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: toggle-off withdraw must restore native LAN IPv6 (ra back to relay)' >&2; exit 1; }
[ "$(get dhcp.lan.dhcpv6)" = 'server' ] || { echo 'FAIL: toggle-off withdraw must restore dhcpv6' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL: toggle-off restore must drop the snapshot' >&2; exit 1; }

# --- restore replays the snapshot and removes options we introduced -----------
seed
run_withdraw
run_restore
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: ra not restored to original' >&2; exit 1; }
[ "$(get dhcp.lan.dhcpv6)" = 'server' ] || { echo 'FAIL: dhcpv6 not restored to original' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL: snapshot section must be removed after restore' >&2; exit 1; }
grep -q 'reload' "$RELOAD_MARK" || { echo 'FAIL: odhcpd was not reloaded on restore' >&2; exit 1; }

# --- restore of an originally-ABSENT option deletes it on restore -------------
# Seed a LAN whose dhcpv6 is absent so had_dhcpv6=0; restore must delete the
# 'disabled' we introduced rather than leaving it behind.
: > "$RELOAD_MARK"
cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=relay
EOF
run_withdraw
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6)" = '0' ] || { echo 'FAIL: absent dhcpv6 must record had_dhcpv6=0' >&2; exit 1; }
[ "$(get dhcp.lan.dhcpv6)" = 'disabled' ] || { echo 'FAIL: dhcpv6 not set on withdraw' >&2; exit 1; }
run_restore
[ "$(get dhcp.lan.dhcpv6)" = '<none>' ] || { echo 'FAIL: dhcpv6 we introduced (originally absent) must be deleted on restore' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: ra not restored to original' >&2; exit 1; }

# --- restore is idempotent + crash-safe: a no-op when no snapshot exists -------
: > "$RELOAD_MARK"
run_restore
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: idempotent restore changed state' >&2; exit 1; }
[ -s "$RELOAD_MARK" ] && { echo 'FAIL: a no-op restore must not reload odhcpd' >&2; exit 1; }

# --- FIX 3: a failed odhcpd reload is retried on the next healthy pass ---------
# odhcpd-init stub that fails the FIRST reload (leaving the withdrawal committed
# but odhcpd out of sync) then succeeds. The withdraw must drop a pending-reload
# marker on the failure; the NEXT pass (a steady-state no-op, RA_CHANGED=0) must
# still retry the reload and clear the marker on success.
PENDING_MARK="$TMP_DIR/ra-reload-pending"
rm -f "$PENDING_MARK"
FAIL_COUNTER="$TMP_DIR/odhcpd-fail-count"
printf '1' > "$FAIL_COUNTER"
cat > "$TMP_DIR/odhcpd-init-flaky" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$RELOAD_MARK"
n="\$(cat "$FAIL_COUNTER" 2>/dev/null || printf '0')"
if [ "\$n" -gt 0 ]; then
	printf '%s' "\$((n - 1))" > "$FAIL_COUNTER"
	exit 1
fi
exit 0
EOF
chmod +x "$TMP_DIR/odhcpd-init-flaky"

seed
: > "$RELOAD_MARK"
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init-flaky" \
	NORDVPN_EASY_RA_RELOAD_PENDING="$PENDING_MARK" \
	nordvpn_easy_withdraw_lan_ipv6
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: first withdraw must still commit ra=disabled even if the reload fails' >&2; exit 1; }
[ -e "$PENDING_MARK" ] || { echo 'FAIL: a failed odhcpd reload must drop the pending-reload marker' >&2; exit 1; }

# Second pass: steady-state (already ra=disabled, RA_CHANGED=0) but the marker is
# set, so the reload must be RETRIED and, on success, the marker cleared.
: > "$RELOAD_MARK"
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init-flaky" \
	NORDVPN_EASY_RA_RELOAD_PENDING="$PENDING_MARK" \
	nordvpn_easy_withdraw_lan_ipv6
grep -q 'reload' "$RELOAD_MARK" || { echo 'FAIL: the retry pass must reload odhcpd even though RA_CHANGED=0' >&2; exit 1; }
[ -e "$PENDING_MARK" ] && { echo 'FAIL: a successful retry reload must clear the pending-reload marker' >&2; exit 1; }
rm -f "$PENDING_MARK"

# --- superseded/reaped writer cannot leave LAN v6 permanently off -------------
# A withdraw whose fenced commit is refused (superseded owner) must revert BOTH
# the snapshot and the dhcp mutation, leaving the LAN untouched (no orphan
# snapshot, no orphan withdrawal).
seed
NORDVPN_EASY_OWNER_TOKEN='stale-token'
nordvpn_easy_owner_assert() { return 1; }
superseded_rc=0
run_withdraw || superseded_rc=$?
[ "$superseded_rc" -eq 1 ] || { echo 'FAIL: a superseded withdraw must fail' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: a superseded withdraw must leave dhcp.lan.ra untouched' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL: a superseded withdraw must not leave an orphan snapshot' >&2; exit 1; }
nordvpn_easy_owner_assert() { return 0; }
NORDVPN_EASY_OWNER_TOKEN=''

# --- superseded restore keeps the snapshot for the legit owner (no leak) ------
# Build a withdrawn state, then a superseded restore: the fence refuses and the
# snapshot survives so LAN v6 is never permanently disabled by a reaped teardown,
# and the withdrawal (kill-switch justification) stays in place.
seed
run_withdraw
NORDVPN_EASY_OWNER_TOKEN='stale-token'
nordvpn_easy_owner_assert() { return 1; }
superseded_restore_rc=0
run_restore || superseded_restore_rc=$?
[ "$superseded_restore_rc" -eq 1 ] || { echo 'FAIL: a superseded restore must fail' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" != '<none>' ] || { echo 'FAIL: a superseded restore must keep the snapshot for the real owner' >&2; exit 1; }
nordvpn_easy_owner_assert() { return 0; }
NORDVPN_EASY_OWNER_TOKEN=''
# the legit owner can now restore cleanly.
run_restore
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: legit owner restore after superseded attempt failed' >&2; exit 1; }

# --- zone -> dhcp mapping resolves via the dhcp section .interface option ------
# A bridged/renamed dhcp section (name != interface) must still map from the LAN
# zone's network to the right dhcp section.
cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
dhcp.homelan=dhcp
dhcp.homelan.interface=lan
EOF
mapped="$(VPN_IF='wg0' nordvpn_easy_dhcp_sections_for_zone firewall.z_lan)"
[ "$mapped" = 'homelan' ] || { echo "FAIL: zone->dhcp mapping should resolve via .interface (got: $mapped)" >&2; exit 1; }

# --- gate: dual-stack tunnel (::/0 present) is NOT v4-only full-tunnel ---------
# Re-source wireguard.sh to restore the REAL gate (it was stubbed above).
# shellcheck disable=SC1090
. "$LIB_DIR/wireguard.sh"
nordvpn_easy_owner_assert() { return 0; }
# A ::/0 in allowed_ips is the dual-stack signal; the fake uci get returns a
# single value per key so model it with ::/0 to prove the short-circuit fires.
cat > "$STORE" <<'EOF'
network.wg0server=wireguard_wg0
network.wg0server.endpoint_host=example.nordvpn.com
network.wg0server.allowed_ips=::/0
network.wg0.addresses=10.5.0.2/32
EOF
if VPN_IF='wg0' nordvpn_easy_tunnel_is_v4_only_full 'wg0'; then
	echo 'FAIL: a ::/0 (dual-stack) tunnel must NOT be treated as v4-only full-tunnel' >&2; exit 1
fi

# --- gate: v4-only full-tunnel is detected ------------------------------------
cat > "$STORE" <<'EOF'
network.wg0server=wireguard_wg0
network.wg0server.endpoint_host=example.nordvpn.com
network.wg0server.allowed_ips=0.0.0.0/0
network.wg0.addresses=10.5.0.2/32
EOF
VPN_IF='wg0' nordvpn_easy_tunnel_is_v4_only_full 'wg0' || { echo 'FAIL: a v4-only full-tunnel must be detected' >&2; exit 1; }

# --- FIX 4: an AUTHORITATIVE ubus zero-prefix result must NOT fall through to the -
# --- WAN-GUA address scan (no-PD, IA_NA-only WAN must return 1) -----------------
# ubus + jq are mandatory deps and authoritative on prefix delegation. Model both
# with shell functions (command -v finds functions in ash/dash). ubus returns a
# status with an EMPTY ipv6-prefix array (length 0) for both probed interfaces, so
# the probe RAN and authoritatively parsed length 0. The GUA scan (ip -6 addr)
# would return 0 on a global GUA with no PD; the fix must NOT consult it here.
UBUS_EMPTY_PREFIX='{"ipv6-prefix":[]}'
UBUS_HAS_PREFIX='{"ipv6-prefix":[{"address":"2001:db8::"}]}'
ubus() {
	# args: call network.interface.<if> status
	case "$3" in
		*) printf '%s\n' "$UBUS_RESPONSE" ;;
	esac
}
# Minimal jq shim honoring only the exact filter the function uses:
# '(."ipv6-prefix" // []) | length'. Count objects in the array by a crude grep.
jq() {
	# read stdin, count "address" occurrences as the array length proxy.
	body="$(cat)"
	case "$body" in
		*'"ipv6-prefix":[]'*) printf '0\n' ;;
		*'ipv6-prefix'*) printf '%s\n' "$(printf '%s' "$body" | grep -o 'address' | wc -l | tr -d ' ')" ;;
		*) return 1 ;;
	esac
}
# GUA scan fallback would say YES (a global GUA is present) -- prove it is NOT used.
ip() {
	case "$*" in
		'-6 addr show dev eth0 scope global') printf '%s\n' '    inet6 2001:db8::1/64 scope global' ;;
		*) return 0 ;;
	esac
}
nordvpn_easy_resolve_wan_device() { WAN_DEVICE='eth0'; return 0; }

UBUS_RESPONSE="$UBUS_EMPTY_PREFIX"
if WAN_IF='wan' nordvpn_easy_wan_has_delegated_prefix; then
	echo 'FAIL: an authoritative ubus length-0 result must return 1 (no PD), not fall through to the GUA scan' >&2; exit 1
fi
# Sanity: when ubus authoritatively reports a prefix, it returns 0.
UBUS_RESPONSE="$UBUS_HAS_PREFIX"
WAN_IF='wan' nordvpn_easy_wan_has_delegated_prefix || { echo 'FAIL: an authoritative ubus prefix>0 must return 0' >&2; exit 1; }
# When ubus produces EMPTY/unparseable output (probe did not run), the GUA-scan
# fallback IS consulted and finds the global GUA -> returns 0.
ubus() { printf '' ; }
WAN_IF='wan' nordvpn_easy_wan_has_delegated_prefix || { echo 'FAIL: an empty/unparseable ubus reply must fall back to the GUA scan (which finds a global GUA)' >&2; exit 1; }
unset -f ubus jq ip nordvpn_easy_resolve_wan_device

# --- FIX 2: nordvpn_easy_lan_has_relayed_ipv6 detects a relay/hybrid LAN --------
# The real helper (wireguard.sh was re-sourced above) resolves wan zone -> lan zone
# -> dhcp section and returns true iff a WAN-forwarding LAN dhcp section is ra=relay
# or ra=hybrid. A relay/hybrid downstream implies native ISP v6 on the LAN even with
# NO router-held PD (ubus prefix length 0), which the delegated-prefix check misses.
lan_relay_seed() {
	cat > "$STORE" <<EOF
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=$1
EOF
}
lan_relay_seed 'relay'
WAN_IF='wan' nordvpn_easy_lan_has_relayed_ipv6 || { echo 'FAIL: a WAN-forwarding ra=relay LAN must be detected as relayed native v6' >&2; exit 1; }
lan_relay_seed 'hybrid'
WAN_IF='wan' nordvpn_easy_lan_has_relayed_ipv6 || { echo 'FAIL: a WAN-forwarding ra=hybrid LAN must be detected as relayed native v6' >&2; exit 1; }
# server-mode / disabled / unset are NOT relay/hybrid, so the helper returns false
# (that path relies on wan_has_delegated_prefix instead; no IA_NA-only-GUA regression).
lan_relay_seed 'server'
if WAN_IF='wan' nordvpn_easy_lan_has_relayed_ipv6; then echo 'FAIL: a server-mode LAN must NOT be treated as relayed v6' >&2; exit 1; fi
lan_relay_seed 'disabled'
if WAN_IF='wan' nordvpn_easy_lan_has_relayed_ipv6; then echo 'FAIL: a disabled LAN must NOT be treated as relayed v6' >&2; exit 1; fi

# --- FIX 2: Gate 2 broadened -- withdrawal proceeds on a relay LAN even when -----
# --- wan_has_delegated_prefix is FALSE (no router-held PD, ubus length 0) --------
# Stub the delegated-prefix gate to FALSE; the relay LAN alone must let the
# withdrawal run and set ra=disabled (the round-5 gate would have skipped here).
nordvpn_easy_tunnel_is_v4_only_full() { return 0; }
nordvpn_easy_wan_has_delegated_prefix() { return 1; }
: > "$RELOAD_MARK"
lan_relay_seed 'relay'
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init" \
	nordvpn_easy_withdraw_lan_ipv6
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: Gate 2 must proceed on a relay LAN even when wan_has_delegated_prefix is false (FIX 2)' >&2; exit 1; }
# With NO delegated prefix AND no relay/hybrid LAN, Gate 2 must still SKIP (no native v6).
nordvpn_easy_wan_has_delegated_prefix() { return 1; }
: > "$RELOAD_MARK"
lan_relay_seed 'server'
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init" \
	nordvpn_easy_withdraw_lan_ipv6
[ "$(get dhcp.lan.ra)" = 'server' ] || { echo 'FAIL: Gate 2 must SKIP when there is no delegated prefix and no relay/hybrid LAN (server-mode GUA-only WAN is untouched)' >&2; exit 1; }

# Re-stub the gates for the withdraw/restore exercises below (real gate restored above).
nordvpn_easy_tunnel_is_v4_only_full() { return 0; }
nordvpn_easy_wan_has_delegated_prefix() { return 0; }

# --- ANONYMOUS pools are SKIPPED (never withdrawn/snapshotted); NAMED pools beside --
# --- them ARE withdrawn. An @dhcp[N] id is POSITIONAL (no stable identity to -------
# --- snapshot/restore against), so the withdrawal deliberately leaves it untouched --
# --- and relies on the ks6 REJECT; it also logs the skip ONCE. -------------------
# Seed a guest zone served by BOTH an anonymous @dhcp[0] pool AND a named pool
# 'guestn' (both on the WAN-forwarding LAN). Withdraw must skip @dhcp[0] entirely
# (ra unchanged, no snapshot) and withdraw the named pool (ra=disabled + snapshot).
LOGCAP="$TMP_DIR/logcap-anon"
: > "$LOGCAP"
log() { printf '%s\n' "$*" >> "$LOGCAP"; }
: > "$RELOAD_MARK"
cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=guest
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.@dhcp[0]=dhcp
dhcp.@dhcp[0].interface=guest
dhcp.@dhcp[0].ra=server
dhcp.@dhcp[0].dhcpv6=server
dhcp.guestn=dhcp
dhcp.guestn.interface=guest
dhcp.guestn.ra=server
dhcp.guestn.dhcpv6=server
EOF
run_withdraw
# The anonymous pool is left EXACTLY as it was: no snapshot, ra unchanged.
[ "$(get 'dhcp.@dhcp[0].ra')" = 'server' ] || { echo 'FAIL(anon): an anonymous @dhcp[0] pool must be SKIPPED (ra left unchanged, not withdrawn)' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap__dhcp_0_)" = '<none>' ] || { echo 'FAIL(anon): no snapshot must be created for an anonymous @dhcp[0] pool' >&2; exit 1; }
# The NAMED pool alongside it IS withdrawn + snapshotted.
[ "$(get dhcp.guestn.ra)" = 'disabled' ] || { echo 'FAIL(anon): a NAMED pool alongside an anonymous one must still be withdrawn to disabled' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_guestn.dhcp_section)" = 'guestn' ] || { echo 'FAIL(anon): the named pool must be snapshotted verbatim by its stable id' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_guestn.orig_ra)" = 'server' ] || { echo 'FAIL(anon): the named pool snapshot must capture its original ra' >&2; exit 1; }
# The skip is logged ONCE (mode-agnostic ks6-REJECT rationale), not per-section.
grep -q 'does not touch anonymous WAN-forwarding dhcp pools' "$LOGCAP" || { echo 'FAIL(anon): the anonymous-skip must be logged (rely on ks6 REJECT)' >&2; exit 1; }
[ "$(grep -c 'does not touch anonymous WAN-forwarding dhcp pools' "$LOGCAP")" = '1' ] || { echo 'FAIL(anon): the anonymous-skip must be logged ONCE, not per-section' >&2; exit 1; }
# Restore returns ONLY the named pool to its original; the anonymous pool is untouched.
run_restore
[ "$(get dhcp.guestn.ra)" = 'server' ] || { echo 'FAIL(anon): restore must return the named pool to its original ra' >&2; exit 1; }
[ "$(get 'dhcp.@dhcp[0].ra')" = 'server' ] || { echo 'FAIL(anon): the anonymous pool must remain untouched through restore' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_guestn)" = '<none>' ] || { echo 'FAIL(anon): the named pool snapshot must be dropped after restore' >&2; exit 1; }
log() { :; }

# --- CONFIRMED FINDING #1: TWO NAMED sections serving ONE interface -- withdraw ----
# --- snapshots BOTH and restore returns EACH to its own original by verbatim id ----
# --- (neither is left ra=disabled; no cross-contamination). This is the case the ---
# --- removed interface re-resolution broke: both sections re-resolved to the FIRST --
# --- match, leaving the second permanently ra=disabled. ---------------------------
# `dhcp.lan` (no .interface -> its NAME 'lan' is the served interface) and
# `dhcp.lan_extra` (option interface 'lan') both serve interface 'lan'.
: > "$RELOAD_MARK"
cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.ra=server
dhcp.lan.dhcpv6=server
dhcp.lan_extra=dhcp
dhcp.lan_extra.interface=lan
dhcp.lan_extra.ra=relay
dhcp.lan_extra.dhcpv6=server
EOF
# `dhcp.lan` has NO .interface (its NAME 'lan' is the served interface) exactly as
# the confirmed finding requires. The production libs do NOT run under `set -e`, but
# THIS harness does (set -eu at the top): the fake `uci -q get dhcp.lan.interface`
# returns rc 1 for that absent option, which only aborts under the harness errexit.
# Suspend errexit around the two calls so the mapping models the real no-.interface
# section faithfully; the assertions below still run under errexit.
set +e
run_withdraw
# Both named sections are withdrawn and BOTH have their OWN snapshot (verbatim id).
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { set -e; echo 'FAIL(two-named): dhcp.lan must be withdrawn' >&2; exit 1; }
[ "$(get dhcp.lan_extra.ra)" = 'disabled' ] || { set -e; echo 'FAIL(two-named): dhcp.lan_extra must be withdrawn' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)" = 'server' ] || { set -e; echo 'FAIL(two-named): dhcp.lan snapshot must capture orig_ra=server' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan_extra.orig_ra)" = 'relay' ] || { set -e; echo 'FAIL(two-named): dhcp.lan_extra snapshot must capture orig_ra=relay (its OWN original, not the first match)' >&2; exit 1; }
run_restore
set -e
# Each section is returned to its OWN original -- neither left disabled, no clobber.
[ "$(get dhcp.lan.ra)" = 'server' ] || { echo 'FAIL(two-named): dhcp.lan must restore to its own original (server), not be left disabled' >&2; exit 1; }
[ "$(get dhcp.lan_extra.ra)" = 'relay' ] || { echo 'FAIL(two-named): dhcp.lan_extra must restore to its OWN original (relay), not the first section value' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(two-named): dhcp.lan snapshot must be dropped after restore' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan_extra)" = '<none>' ] || { echo 'FAIL(two-named): dhcp.lan_extra snapshot must be dropped after restore' >&2; exit 1; }

# --- FIX 3a: the withdraw success log is a SINGLE mode-agnostic statement -------
# Whether a section's ra=disabled resolves to a graceful final RA is a RUNTIME
# property of odhcpd (a downstream ra=hybrid resolves to server OR relay depending
# on the master, config.c 2206-2213) that we do NOT introspect, so the log must NOT
# classify a given section as server-vs-relay/hybrid. It states BOTH outcomes once
# and makes no per-section claim, for ANY seed mode. Assert on the relay seed here,
# and again on a server seed below: the log line must be identical (mode-agnostic).
LOGCAP="$TMP_DIR/logcap"
: > "$LOGCAP"
log() { printf '%s\n' "$*" >> "$LOGCAP"; }
seed
run_withdraw
grep -q 'withdrew native LAN IPv6 (ra=disabled)' "$LOGCAP" || { echo 'FAIL: withdraw must log the single mode-agnostic summary' >&2; exit 1; }
grep -q 'server-mode LANs get a final RA' "$LOGCAP" || { echo 'FAIL: the mode-agnostic summary must state the server-mode outcome' >&2; exit 1; }
grep -q 'relay/hybrid LANs stop relaying' "$LOGCAP" || { echo 'FAIL: the mode-agnostic summary must state the relay/hybrid outcome' >&2; exit 1; }
# The round-5 per-section classification wording must be GONE (no per-mode branches).
grep -q 'relay/hybrid RA stopped' "$LOGCAP" && { echo 'FAIL: the removed per-section relay/hybrid log wording must not appear' >&2; exit 1; }
relay_log="$(cat "$LOGCAP")"
# A server-mode seed must produce the IDENTICAL mode-agnostic summary (no classification).
: > "$LOGCAP"
: > "$RELOAD_MARK"
cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=server
dhcp.lan.dhcpv6=server
EOF
run_withdraw
grep -q 'withdrew native LAN IPv6 (ra=disabled)' "$LOGCAP" || { echo 'FAIL: server-mode withdraw must log the SAME mode-agnostic summary' >&2; exit 1; }
[ "$(cat "$LOGCAP")" = "$relay_log" ] || { echo 'FAIL: the withdraw summary must be identical for server and relay seeds (mode-agnostic)' >&2; exit 1; }
log() { :; }

# --- FIX 5: an ORPHAN snapshot (crash between restore's two fenced commits, or a --
# --- user editing dhcp.<sec>.ra afterward) must NOT be trusted; withdraw must -----
# --- re-snapshot the CURRENT real values before mutating ------------------------
# Pre-seed a stale snapshot (orig_ra=server) while the LIVE dhcp.lan.ra is 'relay'
# (i.e. NOT the withdrawn sentinel 'disabled'): this models a restored/partially
# restored or user-edited section whose snapshot is stale. A withdraw must detect
# the orphan, drop it, and re-snapshot orig_ra='relay' (the current real value),
# never leaving it at the stale 'server' (which restore would later wrongly apply).
: > "$RELOAD_MARK"
cat > "$STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=relay
dhcp.lan.dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section=lan
nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_lan.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_default=0
EOF
run_withdraw
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: withdraw must still set ra=disabled after refreshing a stale snapshot' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)" = 'relay' ] || { echo 'FAIL: withdraw must REFRESH a stale orphan snapshot to the CURRENT real ra (relay), not leave it at the stale server' >&2; exit 1; }
# And restore replays the REFRESHED original, returning the LAN to relay (not server).
run_restore
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: restore must apply the refreshed original (relay), not the stale server' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL: snapshot must be dropped after restore' >&2; exit 1; }

# A GENUINE steady-state snapshot (live ra already 'disabled') must NOT be treated
# as stale: a second withdraw must keep the original orig_ra intact (idempotent).
: > "$RELOAD_MARK"
seed
run_withdraw
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)" = 'relay' ] || { echo 'FAIL: setup: first withdraw must snapshot orig_ra=relay' >&2; exit 1; }
: > "$RELOAD_MARK"
run_withdraw
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra)" = 'relay' ] || { echo 'FAIL: a genuine ra=disabled steady-state snapshot must NOT be refreshed (idempotency preserved)' >&2; exit 1; }
[ -s "$RELOAD_MARK" ] && { echo 'FAIL: a genuine steady-state re-pass must NOT reload odhcpd' >&2; exit 1; }

# --- FIX 2: a FAILED odhcpd reload on the RESTORE path keeps the retry marker ----
# and a later restore pass re-syncs odhcpd (clears the marker on success). The
# stub fails the FIRST reload it sees, then succeeds. Build a withdrawn state first
# (with a working stub), then restore with the flaky stub: the restore-time reload
# fails -> flash=ra restored but the marker must SURVIVE (not be deleted). A second
# restore pass (a no-op: snapshot already gone) must retry the reload and clear it.
RESTORE_PENDING="$TMP_DIR/ra-restore-pending"
rm -f "$RESTORE_PENDING"
RESTORE_FAIL_COUNTER="$TMP_DIR/odhcpd-restore-fail-count"
printf '1' > "$RESTORE_FAIL_COUNTER"
cat > "$TMP_DIR/odhcpd-init-restore-flaky" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$RELOAD_MARK"
n="\$(cat "$RESTORE_FAIL_COUNTER" 2>/dev/null || printf '0')"
if [ "\$n" -gt 0 ]; then
	printf '%s' "\$((n - 1))" > "$RESTORE_FAIL_COUNTER"
	exit 1
fi
exit 0
EOF
chmod +x "$TMP_DIR/odhcpd-init-restore-flaky"

seed
: > "$RELOAD_MARK"
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init" \
	NORDVPN_EASY_RA_RELOAD_PENDING="$RESTORE_PENDING" \
	nordvpn_easy_withdraw_lan_ipv6
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL: setup withdraw for restore-retry test failed' >&2; exit 1; }
rm -f "$RESTORE_PENDING"

# Restore with the flaky stub: the reload fails, flash=ra restored, marker survives.
: > "$RELOAD_MARK"
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init-restore-flaky" \
	NORDVPN_EASY_RA_RELOAD_PENDING="$RESTORE_PENDING" \
	nordvpn_easy_restore_lan_ipv6
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: restore must restore ra even when the reload fails' >&2; exit 1; }
[ -e "$RESTORE_PENDING" ] || { echo 'FAIL: a FAILED restore reload must keep the pending-reload marker (symmetric with withdraw)' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL: restore must still drop the snapshot even when the reload fails' >&2; exit 1; }

# Second restore pass (a no-op: snapshot gone) must RETRY the reload via the marker
# and clear it on success.
: > "$RELOAD_MARK"
cp "$STORE" "$SNAPSHOT"
VPN_IF='wg0' WAN_IF='wan' \
	NORDVPN_EASY_ODHCPD_INIT="$TMP_DIR/odhcpd-init-restore-flaky" \
	NORDVPN_EASY_RA_RELOAD_PENDING="$RESTORE_PENDING" \
	nordvpn_easy_restore_lan_ipv6
grep -q 'reload' "$RELOAD_MARK" || { echo 'FAIL: the restore retry pass must reload odhcpd even with no snapshots left' >&2; exit 1; }
[ -e "$RESTORE_PENDING" ] && { echo 'FAIL: a successful restore retry reload must clear the pending-reload marker' >&2; exit 1; }
rm -f "$RESTORE_PENDING"

# --- restore anchors on the VERBATIM stored .dhcp_section id (named = stable 1:1) --
# A named pool snapshot stores the raw dhcp id and NO interface anchor; restore
# targets that id directly. Named sections have stable ids so this is exactly 1:1.
: > "$RELOAD_MARK"
seed
run_withdraw
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section)" = 'lan' ] || { echo 'FAIL(named): a named pool snapshot must store its verbatim id in .dhcp_section' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_interface)" = '<none>' ] || { echo 'FAIL(named): the snapshot must NOT store a .dhcp_interface anchor (re-resolution removed)' >&2; exit 1; }
run_restore
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL(named): a named pool must restore to its original via its verbatim id' >&2; exit 1; }
[ "$(get dhcp.lan.dhcpv6)" = 'server' ] || { echo 'FAIL(named): a named pool dhcpv6 must restore' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(named): named pool snapshot must be dropped after restore' >&2; exit 1; }

# --- CONFIRMED FINDING #2: RESTORE-TIME GC of an orphan snapshot -- a snapshot -----
# --- whose .dhcp_section was DELETED while the VPN was up must NOT recreate a -------
# --- phantom section; restore drops the snapshot and creates no dhcp.<id>. ---------
# This is the second case the removed re-resolution broke (a stale snapshot for a
# deleted+recreated section re-resolved onto the current live section and clobbered
# it). With verbatim-id restore + this GC guard, a deleted id is simply dropped.
: > "$RELOAD_MARK"
cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=relay
nordvpn_easy.nordvpn_ra6_snap_gone=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_gone.dhcp_section=gone
nordvpn_easy.nordvpn_ra6_snap_gone.orig_ra=server
nordvpn_easy.nordvpn_ra6_snap_gone.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_gone.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_gone.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_gone.had_ra_default=0
EOF
run_restore
# No phantom dhcp.gone section is created (neither the type line nor its options).
[ "$(get dhcp.gone)" = '<none>' ] || { echo 'FAIL(gc): restore must NOT recreate a phantom dhcp.gone section for a deleted id' >&2; exit 1; }
[ "$(get dhcp.gone.ra)" = '<none>' ] || { echo 'FAIL(gc): restore must NOT write dhcp.gone.ra for a deleted section' >&2; exit 1; }
# The orphan snapshot is GCed (dropped) so it never lingers.
[ "$(get nordvpn_easy.nordvpn_ra6_snap_gone)" = '<none>' ] || { echo 'FAIL(gc): restore must drop the orphan snapshot for a deleted section' >&2; exit 1; }
# The live, unrelated dhcp.lan is left completely untouched (no clobber).
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL(gc): restore of an orphan snapshot must NOT touch an unrelated live section' >&2; exit 1; }

# --- FIX 2b: FAIL CLOSED -- a failing snapshot store must NOT commit ra=disabled -
# Flip the file-backed fake uci into a mode where a `set` on nordvpn_easy.* fails
# (simulating a read-only/invalid snapshot section) while dhcp reads/sets still
# work. The withdraw must abort with ra left UNCHANGED and no orphan snapshot (no
# orphan withdrawal without a recoverable snapshot). This is the LAST exercise so
# leaving the flag set is fine.
seed
FAIL_SNAPSHOT_SET=1
failclosed_rc=0
run_withdraw || failclosed_rc=$?
[ "$failclosed_rc" -eq 1 ] || { echo 'FAIL: a withdraw whose snapshot store fails must return 1 (fail closed)' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL: fail-closed withdraw must leave dhcp.lan.ra UNCHANGED (no orphan withdrawal)' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL: fail-closed withdraw must not leave an orphan snapshot' >&2; exit 1; }

printf '%s\n' 'test-ra-withdrawal.sh: ok'
