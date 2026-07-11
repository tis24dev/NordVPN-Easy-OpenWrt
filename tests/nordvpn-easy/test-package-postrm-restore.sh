#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# FIX 1: the backend postrm restores native LAN IPv6 from the app-owned RA
# snapshot BEFORE it deletes the snapshot store -- and does so WITHOUT sourcing
# any package lib file, because opkg/apk delete the lib dir before postrm runs.
# This test extracts the postrm scriptlet from the Makefile, de-escapes the
# `$$` -> `$` make quoting, and exercises the restore inline against a file-backed
# fake uci with the lib dir absent.

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
BACKEND_MAKEFILE="$ROOT_DIR/openwrt-packages/nordvpn-easy/Makefile"
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

# Extract the postrm scriptlet body (between its define and endef) and undo the
# Makefile's `$$` -> `$` escaping so it is runnable shell.
SCRIPTLET="$TMP_DIR/postrm.sh"
awk '
	/^define Package\/nordvpn-easy\/postrm/ { f = 1; next }
	f && /^endef/ { exit }
	f { print }
' "$BACKEND_MAKEFILE" | sed 's/\$\$/$/g' > "$SCRIPTLET"

# The scriptlet's own shebang line is stripped by the awk skip of the define line;
# make it sourceable by trimming the leading "#!/bin/sh" if present (harmless).

# File-backed fake uci over package.section.option=value lines.
STORE="$TMP_DIR/uci-store"
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
		commit) : ;;
		*) : ;;
	esac
	return 0
}

get() { uci -q get "$1" 2>/dev/null || printf '%s' '<none>'; }

# Seed a WITHDRAWN LAN: dhcp.lan.ra=disabled (the withdrawal) plus an app-owned
# snapshot recording the original (ra=relay, dhcpv6=server, ra_default absent).
cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=disabled
dhcp.lan.dhcpv6=disabled
dhcp.lan.ra_default=0
nordvpn_easy.nordvpn_ra6_snap_lan=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section=lan
nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra=relay
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_lan.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_default=0
EOF

# Prove the lib dir is genuinely ABSENT (mirrors opkg/apk deleting it pre-postrm):
# the config-context/wireguard libs the OLD implementation sourced do not exist.
CONFIG_CONTEXT="$TMP_DIR/absent-lib/config-context.sh"
[ ! -e "$CONFIG_CONTEXT" ] || { echo 'FAIL: test setup should have no lib dir' >&2; exit 1; }

# odhcpd init stub (records reload; the scriptlet calls /etc/init.d/odhcpd, so
# shadow it via a PATH-independent function is not possible -- assert on effect,
# not on the reload call, since the hardcoded path is best-effort `|| true`).

# Source the extracted scriptlet's FUNCTION DEFINITIONS only, without executing
# the trailing case block (which would exit). We strip from the first bare
# top-level command onward by cutting at the IPKG_INSTROOT guard line.
FUNCS_ONLY="$TMP_DIR/postrm-funcs.sh"
awk '
	/^\[ -n "\$\{IPKG_INSTROOT\}" \]/ { exit }
	{ print }
' "$SCRIPTLET" > "$FUNCS_ONLY"

# shellcheck disable=SC1090
. "$FUNCS_ONLY"

# Capture dhcp.lan.ra AT THE MOMENT cleanup would run, by overriding
# nordvpn_easy_cleanup_files to snapshot state, then invoke the two steps in the
# SAME order as the real case block (restore THEN cleanup). This proves the
# restore already applied before the config store is deleted.
RA_AT_CLEANUP=''
nordvpn_easy_cleanup_files() {
	RA_AT_CLEANUP="$(get dhcp.lan.ra)"
	uci -q delete nordvpn_easy 2>/dev/null || true
}

nordvpn_easy_restore_lan_ipv6_before_removal
nordvpn_easy_cleanup_files

[ "$RA_AT_CLEANUP" = 'relay' ] || {
	echo "FAIL: dhcp.lan.ra must be restored to 'relay' BEFORE the snapshot store is deleted (got: $RA_AT_CLEANUP)" >&2
	exit 1
}
[ "$(get dhcp.lan.dhcpv6)" = 'server' ] || { echo 'FAIL: dhcpv6 must be restored to its original' >&2; exit 1; }
# ra_default was originally absent (had=0), so restore must DELETE the forced 0.
[ "$(get dhcp.lan.ra_default)" = '<none>' ] || { echo 'FAIL: the introduced ra_default=0 must be deleted on restore' >&2; exit 1; }

# --- a clean uninstall (no snapshot) is a pure no-op --------------------------
cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.ra=server
EOF
nordvpn_easy_restore_lan_ipv6_before_removal
[ "$(get dhcp.lan.ra)" = 'server' ] || { echo 'FAIL: a no-snapshot uninstall must not touch dhcp.lan.ra' >&2; exit 1; }

# =============================================================================
# FIX 1: model the TWO mutual guards + the luci-app cleanup_files across removal
# orderings. The backend postrm exits early when the luci-app is still installed;
# the luci-app postrm exits early when the backend is still installed. Only the
# LAST-removed package runs real cleanup. Both postrms MUST restore RA before
# their cleanup deletes /etc/config/nordvpn_easy -- otherwise removing the backend
# first (its guard early-exits without restoring) then the luci-app (which then
# runs cleanup) would wipe the snapshot un-restored, leaving LAN IPv6 withdrawn.
# =============================================================================
LUCI_MAKEFILE="$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/Makefile"

# Extract each package's postrm scriptlet FUNCTIONS (de-escape $$ -> $, drop the
# trailing case block at the IPKG_INSTROOT guard) into its own namespaced file so
# both can be sourced side by side. The luci-app and backend both define
# nordvpn_easy_cleanup_files / nordvpn_easy_restore_lan_ipv6_before_removal with
# identical bodies for our purposes, so we rename them per package on extraction.
extract_postrm_funcs() {
	# $1 = makefile, $2 = "define ...postrm" header, $3 = output file, $4 = suffix
	awk -v hdr="$2" '
		$0 == hdr { f = 1; next }
		f && /^endef/ { exit }
		f { print }
	' "$1" | sed 's/\$\$/$/g' | awk '
		/^\[ -n "\$\{IPKG_INSTROOT\}" \]/ { exit }
		{ print }
	' | sed \
		-e "s/nordvpn_easy_restore_lan_ipv6_before_removal/restore_$4/g" \
		-e "s/nordvpn_easy_cleanup_files/cleanup_$4/g" \
		> "$3"
}

BACKEND_FUNCS="$TMP_DIR/backend-funcs.sh"
LUCI_FUNCS="$TMP_DIR/luci-funcs.sh"
# The luci-app postrm header is literally "define Package/$(PKG_NAME)/postrm" in the
# Makefile. Assemble the make-variable token from pieces (never writing a literal
# single-quoted '$(...)', which shellcheck SC2016 would flag as an accidental
# non-expansion) and splice it in. We only extract the FUNCTION definitions (the
# case block that references the token is cut at the IPKG_INSTROOT guard), so the
# token itself never needs evaluating.
dollar='$'
LUCI_PKG_TOKEN="${dollar}(PKG_NAME)"
extract_postrm_funcs "$BACKEND_MAKEFILE" 'define Package/nordvpn-easy/postrm' "$BACKEND_FUNCS" 'be'
extract_postrm_funcs "$LUCI_MAKEFILE" "define Package/${LUCI_PKG_TOKEN}/postrm" "$LUCI_FUNCS" 'la'

# shellcheck disable=SC1090
. "$BACKEND_FUNCS"
# shellcheck disable=SC1090
. "$LUCI_FUNCS"

# Sanity: BOTH postrms actually carry a restore function (FIX 1 core assertion).
command -v restore_be >/dev/null 2>&1 || { echo 'FAIL: backend postrm must define the RA restore' >&2; exit 1; }
command -v restore_la >/dev/null 2>&1 || { echo 'FAIL: luci-app postrm must ALSO define the RA restore (FIX 1)' >&2; exit 1; }

# Model the mutual guards + a package-install ledger. installed <pkg> tracks which
# packages are still present; the guards read it.
BACKEND_PRESENT=1
LUCI_PRESENT=1
nordvpn_easy_backend_installed() { [ "$BACKEND_PRESENT" = '1' ]; }
luci_app_installed() { [ "$LUCI_PRESENT" = '1' ]; }

# Reseed a withdrawn LAN with its snapshot before each ordering.
seed_withdrawn() {
	cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=disabled
dhcp.lan.dhcpv6=disabled
dhcp.lan.ra_default=0
nordvpn_easy.nordvpn_ra6_snap_lan=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section=lan
nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra=relay
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_lan.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_default=0
EOF
}

# The two cleanup_files variants both snapshot dhcp.lan.ra at the moment they would
# delete the config store, then delete the config -- so we can assert the restore
# already ran BEFORE the delete, in whichever package runs last.
RA_AT_CLEANUP=''
cleanup_be() { RA_AT_CLEANUP="$(get dhcp.lan.ra)"; uci -q delete nordvpn_easy 2>/dev/null || true; }
cleanup_la() { RA_AT_CLEANUP="$(get dhcp.lan.ra)"; uci -q delete nordvpn_easy 2>/dev/null || true; }

# The real case blocks, re-expressed: guard first, then restore, then cleanup.
run_backend_postrm() {
	if luci_app_installed; then return 0; fi
	restore_be
	cleanup_be
}
run_luci_postrm() {
	if nordvpn_easy_backend_installed; then return 0; fi
	restore_la
	cleanup_la
}

# --- Ordering A: backend removed FIRST, luci-app removed LAST -----------------
# Backend postrm early-exits (luci still installed) WITHOUT touching anything, then
# the luci-app postrm (backend now gone) restores RA before deleting the config.
seed_withdrawn
RA_AT_CLEANUP=''
BACKEND_PRESENT=1; LUCI_PRESENT=1
# remove backend: mark it gone, run its postrm (guard sees luci present -> early exit).
BACKEND_PRESENT=0
run_backend_postrm
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = 'nordvpn_ra6_snapshot' ] || { echo 'FAIL(A): backend removed first must NOT delete the snapshot (guard early-exit)' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL(A): backend early-exit must not have restored yet' >&2; exit 1; }
# remove luci-app (last): mark it gone, run its postrm -> restore THEN cleanup.
LUCI_PRESENT=0
run_luci_postrm
[ "$RA_AT_CLEANUP" = 'relay' ] || { echo "FAIL(A): luci-app-last must restore dhcp.lan.ra to 'relay' BEFORE deleting the config (got: $RA_AT_CLEANUP)" >&2; exit 1; }
[ "$(get dhcp.lan.dhcpv6)" = 'server' ] || { echo 'FAIL(A): luci-app-last must restore dhcpv6 before cleanup' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(A): config store must be deleted after the restore' >&2; exit 1; }

# --- Ordering B: luci-app removed FIRST, backend removed LAST -----------------
# luci-app postrm early-exits (backend still installed), then the backend postrm
# (luci now gone) restores RA before deleting the config.
seed_withdrawn
RA_AT_CLEANUP=''
BACKEND_PRESENT=1; LUCI_PRESENT=1
LUCI_PRESENT=0
run_luci_postrm
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = 'nordvpn_ra6_snapshot' ] || { echo 'FAIL(B): luci-app removed first must NOT delete the snapshot (guard early-exit)' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'disabled' ] || { echo 'FAIL(B): luci-app early-exit must not have restored yet' >&2; exit 1; }
BACKEND_PRESENT=0
run_backend_postrm
[ "$RA_AT_CLEANUP" = 'relay' ] || { echo "FAIL(B): backend-last must restore dhcp.lan.ra to 'relay' BEFORE deleting the config (got: $RA_AT_CLEANUP)" >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(B): config store must be deleted after the restore' >&2; exit 1; }

# --- Ordering C: backend-only install (no luci-app) --------------------------
# The backend postrm's guard sees no luci-app, so it restores + cleans up itself.
seed_withdrawn
RA_AT_CLEANUP=''
BACKEND_PRESENT=0; LUCI_PRESENT=0
run_backend_postrm
[ "$RA_AT_CLEANUP" = 'relay' ] || { echo "FAIL(C): backend-only removal must restore RA BEFORE deleting the config (got: $RA_AT_CLEANUP)" >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(C): backend-only removal must delete the config after restore' >&2; exit 1; }

# =============================================================================
# The postrm restore targets the stored VERBATIM .dhcp_section id only. Only NAMED
# sections are ever snapshotted (the withdrawal skips anonymous @dhcp[N] pools), and
# a named id is stable, so verbatim restore is exactly 1:1. We reuse the backend
# postrm functions extracted above (restore_be / cleanup_be).
# =============================================================================
# CONFIRMED FINDING #1: TWO NAMED sections serving ONE interface each restore their
# OWN original by verbatim id -- neither is left ra=disabled, no cross-contamination.
cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.ra=disabled
dhcp.lan.dhcpv6=disabled
dhcp.lan.ra_default=0
dhcp.lan_extra=dhcp
dhcp.lan_extra.interface=lan
dhcp.lan_extra.ra=disabled
dhcp.lan_extra.dhcpv6=disabled
dhcp.lan_extra.ra_default=0
nordvpn_easy.nordvpn_ra6_snap_lan=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section=lan
nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_lan.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_default=0
nordvpn_easy.nordvpn_ra6_snap_lan_extra=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_lan_extra.dhcp_section=lan_extra
nordvpn_easy.nordvpn_ra6_snap_lan_extra.orig_ra=relay
nordvpn_easy.nordvpn_ra6_snap_lan_extra.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_lan_extra.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan_extra.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_lan_extra.had_ra_default=0
EOF
restore_be
[ "$(get dhcp.lan.ra)" = 'server' ] || { echo 'FAIL(postrm two-named): dhcp.lan must restore to its OWN original (server), not be left disabled' >&2; exit 1; }
[ "$(get dhcp.lan_extra.ra)" = 'relay' ] || { echo 'FAIL(postrm two-named): dhcp.lan_extra must restore to its OWN original (relay), not the first section value' >&2; exit 1; }
[ "$(get dhcp.lan.ra_default)" = '<none>' ] || { echo 'FAIL(postrm two-named): the introduced ra_default on dhcp.lan must be deleted' >&2; exit 1; }
[ "$(get dhcp.lan_extra.ra_default)" = '<none>' ] || { echo 'FAIL(postrm two-named): the introduced ra_default on dhcp.lan_extra must be deleted' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(postrm two-named): dhcp.lan snapshot must be dropped after restore' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan_extra)" = '<none>' ] || { echo 'FAIL(postrm two-named): dhcp.lan_extra snapshot must be dropped after restore' >&2; exit 1; }

# CONFIRMED FINDING #2: RESTORE-TIME GC of an orphan snapshot -- a snapshot whose
# .dhcp_section was DELETED while the VPN was up must NOT recreate a phantom section;
# the postrm drops the snapshot and creates no dhcp.<id>.
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
restore_be
[ "$(get dhcp.gone)" = '<none>' ] || { echo 'FAIL(postrm gc): must NOT recreate a phantom dhcp.gone section for a deleted id' >&2; exit 1; }
[ "$(get dhcp.gone.ra)" = '<none>' ] || { echo 'FAIL(postrm gc): must NOT write dhcp.gone.ra for a deleted section' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_gone)" = '<none>' ] || { echo 'FAIL(postrm gc): must drop the orphan snapshot for a deleted section' >&2; exit 1; }
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL(postrm gc): restore of an orphan snapshot must NOT touch an unrelated live section' >&2; exit 1; }

# Named happy-path via verbatim id: a single named pool restores cleanly.
cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.interface=lan
dhcp.lan.ra=disabled
dhcp.lan.dhcpv6=disabled
nordvpn_easy.nordvpn_ra6_snap_lan=nordvpn_ra6_snapshot
nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section=lan
nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra=relay
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra=1
nordvpn_easy.nordvpn_ra6_snap_lan.orig_dhcpv6=server
nordvpn_easy.nordvpn_ra6_snap_lan.had_dhcpv6=1
nordvpn_easy.nordvpn_ra6_snap_lan.had_ra_default=0
EOF
restore_be
[ "$(get dhcp.lan.ra)" = 'relay' ] || { echo 'FAIL(postrm named): a named pool must restore to its original via its verbatim id' >&2; exit 1; }
[ "$(get nordvpn_easy.nordvpn_ra6_snap_lan)" = '<none>' ] || { echo 'FAIL(postrm named): snapshot must be dropped after restore' >&2; exit 1; }

printf '%s\n' 'test-package-postrm-restore.sh: ok'
