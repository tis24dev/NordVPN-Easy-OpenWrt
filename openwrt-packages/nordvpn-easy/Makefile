include $(TOPDIR)/rules.mk

PKG_NAME:=nordvpn-easy
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Unlicense
PKG_MAINTAINER:=Codex
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/nordvpn-easy
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=NordVPN Easy backend service for OpenWrt
  DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools
  PKGARCH:=all
endef

define Package/nordvpn-easy/description
  NordVPN Easy provides the backend service, recovery logic and UCI integration
  used by the LuCI frontend package.
endef

define Package/nordvpn-easy/conffiles
/etc/config/nordvpn_easy
endef

define Build/Compile
endef

define Package/nordvpn-easy/install
	$(INSTALL_DIR) $(1)/usr/libexec/nordvpn-easy
	$(INSTALL_BIN) ./files/usr/libexec/nordvpn-easy/core.sh $(1)/usr/libexec/nordvpn-easy/core.sh
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/nordvpn_easy $(1)/etc/config/nordvpn_easy
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/nordvpn-easy $(1)/etc/init.d/nordvpn-easy
endef

$(eval $(call BuildPackage,nordvpn-easy))
