#!/bin/sh

LIB_DIR="${NORDVPN_EASY_LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"

# shellcheck disable=SC1090
. "${LIB_DIR}/common.sh" || exit 1
# shellcheck disable=SC1090
. "${LIB_DIR}/runtime.sh" || exit 1
# shellcheck disable=SC1090
. "${LIB_DIR}/public-ip.sh" || exit 1

nordvpn_easy_run_public_ip_check "${1:-quiet}"
exit $?
