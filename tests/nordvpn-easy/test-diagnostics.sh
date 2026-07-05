#!/bin/sh

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

printf '%s\n' 'test-diagnostics.sh: ok'
