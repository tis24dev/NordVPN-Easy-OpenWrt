include $(TOPDIR)/rules.mk

NORDVPN_EASY_DEFAULT_VERSION:=0.1.0
NORDVPN_EASY_DEFAULT_RELEASE:=1
NORDVPN_EASY_PACKAGE_MAINTAINER?=tis24dev
NORDVPN_EASY_PACKAGE_URL?=https://github.com/tis24dev/NordVPN-Easy-OpenWrt

PKG_NAME:=nordvpn-easy
PKG_VERSION:=$(if $(NORDVPN_EASY_VERSION),$(NORDVPN_EASY_VERSION),$(NORDVPN_EASY_DEFAULT_VERSION))
PKG_RELEASE:=$(if $(NORDVPN_EASY_RELEASE),$(NORDVPN_EASY_RELEASE),$(NORDVPN_EASY_DEFAULT_RELEASE))
PKG_LICENSE:=Unlicense
PKG_MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/nordvpn-easy
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=NordVPN Easy backend service for OpenWrt
  DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools
  PKGARCH:=all
  URL:=$(NORDVPN_EASY_PACKAGE_URL)
  MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)
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
	$(INSTALL_DIR) $(1)/usr/libexec/nordvpn-easy/lib
	$(CP) ./files/usr/libexec/nordvpn-easy/lib/. $(1)/usr/libexec/nordvpn-easy/lib/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/nordvpn_easy $(1)/etc/config/nordvpn_easy
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/nordvpn-easy $(1)/etc/init.d/nordvpn-easy
endef

$(eval $(call BuildPackage,nordvpn-easy))
