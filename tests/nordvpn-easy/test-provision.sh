#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
ACTIONS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh"

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"
# shellcheck disable=SC1090
. "$ACTIONS_LIB"

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

VPN_IF='wg0'
WAN_IF='wan'
SERVER_LIST_FILE='/tmp/nordvpn-easy-test-provision-server-list.json'
SERVER_SELECTION_MODE='auto'
VPN_COUNTRY=''
VPN_ADDR='10.5.0.2/32'
VPN_PORT='51820'
VPN_DNS1='103.86.99.99'
VPN_DNS2='103.86.96.96'
POST_RESTART_DELAY='0'
INTERFACE_RESTART_DELAY='0'
WIREGUARD_PERSISTENT_KEEPALIVE='15'
WIREGUARD_MTU=''
PRIVATE_KEY='test-private-key'
LOG_PHASE='runtime'
PROVISION_ORDER=''
FETCH_FAIL=0

log() { :; }
refresh_countries_cache() { return 0; }
resolve_country_filter() { return 0; }
get_private_key() { return 0; }
verify_public_country_selection() { return 0; }
nordvpn_easy_wait_for_vpn_connectivity() { return 0; }
nordvpn_easy_get_servers_list() { return 0; }
nordvpn_easy_server_selection_is_manual() { return 1; }
nordvpn_easy_fetch_provision_prerequisites() {
	PROVISION_ORDER="${PROVISION_ORDER}fetch,"
	if [ "$FETCH_FAIL" = '1' ]; then
		return 1
	fi
	return 0
}
nordvpn_easy_immediate_vpn_shutdown() {
	PROVISION_ORDER="${PROVISION_ORDER}shutdown,"
	return 0
}
nordvpn_easy_clear_provision_caches() {
	PROVISION_ORDER="${PROVISION_ORDER}clear,"
	return 0
}
nordvpn_easy_teardown_vpn() {
	PROVISION_ORDER="${PROVISION_ORDER}teardown,"
	return 0
}
nordvpn_easy_configure_vpn_interface() {
	PROVISION_ORDER="${PROVISION_ORDER}configure,"
	return 0
}
nordvpn_easy_require_core_action_helpers() { return 0; }

nordvpn_easy_provision_vpn

assert_eq 'fetch,teardown,configure,' "$PROVISION_ORDER" 'provision fetches prerequisites before teardown and configure'

PROVISION_ORDER=''
nordvpn_easy_stop_vpn_for_server_change
assert_eq 'shutdown,clear,teardown,' "$PROVISION_ORDER" 'stop_vpn shuts down VPN and clears caches before connect'

PROVISION_ORDER=''
nordvpn_easy_provision_vpn connect_fresh
assert_eq 'fetch,configure,' "$PROVISION_ORDER" 'connect_fresh fetches a new server list after stop_vpn'

PROVISION_ORDER=''
nordvpn_easy_provision_vpn server_change
assert_eq 'shutdown,clear,teardown,fetch,configure,' "$PROVISION_ORDER" 'server_change runs stop_vpn then connect_fresh'

PROVISION_ORDER=''
FETCH_FAIL=1
nordvpn_easy_provision_vpn || true
assert_eq 'fetch,' "$PROVISION_ORDER" 'provision fetch failure leaves existing VPN configuration untouched'

uci() { return 0; }

printf '%s\n' '[{"hostname":"de1.nordvpn.com","station":"1.2.3.4","technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"PUBKEY"}]}],"locations":[{"country":{"code":"DE","city":{"name":"Berlin"}}}],"load":10},{"hostname":"de2.nordvpn.com","station":"5.6.7.8","technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"PUBKEY2"}]}],"locations":[{"country":{"code":"DE","city":{"name":"Berlin"}}}],"load":12}]' > "$SERVER_LIST_FILE"

NORDVPN_EASY_ROTATE_EXCLUDE_STATION='1.2.3.4'
LAST_SET_HOST=''
nordvpn_easy_set_vpn_server_in_uci() { LAST_SET_HOST="$1"; return 0; }
nordvpn_easy_set_first_server_from_list
assert_eq 'de2.nordvpn.com' "$LAST_SET_HOST" 'rotate mode skips the current recommended station'

printf '%s\n' 'test-provision.sh: ok'
