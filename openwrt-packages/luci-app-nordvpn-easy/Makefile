include $(TOPDIR)/rules.mk

PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Unlicense
PKG_MAINTAINER:=Codex
LUCI_TITLE:=LuCI support for NordVPN Easy
LUCI_DESCRIPTION:=User-facing LuCI integration for NordVPN Easy on OpenWrt, bundled with the backend for manual upload installs
LUCI_DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools +luci-base
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Build/Prepare/luci-app-nordvpn-easy
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/etc/config
	$(INSTALL_CONF) $(CURDIR)/../nordvpn-easy/files/etc/config/nordvpn_easy $(PKG_BUILD_DIR)/root/etc/config/nordvpn_easy
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/../nordvpn-easy/files/etc/init.d/nordvpn-easy $(PKG_BUILD_DIR)/root/etc/init.d/nordvpn-easy
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy
	$(INSTALL_BIN) $(CURDIR)/../nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy/core.sh
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/nordvpn_easy
endef

# call BuildPackage - OpenWrt buildroot signature
