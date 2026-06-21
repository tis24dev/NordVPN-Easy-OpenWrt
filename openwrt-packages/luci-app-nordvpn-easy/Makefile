include $(TOPDIR)/rules.mk

NORDVPN_EASY_DEFAULT_VERSION:=0.9.0
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
LUCI_DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools +firewall4 +luci-base +rpcd
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
		nordvpn_easy_cleanup_files
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
