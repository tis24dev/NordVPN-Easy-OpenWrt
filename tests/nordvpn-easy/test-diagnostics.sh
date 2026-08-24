#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
HANDSHAKE_EPOCH="$(date +%s)"
DIAG_TMP="$(mktemp -d)"
ORIGINAL_PATH="$PATH"

cleanup() {
	rm -rf "$DIAG_TMP"
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"
# shellcheck disable=SC1090
. "$DIAGNOSTICS_LIB"

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

assert_contains() {
	needle="$1"
	haystack="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*) ;;
		*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "missing: $needle" >&2
			exit 1
			;;
	esac
}

pick_ping_ip() {
	printf '%s\n' '1.1.1.1'
}

nordvpn_easy_resolve_wan_device() {
	WAN_DEVICE='eth0'
	return 0
}

VPN_IF='wg0'
WAN_IF='wan'
NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES='0'
SERVER_LIST_FILE="$DIAG_TMP/nordvpn-server-list.json"
COUNTRIES_CACHE_FILE="$DIAG_TMP/nordvpn-countries.json"
COUNTRIES_CACHE_TS_FILE="$DIAG_TMP/nordvpn-countries.timestamp"
NORDVPN_EASY_LAST_ERROR_CACHE="$DIAG_TMP/last_error"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="$DIAG_TMP/public_verification"

# S9: a runtime transition (which suppresses transient findings) is detected off the
# operation lock state, not a connect-apply guard file. Seed a held lock whose action
# is a transition verb so the diagnostics collect reports held:<action>.
DIAG_LOCK_DIR="$DIAG_TMP/lock"
LOCK_DIR="$DIAG_TMP/no-lock"
seed_transition_lock() {
	mkdir -p "$DIAG_LOCK_DIR"
	printf '%s\n' "$$" > "$DIAG_LOCK_DIR/pid"
	printf '%s\n' "${1:-reconnect}" > "$DIAG_LOCK_DIR/action"
	: > "$DIAG_LOCK_DIR/state"
	date +%s > "$DIAG_LOCK_DIR/started_at"
	LOCK_DIR="$DIAG_LOCK_DIR"
}
clear_transition_lock() {
	rm -rf "$DIAG_LOCK_DIR"
	LOCK_DIR="$DIAG_TMP/no-lock"
}

printf '%s\n' '[{"station":"hk270"}]' > "$SERVER_LIST_FILE"
printf '%s\n' '[{"code":"HK","name":"Hong Kong"}]' > "$COUNTRIES_CACHE_FILE"
date +%s > "$COUNTRIES_CACHE_TS_FILE"

emit_scenario_json() {
	nordvpn_easy_emit_diagnostics_summary_json wg0
}

primary_code() {
	printf '%s' "$1" | jq -r '.primary_finding.code'
}

findings_codes() {
	printf '%s' "$1" | jq -r '.findings[].code' | tr '\n' ' '
}

install_ping_mock() {
	local exit_code="$1"

	printf '%s\n' '#!/bin/sh' 'exit '"$exit_code" > "$DIAG_TMP/ping"
	chmod +x "$DIAG_TMP/ping"
	PATH="$DIAG_TMP:$PATH"
	export PATH
}

install_nslookup_mock() {
	local exit_code="$1"

	printf '%s\n' '#!/bin/sh' 'exit '"$exit_code" > "$DIAG_TMP/nslookup"
	chmod +x "$DIAG_TMP/nslookup"
	PATH="$DIAG_TMP:$PATH"
	export PATH
}

restore_path_mock() {
	PATH="$ORIGINAL_PATH"
	export PATH
}

assert_scenario_primary() {
	local expected="$1"
	local label="$2"
	local json
	local err_file

	err_file="$DIAG_TMP/emit.err"
	: >"$err_file"
	set +e
	json="$(emit_scenario_json 2>>"$err_file")"
	emit_rc=$?
	set -e
	if [ "$emit_rc" -ne 0 ] || [ -z "$json" ]; then
		printf '%s\n' "FAIL: $label (emit_scenario_json failed, rc=$emit_rc)" >&2
		cat "$err_file" >&2
		exit 1
	fi
	assert_eq "$expected" "$(primary_code "$json")" "$label"
	printf '%s' "$json"
}

assert_scenario_includes() {
	local json="$1"
	local code="$2"
	local label="$3"

	assert_contains "$code" "$(findings_codes "$json")" "$label"
}

uci_complete() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'wireguard' ;;
		'get network.wg0.disabled') printf '%s\n' '0' ;;
		'get network.wg0.private_key') printf '%s\n' 'private-secret' ;;
		'get network.wg0.addresses') printf '%s\n' '10.5.0.2/32' ;;
		'get network.wg0.peerdns') printf '%s\n' '0' ;;
		'get network.wg0.delegate') printf '%s\n' '0' ;;
		'get network.wg0.force_link') printf '%s\n' '1' ;;
		'get network.wg0server.endpoint_host') printf '%s\n' 'hk270.nordvpn.com' ;;
		'get network.wg0server.public_key') printf '%s\n' 'peer-public-key' ;;
		'get network.wg0server.allowed_ips') printf '%s\n' '0.0.0.0/0' ;;
		'get network.wg0server.route_allowed_ips') printf '%s\n' '1' ;;
		'get network.wg0server.nordvpn_country_code') printf '%s\n' 'HK' ;;
		'get network.wg0server.nordvpn_station') printf '%s\n' '185.225.234.11' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.vpn_country') printf '%s\n' '' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' '' ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '0' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network')
			printf '%s\n' 'network.wg0=interface'
			printf '%s\n' 'network.wg0server=wireguard_wg0'
			;;
		*) return 1 ;;
	esac
}

wg_blackhole() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t0\t0\t1184\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*)
			return 1
			;;
	esac
}

wg_no_handshake() {
	wg_blackhole "$@"
}

wg_no_peers() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' 'private\tpublic\t51820\t'
			;;
		'show wg0 peers')
			return 0
			;;
		*)
			return 1
			;;
	esac
}

wg_connected() {
	case "$1 $2 $3" in
		'show wg0 dump')
			printf '%b\n' \
				'private\tpublic\t51820\t' \
				"peerpub\tpsk\t185.225.234.11:51820\t10.5.0.2/32\t${HANDSHAKE_EPOCH}\t4096\t4096\t15"
			;;
		'show wg0 peers')
			printf '%s\n' 'peerpub'
			;;
		*)
			return 1
			;;
	esac
}

ip_blackhole() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' 'default proto static scope link' ;;
		'route show default') printf '%s\n' 'default dev wg0 proto static scope link' ;;
		*) return 0 ;;
	esac
}

ip_healthy() {
	case "$*" in
		'link show dev wg0') return 0 ;;
		'route show dev wg0') printf '%s\n' '10.5.0.2/32 proto kernel scope link src 10.5.0.2' ;;
		'route show default') printf '%s\n' 'default dev eth0 proto static' ;;
		*) return 0 ;;
	esac
}

ip_link_down() {
	case "$*" in
		'link show dev wg0') return 1 ;;
		*) return 0 ;;
	esac
}

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}

wg() {
	wg_blackhole "$@"
}

ip() {
	ip_blackhole "$@"
}

# --- Integration scenarios (blackhole, kill switch, healthy) ---

SUMMARY="$(nordvpn_easy_diagnostics_print_health_summary wg0)"

assert_eq 'routing.blackhole_default_via_vpn' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^probable_issue_code=//p')" \
	'blackhole scenario selects routing finding first'
assert_contains 'routing.blackhole_default_via_vpn' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^probable_issues=//p')" \
	'blackhole scenario lists routing finding'
assert_eq 'yes' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^routing_blackhole_risk=//p')" \
	'blackhole scenario flags routing risk'
assert_eq 'stuck_tunnel_suspected' \
	"$(printf '%s\n' "$SUMMARY" | sed -n 's/^transfer_asymmetry=//p')" \
	'blackhole scenario flags asymmetric transfer'

BLACKHOLE_JSON="$(emit_scenario_json)"
assert_eq 'routing.blackhole_default_via_vpn' \
	"$(primary_code "$BLACKHOLE_JSON")" \
	'summary json exposes primary finding code'
assert_contains 'runtime.no_handshake' "$(findings_codes "$BLACKHOLE_JSON")" \
	'summary json includes no_handshake with blackhole'
assert_contains 'runtime.stuck_tunnel' "$(findings_codes "$BLACKHOLE_JSON")" \
	'summary json includes stuck_tunnel with blackhole'
assert_eq 'yes' \
	"$(printf '%s' "$BLACKHOLE_JSON" | jq -r '.connectivity.routing_blackhole_risk')" \
	'summary json includes connectivity assessment'

wg() { wg_blackhole "$@"; }
ip() { ip_blackhole "$@"; }
uci_kill_switch() {
	case "$*" in
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '1' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_kill_switch "$@"
}
PRIORITY_JSON="$(emit_scenario_json)"
assert_eq 'routing.blackhole_default_via_vpn' \
	"$(primary_code "$PRIORITY_JSON")" \
	'routing blackhole stays primary over kill switch and handshake findings'
assert_eq 'critical' \
	"$(printf '%s' "$PRIORITY_JSON" | jq -r '.primary_finding.severity')" \
	'primary finding exposes severity in summary json'
assert_contains 'operational.kill_switch_active' "$(findings_codes "$PRIORITY_JSON")" \
	'kill switch finding is still listed with blackhole present'

KILL_SWITCH_JSON="$(emit_scenario_json)"
assert_eq 'true' \
	"$(printf '%s' "$KILL_SWITCH_JSON" | jq -r '.health.kill_switch_enabled')" \
	'kill switch scenario exposes kill_switch_enabled in summary json'
assert_contains 'operational.kill_switch_active' "$(findings_codes "$KILL_SWITCH_JSON")" \
	'kill switch scenario lists kill switch finding when tunnel is down'

# Policy routing mode: the kill switch is configured but never installed (it would
# drop the traffic pbr steers around the tunnel), so reporting it as active would be
# a permanent false positive on a tunnel that is legitimately not the default route.
uci_policy_mode() {
	case "$*" in
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.routing_mode') printf '%s\n' 'policy' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_policy_mode "$@"
}
POLICY_JSON="$(emit_scenario_json)"
assert_eq 'policy' \
	"$(printf '%s' "$POLICY_JSON" | jq -r '.health.routing_mode')" \
	'summary json exposes the policy routing mode'
assert_eq 'false' \
	"$(printf '%s' "$POLICY_JSON" | jq -r '.health.kill_switch_enabled')" \
	'policy routing mode reports the kill switch as not in effect'
case "$(findings_codes "$POLICY_JSON")" in
	*operational.kill_switch_active*)
		printf '%s\n' 'FAIL: policy routing mode must not raise the kill switch finding' >&2
		exit 1
		;;
esac

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_kill_switch "$@"
}

uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
wg() { wg_connected "$@"; }
ip() { ip_link_down "$@"; }
nordvpn_easy_runtime_configured() { return 1; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(emit_scenario_json)"
assert_eq 'operational.apply_incomplete' "$(primary_code "$JSON")" \
	'operational.apply_incomplete is primary when VPN is enabled without configured runtime'
assert_scenario_includes "$JSON" 'operational.apply_incomplete' \
	'operational.apply_incomplete appears in findings'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "runtime.link_down")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: runtime.link_down should not duplicate apply_incomplete orphan state' >&2
	exit 1
fi

wg() { wg_connected "$@"; }
ip() { ip_link_down "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_complete "$@"
}
JSON="$(assert_scenario_primary 'runtime.link_down' 'runtime.link_down is primary when VPN link is absent')"
assert_scenario_includes "$JSON" 'runtime.link_down' 'runtime.link_down appears in findings'
seed_transition_lock reconnect
JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$JSON")" \
	'runtime.link_down is suppressed during an active runtime transition'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "runtime.link_down")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: runtime.link_down should not appear during an active runtime transition' >&2
	exit 1
fi
clear_transition_lock

DIAG_OPERATION_LOCK_STATE='held'
DIAG_OPERATION_LOCK_ACTION='reconnect'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: held reconnect should suppress transient diagnostics' >&2
	exit 1
}
DIAG_OPERATION_LOCK_STATE='stale_recovered'
DIAG_OPERATION_LOCK_ACTION='reconcile'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: stale-recovered reconcile should suppress transient diagnostics' >&2
	exit 1
}
# PR #81 review: a supervised Save & Apply holds the lock as 'supervise', and the
# provision verb as 'connect'; both are in-flight runtime transitions and must suppress
# transient diagnostics like the legacy actions.
DIAG_OPERATION_LOCK_STATE='held'
DIAG_OPERATION_LOCK_ACTION='supervise'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: held supervise (supervised apply) should suppress transient diagnostics' >&2
	exit 1
}
DIAG_OPERATION_LOCK_ACTION='connect'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: held connect should suppress transient diagnostics' >&2
	exit 1
}
DIAG_OPERATION_LOCK_STATE='stale_recovered'
DIAG_OPERATION_LOCK_ACTION='supervise'
nordvpn_easy_diagnostics_runtime_transition_active || {
	printf '%s\n' 'FAIL: stale-recovered supervise should suppress transient diagnostics' >&2
	exit 1
}

uci_wg0_no_peer() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'wireguard' ;;
		'get network.wg0.disabled') printf '%s\n' '0' ;;
		'get network.wg0.private_key') printf '%s\n' 'private-secret' ;;
		'get network.wg0.addresses') printf '%s\n' '10.5.0.2/32' ;;
		'get network.wg0.peerdns') printf '%s\n' '0' ;;
		'get network.wg0.delegate') printf '%s\n' '0' ;;
		'get network.wg0.force_link') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.vpn_country') printf '%s\n' '' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' '' ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '0' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network')
			printf '%s\n' 'network.wg0=interface'
			;;
		*) return 1 ;;
	esac
}

wg() { wg_no_peers "$@"; }
ip() { ip_healthy "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_wg0_no_peer "$@"
}
seed_transition_lock reconnect
JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$JSON")" \
	'config.peer_missing is suppressed during an active runtime transition'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "config.peer_missing")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: config.peer_missing should not appear during an active runtime transition' >&2
	exit 1
fi
clear_transition_lock

wg() { wg_no_peers "$@"; }
ip() { ip_healthy "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
uci_wg0_absent() {
	case "$*" in
		'get network.wg0.proto') return 1 ;;
		'get nordvpn_easy.main.enabled') printf '%s\n' '1' ;;
		'get nordvpn_easy.main.server_selection_mode') printf '%s\n' 'auto' ;;
		'get nordvpn_easy.main.vpn_country') printf '%s\n' 'DE' ;;
		'get nordvpn_easy.main.preferred_server_station') printf '%s\n' '' ;;
		'get nordvpn_easy.main.kill_switch_enabled') printf '%s\n' '0' ;;
		'get nordvpn_easy.main.wan_if') printf '%s\n' 'wan' ;;
		'show network') return 0 ;;
		*) return 1 ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_wg0_absent "$@"
}
seed_transition_lock reconnect
JSON="$(emit_scenario_json)"
assert_eq 'none' "$(primary_code "$JSON")" \
	'config.not_wireguard is suppressed during an active runtime transition when wg0 is torn down'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "config.not_wireguard")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: config.not_wireguard should not appear during an active runtime transition' >&2
	exit 1
fi
clear_transition_lock

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
uci_not_wireguard() {
	case "$*" in
		'get network.wg0.proto') printf '%s\n' 'openvpn' ;;
		*) uci_complete "$@" ;;
	esac
}
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_not_wireguard "$@"
}
JSON="$(assert_scenario_primary 'config.not_wireguard' 'config.not_wireguard is primary for non-WireGuard proto')"
assert_scenario_includes "$JSON" 'config.not_wireguard' 'config.not_wireguard appears in findings'

# --- Incomplete interface: credentials blocker re-prioritizes over key editing ---

primary_action() {
	printf '%s' "$1" | jq -r '.primary_finding.action'
}

assert_not_contains() {
	needle="$1"
	haystack="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "unexpected: $needle" >&2
			exit 1
			;;
	esac
}

# Drops force_link so the interface is reported incomplete (proto stays wireguard).
uci_wg0_incomplete() {
	case "$*" in
		'get network.wg0.force_link') return 1 ;;
		*) uci_complete "$@" ;;
	esac
}

wg() { wg_connected "$@"; }
ip() { ip_healthy "$@"; }
nordvpn_easy_runtime_configured() { return 0; }
uci() {
	if [ "$1" = '-q' ]; then
		shift
	fi
	uci_wg0_incomplete "$@"
}

printf '%s\n' 'could not retrieve NordLynx private key from NordVPN API (curl_rc=22: HTTP error response, http_code=400)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
JSON="$(assert_scenario_primary 'config.connect_blocked_credentials' 'credentials blocker re-prioritizes over interface_incomplete')"
assert_scenario_includes "$JSON" 'config.connect_blocked_credentials' 'config.connect_blocked_credentials appears in findings'
assert_contains 'token' "$(primary_action "$JSON")" 'credentials blocker action points at the access token'
assert_not_contains 'Complete the WireGuard interface keys' "$(primary_action "$JSON")" \
	'credentials blocker action does not tell the user to edit keys'

printf '%s\n' 'invalid NordLynx private key response received from NordVPN API (http_code=200, response_bytes=12)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
JSON="$(assert_scenario_primary 'config.connect_blocked_credentials' 'invalid-response variant also re-prioritizes')"
assert_scenario_includes "$JSON" 'config.connect_blocked_credentials' 'invalid-response variant appears in findings'

printf '%s\n' 'could not retrieve VPN servers (curl_rc=6: name resolution failure, http_code=000)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
JSON="$(assert_scenario_primary 'config.interface_incomplete' 'unrelated last_error keeps interface_incomplete primary')"
assert_scenario_includes "$JSON" 'config.interface_incomplete' 'config.interface_incomplete appears in findings'
assert_not_contains 'Complete the WireGuard interface keys' "$(primary_action "$JSON")" \
	'corrected interface_incomplete action no longer tells the user to edit keys'

printf '%s\n' 'could not retrieve NordLynx private key from NordVPN API (curl_rc=22: HTTP error response, http_code=400)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
seed_transition_lock reconnect
JSON="$(emit_scenario_json)"
# The credentials blocker keys off the incomplete-interface emission, which an active
# runtime transition suppresses; the unchanged operational.last_error gate then
# surfaces the raw error as a generic fallback (never the suppressed blocker).
assert_not_contains 'config.connect_blocked_credentials' "$(primary_code "$JSON")" \
	'config.connect_blocked_credentials is not primary during an active runtime transition'
if printf '%s' "$JSON" | jq -e '.findings[]? | select(.code == "config.connect_blocked_credentials")' >/dev/null 2>&1; then
	printf '%s\n' 'FAIL: config.connect_blocked_credentials should not appear during an active runtime transition' >&2
	exit 1
fi
clear_transition_lock

printf '%s\n' 'could not retrieve NordLynx private key from NordVPN API (curl_rc=6: name resolution failure, http_code=000)' > "$NORDVPN_EASY_LAST_ERROR_CACHE"
JSON="$(assert_scenario_primary 'config.connect_blocked_credentials' 'credentials blocker maps on a stable substring regardless of curl tail')"
assert_scenario_includes "$JSON" 'config.connect_blocked_credentials' 'stable-substring variant appears in findings'

: > "$NORDVPN_EASY_LAST_ERROR_CACHE"

assert_eq '2001:db8::1' "$(nordvpn_easy_diagnostics_endpoint_host '[2001:db8::1]:51820')" 'bracketed IPv6 endpoint host extraction'
assert_eq 'hk270.nordvpn.com' "$(nordvpn_easy_diagnostics_endpoint_host 'hk270.nordvpn.com:51820')" 'host:port endpoint host extraction'

# --- FIX 4: lan_dhcp_still_advertising flags only true advertising modes -------
# A file-backed fake uci modelling a lan->wan forwarding topology with a single
# dhcp.lan section, so the helper resolves wan zone -> lan zone -> dhcp.lan and
# reads dhcp.lan.ra. Only server|relay|hybrid is "still advertising"; unset/empty
# and disabled are NOT.
RA_STORE="$DIAG_TMP/ra-uci-store"
ra_seed() {
	cat > "$RA_STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.lan=dhcp
dhcp.lan.interface=lan
EOF
	if [ -n "${1:-}" ]; then
		printf 'dhcp.lan.ra=%s\n' "$1" >> "$RA_STORE"
	fi
}
uci() {
	[ "${1:-}" = '-q' ] && shift
	ra_cmd="${1:-}"; shift 2>/dev/null || true
	case "$ra_cmd" in
		show)
			ra_pkg="${1:-}"
			if [ -z "$ra_pkg" ]; then cat "$RA_STORE"; return 0; fi
			while IFS='=' read -r rk rv; do
				case "$rk" in "$ra_pkg".*) printf '%s=%s\n' "$rk" "$rv" ;; esac
			done < "$RA_STORE"
			;;
		get)
			while IFS='=' read -r rk rv; do
				[ "$rk" = "$1" ] && { printf '%s\n' "$rv"; return 0; }
			done < "$RA_STORE"
			return 1
			;;
		*) : ;;
	esac
	return 0
}

VPN_IF='wg0'; WAN_IF='wan'; DIAG_WAN_IF='wan'

ra_seed 'relay'
assert_eq 'lan' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=relay is flagged as still advertising'
ra_seed 'server'
assert_eq 'lan' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=server is flagged as still advertising'
ra_seed 'hybrid'
assert_eq 'lan' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=hybrid is flagged as still advertising'
ra_seed 'disabled'
assert_eq '' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=disabled is NOT flagged'
# FIX 4: an UNSET/absent ra must NOT be treated as advertising.
ra_seed ''
assert_eq '' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'an unset ra is NOT treated as still advertising'

# ANONYMOUS-SKIP: the withdrawal intentionally does NOT touch an @dhcp[N] pool (no
# stable id to snapshot/restore against; it relies on the ks6 REJECT). The scan must
# apply the SAME skip so it never persistently flags a pool the withdrawal skips --
# even though its live ra is 'server' (an advertising mode). Model the REAL uci
# extended @dhcp[N] form. A NAMED pool alongside it IS still flagged.
cat > "$RA_STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.@dhcp[0]=dhcp
dhcp.@dhcp[0].interface=lan
dhcp.@dhcp[0].ra=server
EOF
assert_eq '' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'an anonymous @dhcp[0] pool the withdrawal skips is NOT flagged as still advertising'
# Add a NAMED advertising pool on the same interface: it IS flagged (the skip is
# scoped to anonymous ids only, and never suppresses a real named finding).
cat > "$RA_STORE" <<'EOF'
firewall.z_lan=zone
firewall.z_lan.name=lan
firewall.z_lan.network=lan
firewall.z_wan=zone
firewall.z_wan.name=wan
firewall.z_wan.network=wan
firewall.fwd0=forwarding
firewall.fwd0.src=lan
firewall.fwd0.dest=wan
dhcp.@dhcp[0]=dhcp
dhcp.@dhcp[0].interface=lan
dhcp.@dhcp[0].ra=server
dhcp.lann=dhcp
dhcp.lann.interface=lan
dhcp.lann.ra=server
EOF
assert_eq 'lann' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'a NAMED advertising pool beside an anonymous one is still flagged (anonymous skip does not suppress it)'

# FIX 3b: PURE CONFIG-STATE. ra=disabled clears the finding for EVERY mode -- the
# snapshot orig_ra is NOT consulted anymore. Whether ra=disabled emitted a graceful
# final RA is a runtime property of odhcpd (a hybrid resolves to server or relay
# depending on the master, config.c 2206-2213) we cannot read from UCI, so keeping
# the finding lit after ra=disabled produced a persistent false positive for hybrid
# LANs that actually resolve to server. Append a snapshot with orig_ra to PROVE the
# helper ignores it (the snapshot-name derivation matches
# nordvpn_easy_ra_snapshot_section: 'lan' -> nordvpn_ra6_snap_lan).
ra_seed_disabled_snap() {
	ra_seed 'disabled'
	{
		printf 'nordvpn_easy.nordvpn_ra6_snap_lan=nordvpn_ra6_snapshot\n'
		printf 'nordvpn_easy.nordvpn_ra6_snap_lan.dhcp_section=lan\n'
		printf 'nordvpn_easy.nordvpn_ra6_snap_lan.orig_ra=%s\n' "$1"
		printf 'nordvpn_easy.nordvpn_ra6_snap_lan.had_ra=1\n'
	} >> "$RA_STORE"
}
ra_seed_disabled_snap 'relay'
assert_eq '' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=disabled clears the finding even when snapshot orig_ra=relay (pure config-state, FIX 3b)'
ra_seed_disabled_snap 'hybrid'
assert_eq '' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=disabled clears the finding even when snapshot orig_ra=hybrid (hybrid may resolve to server at runtime)'
ra_seed_disabled_snap 'server'
assert_eq '' "$(nordvpn_easy_diagnostics_lan_dhcp_still_advertising wan || true)" \
	'ra=disabled with snapshot orig_ra=server is a clean withdrawal and NOT flagged'

# --- FIX 3: the native_ipv6_not_withdrawn finding honors the master toggle -----
# With the tunnel up as a v4-only full-tunnel and a LAN still advertising, the
# finding fires ONLY when the toggle is on; with ipv6_ra_withdraw=0 (operator
# deliberately keeps native v6) it must NOT fire.
nordvpn_easy_tunnel_is_v4_only_full() { return 0; }
nordvpn_easy_wan_has_delegated_prefix() { return 0; }
ra_seed 'relay'
DIAG_FULL_TUNNEL_ROUTING='yes'
DIAG_PEER_SECTION_FOUND='yes'
DIAG_WG_CONNECTED='yes'
DIAG_DEFAULT_ROUTE_VIA_VPN='yes'
DIAG_LAN_DHCP_ADVERTISING_SECTION='lan'
DIAG_VPN_IF='wg0'
DIAG_DEFAULT_ROUTE_DEVICE6='br-lan'

NORDVPN_EASY_RA_WITHDRAW_ENABLED='1' nordvpn_easy_diagnostics_compute_findings
case "$DIAG_FINDINGS_CODES" in
	*routing.native_ipv6_not_withdrawn*) : ;;
	*) printf '%s\n' 'FAIL: native_ipv6_not_withdrawn should fire when the toggle is on' >&2; exit 1 ;;
esac

NORDVPN_EASY_RA_WITHDRAW_ENABLED='0' nordvpn_easy_diagnostics_compute_findings
case "$DIAG_FINDINGS_CODES" in
	*routing.native_ipv6_not_withdrawn*)
		printf '%s\n' 'FAIL: native_ipv6_not_withdrawn must NOT fire when the master toggle is off' >&2
		exit 1
		;;
	*) : ;;
esac

# --- FIX 2: the diagnostics Gate 2 is broadened -- the finding fires on a relay --
# --- LAN even when wan_has_delegated_prefix is FALSE (no router-held PD) ---------
# Stub the delegated-prefix gate to FALSE; the seed dhcp.lan.ra=relay makes the real
# nordvpn_easy_lan_has_relayed_ipv6 (reached via the OR) return true, so the finding
# must still fire (the round-5 gate would have suppressed it, leaving relay clients
# on the v6 kill-switch with no diagnostic). Mirrors the runtime Gate-2 broadening.
DIAG_FINDINGS_RECORDS=''
nordvpn_easy_wan_has_delegated_prefix() { return 1; }
ra_seed 'relay'
NORDVPN_EASY_RA_WITHDRAW_ENABLED='1' nordvpn_easy_diagnostics_compute_findings
case "$DIAG_FINDINGS_CODES" in
	*routing.native_ipv6_not_withdrawn*) : ;;
	*) printf '%s\n' 'FAIL: native_ipv6_not_withdrawn must fire on a relay LAN even without a delegated prefix (FIX 2)' >&2; exit 1 ;;
esac
# And with neither a delegated prefix NOR a relay/hybrid LAN, it must NOT fire even
# though the live ra is server (still-advertising): the tunnel-side Gate 2 has no
# native v6 to withdraw. Seed a server-mode LAN so lan_has_relayed_ipv6 is false too.
DIAG_FINDINGS_RECORDS=''
ra_seed 'server'
NORDVPN_EASY_RA_WITHDRAW_ENABLED='1' nordvpn_easy_diagnostics_compute_findings
case "$DIAG_FINDINGS_CODES" in
	*routing.native_ipv6_not_withdrawn*)
		printf '%s\n' 'FAIL: native_ipv6_not_withdrawn must NOT fire with no delegated prefix and no relay/hybrid LAN (server-mode GUA-only WAN)' >&2
		exit 1
		;;
	*) : ;;
esac
# Restore the delegated-prefix stub to TRUE for the message-clause exercises below.
nordvpn_easy_wan_has_delegated_prefix() { return 0; }
ra_seed 'relay'

# --- FIX 4: the finding message never renders a self-contradictory 'dev none' --
# When a v6 default-route device WAS observed the message includes the clause;
# when DIAG_DEFAULT_ROUTE_DEVICE6 is 'none' the clause is OMITTED (never 'dev none').
# compute_findings does not reset DIAG_FINDINGS_RECORDS (collect does, via
# reset_state), so clear it before each direct call here to avoid the finalize
# step re-deriving the primary from a stale accumulated record.
DIAG_FINDINGS_RECORDS=''
DIAG_DEFAULT_ROUTE_DEVICE6='br-lan'
NORDVPN_EASY_RA_WITHDRAW_ENABLED='1' nordvpn_easy_diagnostics_compute_findings
assert_contains 'v6 default route dev br-lan' "$DIAG_PRIMARY_FINDING_MESSAGE" \
	'finding message includes the v6-route clause when a device was observed'

DIAG_FINDINGS_RECORDS=''
DIAG_DEFAULT_ROUTE_DEVICE6='none'
NORDVPN_EASY_RA_WITHDRAW_ENABLED='1' nordvpn_easy_diagnostics_compute_findings
case "$DIAG_PRIMARY_FINDING_MESSAGE" in
	*'dev none'*)
		printf '%s\n' "FAIL: finding message must not render 'dev none' (self-contradictory)" >&2
		exit 1
		;;
esac
case "$DIAG_PRIMARY_FINDING_MESSAGE" in
	*'v6 default route'*)
		printf '%s\n' "FAIL: the v6-route clause must be omitted when no v6 default-route device was observed" >&2
		exit 1
		;;
esac
# The finding still fires (config-state based), just without the route clause.
case "$DIAG_FINDINGS_CODES" in
	*routing.native_ipv6_not_withdrawn*) : ;;
	*) printf '%s\n' 'FAIL: the finding must still fire with device6=none' >&2; exit 1 ;;
esac

printf '%s\n' 'test-diagnostics.sh: ok'
