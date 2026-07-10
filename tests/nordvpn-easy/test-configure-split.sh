#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# S7 increment 5a: nordvpn_easy_configure_vpn_interface was split into a
# _no_bringup body + a wrapper that re-composes the legacy sequence. The legacy log
# stream must stay byte-identical: the 'created successfully' log and the
# 'after-create' interface-state snapshot occur AFTER the ifup, and a bring-up
# FAILURE must emit NO 'created successfully' log (it short-circuits, as before).

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
ACTIONS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

LOGF="$TMP_DIR/log"

VPN_IF='wg0'
VPN_ADDR='10.5.0.2/32'
VPN_PORT='51820'
WAN_IF='wan'
VPN_DNS1=''
VPN_DNS2=''
PRIVATE_KEY='private-secret'
NORDVPN_EASY_PROVISION_FETCH_DONE='1'
BRINGUP_RC='0'

# shellcheck disable=SC1090
. "$ACTIONS_LIB"

# Mocks (defined AFTER sourcing so they override the real actions.sh helpers). Each
# ordered marker is appended to $LOGF so the relative order can be asserted.
log() { printf '%s\n' "$*" >> "$LOGF"; }
nordvpn_easy_log_vpn_interface_state() { printf 'STATE:%s\n' "${1:-}" >> "$LOGF"; }
nordvpn_easy_log_blocker() { :; }
nordvpn_easy_require_core_action_helpers() { return 0; }
nordvpn_easy_fetch_provision_prerequisites() { return 0; }
nordvpn_easy_ensure_vpn_firewall() { return 0; }
nordvpn_easy_build_wireguard_peer_section() { return 0; }
nordvpn_easy_fenced_uci_commit() { return 0; }
nordvpn_easy_harden_secret_config_perms() { return 0; }
uci() { return 0; }
nordvpn_easy_bring_up_vpn_interface() { printf 'BRINGUP\n' >> "$LOGF"; return "$BRINGUP_RC"; }

line_of() { grep -n -- "$1" "$LOGF" 2>/dev/null | head -n1 | cut -d: -f1; }

# --- success path: success log + after-create snapshot come AFTER the ifup -------
: > "$LOGF"
BRINGUP_RC='0'
ok_rc=0
nordvpn_easy_configure_vpn_interface || ok_rc=$?
[ "$ok_rc" -eq 0 ] || { printf '%s\n' 'FAIL: a successful configure must return 0' >&2; exit 1; }
bringup_ln="$(line_of 'BRINGUP')"
success_ln="$(line_of 'created successfully')"
aftercreate_ln="$(line_of 'STATE:after-create')"
[ -n "$bringup_ln" ] && [ -n "$success_ln" ] && [ -n "$aftercreate_ln" ] || {
	printf '%s\n' 'FAIL: expected BRINGUP, created-successfully and after-create markers' >&2
	exit 1
}
[ "$bringup_ln" -lt "$success_ln" ] || { printf '%s\n' "FAIL: 'created successfully' must be logged AFTER the ifup" >&2; exit 1; }
[ "$bringup_ln" -lt "$aftercreate_ln" ] || { printf '%s\n' "FAIL: the after-create state snapshot must be AFTER the ifup" >&2; exit 1; }
# before-create snapshot must precede the ifup (unchanged legacy ordering)
before_ln="$(line_of 'STATE:before-create')"
[ -n "$before_ln" ] && [ "$before_ln" -lt "$bringup_ln" ] || { printf '%s\n' 'FAIL: before-create snapshot must precede the ifup' >&2; exit 1; }

# --- failure path: bring-up fails -> NO 'created successfully', non-zero return ---
: > "$LOGF"
BRINGUP_RC='1'
fail_rc=0
nordvpn_easy_configure_vpn_interface || fail_rc=$?
[ "$fail_rc" -ne 0 ] || { printf '%s\n' 'FAIL: a failed bring-up must make configure return non-zero' >&2; exit 1; }
[ -n "$(line_of 'BRINGUP')" ] || { printf '%s\n' 'FAIL: bring-up must have been attempted' >&2; exit 1; }
[ -z "$(line_of 'created successfully')" ] || { printf '%s\n' "FAIL: a failed bring-up must NOT log 'created successfully'" >&2; exit 1; }
[ -z "$(line_of 'STATE:after-create')" ] || { printf '%s\n' 'FAIL: a failed bring-up must NOT emit the after-create snapshot' >&2; exit 1; }

# --- the _no_bringup body itself never brings the interface up ------------------
: > "$LOGF"
nbrc=0
nordvpn_easy_configure_vpn_interface_no_bringup || nbrc=$?
[ "$nbrc" -eq 0 ] || { printf '%s\n' 'FAIL: _no_bringup must succeed with the mocks' >&2; exit 1; }
[ -z "$(line_of 'BRINGUP')" ] || { printf '%s\n' 'FAIL: _no_bringup must NOT bring the interface up' >&2; exit 1; }
[ -z "$(line_of 'created successfully')" ] || { printf '%s\n' 'FAIL: _no_bringup must NOT log the wrapper success line' >&2; exit 1; }

printf '%s\n' 'test-configure-split.sh: ok'
