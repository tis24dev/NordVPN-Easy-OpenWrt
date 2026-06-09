#!/bin/sh

LIB_DIR="${NORDVPN_EASY_LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"

# shellcheck disable=SC1090
. "${LIB_DIR}/common.sh" || exit 1
# shellcheck disable=SC1090
. "${LIB_DIR}/runtime.sh" || exit 1
# shellcheck disable=SC1090
. "${LIB_DIR}/public-ip.sh" || exit 1

if [ -z "${NORDVPN_EASY_EXPECTED_PUBLIC_COUNTRY:-}" ] && command -v uci >/dev/null 2>&1; then
	NORDVPN_EASY_EXPECTED_PUBLIC_COUNTRY="$(uci -q get nordvpn_easy.main.vpn_country 2>/dev/null | tr 'a-z' 'A-Z')"
	export NORDVPN_EASY_EXPECTED_PUBLIC_COUNTRY
fi

nordvpn_easy_run_public_ip_check "${1:-quiet}"
exit $?
