include $(TOPDIR)/rules.mk

NORDVPN_EASY_DEFAULT_VERSION:=1.2.0
NORDVPN_EASY_DEFAULT_RELEASE:=1
NORDVPN_EASY_PACKAGE_MAINTAINER?=tis24dev
NORDVPN_EASY_PACKAGE_URL?=https://github.com/tis24dev/NordVPN-Easy-OpenWrt

PKG_NAME:=nordvpn-easy
PKG_VERSION:=$(if $(NORDVPN_EASY_VERSION),$(NORDVPN_EASY_VERSION),$(NORDVPN_EASY_DEFAULT_VERSION))
PKG_RELEASE:=$(if $(NORDVPN_EASY_RELEASE),$(NORDVPN_EASY_RELEASE),$(NORDVPN_EASY_DEFAULT_RELEASE))
PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/nordvpn-easy
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=NordVPN Easy backend service for OpenWrt
  DEPENDS:=+ca-certificates +curl +jq +kmod-wireguard +wireguard-tools +firewall4 +conntrack +rpcd
  PKGARCH:=all
  URL:=$(NORDVPN_EASY_PACKAGE_URL)
  MAINTAINER:=$(NORDVPN_EASY_PACKAGE_MAINTAINER)
endef

define Package/nordvpn-easy/description
  NordVPN Easy provides the backend service, recovery logic and UCI integration
  used by the LuCI frontend package.
endef

define Package/nordvpn-easy/postrm
#!/bin/sh

luci_app_installed() {
	if command -v opkg >/dev/null 2>&1 && opkg status luci-app-nordvpn-easy >/dev/null 2>&1; then
		return 0
	fi

	if command -v apk >/dev/null 2>&1 && apk info -e luci-app-nordvpn-easy >/dev/null 2>&1; then
		return 0
	fi

	return 1
}

nordvpn_easy_restore_lan_ipv6_before_removal() {
	# Replay any native-LAN-IPv6 RA snapshot BEFORE nordvpn_easy_cleanup_files
	# deletes the snapshot store (/etc/config/nordvpn_easy). If the VPN is connected
	# at uninstall the RA withdrawal is still active; without this the LAN would be
	# left with IPv6 permanently withdrawn (no snapshot left to restore from).
	#
	# SELF-CONTAINED: opkg/apk delete the package lib files (config-context.sh and
	# wireguard.sh) BEFORE postrm runs, so sourcing them here would silently no-op
	# and the withdrawal would persist while cleanup drops the only snapshot. We
	# therefore restore inline with plain `uci` (always present), reading each
	# nordvpn_ra6_snapshot section's .dhcp_section value and restoring the tracked
	# options directly. Idempotent + tolerant of "no snapshots" (pure no-op), so a
	# clean uninstall is unaffected. No lib dependency, no prerm (the lockstep test
	# forbids a backend prerm).
	command -v uci >/dev/null 2>&1 || return 0

	restore_any=0
	for snap in $$(uci show nordvpn_easy 2>/dev/null | \
		sed -n 's/^nordvpn_easy\.\(nordvpn_ra6_snap_[A-Za-z0-9_]*\)=nordvpn_ra6_snapshot$$/\1/p'); do
		[ -n "$$snap" ] || continue
		dhcp_section="$$(uci -q get "nordvpn_easy.$${snap}.dhcp_section" 2>/dev/null || true)"
		# Restore by the stored VERBATIM .dhcp_section id only. Only NAMED sections are
		# ever snapshotted (the withdrawal skips anonymous @dhcp[N] pools), and a named
		# id is stable, so verbatim restore is exactly 1:1: two named sections serving
		# one interface each restore their own id, and a stale snapshot can never
		# re-resolve onto an unrelated live section.
		#
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
				uci set "dhcp.$${dhcp_section}.$${opt}=$${orig}" 2>/dev/null || true
			else
				uci -q delete "dhcp.$${dhcp_section}.$${opt}" 2>/dev/null || true
			fi
		done
		uci -q delete "nordvpn_easy.$${snap}" 2>/dev/null || true
		restore_any=1
	done

	[ "$$restore_any" = '1' ] || return 0
	uci commit dhcp 2>/dev/null || true
	/etc/init.d/odhcpd reload >/dev/null 2>&1 || true
}

nordvpn_easy_cleanup_files() {
	rm -f /etc/config/nordvpn_easy /etc/config/nordvpn_easy-opkg
	rm -f /etc/cron.d/nordvpn-easy /etc/hotplug.d/iface/95-nordvpn-easy
	if [ -f /etc/crontabs/root ]; then
		crontab_begins="$$(grep -Fxc '# BEGIN nordvpn-easy' /etc/crontabs/root 2>/dev/null)"; \
		crontab_ends="$$(grep -Fxc '# END nordvpn-easy' /etc/crontabs/root 2>/dev/null)"; \
		if [ "$${crontab_begins:-0}" = "$${crontab_ends:-0}" ] && \
			crontab_tmp="$$(mktemp /etc/crontabs/.root.XXXXXX 2>/dev/null)"; then \
			awk '
				$$0 == "# BEGIN nordvpn-easy" { skip = 1; next }
				$$0 == "# END nordvpn-easy" { skip = 0; next }
				!skip { print }
			' /etc/crontabs/root > "$$crontab_tmp" && mv "$$crontab_tmp" /etc/crontabs/root || rm -f "$$crontab_tmp"; \
		fi
		/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
	fi
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
		if luci_app_installed; then
			exit 0
		fi
		nordvpn_easy_restore_lan_ipv6_before_removal
		nordvpn_easy_cleanup_files
		;;
esac

exit 0
endef

define Package/nordvpn-easy/postinst
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

# /etc/config/nordvpn_easy holds the NordVPN account token; keep it root-only.
chmod 0600 /etc/config/nordvpn_easy 2>/dev/null || true

# S7 tag 9: this package ships the rpcd plugin (usr/libexec/rpcd/nordvpn.easy), so a
# backend-only upgrade that adds the async `apply` method needs rpcd reloaded to
# register it (the luci-app postinst reloads too, but it may not be upgraded in lockstep).
RPCD_OUTPUT="$$(/etc/init.d/rpcd reload 2>&1)"
RPCD_STATUS=$$?
if [ "$$RPCD_STATUS" -ne 0 ]; then
	printf "%s\n" "nordvpn-easy: rpcd reload failed with exit code $$RPCD_STATUS" >&2
	[ -n "$$RPCD_OUTPUT" ] && printf "%s\n" "$$RPCD_OUTPUT" >&2
fi

exit 0
endef

define Build/Compile
endef

define Package/nordvpn-easy/install
	$(INSTALL_DIR) $(1)/usr/libexec/nordvpn-easy
	$(INSTALL_BIN) ./files/usr/libexec/nordvpn-easy/core.sh $(1)/usr/libexec/nordvpn-easy/core.sh
	$(INSTALL_BIN) ./files/usr/libexec/nordvpn-easy/public-ip-poll.sh $(1)/usr/libexec/nordvpn-easy/public-ip-poll.sh
	$(INSTALL_BIN) ./files/usr/libexec/nordvpn-easy/migrate-config.sh $(1)/usr/libexec/nordvpn-easy/migrate-config.sh
	$(INSTALL_DIR) $(1)/usr/libexec/nordvpn-easy/lib
	$(CP) ./files/usr/libexec/nordvpn-easy/lib/. $(1)/usr/libexec/nordvpn-easy/lib/
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/nordvpn.easy $(1)/usr/libexec/rpcd/nordvpn.easy
	$(INSTALL_DIR) $(1)/usr/share/nordvpn-easy/defaults
	$(INSTALL_CONF) ./files/usr/share/nordvpn-easy/defaults/nordvpn_easy $(1)/usr/share/nordvpn-easy/defaults/nordvpn_easy
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/nordvpn-easy $(1)/etc/init.d/nordvpn-easy
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout $(1)/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout
endef

$(eval $(call BuildPackage,nordvpn-easy))
