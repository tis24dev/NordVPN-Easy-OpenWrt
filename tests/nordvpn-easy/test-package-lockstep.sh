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
MIGRATOR_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/migrate-config.sh"
CONFIG_TEMPLATE="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/share/nordvpn-easy/defaults/nordvpn_easy"

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

assert_block_contains() {
	block_start="$1"
	expected="$2"
	file_path="$3"
	label="$4"

	awk -v block_start="$block_start" -v expected="$expected" '
		$0 == block_start {
			in_block = 1
		}

		in_block && index($0, expected) {
			found = 1
		}

		in_block && $0 == "endef" {
			exit
		}

		END {
			exit(found ? 0 : 1)
		}
	' "$file_path" || {
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "missing from block $block_start: $expected" >&2
		exit 1
	}
}

extract_make_var() {
	var_name="$1"
	file_path="$2"

	sed -n "s/^${var_name}:=//p" "$file_path" | head -n 1
}

# Collect the ${BACKEND_FILES}/... sources a single release job pre-places into
# the luci-app tree. Job keys sit at a 2-space indent under jobs:, so the body
# runs from "  <job>:" to the next 2-space key.
job_preplace_sources() {
	awk -v job="  $1:" '
		$0 == job { injob = 1; next }
		injob && /^  [A-Za-z]/ { exit }
		injob {
			s = $0
			while (match(s, "\\$\\{BACKEND_FILES\\}/[A-Za-z0-9._/-]+")) {
				print substr(s, RSTART, RLENGTH)
				s = substr(s, RSTART + RLENGTH)
			}
		}
	' "$2" | sort -u
}

backend_version="$(extract_make_var 'NORDVPN_EASY_DEFAULT_VERSION' "$BACKEND_MAKEFILE")"
luci_version="$(extract_make_var 'NORDVPN_EASY_DEFAULT_VERSION' "$LUCI_MAKEFILE")"
backend_release="$(extract_make_var 'NORDVPN_EASY_DEFAULT_RELEASE' "$BACKEND_MAKEFILE")"
luci_release="$(extract_make_var 'NORDVPN_EASY_DEFAULT_RELEASE' "$LUCI_MAKEFILE")"
release_preplace_publicip="\${BACKEND_FILES}/usr/libexec/nordvpn-easy/public-ip-poll.sh"
release_preplace_ucidefaults="\${BACKEND_FILES}/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout"
release_apk_publicip="\${VERIFY_DIR}/usr/libexec/nordvpn-easy/public-ip-poll.sh"
release_ipk_publicip="\${VERIFY_DIR}/data/usr/libexec/nordvpn-easy/public-ip-poll.sh"
release_apk_ucidefaults="\${VERIFY_DIR}/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout"
release_ipk_ucidefaults="\${VERIFY_DIR}/data/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout"
backend_rpcd_install="\$(INSTALL_BIN) ./files/usr/libexec/rpcd/nordvpn.easy \$(1)/usr/libexec/rpcd/nordvpn.easy"
backend_migrator_install="\$(INSTALL_BIN) ./files/usr/libexec/nordvpn-easy/migrate-config.sh \$(1)/usr/libexec/nordvpn-easy/migrate-config.sh"
backend_template_install="\$(INSTALL_CONF) ./files/usr/share/nordvpn-easy/defaults/nordvpn_easy \$(1)/usr/share/nordvpn-easy/defaults/nordvpn_easy"
release_preplace_lib="\${BACKEND_FILES}/usr/libexec/nordvpn-easy/lib/."
release_preplace_rpcd="\${BACKEND_FILES}/usr/libexec/rpcd/nordvpn.easy"
release_preplace_migrator="\${BACKEND_FILES}/usr/libexec/nordvpn-easy/migrate-config.sh"
release_preplace_template="\${BACKEND_FILES}/usr/share/nordvpn-easy/defaults/nordvpn_easy"
release_apk_rpcd="\${VERIFY_DIR}/usr/libexec/rpcd/nordvpn.easy"
release_ipk_rpcd="\${VERIFY_DIR}/data/usr/libexec/rpcd/nordvpn.easy"
release_apk_migrator="\${VERIFY_DIR}/usr/libexec/nordvpn-easy/migrate-config.sh"
release_ipk_migrator="\${VERIFY_DIR}/data/usr/libexec/nordvpn-easy/migrate-config.sh"
release_apk_template="\${VERIFY_DIR}/usr/share/nordvpn-easy/defaults/nordvpn_easy"
release_ipk_template="\${VERIFY_DIR}/data/usr/share/nordvpn-easy/defaults/nordvpn_easy"
release_apk_config_context="\${VERIFY_DIR}/usr/libexec/nordvpn-easy/lib/config-context.sh"
release_ipk_config_context="\${VERIFY_DIR}/data/usr/libexec/nordvpn-easy/lib/config-context.sh"
release_apk_runtime="\${VERIFY_DIR}/usr/libexec/nordvpn-easy/lib/runtime.sh"
release_ipk_runtime="\${VERIFY_DIR}/data/usr/libexec/nordvpn-easy/lib/runtime.sh"
release_apk_postrm='post-deinstall: |'
release_ipk_postrm="\${VERIFY_DIR}/control/postrm"
config_cleanup='rm -f /etc/config/nordvpn_easy /etc/config/nordvpn_easy-opkg'
template_cleanup='rm -f /usr/share/nordvpn-easy/defaults/nordvpn_easy'
migrator_cleanup='rm -f /usr/libexec/nordvpn-easy/migrate-config.sh'
runtime_cleanup='rm -rf /tmp/nordvpn-easy.lock /tmp/run/nordvpn-easy'
catalog_cleanup='/tmp/nordvpn-easy-countries.json'
generated_config_payload='/etc/config/nordvpn_easy'
old_config_source='files/etc/config/nordvpn_easy'
make_conffiles='/conffiles'
backend_prerm='define Package/nordvpn-easy/prerm'
backend_postinst='define Package/nordvpn-easy/postinst'
backend_postrm='define Package/nordvpn-easy/postrm'
luci_prerm="define Package/\$(PKG_NAME)/prerm"
luci_postinst="define Package/\$(PKG_NAME)/postinst"
luci_postrm="define Package/\$(PKG_NAME)/postrm"
backend_luci_presence_helper='luci_app_installed()'
backend_opkg_presence_check='opkg status luci-app-nordvpn-easy >/dev/null 2>&1'
backend_apk_presence_check='apk info -e luci-app-nordvpn-easy >/dev/null 2>&1'
luci_backend_presence_helper='nordvpn_easy_backend_installed()'
luci_backend_opkg_presence_check='opkg status nordvpn-easy >/dev/null 2>&1'
luci_backend_apk_presence_check='apk info -e nordvpn-easy >/dev/null 2>&1'
migrator_runtime_path='/usr/libexec/nordvpn-easy/migrate-config.sh'

assert_eq "$backend_version" "$luci_version" 'backend and LuCI packages share default version'
assert_eq "$backend_release" "$luci_release" 'backend and LuCI packages share default release'

# The luci-app bundles the backend into its own payload, so it must NOT depend
# on the separate nordvpn-easy package: that dependency would force a
# conflicting co-install on the shared backend files. Intentional omission
# (bug-audit #25); see the comment above LUCI_DEPENDS in the LuCI Makefile.
luci_depends_line="$(grep '^LUCI_DEPENDS:=' "$LUCI_MAKEFILE" || true)"
case "$luci_depends_line" in
	*+nordvpn-easy*)
		printf '%s\n' 'FAIL: luci-app must not depend on +nordvpn-easy (backend is bundled; the dep would conflict on shared files)' >&2
		exit 1
		;;
esac

[ -f "$RPCD_SCRIPT" ] || {
	printf '%s\n' 'FAIL: backend rpcd plugin must exist in package source' >&2
	exit 1
}

[ -x "$RPCD_SCRIPT" ] || {
	printf '%s\n' 'FAIL: backend rpcd plugin must be executable in package source' >&2
	exit 1
}

[ -f "$MIGRATOR_SCRIPT" ] || {
	printf '%s\n' 'FAIL: backend config migrator must exist in package source' >&2
	exit 1
}

[ -x "$MIGRATOR_SCRIPT" ] || {
	printf '%s\n' 'FAIL: backend config migrator must be executable in package source' >&2
	exit 1
}

[ -f "$CONFIG_TEMPLATE" ] || {
	printf '%s\n' 'FAIL: backend config template must exist in package source' >&2
	exit 1
}

[ ! -e "$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/config/nordvpn_easy" ] || {
	printf '%s\n' 'FAIL: generated UCI config must not remain in backend package payload source' >&2
	exit 1
}

# Backend files are no longer pre-placed via a (dead) Build/Prepare define in
# the LuCI Makefile; the release workflow is the single source of truth for the
# manual-upload bundle and is verified below, so we no longer assert backend
# source paths inside the LuCI Makefile.

grep -F "$backend_rpcd_install" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must install rpcd plugin with executable permissions' >&2
	exit 1
}

grep -F "$backend_migrator_install" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must install config migrator with executable permissions' >&2
	exit 1
}

grep -F "$backend_template_install" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must install config template under /usr/share defaults' >&2
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

grep -F "$release_preplace_migrator" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: OPKG compatibility pre-place must copy config migrator' >&2
	exit 1
}

grep -F "$release_preplace_template" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: OPKG compatibility pre-place must copy config template' >&2
	exit 1
}

grep -F "$release_preplace_publicip" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: OPKG compatibility pre-place must copy the public IP poll script' >&2
	exit 1
}

grep -F "$release_preplace_ucidefaults" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: OPKG compatibility pre-place must copy the rpcd timeout uci-default' >&2
	exit 1
}

# The grep checks above only prove the pre-place exists *somewhere* in the
# workflow. build-apk once lacked it entirely (bug-audit #24) so the tagged APK
# release built a backend-less package and failed verification, undetected
# because no PR job builds the packages. Assert the pre-place exists in EACH
# build job and that both stage the same backend file set (kept in lockstep).
apk_preplace_sources="$(job_preplace_sources 'build-apk' "$RELEASE_WORKFLOW")"
opkg_preplace_sources="$(job_preplace_sources 'build-opkg' "$RELEASE_WORKFLOW")"

[ -n "$apk_preplace_sources" ] || {
	printf '%s\n' 'FAIL: build-apk job must pre-place the bundled backend (no backend sources found)' >&2
	exit 1
}

[ -n "$opkg_preplace_sources" ] || {
	printf '%s\n' 'FAIL: build-opkg job must pre-place the bundled backend (no backend sources found)' >&2
	exit 1
}

assert_eq "$opkg_preplace_sources" "$apk_preplace_sources" \
	'build-apk and build-opkg must pre-place the same backend files (kept in lockstep)'

for release_payload in \
	"$release_apk_rpcd" \
	"$release_ipk_rpcd" \
	"$release_apk_migrator" \
	"$release_ipk_migrator" \
	"$release_apk_template" \
	"$release_ipk_template" \
	"$release_apk_config_context" \
	"$release_ipk_config_context" \
	"$release_apk_runtime" \
	"$release_ipk_runtime" \
	"$release_apk_publicip" \
	"$release_ipk_publicip" \
	"$release_apk_ucidefaults" \
	"$release_ipk_ucidefaults" \
	"$release_apk_postrm" \
	"$release_ipk_postrm"
do
	grep -F "$release_payload" "$RELEASE_WORKFLOW" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: release workflow must verify payload file: $release_payload" >&2
		exit 1
	}
done

for makefile_path in "$BACKEND_MAKEFILE" "$LUCI_MAKEFILE"; do
	grep -F "$make_conffiles" "$makefile_path" >/dev/null 2>&1 && {
		printf '%s\n' "FAIL: package Makefile must not define conffiles for generated UCI config: $makefile_path" >&2
		exit 1
	}

	grep -F "$old_config_source" "$makefile_path" >/dev/null 2>&1 && {
		printf '%s\n' "FAIL: package Makefile must not install /etc/config/nordvpn_easy directly: $makefile_path" >&2
		exit 1
	}
done

grep -F "$generated_config_payload" "$RELEASE_WORKFLOW" | grep -F 'required_path' >/dev/null 2>&1 && {
	printf '%s\n' 'FAIL: release workflow must not require generated UCI config in package payload' >&2
	exit 1
}

backend_cleanup_count="$(grep -F -c "$config_cleanup" "$BACKEND_MAKEFILE" || true)"
luci_cleanup_count="$(grep -F -c "$config_cleanup" "$LUCI_MAKEFILE" || true)"

assert_eq '1' "$backend_cleanup_count" 'backend package must remove UCI config from a single uninstall hook'
assert_eq '1' "$luci_cleanup_count" 'LuCI package must remove UCI config from a single uninstall hook'

for cleanup_pattern in "$template_cleanup" "$migrator_cleanup" "$runtime_cleanup" "$catalog_cleanup"; do
	grep -F "$cleanup_pattern" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: backend postrm must remove generated or residual path: $cleanup_pattern" >&2
		exit 1
	}

	grep -F "$cleanup_pattern" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: LuCI postrm must remove generated or residual path: $cleanup_pattern" >&2
		exit 1
	}
done

grep -F "$backend_prerm" "$BACKEND_MAKEFILE" >/dev/null 2>&1 && {
	printf '%s\n' 'FAIL: backend package must not remove UCI config from prerm' >&2
	exit 1
}

grep -F "$luci_prerm" "$LUCI_MAKEFILE" >/dev/null 2>&1 && {
	printf '%s\n' 'FAIL: LuCI package must not remove UCI config from prerm' >&2
	exit 1
}

grep -F "$backend_postrm" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must define postrm cleanup for generated config and residual files' >&2
	exit 1
}

grep -F "$backend_postinst" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend package must define postinst config migration' >&2
	exit 1
}

grep -F "$migrator_runtime_path" "$BACKEND_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: backend postinst must call the installed config migrator' >&2
	exit 1
}

assert_block_contains "$backend_postrm" "$backend_luci_presence_helper" "$BACKEND_MAKEFILE" \
	'backend postrm must define a shared-package presence helper'
assert_block_contains "$backend_postrm" "$backend_opkg_presence_check" "$BACKEND_MAKEFILE" \
	'backend postrm must keep shared UCI config while luci-app-nordvpn-easy is installed'
assert_block_contains "$backend_postrm" "$backend_apk_presence_check" "$BACKEND_MAKEFILE" \
	'backend postrm must support APK package presence checks'

grep -F "$luci_postrm" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must define postrm cleanup for generated config and residual files' >&2
	exit 1
}

assert_block_contains "$luci_postrm" "$luci_backend_presence_helper" "$LUCI_MAKEFILE" \
	'LuCI postrm must define a backend-package presence helper'
assert_block_contains "$luci_postrm" "$luci_backend_opkg_presence_check" "$LUCI_MAKEFILE" \
	'LuCI postrm must keep shared files while nordvpn-easy backend is installed'
assert_block_contains "$luci_postrm" "$luci_backend_apk_presence_check" "$LUCI_MAKEFILE" \
	'LuCI postrm must support APK backend package presence checks'

grep -F "$luci_postinst" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must define postinst config migration' >&2
	exit 1
}

grep -F "$migrator_runtime_path" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI postinst must call the installed config migrator' >&2
	exit 1
}

schema_payload="$(sed -n "s/^NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE=\"\${NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE:-\\(.*\\)}\"/\\1/p" "$SCHEMA_LIB" | head -n 1)"
core_payload="$(sed -n "s/^CORE_BACKEND_PAYLOAD_SIGNATURE='\\(.*\\)'/\\1/p" "$CORE_SCRIPT" | head -n 1)"
init_payload="$(sed -n "s/^SERVICE_BACKEND_PAYLOAD_SIGNATURE='\\(.*\\)'/\\1/p" "$INIT_SCRIPT" | head -n 1)"

assert_eq "$schema_payload" "$core_payload" 'schema and core share payload signature'
assert_eq "$schema_payload" "$init_payload" 'schema and init share payload signature'

printf '%s\n' 'test-package-lockstep.sh: ok'
