#!/bin/sh

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

log() { :; }

FW_STORE="$TMP_DIR/fw"
RELOAD_MARK="$TMP_DIR/reload"

# File-backed fake uci. UCI keys contain [ ] @ . so match keys by exact string
# (split on the first '='), never by regex.
uci() {
	[ "${1:-}" = '-q' ] && shift
	cmd="${1:-}"; shift 2>/dev/null || true
	case "$cmd" in
		show)
			[ "${1:-}" = 'firewall' ] || return 0
			cat "$FW_STORE" 2>/dev/null || true
			;;
		get)
			while IFS='=' read -r ek ev; do
				[ "$ek" = "$1" ] && { printf '%s\n' "$ev"; return 0; }
			done < "$FW_STORE"
			return 1
			;;
		set)
			k="${1%%=*}"; val="${1#*=}"
			{ while IFS='=' read -r ek ev; do [ "$ek" = "$k" ] || printf '%s=%s\n' "$ek" "$ev"; done < "$FW_STORE"; printf '%s=%s\n' "$k" "$val"; } > "$FW_STORE.t"
			mv "$FW_STORE.t" "$FW_STORE"
			;;
		delete)
			{ while IFS='=' read -r ek ev; do
				case "$ek" in "$1"|"$1".*) continue ;; esac
				printf '%s=%s\n' "$ek" "$ev"
			done < "$FW_STORE"; } > "$FW_STORE.t"
			mv "$FW_STORE.t" "$FW_STORE"
			;;
		del_list)
			k="${1%%=*}"; val="${1#*=}"; cur=''
			while IFS='=' read -r ek ev; do [ "$ek" = "$k" ] && cur="$ev"; done < "$FW_STORE"
			new=''
			for item in $cur; do [ "$item" = "$val" ] || new="${new:+$new }$item"; done
			{ while IFS='=' read -r ek ev; do [ "$ek" = "$k" ] || printf '%s=%s\n' "$ek" "$ev"; done < "$FW_STORE"; [ -n "$new" ] && printf '%s=%s\n' "$k" "$new"; } > "$FW_STORE.t"
			mv "$FW_STORE.t" "$FW_STORE"
			;;
		commit) : ;;
		*) : ;;
	esac
	return 0
}

seed_firewall() {
	cat > "$FW_STORE" <<'EOF'
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan wan6 wg0
firewall.@forwarding[0]=forwarding
firewall.@forwarding[0].src=lan
firewall.@forwarding[0].dest=wan
EOF
}

fwget() { uci -q get "$1" 2>/dev/null || printf '%s' '<none>'; }

run_ensure() {
	: > "$RELOAD_MARK"
	VPN_IF='wg0' WAN_IF='wan' FIREWALL_MTU_FIX='1' \
		KILL_SWITCH_ENABLED="$1" \
		NORDVPN_EASY_FIREWALL_INIT="$TMP_DIR/fw-init" \
		nordvpn_easy_ensure_vpn_firewall
}

# A stub firewall init that records the reload.
cat > "$TMP_DIR/fw-init" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$RELOAD_MARK"
exit 0
EOF
chmod +x "$TMP_DIR/fw-init"

# --- strict kill switch (default) ---------------------------------------------
seed_firewall
run_ensure 1

[ "$(fwget firewall.nordvpn_vpn)" = 'zone' ] || { echo 'FAIL: vpn zone not created' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_vpn.name)" = 'nordvpn' ] || { echo 'FAIL: vpn zone name' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_vpn.network)" = 'wg0' ] || { echo 'FAIL: vpn zone network' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_vpn.masq)" = '1' ] || { echo 'FAIL: vpn zone masq' >&2; exit 1; }
case " $(fwget firewall.@zone[1].network) " in
	*' wg0 '*) echo 'FAIL: wg0 still in the wan zone' >&2; exit 1 ;;
esac
[ "$(fwget firewall.nordvpn_fwd_1.dest)" = 'nordvpn' ] || { echo 'FAIL: lan->vpn forwarding missing' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_fwd_1.src)" = 'lan' ] || { echo 'FAIL: lan->vpn forwarding src' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_ks6_1.target)" = 'DROP' ] && [ "$(fwget firewall.nordvpn_ks6_1.family)" = 'ipv6' ] || { echo 'FAIL: IPv6 drop rule missing' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_ks4_1.target)" = 'DROP' ] && [ "$(fwget firewall.nordvpn_ks4_1.family)" = 'ipv4' ] || { echo 'FAIL: IPv4 kill-switch rule missing when strict' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_ks4_1.dest)" = 'wan' ] || { echo 'FAIL: kill-switch rule must target the wan zone' >&2; exit 1; }
grep -q 'reload' "$RELOAD_MARK" || { echo 'FAIL: firewall was not reloaded' >&2; exit 1; }

# --- fallback (kill switch off): IPv6 still blocked, IPv4 NOT blocked ----------
seed_firewall
run_ensure 0

[ "$(fwget firewall.nordvpn_ks6_1.target)" = 'DROP' ] || { echo 'FAIL: IPv6 must be blocked even with the kill switch off' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_ks4_1.target)" = '<none>' ] || { echo 'FAIL: IPv4 kill-switch rule must be absent when fallback is allowed' >&2; exit 1; }

# --- teardown removes every app-owned section ---------------------------------
nordvpn_easy_remove_app_firewall_sections
[ "$(fwget firewall.nordvpn_vpn)" = '<none>' ] || { echo 'FAIL: vpn zone not removed on teardown' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_ks6_1.target)" = '<none>' ] || { echo 'FAIL: IPv6 rule not removed on teardown' >&2; exit 1; }
[ "$(fwget firewall.nordvpn_fwd_1.dest)" = '<none>' ] || { echo 'FAIL: forwarding not removed on teardown' >&2; exit 1; }

printf '%s\n' 'test-vpn-firewall.sh: ok'
