#!/bin/sh

# Extended diagnostics: config, runtime WireGuard, routing, caches, and findings.
# Expects runtime.sh and wireguard.sh to be sourced before this file.

DIAG_VPN_IF='wg0'
DIAG_COLLECTED='0'
DIAG_PROBE_DURATION_MS='0'

# Config layer
DIAG_VPN_PROTO='unknown'
DIAG_INTERFACE_DISABLED='unknown'
DIAG_PRIVATE_KEY_STATE='unknown'
DIAG_PEER_SECTION=''
DIAG_PEER_SECTION_FOUND='no'
DIAG_PEER_SECTIONS='none'
DIAG_MISSING_INTERFACE=''
DIAG_MISSING_REQUIRED=''
DIAG_SERVER_SELECTION_DRIFT='none'
DIAG_SELECTION_MODE='auto'
DIAG_SELECTED_COUNTRY=''
DIAG_CURRENT_SERVER_COUNTRY=''
DIAG_PREFERRED_STATION=''
DIAG_CURRENT_STATION=''
DIAG_LINK_PRESENT='unknown'
DIAG_ROUTES_VIA_VPN='unknown'
DIAG_WG_PEER_COUNT='unknown'
DIAG_ROUTE_ALLOWED_IPS=''
DIAG_FULL_TUNNEL_ROUTING='no'

# Runtime layer
DIAG_WG_ENDPOINT='N/A'
DIAG_WG_HANDSHAKE_EPOCH='0'
DIAG_WG_HANDSHAKE='Never'
DIAG_WG_CONNECTED='no'
DIAG_TRANSFER_RX_BYTES='0'
DIAG_TRANSFER_TX_BYTES='0'
DIAG_TRANSFER_ASYMMETRY='none'
DIAG_ENTERPRISE_STATE='unknown'
DIAG_VPN_STATUS='unknown'
DIAG_DESIRED_ENABLED='0'
DIAG_SERVICE_ENABLED='0'
DIAG_KILL_SWITCH_ENABLED='0'
DIAG_SERVICE_ENABLED_MISMATCH='no'

# Routing layer
DIAG_DEFAULT_ROUTE_DEVICE='none'
DIAG_DEFAULT_ROUTE_VIA_VPN='no'
DIAG_ROUTING_BLACKHOLE_RISK='no'
DIAG_WAN_IF='wan'
DIAG_WAN_DEVICE=''
DIAG_WAN_PING='skipped'
DIAG_DNS_API_NORDVPN_COM='skipped'
DIAG_VPN_ENDPOINT_HOST=''
DIAG_VPN_ENDPOINT_REACHABLE='skipped'
DIAG_PRIMARY_FINDING_PRIORITY='0'
DIAG_PRIMARY_FINDING_SEVERITY='none'
DIAG_DEGRADED_SINCE='0'
DIAG_DEGRADED_DURATION_SECONDS='0'

# Operational layer
DIAG_API_SERVER_LIST_CACHE='missing'
DIAG_API_COUNTRIES_CACHE='missing'
DIAG_API_COUNTRIES_CACHE_AGE_SECONDS='unknown'
DIAG_LAST_ERROR=''
DIAG_OPERATION_LOCK_STATE='none'
DIAG_OPERATION_LOCK_ACTION=''

# Findings
DIAG_PRIMARY_FINDING_CODE='none'
DIAG_PRIMARY_FINDING_MESSAGE='none detected'
DIAG_PRIMARY_FINDING_ACTION=''
DIAG_FINDINGS_CODES='none'
DIAG_FINDINGS_RECORDS=''

nordvpn_easy_diagnostics_reset_state() {
	DIAG_VPN_IF='wg0'
	DIAG_COLLECTED='0'
	DIAG_PROBE_DURATION_MS='0'
	DIAG_VPN_PROTO='unknown'
	DIAG_INTERFACE_DISABLED='unknown'
	DIAG_PRIVATE_KEY_STATE='unknown'
	DIAG_PEER_SECTION=''
	DIAG_PEER_SECTION_FOUND='no'
	DIAG_PEER_SECTIONS='none'
	DIAG_MISSING_INTERFACE=''
	DIAG_MISSING_REQUIRED=''
	DIAG_SERVER_SELECTION_DRIFT='none'
	DIAG_SELECTION_MODE='auto'
	DIAG_SELECTED_COUNTRY=''
	DIAG_CURRENT_SERVER_COUNTRY=''
	DIAG_PREFERRED_STATION=''
	DIAG_CURRENT_STATION=''
	DIAG_LINK_PRESENT='unknown'
	DIAG_ROUTES_VIA_VPN='unknown'
	DIAG_WG_PEER_COUNT='unknown'
	DIAG_ROUTE_ALLOWED_IPS=''
	DIAG_FULL_TUNNEL_ROUTING='no'
	DIAG_WG_ENDPOINT='N/A'
	DIAG_WG_HANDSHAKE_EPOCH='0'
	DIAG_WG_HANDSHAKE='Never'
	DIAG_WG_CONNECTED='no'
	DIAG_TRANSFER_RX_BYTES='0'
	DIAG_TRANSFER_TX_BYTES='0'
	DIAG_TRANSFER_ASYMMETRY='none'
	DIAG_ENTERPRISE_STATE='unknown'
	DIAG_VPN_STATUS='unknown'
	DIAG_DESIRED_ENABLED='0'
	DIAG_SERVICE_ENABLED='0'
	DIAG_KILL_SWITCH_ENABLED='0'
	DIAG_SERVICE_ENABLED_MISMATCH='no'
	DIAG_DEFAULT_ROUTE_DEVICE='none'
	DIAG_DEFAULT_ROUTE_VIA_VPN='no'
	DIAG_ROUTING_BLACKHOLE_RISK='no'
	DIAG_WAN_IF='wan'
	DIAG_WAN_DEVICE=''
	DIAG_WAN_PING='skipped'
	DIAG_DNS_API_NORDVPN_COM='skipped'
	DIAG_VPN_ENDPOINT_HOST=''
	DIAG_VPN_ENDPOINT_REACHABLE='skipped'
	DIAG_PRIMARY_FINDING_PRIORITY='0'
	DIAG_PRIMARY_FINDING_SEVERITY='none'
	DIAG_DEGRADED_SINCE='0'
	DIAG_DEGRADED_DURATION_SECONDS='0'
	DIAG_API_SERVER_LIST_CACHE='missing'
	DIAG_API_COUNTRIES_CACHE='missing'
	DIAG_API_COUNTRIES_CACHE_AGE_SECONDS='unknown'
	DIAG_LAST_ERROR=''
	DIAG_OPERATION_LOCK_STATE='none'
	DIAG_OPERATION_LOCK_ACTION=''
	DIAG_PRIMARY_FINDING_CODE='none'
	DIAG_PRIMARY_FINDING_MESSAGE='none detected'
	DIAG_PRIMARY_FINDING_ACTION=''
	DIAG_FINDINGS_CODES='none'
	DIAG_FINDINGS_RECORDS=''
}

nordvpn_easy_diagnostics_pick_ping_ip() {
	if command -v pick_ping_ip >/dev/null 2>&1; then
		pick_ping_ip
		return 0
	fi

	printf '%s\n' '1.1.1.1'
}

nordvpn_easy_diagnostics_default_route_device() {
	ip route show default 2>/dev/null | awk '
		/^default / {
			for (i = 1; i <= NF; i++) {
				if ($i == "dev") {
					print $(i + 1)
					exit
				}
			}
		}
	'
}

nordvpn_easy_diagnostics_peer_allowed_ips_contains_full_tunnel() {
	local peer_section="$1"
	local allowed_ip=''

	[ -n "$peer_section" ] || return 1

	for allowed_ip in $(uci -q get "network.${peer_section}.allowed_ips" 2>/dev/null); do
		case "$allowed_ip" in
			0.0.0.0/0|::/0)
				return 0
				;;
		esac
	done

	return 1
}

nordvpn_easy_diagnostics_server_list_cache_state() {
	local cache_file="${SERVER_LIST_FILE:-/tmp/nordvpn.json}"

	[ -f "$cache_file" ] || {
		printf '%s\n' 'missing'
		return 0
	}

	if command -v jq >/dev/null 2>&1 &&
		jq -er '.[0].station // empty' "$cache_file" >/dev/null 2>&1; then
		printf '%s\n' 'present_ok'
		return 0
	fi

	printf '%s\n' 'present_invalid'
}

nordvpn_easy_diagnostics_countries_cache_state() {
	local cache_file="${COUNTRIES_CACHE_FILE:-/tmp/nordvpn-easy-countries.json}"
	local ts_file="${COUNTRIES_CACHE_TS_FILE:-/tmp/nordvpn-easy-countries.timestamp}"
	local now_ts cache_ts age

	[ -f "$cache_file" ] || {
		printf '%s\n' 'missing'
		printf '%s\n' 'unknown'
		return 0
	}

	if command -v jq >/dev/null 2>&1 &&
		jq -er 'type == "array" and length > 0' "$cache_file" >/dev/null 2>&1; then
		cache_state='present_ok'
	else
		cache_state='present_invalid'
	fi

	age='unknown'
	if [ -f "$ts_file" ]; then
		cache_ts="$(cat "$ts_file" 2>/dev/null || true)"
		now_ts="$(date +%s 2>/dev/null || true)"
		case "$cache_ts" in
			''|*[!0-9]*)
				age='unknown'
				;;
			*)
				case "$now_ts" in
					''|*[!0-9]*)
						age='unknown'
						;;
					*)
						age=$((now_ts - cache_ts))
						[ "$age" -lt 0 ] && age=0
						;;
				esac
				;;
		esac
	fi

	printf '%s\n' "$cache_state"
	printf '%s\n' "$age"
}

nordvpn_easy_diagnostics_resolve_wan_nameserver() {
	awk '
		$0 == "# Interface wan" { wan = 1; next }
		$0 ~ /^# Interface / { wan = 0 }
		wan && /^nameserver[[:space:]]+/ {
			print $2
			exit
		}
	' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null
}

nordvpn_easy_diagnostics_finding_priority() {
	case "$1" in
		routing.blackhole_default_via_vpn) printf '%s\n' '10' ;;
		connectivity.wan_down) printf '%s\n' '20' ;;
		connectivity.dns_failure) printf '%s\n' '30' ;;
		operational.kill_switch_active) printf '%s\n' '40' ;;
		runtime.endpoint_unreachable) printf '%s\n' '50' ;;
		runtime.link_down) printf '%s\n' '60' ;;
		runtime.no_peers) printf '%s\n' '70' ;;
		runtime.no_handshake) printf '%s\n' '80' ;;
		runtime.stuck_tunnel) printf '%s\n' '90' ;;
		config.interface_incomplete) printf '%s\n' '100' ;;
		config.peer_missing) printf '%s\n' '110' ;;
		config.peer_incomplete) printf '%s\n' '120' ;;
		config.not_wireguard) printf '%s\n' '130' ;;
		service.enabled_mismatch) printf '%s\n' '140' ;;
		selection.drift) printf '%s\n' '150' ;;
		operational.api_cache_missing) printf '%s\n' '160' ;;
		operational.last_error) printf '%s\n' '170' ;;
		*) printf '%s\n' '900' ;;
	esac
}

nordvpn_easy_diagnostics_finding_severity() {
	case "$1" in
		routing.blackhole_default_via_vpn|connectivity.wan_down|connectivity.dns_failure|operational.kill_switch_active|runtime.endpoint_unreachable|runtime.link_down|runtime.no_peers|runtime.no_handshake|runtime.stuck_tunnel)
			printf '%s\n' 'critical'
			;;
		*)
			printf '%s\n' 'warning'
			;;
	esac
}

nordvpn_easy_diagnostics_endpoint_host() {
	local endpoint="${1:-$DIAG_WG_ENDPOINT}"
	local host=''

	case "$endpoint" in
		''|N/A|*[!0-9A-Za-z.:_-]*)
			return 1
			;;
	esac

	host="${endpoint%%:*}"
	[ -n "$host" ] || return 1
	printf '%s\n' "$host"
}

nordvpn_easy_diagnostics_add_finding() {
	local code="$1"
	local message="$2"
	local action="$3"
	local priority='900'
	local current_priority='900'

	case "$DIAG_FINDINGS_CODES" in
		''|none)
			DIAG_FINDINGS_CODES="$code"
			;;
		*)
			DIAG_FINDINGS_CODES="${DIAG_FINDINGS_CODES},${code}"
			;;
	esac

	priority="$(nordvpn_easy_diagnostics_finding_priority "$code")"
	if [ "$DIAG_PRIMARY_FINDING_CODE" != 'none' ]; then
		current_priority="$(nordvpn_easy_diagnostics_finding_priority "$DIAG_PRIMARY_FINDING_CODE")"
	fi

	if [ "$DIAG_PRIMARY_FINDING_CODE" = 'none' ] || [ "$priority" -lt "$current_priority" ]; then
		DIAG_PRIMARY_FINDING_CODE="$code"
		DIAG_PRIMARY_FINDING_MESSAGE="$message"
		DIAG_PRIMARY_FINDING_ACTION="$action"
		DIAG_PRIMARY_FINDING_PRIORITY="$priority"
		DIAG_PRIMARY_FINDING_SEVERITY="$(nordvpn_easy_diagnostics_finding_severity "$code")"
	fi

	DIAG_FINDINGS_RECORDS="${DIAG_FINDINGS_RECORDS}${code}	${message}	${action}
"
}

nordvpn_easy_diagnostics_finalize_primary_finding() {
	local code='' message='' action='' priority=''
	local best_priority='9999'

	[ -n "$DIAG_FINDINGS_RECORDS" ] || return 0

	while IFS="$(printf '\t')" read -r code message action; do
		[ -n "$code" ] || continue
		priority="$(nordvpn_easy_diagnostics_finding_priority "$code")"
		if [ "$priority" -lt "$best_priority" ]; then
			best_priority="$priority"
			DIAG_PRIMARY_FINDING_CODE="$code"
			DIAG_PRIMARY_FINDING_MESSAGE="$message"
			DIAG_PRIMARY_FINDING_ACTION="$action"
			DIAG_PRIMARY_FINDING_PRIORITY="$priority"
			DIAG_PRIMARY_FINDING_SEVERITY="$(nordvpn_easy_diagnostics_finding_severity "$code")"
		fi
	done <<EOF
$(printf '%s' "$DIAG_FINDINGS_RECORDS")
EOF
}

nordvpn_easy_diagnostics_build_findings_json() {
	if [ -z "$DIAG_FINDINGS_RECORDS" ]; then
		printf '%s\n' '[]'
		return 0
	fi

	printf '%s' "$DIAG_FINDINGS_RECORDS" | jq -R -s '
		split("\n")
		| map(select(length > 0))
		| map(split("\t"))
		| map(select(length >= 3))
		| map({
			code: .[0],
			message: .[1],
			action: .[2],
			priority: (
				.[0] as $c |
				if $c == "routing.blackhole_default_via_vpn" then 10
				elif $c == "connectivity.wan_down" then 20
				elif $c == "connectivity.dns_failure" then 30
				elif $c == "operational.kill_switch_active" then 40
				elif $c == "runtime.endpoint_unreachable" then 50
				elif $c == "runtime.link_down" then 60
				elif $c == "runtime.no_peers" then 70
				elif $c == "runtime.no_handshake" then 80
				elif $c == "runtime.stuck_tunnel" then 90
				elif $c == "config.interface_incomplete" then 100
				elif $c == "config.peer_missing" then 110
				elif $c == "config.peer_incomplete" then 120
				elif $c == "config.not_wireguard" then 130
				elif $c == "service.enabled_mismatch" then 140
				elif $c == "selection.drift" then 150
				elif $c == "operational.api_cache_missing" then 160
				elif $c == "operational.last_error" then 170
				else 900
				end
			),
			severity: (
				if (.[0] | test("^routing\\.|^connectivity\\.|^runtime\\.(endpoint_unreachable|link_down|no_peers|no_handshake|stuck_tunnel)$|^operational\\.kill_switch_active$")) then "critical"
				else "warning"
				end
			)
		})
		| sort_by(.priority)
	'
}

nordvpn_easy_emit_diagnostics_summary_json() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"
	local generated_at='0'
	local findings_json='[]'
	local status_json='null'
	local yes_no='false'

	[ "$DIAG_COLLECTED" = '1' ] || nordvpn_easy_diagnostics_collect "$vpn_if"

	generated_at="$(date +%s 2>/dev/null || printf '%s' '0')"
	findings_json="$(nordvpn_easy_diagnostics_build_findings_json)" || findings_json='[]'

	if command -v nordvpn_easy_emit_status_json >/dev/null 2>&1; then
		status_json="$(nordvpn_easy_emit_status_json 2>/dev/null)" || status_json='null'
		if ! printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
			status_json='null'
		fi
	fi

	case "$DIAG_WG_CONNECTED" in yes) yes_no='true' ;; esac

	nordvpn_easy_read_enterprise_state_snapshot_cache || true
	case "${DIAG_ENTERPRISE_STATE:-unknown}" in
		degraded)
			case "${NORDVPN_EASY_CACHED_DEGRADED_SINCE:-0}" in
				''|*[!0-9]*|0)
					DIAG_DEGRADED_SINCE='0'
					DIAG_DEGRADED_DURATION_SECONDS='0'
					;;
				*)
					DIAG_DEGRADED_SINCE="$NORDVPN_EASY_CACHED_DEGRADED_SINCE"
					case "$generated_at" in
						''|*[!0-9]*|0)
							DIAG_DEGRADED_DURATION_SECONDS='0'
							;;
						*)
							if [ "$generated_at" -ge "$NORDVPN_EASY_CACHED_DEGRADED_SINCE" ]; then
								DIAG_DEGRADED_DURATION_SECONDS=$((generated_at - NORDVPN_EASY_CACHED_DEGRADED_SINCE))
							else
								DIAG_DEGRADED_DURATION_SECONDS='0'
							fi
							;;
					esac
					;;
			esac
			;;
		*)
			DIAG_DEGRADED_SINCE='0'
			DIAG_DEGRADED_DURATION_SECONDS='0'
			;;
	esac

	jq -n \
		--argjson generated_at "${generated_at:-0}" \
		--arg vpn_if "$DIAG_VPN_IF" \
		--argjson status "$status_json" \
		--argjson findings "$findings_json" \
		--arg primary_code "$DIAG_PRIMARY_FINDING_CODE" \
		--arg primary_message "$DIAG_PRIMARY_FINDING_MESSAGE" \
		--arg primary_action "$DIAG_PRIMARY_FINDING_ACTION" \
		--arg primary_severity "${DIAG_PRIMARY_FINDING_SEVERITY:-none}" \
		--argjson primary_priority "${DIAG_PRIMARY_FINDING_PRIORITY:-900}" \
		--arg enterprise_state "$DIAG_ENTERPRISE_STATE" \
		--arg vpn_status "$DIAG_VPN_STATUS" \
		--argjson desired_enabled "$([ "$DIAG_DESIRED_ENABLED" = '1' ] && printf '%s' 'true' || printf '%s' 'false')" \
		--argjson wireguard_connected "$yes_no" \
		--arg wireguard_handshake "$DIAG_WG_HANDSHAKE" \
		--argjson wireguard_handshake_epoch "${DIAG_WG_HANDSHAKE_EPOCH:-0}" \
		--arg routing_blackhole_risk "$DIAG_ROUTING_BLACKHOLE_RISK" \
		--arg default_route_device "$DIAG_DEFAULT_ROUTE_DEVICE" \
		--arg default_route_via_vpn "$DIAG_DEFAULT_ROUTE_VIA_VPN" \
		--arg full_tunnel_routing "$DIAG_FULL_TUNNEL_ROUTING" \
		--arg transfer_asymmetry "$DIAG_TRANSFER_ASYMMETRY" \
		--argjson transfer_rx_bytes "${DIAG_TRANSFER_RX_BYTES:-0}" \
		--argjson transfer_tx_bytes "${DIAG_TRANSFER_TX_BYTES:-0}" \
		--arg wan_ping "$DIAG_WAN_PING" \
		--arg wan_device "${DIAG_WAN_DEVICE:-}" \
		--arg vpn_endpoint_host "${DIAG_VPN_ENDPOINT_HOST:-}" \
		--arg vpn_endpoint_reachable "$DIAG_VPN_ENDPOINT_REACHABLE" \
		--arg dns_api_nordvpn_com "$DIAG_DNS_API_NORDVPN_COM" \
		--argjson degraded_since "${DIAG_DEGRADED_SINCE:-0}" \
		--argjson degraded_duration_seconds "${DIAG_DEGRADED_DURATION_SECONDS:-0}" \
		--argjson diagnostics_probe_duration_ms "${DIAG_PROBE_DURATION_MS:-0}" \
		--arg api_server_list_cache "$DIAG_API_SERVER_LIST_CACHE" \
		--arg api_countries_cache "$DIAG_API_COUNTRIES_CACHE" \
		--argjson api_countries_cache_age_seconds "$(
			case "${DIAG_API_COUNTRIES_CACHE_AGE_SECONDS:-unknown}" in
				''|*[!0-9]*) printf '%s' '0' ;;
				*) printf '%s' "${DIAG_API_COUNTRIES_CACHE_AGE_SECONDS}" ;;
			esac
		)" \
		--arg last_error "$DIAG_LAST_ERROR" \
		--arg operation_lock_state "$DIAG_OPERATION_LOCK_STATE" \
		--arg operation_lock_action "${DIAG_OPERATION_LOCK_ACTION:-}" \
		--arg service_enabled_mismatch "$DIAG_SERVICE_ENABLED_MISMATCH" \
		--argjson kill_switch_enabled "$([ "$DIAG_KILL_SWITCH_ENABLED" = '1' ] && printf '%s' 'true' || printf '%s' 'false')" \
		'{
			generated_at: $generated_at,
			vpn_if: $vpn_if,
			status: $status,
			health: {
				enterprise_state: $enterprise_state,
				vpn_status: $vpn_status,
				desired_enabled: $desired_enabled,
				wireguard_connected: $wireguard_connected,
				wireguard_handshake: $wireguard_handshake,
				wireguard_handshake_epoch: $wireguard_handshake_epoch,
				routing_blackhole_risk: $routing_blackhole_risk,
				default_route_device: $default_route_device,
				default_route_via_vpn: $default_route_via_vpn,
				full_tunnel_routing: $full_tunnel_routing,
				transfer_asymmetry: $transfer_asymmetry,
				transfer_rx_bytes: $transfer_rx_bytes,
				transfer_tx_bytes: $transfer_tx_bytes,
				service_enabled_mismatch: $service_enabled_mismatch,
				kill_switch_enabled: $kill_switch_enabled,
				degraded_since: (if $degraded_since > 0 then $degraded_since else null end),
				degraded_duration_seconds: (if $degraded_duration_seconds > 0 then $degraded_duration_seconds else null end)
			},
			connectivity: {
				routing_blackhole_risk: $routing_blackhole_risk,
				default_route_device: $default_route_device,
				wireguard_connected: $wireguard_connected,
				wan_device: (if ($wan_device | length) > 0 then $wan_device else null end),
				wan_ping: $wan_ping,
				vpn_endpoint_host: (if ($vpn_endpoint_host | length) > 0 then $vpn_endpoint_host else null end),
				vpn_endpoint_reachable: $vpn_endpoint_reachable,
				dns_api_nordvpn_com: $dns_api_nordvpn_com,
				api_server_list_cache: $api_server_list_cache,
				diagnostics_probe_duration_ms: $diagnostics_probe_duration_ms
			},
			caches: {
				last_error: $last_error,
				operation_lock_state: $operation_lock_state,
				operation_lock_action: $operation_lock_action,
				server_list_cache_path: "/tmp/nordvpn.json",
				server_list_cache_state: $api_server_list_cache,
				countries_cache_path: "/tmp/nordvpn-easy-countries.json",
				countries_cache_state: $api_countries_cache,
				countries_cache_age_seconds: $api_countries_cache_age_seconds
			},
			primary_finding: {
				code: $primary_code,
				message: $primary_message,
				action: $primary_action,
				severity: $primary_severity,
				priority: $primary_priority
			},
			findings: $findings
		}'
}

nordvpn_easy_diagnostics_collect_config() {
	local vpn_if="$1"
	local value=''

	DIAG_VPN_PROTO='absent'
	DIAG_INTERFACE_DISABLED='0'
	DIAG_PRIVATE_KEY_STATE='missing'
	DIAG_PEER_SECTIONS='none'
	DIAG_PEER_SECTION_FOUND='no'
	DIAG_MISSING_INTERFACE=''
	DIAG_MISSING_REQUIRED=''
	DIAG_ROUTE_ALLOWED_IPS=''
	DIAG_FULL_TUNNEL_ROUTING='no'

	[ -n "$vpn_if" ] || return 0
	command -v uci >/dev/null 2>&1 || {
		DIAG_MISSING_REQUIRED='uci_command'
		return 0
	}

	DIAG_VPN_PROTO="$(uci -q get "network.${vpn_if}.proto" 2>/dev/null || printf '%s' 'absent')"
	DIAG_INTERFACE_DISABLED="$(uci -q get "network.${vpn_if}.disabled" 2>/dev/null || printf '%s' '0')"
	if uci -q get "network.${vpn_if}.private_key" >/dev/null 2>&1; then
		DIAG_PRIVATE_KEY_STATE='present'
	fi

	if [ "$DIAG_VPN_PROTO" = 'wireguard' ]; then
		for value in private_key addresses peerdns delegate force_link; do
			if ! uci -q get "network.${vpn_if}.${value}" >/dev/null 2>&1; then
				DIAG_MISSING_INTERFACE="$(nordvpn_easy_diagnostics_csv_append "$DIAG_MISSING_INTERFACE" "$value")"
			fi
		done
	fi

	DIAG_PEER_SECTIONS="$(
		uci show network 2>/dev/null | awk -F '[.=]' '
			$1 == "network" && $3 ~ /^wireguard_/ {
				if (out != "")
					out = out "," $2
				else
					out = $2
			}
			END { print out }
		'
	)"
	[ -n "$DIAG_PEER_SECTIONS" ] || DIAG_PEER_SECTIONS='none'

	DIAG_PEER_SECTION="$(nordvpn_easy_diagnostics_peer_section_name "$vpn_if" 2>/dev/null || true)"
	if [ -n "$DIAG_PEER_SECTION" ]; then
		DIAG_PEER_SECTION_FOUND='yes'
		for value in endpoint_host public_key allowed_ips route_allowed_ips; do
			if ! uci -q get "network.${DIAG_PEER_SECTION}.${value}" >/dev/null 2>&1; then
				DIAG_MISSING_REQUIRED="$(nordvpn_easy_diagnostics_csv_append "$DIAG_MISSING_REQUIRED" "$value")"
			fi
		done
		DIAG_CURRENT_SERVER_COUNTRY="$(uci -q get "network.${DIAG_PEER_SECTION}.nordvpn_country_code" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
		DIAG_CURRENT_STATION="$(uci -q get "network.${DIAG_PEER_SECTION}.nordvpn_station" 2>/dev/null || true)"
		DIAG_ROUTE_ALLOWED_IPS="$(uci -q get "network.${DIAG_PEER_SECTION}.route_allowed_ips" 2>/dev/null || true)"
		if [ "$DIAG_ROUTE_ALLOWED_IPS" = '1' ] &&
			nordvpn_easy_diagnostics_peer_allowed_ips_contains_full_tunnel "$DIAG_PEER_SECTION"; then
			DIAG_FULL_TUNNEL_ROUTING='yes'
		fi
	else
		DIAG_MISSING_REQUIRED='peer_section'
	fi

	DIAG_SELECTION_MODE="$(uci -q get 'nordvpn_easy.main.server_selection_mode' 2>/dev/null || printf '%s' 'auto')"
	DIAG_SELECTED_COUNTRY="$(uci -q get 'nordvpn_easy.main.vpn_country' 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
	DIAG_PREFERRED_STATION="$(uci -q get 'nordvpn_easy.main.preferred_server_station' 2>/dev/null || true)"
	DIAG_SERVICE_ENABLED="$(uci -q get 'nordvpn_easy.main.enabled' 2>/dev/null || printf '%s' '0')"
	case "$DIAG_SERVICE_ENABLED" in
		1|true|yes|on)
			DIAG_SERVICE_ENABLED='1'
			;;
		*)
			DIAG_SERVICE_ENABLED='0'
			;;
	esac
	DIAG_WAN_IF="$(uci -q get 'nordvpn_easy.main.wan_if' 2>/dev/null || printf '%s' 'wan')"
	DIAG_KILL_SWITCH_ENABLED="$(uci -q get 'nordvpn_easy.main.kill_switch_enabled' 2>/dev/null || printf '%s' '0')"
	case "$DIAG_KILL_SWITCH_ENABLED" in
		1|true|yes|on)
			DIAG_KILL_SWITCH_ENABLED='1'
			;;
		*)
			DIAG_KILL_SWITCH_ENABLED='0'
			;;
	esac

	if [ "$DIAG_SELECTION_MODE" = 'manual' ]; then
		if [ -n "$DIAG_PREFERRED_STATION" ] && [ -n "$DIAG_CURRENT_STATION" ] &&
			[ "$DIAG_PREFERRED_STATION" != "$DIAG_CURRENT_STATION" ]; then
			DIAG_SERVER_SELECTION_DRIFT="manual preferred server drift (preferred_station=${DIAG_PREFERRED_STATION}, current_station=${DIAG_CURRENT_STATION})"
		fi
	elif [ -n "$DIAG_SELECTED_COUNTRY" ] && [ -n "$DIAG_CURRENT_SERVER_COUNTRY" ] &&
		[ "$DIAG_SELECTED_COUNTRY" != "$DIAG_CURRENT_SERVER_COUNTRY" ]; then
		DIAG_SERVER_SELECTION_DRIFT="country drift (selected_country=${DIAG_SELECTED_COUNTRY}, current_server_country=${DIAG_CURRENT_SERVER_COUNTRY}, current_station=${DIAG_CURRENT_STATION:-unknown})"
	fi

	if [ "$DIAG_SERVICE_ENABLED" = '1' ] && [ "$DIAG_INTERFACE_DISABLED" = '1' ]; then
		DIAG_SERVICE_ENABLED_MISMATCH='yes'
	elif [ "$DIAG_SERVICE_ENABLED" = '0' ] && [ "$DIAG_INTERFACE_DISABLED" != '1' ] &&
		[ "$DIAG_VPN_PROTO" = 'wireguard' ]; then
		DIAG_SERVICE_ENABLED_MISMATCH='yes'
	else
		DIAG_SERVICE_ENABLED_MISMATCH='no'
	fi
}

nordvpn_easy_diagnostics_collect_runtime() {
	local vpn_if="$1"
	local runtime_configured='no'
	local operation='idle'

	[ -n "$vpn_if" ] || return 0

	if command -v nordvpn_easy_collect_wireguard_runtime_snapshot >/dev/null 2>&1; then
		nordvpn_easy_collect_wireguard_runtime_snapshot "$vpn_if"
		DIAG_LINK_PRESENT="$NORDVPN_EASY_WG_RT_LINK_PRESENT"
		DIAG_ROUTES_VIA_VPN="$NORDVPN_EASY_WG_RT_ROUTES_COUNT"
		DIAG_WG_PEER_COUNT="$NORDVPN_EASY_WG_RT_PEER_COUNT"
		DIAG_WG_ENDPOINT="$NORDVPN_EASY_WG_RT_ENDPOINT"
		DIAG_WG_HANDSHAKE_EPOCH="$NORDVPN_EASY_WG_RT_HANDSHAKE_EPOCH"
		DIAG_WG_HANDSHAKE="$NORDVPN_EASY_WG_RT_HANDSHAKE"
		DIAG_TRANSFER_RX_BYTES="$NORDVPN_EASY_WG_RT_TRANSFER_RX_BYTES"
		DIAG_TRANSFER_TX_BYTES="$NORDVPN_EASY_WG_RT_TRANSFER_TX_BYTES"
		DIAG_WG_CONNECTED="$NORDVPN_EASY_WG_RT_CONNECTED"
		DIAG_TRANSFER_ASYMMETRY="$NORDVPN_EASY_WG_RT_TRANSFER_ASYMMETRY"
	fi

	DIAG_DESIRED_ENABLED="$DIAG_SERVICE_ENABLED"
	if command -v nordvpn_easy_runtime_configured >/dev/null 2>&1 &&
		nordvpn_easy_runtime_configured "$vpn_if"; then
		runtime_configured='yes'
	fi

	if command -v nordvpn_easy_load_lock_metadata >/dev/null 2>&1; then
		nordvpn_easy_load_lock_metadata "${LOCK_DIR:-/tmp/nordvpn-easy.lock}"
		operation="$(nordvpn_easy_operation_status_from_loaded_lock 2>/dev/null || printf '%s' 'idle')"
		DIAG_OPERATION_LOCK_STATE="${OPERATION_LOCK_STATE:-none}"
		DIAG_OPERATION_LOCK_ACTION="${OPERATION_LOCK_ACTION:-}"
	fi

	if command -v nordvpn_easy_vpn_status_value >/dev/null 2>&1; then
		DIAG_VPN_STATUS="$(nordvpn_easy_vpn_status_value "$DIAG_DESIRED_ENABLED" "$vpn_if" "$operation")"
	fi

	DIAG_ENTERPRISE_STATE="$(nordvpn_easy_enterprise_state_value \
		"$DIAG_DESIRED_ENABLED" \
		"$DIAG_INTERFACE_DISABLED" \
		"$runtime_configured" \
		"$DIAG_WG_CONNECTED" \
		"$operation")"
}

nordvpn_easy_diagnostics_collect_routing() {
	local vpn_if="$1"
	local default_device=''

	[ -n "$vpn_if" ] || return 0
	command -v ip >/dev/null 2>&1 || return 0

	default_device="$(nordvpn_easy_diagnostics_default_route_device)"
	[ -n "$default_device" ] || default_device='none'
	DIAG_DEFAULT_ROUTE_DEVICE="$default_device"

	if [ "$default_device" = "$vpn_if" ]; then
		DIAG_DEFAULT_ROUTE_VIA_VPN='yes'
	else
		DIAG_DEFAULT_ROUTE_VIA_VPN='no'
	fi

	if [ "$DIAG_DEFAULT_ROUTE_VIA_VPN" = 'yes' ] && [ "$DIAG_WG_CONNECTED" != 'yes' ]; then
		DIAG_ROUTING_BLACKHOLE_RISK='yes'
	fi
}

nordvpn_easy_diagnostics_collect_caches() {
	local countries_age=''

	DIAG_API_SERVER_LIST_CACHE="$(nordvpn_easy_diagnostics_server_list_cache_state)"
	DIAG_API_COUNTRIES_CACHE="$(nordvpn_easy_diagnostics_countries_cache_state)"
	countries_age="$(printf '%s' "$DIAG_API_COUNTRIES_CACHE" | sed -n '2p')"
	DIAG_API_COUNTRIES_CACHE="$(printf '%s' "$DIAG_API_COUNTRIES_CACHE" | sed -n '1p')"
	DIAG_API_COUNTRIES_CACHE_AGE_SECONDS="${countries_age:-unknown}"

	if [ -r "${NORDVPN_EASY_LAST_ERROR_CACHE:-/tmp/run/nordvpn-easy/last_error}" ]; then
		DIAG_LAST_ERROR="$(sed -n '1p' "${NORDVPN_EASY_LAST_ERROR_CACHE:-/tmp/run/nordvpn-easy/last_error}" 2>/dev/null | tr -d '\r')"
	fi
}

nordvpn_easy_diagnostics_run_active_probes() {
	local vpn_if="$1"
	local probe_start probe_end wan_ns dns_out

	case "${NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES:-1}" in
		0|false|no|off)
			DIAG_WAN_PING='skipped'
			DIAG_DNS_API_NORDVPN_COM='skipped'
			DIAG_VPN_ENDPOINT_REACHABLE='skipped'
			return 0
			;;
	esac

	DIAG_VPN_ENDPOINT_REACHABLE='skipped'
	DIAG_VPN_ENDPOINT_HOST="$(nordvpn_easy_diagnostics_endpoint_host "$DIAG_WG_ENDPOINT" 2>/dev/null || true)"

	probe_start="$(date +%s 2>/dev/null || printf '%s' '0')"
	DIAG_WAN_DEVICE=''
	if command -v nordvpn_easy_resolve_wan_device >/dev/null 2>&1; then
		WAN_IF="$DIAG_WAN_IF"
		if nordvpn_easy_resolve_wan_device; then
			DIAG_WAN_DEVICE="$WAN_DEVICE"
		fi
	fi

	if [ -n "$DIAG_WAN_DEVICE" ] &&
		ping -q -c 1 -W 3 "$(nordvpn_easy_diagnostics_pick_ping_ip)" -I "$DIAG_WAN_DEVICE" >/dev/null 2>&1; then
		DIAG_WAN_PING='yes'
	else
		DIAG_WAN_PING='no'
	fi

	wan_ns="$(nordvpn_easy_diagnostics_resolve_wan_nameserver)"
	if [ -n "$wan_ns" ] && command -v nslookup >/dev/null 2>&1; then
		dns_out="$(nslookup api.nordvpn.com "$wan_ns" 2>/dev/null | awk '/^Address [0-9]+: / { print $3; exit }')"
		if [ -n "$dns_out" ]; then
			DIAG_DNS_API_NORDVPN_COM='ok'
		else
			DIAG_DNS_API_NORDVPN_COM='failed'
		fi
	elif command -v nslookup >/dev/null 2>&1 &&
		nslookup api.nordvpn.com 2>/dev/null | awk '/^Address [0-9]+: / { print $3; exit }' | grep -q '.'; then
		DIAG_DNS_API_NORDVPN_COM='ok'
	else
		DIAG_DNS_API_NORDVPN_COM='failed'
	fi

	if [ -n "$DIAG_VPN_ENDPOINT_HOST" ]; then
		if [ -n "$DIAG_WAN_DEVICE" ] &&
			ping -q -c 1 -W 3 "$DIAG_VPN_ENDPOINT_HOST" -I "$DIAG_WAN_DEVICE" >/dev/null 2>&1; then
			DIAG_VPN_ENDPOINT_REACHABLE='yes'
		elif ping -q -c 1 -W 3 "$DIAG_VPN_ENDPOINT_HOST" >/dev/null 2>&1; then
			DIAG_VPN_ENDPOINT_REACHABLE='yes'
		else
			DIAG_VPN_ENDPOINT_REACHABLE='no'
		fi
	fi

	probe_end="$(date +%s 2>/dev/null || printf '%s' '0')"
	case "$probe_start" in
		''|*[!0-9]*|0)
			DIAG_PROBE_DURATION_MS='0'
			;;
		*)
			case "$probe_end" in
				''|*[!0-9]*)
					DIAG_PROBE_DURATION_MS='0'
					;;
				*)
					DIAG_PROBE_DURATION_MS=$(( (probe_end - probe_start) * 1000 ))
					;;
			esac
			;;
	esac
}

nordvpn_easy_diagnostics_compute_findings() {
	DIAG_PRIMARY_FINDING_CODE='none'
	DIAG_PRIMARY_FINDING_MESSAGE='none detected'
	DIAG_PRIMARY_FINDING_ACTION=''
	DIAG_FINDINGS_CODES='none'

	if [ -n "$DIAG_MISSING_INTERFACE" ]; then
		nordvpn_easy_diagnostics_add_finding \
			'config.interface_incomplete' \
			"wireguard interface is incomplete (${DIAG_MISSING_INTERFACE})" \
			'Complete the WireGuard interface keys in Network settings, then run Connect'
	fi

	if [ "$DIAG_PEER_SECTION_FOUND" != 'yes' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'config.peer_missing' \
			'wireguard interface exists but peer section is missing' \
			'Run Connect or Setup to create the WireGuard peer section'
	fi

	if [ -n "$DIAG_MISSING_REQUIRED" ] && [ "$DIAG_MISSING_REQUIRED" != 'peer_section' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'config.peer_incomplete' \
			"wireguard peer section is incomplete (${DIAG_MISSING_REQUIRED})" \
			'Complete endpoint, keys, and allowed_ips on the WireGuard peer, then run Connect'
	fi

	if [ "$DIAG_SERVICE_ENABLED_MISMATCH" = 'yes' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'service.enabled_mismatch' \
			'NordVPN Easy enabled flag does not match network interface disabled state' \
			'Use Connect to align service state or disable the VPN from LuCI'
	fi

	if [ "$DIAG_ROUTING_BLACKHOLE_RISK" = 'yes' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'routing.blackhole_default_via_vpn' \
			"default route uses ${DIAG_VPN_IF} but WireGuard has no handshake (likely traffic blackhole)" \
			"Disconnect VPN or run ifdown ${DIAG_VPN_IF} to restore WAN connectivity, then Connect again"
	fi

	if [ "$DIAG_LINK_PRESENT" = 'yes' ] && [ "$DIAG_PEER_SECTION_FOUND" = 'yes' ] &&
		[ "$DIAG_WG_CONNECTED" != 'yes' ] && [ "$DIAG_WG_PEER_COUNT" != '0' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'runtime.no_handshake' \
			'WireGuard peer is configured but no recent handshake was observed' \
			'Check UDP port 51820, upstream NAT, MTU, and try rotating the VPN server'
	fi

	if [ "$DIAG_TRANSFER_ASYMMETRY" = 'stuck_tunnel_suspected' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'runtime.stuck_tunnel' \
			'WireGuard is sending traffic but receiving none (stuck tunnel suspected)' \
			'Verify endpoint reachability, firewall UDP rules, and try another NordVPN server'
	fi

	if [ "$DIAG_KILL_SWITCH_ENABLED" = '1' ] && [ "$DIAG_WG_CONNECTED" != 'yes' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'operational.kill_switch_active' \
			'Kill switch is enabled while the VPN tunnel is not connected' \
			'Restore VPN connectivity or disable kill switch if all traffic is blocked'
	fi

	if [ "$DIAG_DESIRED_ENABLED" = '1' ] && [ "$DIAG_WAN_PING" = 'no' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'connectivity.wan_down' \
			'WAN connectivity probe failed while VPN is enabled' \
			'Restore upstream Internet on the WAN interface before retrying VPN setup'
	fi

	if [ "$DIAG_DNS_API_NORDVPN_COM" = 'failed' ] && [ "$DIAG_WAN_PING" = 'yes' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'connectivity.dns_failure' \
			'DNS resolution for api.nordvpn.com failed while WAN ping succeeded' \
			'Fix DNS on WAN; avoid routing all traffic through the VPN until the tunnel is connected'
	fi

	if [ "$DIAG_VPN_ENDPOINT_REACHABLE" = 'no' ] && [ "$DIAG_WAN_PING" = 'yes' ] &&
		[ "$DIAG_WG_CONNECTED" != 'yes' ] && [ -n "$DIAG_VPN_ENDPOINT_HOST" ]; then
		nordvpn_easy_diagnostics_add_finding \
			'runtime.endpoint_unreachable' \
			"WireGuard endpoint ${DIAG_VPN_ENDPOINT_HOST} is not reachable from WAN while the tunnel is down" \
			'Check UDP port 51820, upstream firewall/NAT, and try another NordVPN server'
	fi

	if [ "$DIAG_SELECTION_MODE" = 'auto' ] && [ "$DIAG_API_SERVER_LIST_CACHE" = 'missing' ] &&
		[ -n "$DIAG_LAST_ERROR" ]; then
		nordvpn_easy_diagnostics_add_finding \
			'operational.api_cache_missing' \
			'Recommended server list cache is missing after a recent failure' \
			'Restore WAN/DNS reachability, then run Connect or Setup again'
	fi

	if [ -n "$DIAG_LAST_ERROR" ] && [ "$DIAG_PRIMARY_FINDING_CODE" = 'none' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'operational.last_error' \
			"last recorded error: ${DIAG_LAST_ERROR}" \
			'Review the NordVPN Easy log section below for the matching failure'
	fi

	if [ "$DIAG_SERVER_SELECTION_DRIFT" != 'none' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'selection.drift' \
			"$DIAG_SERVER_SELECTION_DRIFT" \
			'Run Reconcile or Connect to apply the selected country or preferred server'
	fi

	if [ "$DIAG_WG_PEER_COUNT" = '0' ] && [ "$DIAG_LINK_PRESENT" = 'yes' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'runtime.no_peers' \
			'WireGuard runtime has no peers' \
			'Run Setup or restart the VPN interface from LuCI'
	fi

	if [ "$DIAG_LINK_PRESENT" = 'no' ] && [ "$DIAG_DESIRED_ENABLED" = '1' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'runtime.link_down' \
			'WireGuard link is not present while VPN is enabled' \
			'Run Connect or check network.wg0.disabled in UCI'
	fi

	if [ "$DIAG_VPN_PROTO" != 'wireguard' ] && [ "$DIAG_DESIRED_ENABLED" = '1' ]; then
		nordvpn_easy_diagnostics_add_finding \
			'config.not_wireguard' \
			'VPN interface is not configured as WireGuard' \
			'Run Setup to create the NordVPN WireGuard interface'
	fi

	nordvpn_easy_diagnostics_finalize_primary_finding
}

nordvpn_easy_try_clear_routing_blackhole() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"
	local phase="${2:-healthcheck}"
	local previous_active_probes="${NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES:-1}"

	if ! command -v nordvpn_easy_diagnostics_collect >/dev/null 2>&1; then
		return 1
	fi

	NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES=0
	nordvpn_easy_diagnostics_collect "$vpn_if"
	NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES="$previous_active_probes"

	if [ "$DIAG_ROUTING_BLACKHOLE_RISK" != 'yes' ]; then
		nordvpn_easy_diagnostics_reset_state
		return 1
	fi

	log "$phase: default route uses $vpn_if without WireGuard handshake; running ifdown to restore WAN connectivity"
	ifdown "$vpn_if" 2>/dev/null || log "WARNING: $phase: ifdown failed for $vpn_if while clearing routing blackhole"
	sleep "${INTERFACE_RESTART_DELAY:-2}"
	nordvpn_easy_diagnostics_reset_state
	return 0
}

nordvpn_easy_diagnostics_collect() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"

	nordvpn_easy_diagnostics_reset_state
	DIAG_VPN_IF="$vpn_if"
	nordvpn_easy_diagnostics_collect_config "$vpn_if"
	nordvpn_easy_diagnostics_collect_runtime "$vpn_if"
	nordvpn_easy_diagnostics_collect_routing "$vpn_if"
	nordvpn_easy_diagnostics_collect_caches
	nordvpn_easy_diagnostics_run_active_probes "$vpn_if"
	nordvpn_easy_diagnostics_compute_findings
	DIAG_COLLECTED='1'
}

nordvpn_easy_diagnostics_print_health_summary() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"

	[ "$DIAG_COLLECTED" = '1' ] || nordvpn_easy_diagnostics_collect "$vpn_if"

	nordvpn_easy_diagnostics_section 'Health summary'

	printf 'vpn_proto=%s\n' "$DIAG_VPN_PROTO"
	printf 'interface_disabled=%s\n' "$DIAG_INTERFACE_DISABLED"
	printf 'private_key=%s\n' "$DIAG_PRIVATE_KEY_STATE"
	printf 'required_interface_keys_missing=%s\n' "${DIAG_MISSING_INTERFACE:-none}"
	printf 'convention_peer_section=%sserver\n' "$vpn_if"
	printf 'peer_section_found=%s\n' "$DIAG_PEER_SECTION_FOUND"
	printf 'peer_section=%s\n' "${DIAG_PEER_SECTION:-none}"
	printf 'wireguard_peer_sections=%s\n' "$DIAG_PEER_SECTIONS"
	printf 'required_peer_keys_missing=%s\n' "${DIAG_MISSING_REQUIRED:-none}"
	printf 'link_present=%s\n' "$DIAG_LINK_PRESENT"
	printf 'wg_peer_count=%s\n' "$DIAG_WG_PEER_COUNT"
	printf 'routes_via_%s=%s\n' "$vpn_if" "$DIAG_ROUTES_VIA_VPN"
	printf 'server_selection_drift=%s\n' "$DIAG_SERVER_SELECTION_DRIFT"
	printf 'wireguard_handshake_epoch=%s\n' "$DIAG_WG_HANDSHAKE_EPOCH"
	printf 'wireguard_handshake=%s\n' "$DIAG_WG_HANDSHAKE"
	printf 'wireguard_connected=%s\n' "$DIAG_WG_CONNECTED"
	printf 'enterprise_state=%s\n' "$DIAG_ENTERPRISE_STATE"
	printf 'vpn_status=%s\n' "$DIAG_VPN_STATUS"
	printf 'desired_enabled=%s\n' "$DIAG_DESIRED_ENABLED"
	printf 'service_enabled_mismatch=%s\n' "$DIAG_SERVICE_ENABLED_MISMATCH"
	printf 'default_route_device=%s\n' "$DIAG_DEFAULT_ROUTE_DEVICE"
	printf 'default_route_via_vpn=%s\n' "$DIAG_DEFAULT_ROUTE_VIA_VPN"
	printf 'route_allowed_ips=%s\n' "${DIAG_ROUTE_ALLOWED_IPS:-unset}"
	printf 'full_tunnel_routing=%s\n' "$DIAG_FULL_TUNNEL_ROUTING"
	printf 'routing_blackhole_risk=%s\n' "$DIAG_ROUTING_BLACKHOLE_RISK"
	printf 'transfer_rx_bytes=%s\n' "$DIAG_TRANSFER_RX_BYTES"
	printf 'transfer_tx_bytes=%s\n' "$DIAG_TRANSFER_TX_BYTES"
	printf 'transfer_asymmetry=%s\n' "$DIAG_TRANSFER_ASYMMETRY"
	printf 'wan_ping=%s\n' "$DIAG_WAN_PING"
	printf 'vpn_endpoint_host=%s\n' "${DIAG_VPN_ENDPOINT_HOST:-none}"
	printf 'vpn_endpoint_reachable=%s\n' "$DIAG_VPN_ENDPOINT_REACHABLE"
	printf 'dns_api_nordvpn_com=%s\n' "$DIAG_DNS_API_NORDVPN_COM"
	printf 'probable_issue_code=%s\n' "$DIAG_PRIMARY_FINDING_CODE"
	printf 'probable_issue_severity=%s\n' "${DIAG_PRIMARY_FINDING_SEVERITY:-none}"
	printf 'probable_issue_priority=%s\n' "${DIAG_PRIMARY_FINDING_PRIORITY:-0}"
	printf 'probable_issues=%s\n' "$DIAG_FINDINGS_CODES"
	printf 'probable_issue=%s\n' "$DIAG_PRIMARY_FINDING_MESSAGE"
	printf 'recommended_action=%s\n' "$DIAG_PRIMARY_FINDING_ACTION"
}

nordvpn_easy_diagnostics_print_connectivity_assessment() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"

	[ "$DIAG_COLLECTED" = '1' ] || nordvpn_easy_diagnostics_collect "$vpn_if"

	nordvpn_easy_diagnostics_section 'Connectivity assessment'
	printf 'routing_blackhole_risk=%s\n' "$DIAG_ROUTING_BLACKHOLE_RISK"
	printf 'default_route_device=%s\n' "$DIAG_DEFAULT_ROUTE_DEVICE"
	printf 'wireguard_connected=%s\n' "$DIAG_WG_CONNECTED"
	printf 'enterprise_state=%s\n' "$DIAG_ENTERPRISE_STATE"
	printf 'wan_device=%s\n' "${DIAG_WAN_DEVICE:-none}"
	printf 'wan_ping=%s\n' "$DIAG_WAN_PING"
	printf 'vpn_endpoint_host=%s\n' "${DIAG_VPN_ENDPOINT_HOST:-none}"
	printf 'vpn_endpoint_reachable=%s\n' "$DIAG_VPN_ENDPOINT_REACHABLE"
	printf 'dns_api_nordvpn_com=%s\n' "$DIAG_DNS_API_NORDVPN_COM"
	printf 'api_server_list_cache=%s\n' "$DIAG_API_SERVER_LIST_CACHE"
	printf 'diagnostics_probe_duration_ms=%s\n' "$DIAG_PROBE_DURATION_MS"
}

nordvpn_easy_diagnostics_print_runtime_caches() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"

	[ "$DIAG_COLLECTED" = '1' ] || nordvpn_easy_diagnostics_collect "$vpn_if"

	nordvpn_easy_diagnostics_section 'Runtime caches & locks'
	printf 'last_error=%s\n' "$DIAG_LAST_ERROR"
	printf 'operation_lock_state=%s\n' "$DIAG_OPERATION_LOCK_STATE"
	printf 'operation_lock_action=%s\n' "${DIAG_OPERATION_LOCK_ACTION:-none}"
	printf 'server_list_cache_path=%s\n' "${SERVER_LIST_FILE:-/tmp/nordvpn.json}"
	printf 'server_list_cache_state=%s\n' "$DIAG_API_SERVER_LIST_CACHE"
	printf 'countries_cache_path=%s\n' "${COUNTRIES_CACHE_FILE:-/tmp/nordvpn-easy-countries.json}"
	printf 'countries_cache_state=%s\n' "$DIAG_API_COUNTRIES_CACHE"
	printf 'countries_cache_age_seconds=%s\n' "$DIAG_API_COUNTRIES_CACHE_AGE_SECONDS"
}

nordvpn_easy_print_diagnostics_health_summary() {
	nordvpn_easy_diagnostics_print_health_summary "$@"
}

nordvpn_easy_diagnostics_summary_json() {
	nordvpn_easy_emit_diagnostics_summary_json "$@"
}

nordvpn_easy_read_enterprise_state_snapshot_cache() {
	local cache_file="${1:-${NORDVPN_EASY_ENTERPRISE_STATE_CACHE:-/tmp/run/nordvpn-easy/enterprise_state_last}}"

	NORDVPN_EASY_CACHED_ENTERPRISE_STATE=''
	NORDVPN_EASY_CACHED_PROBABLE_ISSUE_CODE='none'
	NORDVPN_EASY_CACHED_DEGRADED_SINCE='0'
	[ -r "$cache_file" ] || return 1

	NORDVPN_EASY_CACHED_ENTERPRISE_STATE="$(sed -n 's/^enterprise_state=//p' "$cache_file" | sed -n '1p')"
	NORDVPN_EASY_CACHED_PROBABLE_ISSUE_CODE="$(sed -n 's/^probable_issue_code=//p' "$cache_file" | sed -n '1p')"
	NORDVPN_EASY_CACHED_DEGRADED_SINCE="$(sed -n 's/^degraded_since=//p' "$cache_file" | sed -n '1p')"
	[ -n "$NORDVPN_EASY_CACHED_ENTERPRISE_STATE" ]
}

nordvpn_easy_write_enterprise_state_snapshot_cache() {
	local state="$1"
	local issue_code="$2"
	local degraded_since="${3:-0}"
	local cache_file="${4:-${NORDVPN_EASY_ENTERPRISE_STATE_CACHE:-/tmp/run/nordvpn-easy/enterprise_state_last}}"
	local cache_dir cache_tmp

	[ -n "$state" ] || return 1
	[ -n "$issue_code" ] || issue_code='none'
	case "$degraded_since" in
		''|*[!0-9]*) degraded_since='0' ;;
	esac

	cache_dir="$(dirname "$cache_file")"
	mkdir -p "$cache_dir" || return 1
	cache_tmp="${cache_file}.$$"
	{
		printf 'enterprise_state=%s\n' "$state"
		printf 'probable_issue_code=%s\n' "$issue_code"
		printf 'degraded_since=%s\n' "$degraded_since"
	} > "$cache_tmp" || {
		rm -f "$cache_tmp"
		return 1
	}
	mv "$cache_tmp" "$cache_file"
}

nordvpn_easy_diagnostics_append_history() {
	local event="$1"
	local state="$2"
	local issue_code="$3"
	local history_file="${4:-${NORDVPN_EASY_DIAGNOSTICS_HISTORY:-/tmp/run/nordvpn-easy/diagnostics_history.log}}"
	local history_dir history_tmp now_ts line_count

	[ -n "$event" ] || return 0
	now_ts="$(date +%s 2>/dev/null || printf '%s' '0')"
	history_dir="$(dirname "$history_file")"
	mkdir -p "$history_dir" || return 0
	history_tmp="${history_file}.$$"
	{
		[ -f "$history_file" ] && tail -n 19 "$history_file"
		printf '%s event=%s state=%s probable_issue_code=%s\n' \
			"$now_ts" "$event" "$state" "${issue_code:-none}"
	} > "$history_tmp" 2>/dev/null || {
		rm -f "$history_tmp"
		return 0
	}
	mv "$history_tmp" "$history_file" 2>/dev/null || rm -f "$history_tmp"
}

nordvpn_easy_log_enterprise_state_if_degraded() {
	local vpn_if="${1:-${VPN_IF:-wg0}}"
	local phase="${2:-healthcheck}"
	local previous_state=''
	local previous_code='none'
	local previous_degraded_since='0'
	local next_degraded_since='0'
	local now_ts='0'
	local recovery_duration='0'
	local previous_active_probes="${NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES:-1}"

	command -v nordvpn_easy_diagnostics_collect >/dev/null 2>&1 || return 0

	nordvpn_easy_read_enterprise_state_snapshot_cache || true
	previous_state="${NORDVPN_EASY_CACHED_ENTERPRISE_STATE:-}"
	previous_code="${NORDVPN_EASY_CACHED_PROBABLE_ISSUE_CODE:-none}"
	previous_degraded_since="${NORDVPN_EASY_CACHED_DEGRADED_SINCE:-0}"
	now_ts="$(date +%s 2>/dev/null || printf '%s' '0')"

	NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES=0
	nordvpn_easy_diagnostics_collect "$vpn_if"
	NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES="$previous_active_probes"

	case "$DIAG_ENTERPRISE_STATE" in
		degraded)
			next_degraded_since="$previous_degraded_since"
			case "$next_degraded_since" in
				''|*[!0-9]*|0)
					next_degraded_since="$now_ts"
					;;
			esac
			if [ "$previous_state" != 'degraded' ]; then
				nordvpn_easy_log_phase "$phase" \
					"VPN state degraded: probable_issue_code=${DIAG_PRIMARY_FINDING_CODE:-none} severity=${DIAG_PRIMARY_FINDING_SEVERITY:-none}"
				nordvpn_easy_diagnostics_append_history \
					'entered_degraded' \
					"$DIAG_ENTERPRISE_STATE" \
					"$DIAG_PRIMARY_FINDING_CODE"
			fi
			;;
		*)
			next_degraded_since='0'
			if [ "$previous_state" = 'degraded' ]; then
				case "$previous_degraded_since" in
					''|*[!0-9]*|0) recovery_duration='0' ;;
					*)
						case "$now_ts" in
							''|*[!0-9]*|0) recovery_duration='0' ;;
							*)
								if [ "$now_ts" -ge "$previous_degraded_since" ]; then
									recovery_duration=$((now_ts - previous_degraded_since))
								fi
								;;
						esac
						;;
				esac
				nordvpn_easy_log_phase "$phase" \
					"VPN state recovered: was probable_issue_code=${previous_code:-none} for ${recovery_duration}s; now state=${DIAG_ENTERPRISE_STATE:-unknown}"
				nordvpn_easy_diagnostics_append_history \
					'recovered' \
					"$DIAG_ENTERPRISE_STATE" \
					"$previous_code"
			fi
			;;
	esac

	nordvpn_easy_write_enterprise_state_snapshot_cache \
		"$DIAG_ENTERPRISE_STATE" \
		"$DIAG_PRIMARY_FINDING_CODE" \
		"$next_degraded_since" || true

	return 0
}
