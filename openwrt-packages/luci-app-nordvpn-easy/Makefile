include $(TOPDIR)/rules.mk

NORDVPN_EASY_DEFAULT_VERSION:=1.2.0
NORDVPN_EASY_DEFAULT_RELEASE:=1
NORDVPN_EASY_PACKAGE_MAINTAINER?=tis24dev
NORDVPN_EASY_PACKAGE_URL?=https://github.com/tis24dev/NordVPN-Easy-OpenWrt

PKG_NAME:=luci-app-nordvpn-easy
PKG_VERSION:=$(if $(NORDVPN_EASY_VERSION),$(NORDVPN_EASY_VERSION),$(NORDVPN_EASY_DEFAULT_VERSION))
PKG_RELEASE:=$(if $(NORDVPN_EASY_RELEASE),$(NORDVPN_EASY_RELEASE),$(NORDVPN_EASY_DEFAULT_RELEASE))
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)
LUCI_TITLE:=LuCI support for NordVPN Easy
LUCI_DESCRIPTION:=User-facing LuCI integration for NordVPN Easy on OpenWrt, bundled with the backend for manual upload installs
# +nordvpn-easy is intentionally NOT a dependency: the backend is bundled into
# this package's root/ tree by the release workflow, so this stays a single
# manual-upload package. Depending on the separate nordvpn-easy package would
# force it to co-install and conflict on the shared backend files. Switching to
# a feed model would mean dropping the bundling and adding the dependency.
# tests/nordvpn-easy/test-package-lockstep.sh enforces this omission.
LUCI_DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools +firewall4 +conntrack +luci-base +rpcd
LUCI_PKGARCH:=all
LUCI_URL:=$(NORDVPN_EASY_PACKAGE_URL)
LUCI_MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)

define Package/$(PKG_NAME)/postrm
#!/bin/sh

nordvpn_easy_backend_installed() {
	if command -v opkg >/dev/null 2>&1 && opkg status nordvpn-easy >/dev/null 2>&1; then
		return 0
	fi

	if command -v apk >/dev/null 2>&1 && apk info -e nordvpn-easy >/dev/null 2>&1; then
		return 0
	fi

	return 1
}

nordvpn_easy_restore_lan_ipv6_before_removal() {
	# FIX 1: MIRROR of the backend postrm's restore. The two packages carry mutual
	# early-exit guards (this luci-app postrm exits when the backend is still
	# installed, and the backend postrm exits when this luci-app is still installed),
	# so ONLY the last-removed package runs real cleanup. If the RA restore lived only
	# in the backend, removing the backend FIRST would early-exit before restoring;
	# later this luci-app postrm would nordvpn_easy_cleanup_files (rm -f
	# /etc/config/nordvpn_easy) with the snapshot still un-replayed, leaving LAN IPv6
	# permanently withdrawn. So we replay any RA snapshot here too, BEFORE cleanup
	# deletes the snapshot store. It is self-contained (no lib sourcing: opkg/apk
	# delete the package lib files before postrm runs), idempotent, and a pure no-op
	# when no snapshot exists, so running it in both postrms is safe -- whichever
	# package is removed last performs the restore before deleting the config.
	command -v uci >/dev/null 2>&1 || return 0

	restore_any=0
	for snap in $$(uci show nordvpn_easy 2>/dev/null | \
		sed -n 's/^nordvpn_easy\.\(nordvpn_ra6_snap_[A-Za-z0-9_]*\)=nordvpn_ra6_snapshot$$/\1/p'); do
		[ -n "$$snap" ] || continue
		dhcp_section="$$(uci -q get "nordvpn_easy.$${snap}.dhcp_section" 2>/dev/null || true)"
		# MIRROR of the backend postrm: restore by the stored VERBATIM .dhcp_section id
		# only. Only NAMED sections are ever snapshotted (the withdrawal skips anonymous
		# @dhcp[N] pools), and a named id is stable, so verbatim restore is exactly 1:1.
		# RESTORE-TIME GC of an orphan snapshot: if the stored section was deleted while
		# the VPN was up (its id no longer exists in the live dhcp config), do NOT
		# recreate a phantom section -- drop the snapshot and move on.
		if [ -z "$$dhcp_section" ] || ! uci -q get "dhcp.$${dhcp_section}" >/dev/null 2>&1; then
			uci -q delete "nordvpn_easy.$${snap}" 2>/dev/null || true
			continue
		fi
		for opt in ra dhcpv6 ra_default; do
			had="$$(uci -q get "nordvpn_easy.$${snap}.had_$${opt}" 2>/dev/null || printf '0')"
			if [ "$$had" = '1' ]; then
				orig="$$(uci -q get "nordvpn_easy.$${snap}.orig_$${opt}" 2>/dev/null || printf '')"
				uci set "dhcp.$${dhcp_section}.$${opt}=$${orig}" 2>/dev/null || {
					# Restore failed mid-transaction: revert the staged dhcp + snapshot
					# edits so nothing partial persists, and KEEP the snapshot on flash so
					# the next removal can retry (return 1 skips the cleanup below).
					uci -q revert dhcp 2>/dev/null || true
					uci -q revert nordvpn_easy 2>/dev/null || true
					return 1
				}
			else
				uci -q delete "dhcp.$${dhcp_section}.$${opt}" 2>/dev/null || true
			fi
		done
		uci -q delete "nordvpn_easy.$${snap}" 2>/dev/null || true
		restore_any=1
	done

	[ "$$restore_any" = '1' ] || return 0
	# The commit is the only real data-loss point: if it fails the dhcp restore is
	# NOT persisted, so revert and keep the snapshot (return 1 so the caller skips
	# nordvpn_easy_cleanup_files and the snapshot survives for a retry). A failed
	# odhcpd reload is post-commit (config already restored on flash), so it must
	# NOT block cleanup; the running daemon re-syncs on the next reload/boot.
	uci commit dhcp 2>/dev/null || {
		uci -q revert dhcp 2>/dev/null || true
		uci -q revert nordvpn_easy 2>/dev/null || true
		return 1
	}
	/etc/init.d/odhcpd reload >/dev/null 2>&1 || true
}

nordvpn_easy_cleanup_files() {
	rm -f /etc/config/nordvpn_easy /etc/config/nordvpn_easy-opkg
	rm -f /etc/cron.d/nordvpn-easy /etc/hotplug.d/iface/95-nordvpn-easy
	rm -f /var/etc/nordvpn-easy.conf
	rm -f /tmp/nordvpn.json \
		/tmp/nordvpn-easy-countries.json \
		/tmp/nordvpn-easy-countries.timestamp \
		/tmp/nordvpn-easy-servers.json \
		/tmp/nordvpn-easy-servers.timestamp
	rm -rf /tmp/nordvpn-easy.lock /tmp/run/nordvpn-easy
	rm -f /usr/share/nordvpn-easy/defaults/nordvpn_easy
	rm -f /usr/libexec/nordvpn-easy/migrate-config.sh
	rmdir /usr/share/nordvpn-easy/defaults /usr/share/nordvpn-easy 2>/dev/null || true
}

[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" = "1" ] && exit 0

case "$${1:-remove}" in
	remove|purge)
		if nordvpn_easy_backend_installed; then
			exit 0
		fi
		if nordvpn_easy_restore_lan_ipv6_before_removal; then
			nordvpn_easy_cleanup_files
		else
			printf '%s\n' 'nordvpn-easy: could not restore native LAN IPv6; keeping config for a later retry' >&2
			exit 1
		fi
		;;
esac

exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

MIGRATOR='/usr/libexec/nordvpn-easy/migrate-config.sh'
[ -x "$$MIGRATOR" ] || {
	printf "%s\n" "nordvpn-easy: missing executable config migrator $$MIGRATOR" >&2
	exit 1
}

MIGRATION_OUTPUT="$$( "$$MIGRATOR" 2>&1 )"
MIGRATION_STATUS=$$?
if [ "$$MIGRATION_STATUS" -ne 0 ]; then
	printf "%s\n" "nordvpn-easy: config migration failed with exit code $$MIGRATION_STATUS" >&2
	[ -n "$$MIGRATION_OUTPUT" ] && printf "%s\n" "$$MIGRATION_OUTPUT" >&2
	exit "$$MIGRATION_STATUS"
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/

RPCD_OUTPUT="$$(/etc/init.d/rpcd reload 2>&1)"
RPCD_STATUS=$$?
if [ "$$RPCD_STATUS" -ne 0 ]; then
	printf "%s\n" "nordvpn-easy: rpcd reload failed with exit code $$RPCD_STATUS" >&2
	[ -n "$$RPCD_OUTPUT" ] && printf "%s\n" "$$RPCD_OUTPUT" >&2
fi

	if [ "$${PKG_UPGRADE:-0}" != "1" ] && \
	   [ "$$(uci -q get nordvpn_easy.main.enabled 2>/dev/null)" = "1" ] && \
	   [ -n "$$(uci -q get nordvpn_easy.main.nordvpn_token 2>/dev/null)" ] && \
	   [ -x /etc/init.d/nordvpn-easy ]; then
		SERVICE_OUTPUT="$$(/etc/init.d/nordvpn-easy start 2>&1)"
		SERVICE_STATUS=$$?
		if [ "$$SERVICE_STATUS" -ne 0 ]; then
			printf "%s\n" "nordvpn-easy: service start failed with exit code $$SERVICE_STATUS" >&2
		fi
		[ -n "$$SERVICE_OUTPUT" ] && printf "%s\n" "$$SERVICE_OUTPUT" >&2
	fi

exit 0
endef

# Backend files are pre-placed into the luci-app root/ tree by the release
# workflow (.github/workflows/release.yml). luci.mk does not invoke a
# per-package Build/Prepare/$(PKG_NAME), so no such define is kept here: it was
# dead and had drifted from the workflow's authoritative file list.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
