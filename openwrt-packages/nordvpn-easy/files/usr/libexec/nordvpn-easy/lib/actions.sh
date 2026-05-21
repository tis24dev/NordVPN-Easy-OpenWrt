#!/bin/sh

# This module is sourced by core.sh. Some orchestration helpers remain provided
# by core.sh (for example fetch_server_catalog, resolve_country_filter,
# refresh_countries_cache and get_private_key), so validate that sourcing
# contract when these code paths execute.

nordvpn_easy_require_core_action_helpers() {
	local helper

	for helper in "$@"; do
		command -v "$helper" >/dev/null 2>&1 || {
			printf '%s\n' "nordvpn-easy: lib/actions.sh requires helper '$helper' from core.sh before invocation" >&2
			return 1
		}
	done
}

nordvpn_easy_find_server_in_catalog() {
	local target_hostname="${1:-}"
	local target_station="${2:-}"
	local selection_label="${3:-selected}"

	[ -n "$target_station" ] || {
		log "ERROR: ${selection_label} server station is missing"
		return 1
	}

	CATALOG_MATCHED_SERVER_LINE="$(jq -er \
			--arg hostname "$target_hostname" \
			--arg station "$target_station" '
				([
					.servers[] | select(
						((.station // "" | ascii_downcase) == ($station | ascii_downcase)) and
						(($hostname == "") or ((.hostname // "" | ascii_downcase) == ($hostname | ascii_downcase)))
					)
				][0] // empty) | [
					.hostname,
					.station,
					.public_key,
					.country_code,
				.city,
				((.load // 0) | tostring)
			] | @tsv
		' "$SERVER_CATALOG_FILE" 2>/dev/null)" || {
			if [ -n "$target_hostname" ]; then
				log "ERROR: ${selection_label} server $target_hostname ($target_station) is not available in $VPN_COUNTRY"
			else
				log "ERROR: ${selection_label} server $target_station is not available in $VPN_COUNTRY"
			fi
			return 1
		}
}

nordvpn_easy_apply_catalog_server_line_to_uci() {
	local server_line="$1"
	local selection_label="${2:-selected}"

	MATCHED_SERVER_HOSTNAME=''
	MATCHED_SERVER_STATION=''
	MATCHED_SERVER_PUBLIC_KEY=''
	MATCHED_SERVER_COUNTRY_CODE=''
	MATCHED_SERVER_CITY_NAME=''
	MATCHED_SERVER_LOAD=''

	IFS="$(printf '\t')" read -r \
		MATCHED_SERVER_HOSTNAME \
		MATCHED_SERVER_STATION \
		MATCHED_SERVER_PUBLIC_KEY \
		MATCHED_SERVER_COUNTRY_CODE \
		MATCHED_SERVER_CITY_NAME \
		MATCHED_SERVER_LOAD <<EOF
$server_line
EOF

	[ -n "$MATCHED_SERVER_HOSTNAME" ] || {
		log "ERROR: ${selection_label} server match is missing a hostname"
		return 1
	}

	log "Applying ${selection_label} VPN server $MATCHED_SERVER_HOSTNAME ($MATCHED_SERVER_STATION) for ${MATCHED_SERVER_COUNTRY_CODE:-unknown country}"
	nordvpn_easy_set_vpn_server_in_uci \
		"$MATCHED_SERVER_HOSTNAME" \
		"$MATCHED_SERVER_STATION" \
		"$MATCHED_SERVER_PUBLIC_KEY" \
		"$MATCHED_SERVER_COUNTRY_CODE" \
		"$MATCHED_SERVER_CITY_NAME" \
		"$MATCHED_SERVER_LOAD"
}

nordvpn_easy_find_preferred_server_in_catalog() {
	nordvpn_easy_require_core_action_helpers fetch_server_catalog || return 1
	nordvpn_easy_require_manual_server_preference || return 1
	log "apply: resolving preferred server from catalog for country ${VPN_COUNTRY:-unset}"
	fetch_server_catalog 0 "$VPN_COUNTRY" || return 1
	nordvpn_easy_find_server_in_catalog "$PREFERRED_SERVER_HOSTNAME" "$PREFERRED_SERVER_STATION" 'preferred'
}

nordvpn_easy_normalize_country_code() {
	printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]'
}

nordvpn_easy_apply_preferred_server_from_catalog() {
	nordvpn_easy_find_preferred_server_in_catalog || return 1
	nordvpn_easy_apply_catalog_server_line_to_uci "$CATALOG_MATCHED_SERVER_LINE" 'preferred'
}

nordvpn_easy_build_server_recommendations_url() {
	SERVER_RECOMMENDATIONS_URL="$SERVER_RECOMMENDATIONS_URL_BASE"

	if [ -n "$VPN_COUNTRY" ]; then
		nordvpn_easy_require_core_action_helpers resolve_country_filter || return 1
		resolve_country_filter || return 1
		if [ -n "$RESOLVED_COUNTRY_ID" ]; then
			SERVER_RECOMMENDATIONS_URL="${SERVER_RECOMMENDATIONS_URL}&filters[country_id]=$RESOLVED_COUNTRY_ID"
			log "Building recommendations URL for country filter $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
		else
			log "Building recommendations URL without country_id filter; will select servers matching $RESOLVED_COUNTRY_CODE from the response"
		fi
	else
		log 'Building recommendations URL with automatic country selection'
	fi

	printf '%s\n' "$SERVER_RECOMMENDATIONS_URL"
}

nordvpn_easy_server_list_cache_is_usable() {
	[ -f "$SERVER_LIST_FILE" ] || return 1

	jq -er --arg country "${RESOLVED_COUNTRY_CODE:-}" '
		(type == "array") and
		(length > 0) and
		(.[0].station // "" | length > 0) and
		(
			($country == "") or
			([ .[] | select((.locations[0].country.code // "") == $country) ] | length > 0)
		)
	' "$SERVER_LIST_FILE" >/dev/null 2>&1
}

nordvpn_easy_clear_provision_caches() {
	log 'apply: clearing VPN server selection and public lookup caches'

	rm -f "${SERVER_LIST_FILE:-/tmp/nordvpn.json}" 2>/dev/null || true
	rm -f "${SERVER_CATALOG_FILE:-/tmp/nordvpn-easy-servers.json}" \
		"${SERVER_CATALOG_TS_FILE:-/tmp/nordvpn-easy-servers.timestamp}" 2>/dev/null || true

	rm -f "${NORDVPN_EASY_PUBLIC_IP_CACHE:-}" \
		"${NORDVPN_EASY_PUBLIC_COUNTRY_CACHE:-}" \
		"${NORDVPN_EASY_LAST_ERROR_CACHE:-}" 2>/dev/null || true

	return 0
}

nordvpn_easy_use_cached_server_list_if_available() {
	local reason="$1"

	if [ "${NORDVPN_EASY_FORCE_FRESH_SERVER_LIST:-0}" = '1' ]; then
		return 1
	fi

	if nordvpn_easy_server_list_cache_is_usable; then
		log "WARNING: $reason; using existing recommended server cache at $SERVER_LIST_FILE"
		return 0
	fi

	return 1
}

nordvpn_easy_get_servers_list() {
	local temp_dir=''
	local server_list_tmp=''
	local server_list_stderr=''
	local curl_rc=0
	local curl_error=''
	local failure_reason=''
	SERVER_RECOMMENDATIONS_URL=$(nordvpn_easy_build_server_recommendations_url) || return 1

	nordvpn_easy_mktemp_dir 'server-list' temp_dir || return 1
	server_list_tmp="$(nordvpn_easy_temp_file_path "$temp_dir" 'recommendations.json')"
	server_list_stderr="$(nordvpn_easy_temp_file_path "$temp_dir" 'curl-stderr.log')"

	log "apply: downloading recommended VPN server list to $server_list_tmp"

	curl -g -fsS --connect-timeout 15 --max-time 30 -o "$server_list_tmp" "$SERVER_RECOMMENDATIONS_URL" 2>"$server_list_stderr" || {
		curl_rc=$?
		curl_error="$(nordvpn_easy_curl_error_summary "$server_list_stderr")"
		failure_reason="could not retrieve VPN servers (curl_rc=$curl_rc: $(nordvpn_easy_curl_rc_meaning "$curl_rc")"
		[ -n "$curl_error" ] && failure_reason="$failure_reason, curl_error=$curl_error"
		failure_reason="$failure_reason)"
		rm -rf -- "$temp_dir"
		nordvpn_easy_use_cached_server_list_if_available "$failure_reason" && return 0
		log "ERROR: COULD NOT RETRIEVE VPN SERVERS (curl_rc=$curl_rc: $(nordvpn_easy_curl_rc_meaning "$curl_rc")$([ -n "$curl_error" ] && printf ', curl_error=%s' "$curl_error"))"
		return 1
	}

	jq -er '.[0].station // empty' "$server_list_tmp" >/dev/null 2>&1 || {
		rm -rf -- "$temp_dir"
		nordvpn_easy_use_cached_server_list_if_available 'recommended VPN server response was empty or invalid' && return 0
		if [ -n "$VPN_COUNTRY" ]; then
			log "ERROR: NO WIREGUARD SERVERS FOUND FOR COUNTRY '$VPN_COUNTRY'"
		else
			log 'ERROR: INVALID VPN SERVER LIST'
		fi
		return 1
	}

	mv "$server_list_tmp" "$SERVER_LIST_FILE" || {
		rm -rf -- "$temp_dir"
		nordvpn_easy_use_cached_server_list_if_available 'could not update recommended server cache' && return 0
		log 'ERROR: COULD NOT UPDATE VPN SERVER LIST'
		return 1
	}
	rm -rf -- "$temp_dir"

	SERVER_COUNT=$(jq -r 'length' "$SERVER_LIST_FILE" 2>/dev/null)
	log "apply: VPN server list updated at $SERVER_LIST_FILE with ${SERVER_COUNT:-unknown} entries"
}

nordvpn_easy_set_first_server_from_list() {
	local exclude="${NORDVPN_EASY_ROTATE_EXCLUDE_STATION:-}"

	FIRST_SERVER=$(jq -r --arg exclude "$exclude" --arg want "${RESOLVED_COUNTRY_CODE:-}" '
		[.[] |
			select(($exclude == "") or ((.station // "") != $exclude)) |
			select(($want == "") or ((.locations[0].country.code // "") == $want))
		] | .[0] | [
			.hostname,
			.station,
			([.technologies[]?
				| select(.identifier == "wireguard_udp")
				| .metadata[]?
				| select(.name == "public_key")
				| (.value // "")
			][0] // ""),
			(.locations[0].country.code // ""),
			(.locations[0].country.city.name // ""),
			((.load // 0) | tostring)
		] | @tsv' "$SERVER_LIST_FILE" 2>/dev/null) || {
		log 'ERROR: INVALID VPN SERVER LIST'
		return 1
	}

	[ -n "$FIRST_SERVER" ] || {
		if [ -n "$exclude" ]; then
			log 'ERROR: NO ALTERNATIVE VPN SERVER FOUND FOR ROTATION'
		else
			log 'ERROR: VPN SERVER LIST IS EMPTY'
		fi
		return 1
	}

	IFS="$(printf '\t')" read -r HOST_NAME SERVER_STATION PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD <<EOF
$FIRST_SERVER
EOF

	log "Selected recommended VPN server $HOST_NAME ($SERVER_STATION)"
	nordvpn_easy_set_vpn_server_in_uci "$HOST_NAME" "$SERVER_STATION" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD"
}

nordvpn_easy_apply_next_manual_server_from_catalog() {
	local exclude="${1:-}"
	local candidate_line=''
	local host_name=''
	local server_station=''
	local public_key=''
	local country_code=''
	local city_name=''
	local server_load=''

	nordvpn_easy_require_core_action_helpers fetch_server_catalog || return 1
	nordvpn_easy_require_manual_server_preference || return 1
	fetch_server_catalog 0 "$VPN_COUNTRY" || return 1

	while IFS="$(printf '\t')" read -r host_name server_station public_key country_code city_name server_load; do
		[ -n "$server_station" ] || continue
		[ -n "$exclude" ] && [ "$server_station" = "$exclude" ] && continue

		log "Selected manual VPN server $host_name ($server_station) for rotation"
		nordvpn_easy_set_vpn_server_in_uci "$host_name" "$server_station" "$public_key" "$country_code" "$city_name" "$server_load" || return 1
		nordvpn_easy_set_server_preference_in_uci "$host_name" "$server_station"
		uci commit nordvpn_easy || {
			log 'WARNING: COULD NOT COMMIT MANUAL SERVER PREFERENCE AFTER ROTATION'
		}
		PREFERRED_SERVER_HOSTNAME="$host_name"
		PREFERRED_SERVER_STATION="$server_station"
		return 0
	done <<EOF
$(nordvpn_easy_server_catalog_candidates_tsv "$SERVER_CATALOG_FILE")
EOF

	log 'ERROR: NO ALTERNATIVE MANUAL VPN SERVER FOUND FOR ROTATION'
	return 1
}

nordvpn_easy_apply_manual_peer_for_provision() {
	if [ "${NORDVPN_EASY_PROVISION_MODE:-}" = 'rotate' ]; then
		nordvpn_easy_apply_next_manual_server_from_catalog "${NORDVPN_EASY_ROTATE_EXCLUDE_STATION:-}" || return 1
		return 0
	fi

	nordvpn_easy_apply_preferred_server_from_catalog
}

nordvpn_easy_build_wireguard_peer_section() {
	local peer_section="${VPN_IF}server"

	uci -q delete "network.${peer_section}" || true
	uci set "network.${peer_section}"="wireguard_${VPN_IF}" || return 1
	nordvpn_easy_apply_wireguard_transport_settings "$peer_section" || return 1
	uci set "network.${peer_section}.route_allowed_ips"='1' || return 1
	uci add_list "network.${peer_section}.allowed_ips"='0.0.0.0/0' || return 1

	if nordvpn_easy_server_selection_is_manual; then
		nordvpn_easy_apply_manual_peer_for_provision || return 1
	else
		nordvpn_easy_set_first_server_from_list || return 1
	fi
}

nordvpn_easy_fetch_provision_prerequisites() {
	nordvpn_easy_require_core_action_helpers get_private_key || return 1
	log 'apply: requesting NordLynx private key'
	if ! get_private_key; then
		if command -v nordvpn_easy_try_clear_routing_blackhole >/dev/null 2>&1 &&
			nordvpn_easy_try_clear_routing_blackhole "$VPN_IF" "${LOG_PHASE:-apply}"; then
			get_private_key || return 1
		else
			return 1
		fi
	fi
	if nordvpn_easy_server_selection_is_manual; then
		nordvpn_easy_require_core_action_helpers fetch_server_catalog || return 1
		nordvpn_easy_require_manual_server_preference || return 1
		log "apply: manual mode selected; fetching server catalog for ${VPN_COUNTRY:-unset}"
		if [ "${NORDVPN_EASY_FORCE_FRESH_SERVER_LIST:-0}" = '1' ]; then
			fetch_server_catalog 1 "$VPN_COUNTRY" || return 1
		else
			fetch_server_catalog 0 "$VPN_COUNTRY" || return 1
		fi
	else
		log 'apply: automatic mode selected; fetching NordVPN recommendations'
		nordvpn_easy_get_servers_list || return 1
	fi
	return 0
}

nordvpn_easy_configure_vpn_interface() {
	nordvpn_easy_require_core_action_helpers get_private_key || return 1
	log "apply: creating WireGuard interface $VPN_IF with address $VPN_ADDR and endpoint port $VPN_PORT"
	nordvpn_easy_log_vpn_interface_state 'before-create'

	if [ "${NORDVPN_EASY_PROVISION_FETCH_DONE:-}" != '1' ]; then
		nordvpn_easy_fetch_provision_prerequisites || return 1
	fi
	log "apply: ensuring firewall zone for ${WAN_IF:-unset} contains ${VPN_IF:-unset}"
	nordvpn_easy_ensure_vpn_in_wan_zone || return 1

	uci set "network.${VPN_IF}"='interface'
	uci set "network.${VPN_IF}.proto"='wireguard'
	uci -q delete "network.${VPN_IF}.addresses" >/dev/null 2>&1 || true
	uci add_list "network.${VPN_IF}.addresses"="$VPN_ADDR"
	uci set "network.${VPN_IF}.private_key"="$PRIVATE_KEY"

	uci -q delete "network.${VPN_IF}.dns" >/dev/null 2>&1 || true
	if [ -n "$VPN_DNS1" ] || [ -n "$VPN_DNS2" ]; then
		uci set "network.${VPN_IF}.peerdns"='0'
		[ -n "$VPN_DNS1" ] && uci add_list "network.${VPN_IF}.dns"="$VPN_DNS1"
		[ -n "$VPN_DNS2" ] && uci add_list "network.${VPN_IF}.dns"="$VPN_DNS2"
	else
		uci set "network.${VPN_IF}.peerdns"='1'
	fi

	uci set "network.${VPN_IF}.delegate"='0'
	uci set "network.${VPN_IF}.force_link"='1'

	nordvpn_easy_build_wireguard_peer_section || return 1

	uci set "network.${WAN_IF}.metric"='1024'
	log "apply: committing network configuration for $VPN_IF"
	uci commit network || {
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" 'could not commit network configuration while creating the VPN interface'
		return 1
	}

	log "apply: restarting network to bring up $VPN_IF"
	/etc/init.d/network restart || {
		log 'ERROR: NETWORK RESTART FAILED'
		return 1
	}

	log "apply: $VPN_IF created successfully"
	nordvpn_easy_log_vpn_interface_state 'after-create'
}

nordvpn_easy_stop_vpn_for_server_change() {
	log 'apply: stopping VPN and clearing server selection caches'
	nordvpn_easy_immediate_vpn_shutdown || return 1
	nordvpn_easy_clear_provision_caches || return 1
	nordvpn_easy_teardown_vpn || return 1
	return 0
}

nordvpn_easy_provision_vpn_connect_fresh() {
	NORDVPN_EASY_FORCE_FRESH_SERVER_LIST=1

	log 'apply: connecting with a fresh server list and clean caches'
	nordvpn_easy_fetch_provision_prerequisites || return 1
	NORDVPN_EASY_PROVISION_FETCH_DONE=1
	nordvpn_easy_configure_vpn_interface || return 1
	unset NORDVPN_EASY_PROVISION_FETCH_DONE NORDVPN_EASY_FORCE_FRESH_SERVER_LIST

	if ! nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "$POST_RESTART_DELAY" "provisioning $VPN_IF"; then
		log 'apply: VPN connection is not OK after provisioning'
		return 1
	fi

	verify_public_country_selection || return 1
	log 'apply: VPN provisioning completed'
	return 0
}

nordvpn_easy_provision_vpn_server_change() {
	nordvpn_easy_stop_vpn_for_server_change || return 1
	nordvpn_easy_provision_vpn_connect_fresh
}

nordvpn_easy_provision_vpn() {
	local mode="${1:-}"

	nordvpn_easy_require_core_action_helpers refresh_countries_cache verify_public_country_selection || return 1
	log "apply: provisioning VPN interface $VPN_IF (mode=${mode:-fresh}, selection=${SERVER_SELECTION_MODE:-auto}, country=${VPN_COUNTRY:-automatic})"

	NORDVPN_EASY_PROVISION_MODE="$mode"
	NORDVPN_EASY_ROTATE_EXCLUDE_STATION=''
	NORDVPN_EASY_FORCE_FRESH_SERVER_LIST=0
	if [ "$mode" = 'rotate' ]; then
		NORDVPN_EASY_ROTATE_EXCLUDE_STATION="$(nordvpn_easy_current_server_station 2>/dev/null || true)"
	fi

	refresh_countries_cache || true
	if [ -n "$VPN_COUNTRY" ]; then
		nordvpn_easy_require_core_action_helpers resolve_country_filter || return 1
		resolve_country_filter || return 1
	fi

	if [ "$mode" = 'server_change' ]; then
		nordvpn_easy_provision_vpn_server_change
		return $?
	fi

	if [ "$mode" = 'connect_fresh' ]; then
		nordvpn_easy_provision_vpn_connect_fresh
		return $?
	fi

	nordvpn_easy_fetch_provision_prerequisites || return 1
	NORDVPN_EASY_PROVISION_FETCH_DONE=1
	nordvpn_easy_teardown_vpn || return 1
	nordvpn_easy_configure_vpn_interface || return 1
	unset NORDVPN_EASY_PROVISION_FETCH_DONE

	if ! nordvpn_easy_wait_for_vpn_connectivity "$VPN_IF" "$POST_RESTART_DELAY" "provisioning $VPN_IF"; then
		log 'apply: VPN connection is not OK after provisioning'
		return 1
	fi

	verify_public_country_selection || return 1
	log 'apply: VPN provisioning completed'
}

nordvpn_easy_reconcile_action() {
	log 'apply: reconcile action started'
	nordvpn_easy_provision_vpn || return 1
	nordvpn_easy_check_once
}

nordvpn_easy_rotate_action() {
	log 'apply: rotate action started'
	nordvpn_easy_provision_vpn rotate
}

nordvpn_easy_check_once_finish() {
	nordvpn_easy_log_enterprise_state_if_degraded "${VPN_IF:-wg0}" 'healthcheck' || true
}

nordvpn_easy_check_once() {
	log "healthcheck: starting VPN health-check on interface $VPN_IF (failure_retry_delay=${FAILURE_RETRY_DELAY:-unset})"

	if nordvpn_easy_ping_interface "$VPN_IF"; then
		log "healthcheck: VPN health-check passed on interface $VPN_IF"
		nordvpn_easy_check_once_finish
		return 0
	fi

	nordvpn_easy_ping_wan || {
		log "healthcheck: WAN connectivity is down while VPN health-check is failing on $VPN_IF; skipping VPN recovery"
		nordvpn_easy_check_once_finish
		return 0
	}

	if nordvpn_easy_runtime_needs_provision "$VPN_IF"; then
		log "healthcheck: degraded VPN runtime detected; reprovisioning $VPN_IF"
		nordvpn_easy_provision_vpn || {
			nordvpn_easy_check_once_finish
			return 1
		}
		nordvpn_easy_check_once_finish
		return 0
	fi

	sleep "${FAILURE_RETRY_DELAY:-6}"

	if nordvpn_easy_ping_interface "$VPN_IF"; then
		log "healthcheck: VPN health-check passed on interface $VPN_IF after retry delay"
		nordvpn_easy_check_once_finish
		return 0
	fi

	log "healthcheck: VPN ping still failing; reprovisioning $VPN_IF"
	nordvpn_easy_provision_vpn
	nordvpn_easy_check_once_finish
	return $?
}
