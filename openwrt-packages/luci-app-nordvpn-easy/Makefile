include $(TOPDIR)/rules.mk

NORDVPN_EASY_DEFAULT_VERSION:=0.1.3
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
LUCI_DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools +luci-base
LUCI_PKGARCH:=all
LUCI_URL:=$(NORDVPN_EASY_PACKAGE_URL)
LUCI_MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)

define Package/$(PKG_NAME)/conffiles
/etc/config/nordvpn_easy
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

if uci -q get nordvpn_easy.main.nordvpn_basic_token >/dev/null 2>&1; then
	uci -q delete nordvpn_easy.main.nordvpn_basic_token
	uci -q commit nordvpn_easy
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

define Build/Prepare/$(PKG_NAME)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/etc/config
	$(INSTALL_CONF) $(CURDIR)/../nordvpn-easy/files/etc/config/nordvpn_easy $(PKG_BUILD_DIR)/root/etc/config/nordvpn_easy
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/../nordvpn-easy/files/etc/init.d/nordvpn-easy $(PKG_BUILD_DIR)/root/etc/init.d/nordvpn-easy
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy
	$(INSTALL_BIN) $(CURDIR)/../nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy/core.sh
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy/lib
	for lib in $(CURDIR)/../nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/*.sh; do \
		$(INSTALL_DATA) "$$lib" $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy/lib/; \
	done
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
