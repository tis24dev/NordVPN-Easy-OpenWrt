#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
BACKEND_MAKEFILE="$ROOT_DIR/openwrt-packages/nordvpn-easy/Makefile"
LUCI_MAKEFILE="$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/Makefile"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"
CORE_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"

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
luci_lib_glob_source="\$(CURDIR)/../nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/*.sh"
luci_lib_install_pattern="$(cat <<'EOF'
$(INSTALL_DATA) "$$$$lib" $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy/lib/
EOF
)"

assert_eq "$backend_version" "$luci_version" 'backend and LuCI packages share default version'
assert_eq "$backend_release" "$luci_release" 'backend and LuCI packages share default release'

grep -F "$luci_init_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must install init script from backend package source' >&2
	exit 1
}

grep -F "$luci_core_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must install core script from backend package source' >&2
	exit 1
}

grep -F "$luci_lib_glob_source" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must install backend library files from backend package source' >&2
	exit 1
}

grep -F "$luci_lib_install_pattern" "$LUCI_MAKEFILE" >/dev/null 2>&1 || {
	printf '%s\n' 'FAIL: LuCI package must stage backend library files explicitly into /usr/libexec/nordvpn-easy/lib' >&2
	exit 1
}

expanded_luci_lib_install_recipe="$(
	tmp_makefile="$(mktemp)"
	cat > "$tmp_makefile" <<'EOF'
PKG_NAME:=demo
INSTALL_DATA:=install -m0644
CURDIR:=/src
PKG_BUILD_DIR:=/build

define Build/Prepare/$(PKG_NAME)
	for lib in $(CURDIR)/lib/*.sh; do \
		$(INSTALL_DATA) "$$$$lib" $(PKG_BUILD_DIR)/root/usr/libexec/nordvpn-easy/lib/; \
	done
endef

print:
	@printf '%s\n' '$(Build/Prepare/$(PKG_NAME))'
EOF
	make -f "$tmp_makefile" print | sed 's/^[[:space:]]*//'
	rm -f "$tmp_makefile"
)"

expected_expanded_luci_lib_install_recipe="$(cat <<'EOF'
for lib in /src/lib/*.sh; do install -m0644 "$$lib" /build/root/usr/libexec/nordvpn-easy/lib/; done
EOF
)"

assert_eq "$expected_expanded_luci_lib_install_recipe" "$expanded_luci_lib_install_recipe" 'LuCI package install loop survives make double expansion'

schema_payload="$(sed -n "s/^NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE=\"\${NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE:-\\(.*\\)}\"/\\1/p" "$SCHEMA_LIB" | head -n 1)"
core_payload="$(sed -n "s/^CORE_BACKEND_PAYLOAD_SIGNATURE='\\(.*\\)'/\\1/p" "$CORE_SCRIPT" | head -n 1)"
init_payload="$(sed -n "s/^SERVICE_BACKEND_PAYLOAD_SIGNATURE='\\(.*\\)'/\\1/p" "$INIT_SCRIPT" | head -n 1)"

assert_eq "$schema_payload" "$core_payload" 'schema and core share payload signature'
assert_eq "$schema_payload" "$init_payload" 'schema and init share payload signature'

printf '%s\n' 'test-package-lockstep.sh: ok'
