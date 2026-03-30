#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

JS_FILES="
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/service.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-data.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-format.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-ui.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-state.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/config.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/advanced.js
$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/diagnostics.js
"

SH_FILES="
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/catalog.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh
$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/service-config.sh
$ROOT_DIR/tests/nordvpn-easy/test-schema.sh
$ROOT_DIR/tests/nordvpn-easy/test-catalog-fixtures.sh
$ROOT_DIR/tests/nordvpn-easy/test-common-lock.sh
$ROOT_DIR/tests/nordvpn-easy/test-runtime.sh
$ROOT_DIR/tests/nordvpn-easy/test-service-config.sh
$ROOT_DIR/tests/nordvpn-easy/test-actions.sh
"

printf '%s\n' 'Checking LuCI JavaScript syntax'
for file in $JS_FILES; do
	node --check "$file"
done

printf '%s\n' 'Checking shell syntax'
for file in $SH_FILES; do
	sh -n "$file"
done

printf '%s\n' 'Running fixture tests'
sh "$ROOT_DIR/tests/nordvpn-easy/test-schema.sh"
sh "$ROOT_DIR/tests/nordvpn-easy/test-catalog-fixtures.sh"
sh "$ROOT_DIR/tests/nordvpn-easy/test-common-lock.sh"
sh "$ROOT_DIR/tests/nordvpn-easy/test-runtime.sh"
sh "$ROOT_DIR/tests/nordvpn-easy/test-service-config.sh"
sh "$ROOT_DIR/tests/nordvpn-easy/test-actions.sh"

if command -v shellcheck >/dev/null 2>&1; then
	printf '%s\n' 'Running shellcheck'
	shellcheck $SH_FILES
else
	printf '%s\n' 'shellcheck not found; skipping'
fi

printf '%s\n' 'All NordVPN Easy checks passed'
