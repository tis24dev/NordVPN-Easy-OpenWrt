#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
BACKEND_MAKEFILE="$ROOT_DIR/openwrt-packages/nordvpn-easy/Makefile"
LUCI_MAKEFILE="$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/Makefile"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"
CORE_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
RPCD_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy"

assert_eq() {
	expected="$1"
	actual="$2"
	label="$3"

	if [ "$expected" != "$actual" ]; then
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "expected: $expected" >&2
		printf '%s\n' "actual:   $actual" >&2
		exit 1
	fi
}

extract_make_var() {
	var_name="$1"
	file_path="$2"

	sed -n "s/^${var_name}:=//p" "$file_path" | head -n 1
}

backend_version="$(extract_make_var 'NORDVPN_EASY_DEFAULT_VERSION' "$BACKEND_MAKEFILE")"
luci_version="$(extract_make_var 'NORDVPN_EASY_DEFAULT_VERSION' "$LUCI_MAKEFILE")"
backend_release="$(extract_make_var 'NORDVPN_EASY_DEFAULT_RELEASE' "$BACKEND_MAKEFILE")"
luci_release="$(extract_make_var 'NORDVPN_EASY_DEFAULT_RELEASE' "$LUCI_MAKEFILE")"
luci_init_source="\$(CURDIR)/../nordvpn-easy/files/etc/init.d/nordvpn-easy"
luci_core_source="\$(CURDIR)/../nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"
luci_lib_source="\$(CURDIR)/../nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/."
luci_rpcd_source="\$(CURDIR)/../nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy"
backend_rpcd_install="\$(INSTALL_BIN) ./files/usr/libexec/rpcd/nordvpn.easy \$(1)/usr/libexec/rpcd/nordvpn.easy"
release_preplace_lib="\${BACKEND_FILES}/usr/libexec/nordvpn-easy/lib/."
release_preplace_rpcd="\${BACKEND_FILES}/usr/libexec/rpcd/nordvpn.easy"
release_apk_rpcd="\${VERIFY_DIR}/usr/libexec/rpcd/nordvpn.easy"
release_ipk_rpcd="\${VERIFY_DIR}/data/usr/libexec/rpcd/nordvpn.easy"
release_apk_config_context="\${VERIFY_DIR}/usr/libexec/nordvpn-easy/lib/config-context.sh"
release_ipk_config_context="\${VERIFY_DIR}/data/usr/libexec/nordvpn-easy/lib/config-context.sh"
release_apk_runtime="\${VERIFY_DIR}/usr/libexec/nordvpn-easy/lib/runtime.sh"
release_ipk_runtime="\${VERIFY_DIR}/data/usr/libexec/nordvpn-easy/lib/runtime.sh"
release_apk_postrm='post-deinstall: |'
release_ipk_postrm="\${VERIFY_DIR}/control/postrm"
config_cleanup='rm -f /etc/config/nordvpn_easy /etc/config/nordvpn_easy-opkg'
backend_postrm='define Package/nordvpn-easy/postrm'
luci_postrm="define Package/\$(PKG_NAME)/postrm"

assert_eq "$backend_version" "$luci_version" 'backend and LuCI packages share default version'
assert_eq "$backend_release" "$luci_release" 'backend and LuCI packages share default release'

[ -f "$RPCD_SCRIPT" ] || {
	printf '%s\n' 'FAIL: backend rpcd plugin must exist in package source' >&2
	exit 1
}

[ -x "$RPCD_SCRIPT" ] || {
	printf '%s\n' 'FAIL: backend rpcd plugin must be executable in package source' >&2
	exit 1
}

grep -F "$luci_init_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must install init script from backend package source' >&2
	exit 1
}

grep -F "$luci_core_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must install core script from backend package source' >&2
	exit 1
}

grep -F "$luci_lib_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must copy backend library directory from backend package source' >&2
	exit 1
}

dollar_pattern='[$]'
grep -E "${dollar_pattern}${dollar_pattern}+lib" "$LUCI_MAKEFILE" >/dev/null 2>&1 && {
	printf '%s\n' 'FAIL: LuCI package must not use shell-variable library install loops; OpenWrt expands them differently across build phases' >&2
	exit 1
}

grep -F "$luci_rpcd_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must install rpcd plugin from backend package source' >&2
	exit 1
}

grep -F "$backend_rpcd_install" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must install rpcd plugin with executable permissions' >&2
	exit 1
}

grep -F "$release_preplace_lib" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: OPKG compatibility pre-place must copy backend library directory' >&2
	exit 1
}

grep -F "$release_preplace_rpcd" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: OPKG compatibility pre-place must copy rpcd plugin' >&2
	exit 1
}

for release_payload in \
	"$release_apk_rpcd" \
	"$release_ipk_rpcd" \
	"$release_apk_config_context" \
	"$release_ipk_config_context" \
	"$release_apk_runtime" \
	"$release_ipk_runtime" \
	"$release_apk_postrm" \
	"$release_ipk_postrm"
do
	grep -F "$release_payload" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: release workflow must verify payload file: $release_payload" >&2
		exit 1
	}
done

backend_cleanup_count="$(grep -F -c "$config_cleanup" "$BACKEND_MAKEFILE" || true)"
luci_cleanup_count="$(grep -F -c "$config_cleanup" "$LUCI_MAKEFILE" || true)"

[ "$backend_cleanup_count" -ge 2 ] || {
	printf '%s\n' 'FAIL: backend package must remove UCI config in both prerm and postrm' >&2
	exit 1
}

[ "$luci_cleanup_count" -ge 2 ] || {
	printf '%s\n' 'FAIL: LuCI package must remove UCI config in both prerm and postrm' >&2
	exit 1
}

grep -F "$backend_postrm" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must define postrm cleanup for opkg-preserved conffiles' >&2
	exit 1
}

grep -F "$luci_postrm" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must define postrm cleanup for opkg-preserved conffiles' >&2
	exit 1
}

schema_payload="$(sed -n "s/^NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE=\"\${NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE:-\\(.*\\)}\"/\\1/p" "$SCHEMA_LIB" | head -n 1)"
core_payload="$(sed -n "s/^CORE_BACKEND_PAYLOAD_SIGNATURE='\\(.*\\)'/\\1/p" "$CORE_SCRIPT" | head -n 1)"
init_payload="$(sed -n "s/^SERVICE_BACKEND_PAYLOAD_SIGNATURE='\\(.*\\)'/\\1/p" "$INIT_SCRIPT" | head -n 1)"

assert_eq "$schema_payload" "$core_payload" 'schema and core share payload signature'
assert_eq "$schema_payload" "$init_payload" 'schema and init share payload signature'

printf '%s\n' 'test-package-lockstep.sh: ok'
