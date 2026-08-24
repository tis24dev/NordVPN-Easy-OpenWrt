#!/usr/bin/env bash
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
# SC2018/SC2019: shellcheck suggests [:lower:]/[:upper:] over a-z/A-Z, but
# OpenWrt's busybox tr does not support POSIX character classes, so ranges are
# required.
SHELLCHECK_EXCLUDES='SC1091,SC2034,SC2119,SC2120,SC2154,SC2317,SC2329,SC3043,SC2015,SC2129,SC2018,SC2019'

JS_FILES=(
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/service.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-store.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-actions.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-polling.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-data.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-format.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/manager-ui.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/config.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/advanced.js"
	"$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/view/nordvpn-easy/diagnostics.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-service.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-manager-store.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-manager-actions.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-manager-ui.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-manager-polling.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-config.js"
	"$ROOT_DIR/tests/nordvpn-easy/test-advanced.js"
)

SH_FILES=(
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/rpcd/nordvpn.easy"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/public-ip-poll.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/migrate-config.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/public-ip.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/config-context.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/generation.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/journal.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/supervise.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/hooks.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/catalog.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/service-config.sh"
	"$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout"
	"$ROOT_DIR/tests/nordvpn-easy/test-config-context.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-schema.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-credentials-errors.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-catalog-fixtures.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-common-lock.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-run-phase.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-supervise.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-supervise-check-reap.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-hotplug-self-ifevent.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-supervise-reaper.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-common-temp.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-init-cron.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-init-run-core.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-init-transaction-lock.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-timing-log-cgi.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-init-start-soft-fail.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-rpcd.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-core-dispatch.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-uci-defaults-timeout.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-package-lockstep.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-package-postrm-restore.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-migrate-config.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-runtime.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-public-ip-cache.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-wireguard.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-vpn-firewall.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-routing-mode.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-ra-withdrawal.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-service-config.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-actions.sh"
	"$ROOT_DIR/tests/nordvpn-easy/test-configure-split.sh"
)

printf '%s\n' 'Checking LuCI JavaScript syntax'
for file in "${JS_FILES[@]}"; do
	node --check "$file"
done

printf '%s\n' 'Guarding against debug telemetry beacons in shipped LuCI JS'
RESOURCES_DIR="$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources"
if grep -REn 'localhost:7842|/ingest/|fetch\(.{0,3}http|agentDebugLog|AGENT_DEBUG_SESSION_ID' "$RESOURCES_DIR" --include='*.js'; then
	printf '%s\n' 'ERROR: debug telemetry beacon pattern found in shipped LuCI JS (matches above). The timing log must post same-origin only via request.post.' >&2
	exit 1
fi

printf '%s\n' 'Checking shell syntax'
# The shipped backend runs under OpenWrt's BusyBox ash, not the host sh (dash),
# so parse-check and run the shell suite under busybox ash too when available.
BUSYBOX="$(command -v busybox 2>/dev/null || true)"
for file in "${SH_FILES[@]}"; do
	sh -n "$file"
	[ -z "$BUSYBOX" ] || busybox ash -n "$file"
done
if [ -z "$BUSYBOX" ]; then
	printf '%s\n' 'WARNING: busybox not found; skipping BusyBox ash coverage (host sh only)' >&2
fi

printf '%s\n' 'Running fixture tests'
node "$ROOT_DIR/tests/nordvpn-easy/test-service.js"
node "$ROOT_DIR/tests/nordvpn-easy/test-manager-store.js"
node "$ROOT_DIR/tests/nordvpn-easy/test-manager-actions.js"
node "$ROOT_DIR/tests/nordvpn-easy/test-manager-ui.js"
node "$ROOT_DIR/tests/nordvpn-easy/test-manager-polling.js"
node "$ROOT_DIR/tests/nordvpn-easy/test-config.js"
node "$ROOT_DIR/tests/nordvpn-easy/test-advanced.js"
SHELL_TESTS=(
	test-config-context.sh
	test-schema.sh
	test-generation.sh
	test-journal.sh
	test-run-phase.sh
	test-supervise.sh
	test-supervise-check-reap.sh
	test-hotplug-self-ifevent.sh
	test-supervise-reaper.sh
	test-json-escape.sh
	test-credentials-errors.sh
	test-catalog-fixtures.sh
	test-common-lock.sh
	test-common-temp.sh
	test-diagnostics.sh
	test-healthcheck-blackhole.sh
	test-healthcheck-config-drift.sh
	test-degraded-state-log.sh
	test-init-cron.sh
	test-init-run-core.sh
	test-init-transaction-lock.sh
	test-timing-log-cgi.sh
	test-init-start-soft-fail.sh
	test-init-connect-hooks-order.sh
	test-init-crontab-block.sh
	test-rpcd.sh
	test-core-dispatch.sh
	test-uci-defaults-timeout.sh
	test-package-lockstep.sh
	test-package-postrm-restore.sh
	test-migrate-config.sh
	test-runtime.sh
	test-public-ip-cache.sh
	test-wireguard.sh
	test-vpn-firewall.sh
	test-routing-mode.sh
	test-ra-withdrawal.sh
	test-service-config.sh
	test-actions.sh
	test-configure-split.sh
	test-provision.sh
)
for t in "${SHELL_TESTS[@]}"; do
	sh "$ROOT_DIR/tests/nordvpn-easy/$t"
done
if [ -n "$BUSYBOX" ]; then
	printf '%s\n' 'Re-running shell fixture tests under BusyBox ash'
	for t in "${SHELL_TESTS[@]}"; do
		busybox ash "$ROOT_DIR/tests/nordvpn-easy/$t"
	done
fi

if command -v shellcheck >/dev/null 2>&1; then
	printf '%s\n' 'Running shellcheck'
	shellcheck -e "$SHELLCHECK_EXCLUDES" "${SH_FILES[@]}"
else
	printf '%s\n' 'shellcheck not found; skipping'
fi

printf '%s\n' 'All NordVPN Easy checks passed'
