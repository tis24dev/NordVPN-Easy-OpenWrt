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
			[
				.servers[] | select(
					((.station // "" | ascii_downcase) == ($station | ascii_downcase)) and
					(($hostname == "") or ((.hostname // "" | ascii_downcase) == ($hostname | ascii_downcase)))
				)
			][0] | [
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

nordvpn_easy_preferred_server_matches_current() {
	[ -n "$PREFERRED_SERVER_STATION" ] || return 1
	[ "$(nordvpn_easy_current_server_station)" = "$PREFERRED_SERVER_STATION" ]
}

nordvpn_easy_apply_preferred_server_from_catalog() {
	nordvpn_easy_find_preferred_server_in_catalog || return 1
	nordvpn_easy_apply_catalog_server_line_to_uci "$CATALOG_MATCHED_SERVER_LINE" 'preferred'
}

nordvpn_easy_apply_fallback_server_from_catalog() {
	nordvpn_easy_require_core_action_helpers fetch_server_catalog || return 1
	nordvpn_easy_has_fallback_server_preference || return 1
	log "apply: resolving fallback server from catalog for country ${VPN_COUNTRY:-unset}"
	fetch_server_catalog 0 "$VPN_COUNTRY" || return 1
	nordvpn_easy_find_server_in_catalog '' "$FALLBACK_SERVER_STATION" 'fallback' || return 1
	nordvpn_easy_apply_catalog_server_line_to_uci "$CATALOG_MATCHED_SERVER_LINE" 'fallback'
}

nordvpn_easy_try_configured_fallback_server() {
	local runtime_action="${1:-reload}"
	local recovery_reason="${2:-the configured server could not be applied}"
	local current_station=''

	nordvpn_easy_has_fallback_server_preference || return 1

	if [ "${FALLBACK_SERVER_STATION:-}" = "${PREFERRED_SERVER_STATION:-}" ]; then
		log "apply: configured fallback server ${FALLBACK_SERVER_STATION:-unset} matches the preferred server; skipping fallback recovery"
		return 1
	fi

	current_station="$(nordvpn_easy_current_server_station)"
	if [ -n "$current_station" ] && [ "$current_station" = "${FALLBACK_SERVER_STATION:-}" ]; then
		log "apply: configured fallback server ${FALLBACK_SERVER_STATION:-unset} is already active; skipping fallback recovery"
		return 1
	fi

	log "apply: attempting configured fallback server ${FALLBACK_SERVER_STATION:-unset} because $recovery_reason"
	nordvpn_easy_apply_fallback_server_from_catalog || return 1

	uci commit network || {
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" 'could not commit network configuration while applying the configured fallback server'
		return 1
	}

	if ! nordvpn_easy_apply_server_change_runtime "$runtime_action"; then
		log "apply: configured fallback server ${MATCHED_SERVER_HOSTNAME:-unknown} (${MATCHED_SERVER_STATION:-unknown}) did not restore VPN connectivity"
		return 1
	fi

	nordvpn_easy_set_server_preference_in_uci "$MATCHED_SERVER_HOSTNAME" "$MATCHED_SERVER_STATION"
	if ! uci commit nordvpn_easy; then
		log 'WARNING: COULD NOT COMMIT FALLBACK SERVER PROMOTION; KEEPING WORKING RUNTIME SERVER'
	fi

	PREFERRED_SERVER_HOSTNAME="$MATCHED_SERVER_HOSTNAME"
	PREFERRED_SERVER_STATION="$MATCHED_SERVER_STATION"
	log "apply: promoted fallback server to preferred server $MATCHED_SERVER_HOSTNAME ($MATCHED_SERVER_STATION)"
	return 0
}

nordvpn_easy_build_server_recommendations_url() {
	SERVER_RECOMMENDATIONS_URL="$SERVER_RECOMMENDATIONS_URL_BASE"

	if [ -n "$VPN_COUNTRY" ]; then
		nordvpn_easy_require_core_action_helpers resolve_country_filter || return 1
		resolve_country_filter || return 1
		SERVER_RECOMMENDATIONS_URL="${SERVER_RECOMMENDATIONS_URL}&filters[country_id]=$RESOLVED_COUNTRY_ID"
		log "Building recommendations URL for country filter $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
	else
		log 'Building recommendations URL with automatic country selection'
	fi

	printf '%s\n' "$SERVER_RECOMMENDATIONS_URL"
}

nordvpn_easy_get_servers_list() {
	local temp_dir=''
	local server_list_tmp=''
	SERVER_RECOMMENDATIONS_URL=$(nordvpn_easy_build_server_recommendations_url) || return 1

	nordvpn_easy_mktemp_dir 'server-list' temp_dir || return 1
	server_list_tmp="$(nordvpn_easy_temp_file_path "$temp_dir" 'recommendations.json')"

	log "apply: downloading recommended VPN server list to $server_list_tmp"

	curl -g -fsS --connect-timeout 15 --max-time 30 -o "$server_list_tmp" "$SERVER_RECOMMENDATIONS_URL" || {
		rm -rf -- "$temp_dir"
		log 'ERROR: COULD NOT RETRIEVE VPN SERVERS'
		return 1
	}

	jq -er '.[0].station // empty' "$server_list_tmp" >/dev/null 2>&1 || {
		rm -rf -- "$temp_dir"
		if [ -n "$VPN_COUNTRY" ]; then
			log "ERROR: NO WIREGUARD SERVERS FOUND FOR COUNTRY '$VPN_COUNTRY'"
		else
			log 'ERROR: INVALID VPN SERVER LIST'
		fi
		return 1
	}

	mv "$server_list_tmp" "$SERVER_LIST_FILE" || {
		rm -rf -- "$temp_dir"
		log 'ERROR: COULD NOT UPDATE VPN SERVER LIST'
		return 1
	}
	rm -rf -- "$temp_dir"

	SERVER_COUNT=$(jq -r 'length' "$SERVER_LIST_FILE" 2>/dev/null)
	log "apply: VPN server list updated at $SERVER_LIST_FILE with ${SERVER_COUNT:-unknown} entries"
}

nordvpn_easy_set_first_server_from_list() {
	FIRST_SERVER=$(jq -r '.[0] | [
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
		log 'ERROR: VPN SERVER LIST IS EMPTY'
		return 1
	}

	IFS="$(printf '\t')" read -r HOST_NAME SERVER_STATION PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD <<EOF
$FIRST_SERVER
EOF

	log "Selected first recommended VPN server $HOST_NAME ($SERVER_STATION)"
	nordvpn_easy_set_vpn_server_in_uci "$HOST_NAME" "$SERVER_STATION" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD"
}

nordvpn_easy_change_to_preferred_server() {
	local runtime_action="${1:-reload}"

	nordvpn_easy_apply_preferred_server_from_catalog || {
		nordvpn_easy_try_configured_fallback_server "$runtime_action" 'the preferred server could not be resolved from the catalog'
		return $?
	}

	uci commit network || {
		nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" 'could not commit network configuration while applying preferred server'
		return 1
	}

	log "VPN server changed to preferred server $PREFERRED_SERVER_HOSTNAME ($PREFERRED_SERVER_STATION)"
	nordvpn_easy_apply_server_change_runtime "$runtime_action" && return 0

	nordvpn_easy_try_configured_fallback_server "$runtime_action" "preferred server $PREFERRED_SERVER_HOSTNAME ($PREFERRED_SERVER_STATION) did not restore VPN connectivity"
}

nordvpn_easy_sync_server_selection() {
	nordvpn_easy_vpn_is_configured || return 0

	if nordvpn_easy_server_selection_is_manual; then
		nordvpn_easy_require_manual_server_preference || return 1

		if nordvpn_easy_preferred_server_matches_current; then
			log 'Current VPN server already matches the preferred manual server'
			return 0
		fi

		log 'Current VPN server does not match the preferred manual server, applying preference'
		nordvpn_easy_change_to_preferred_server reload
		return $?
	fi

	nordvpn_easy_get_servers_list || return 1

	if nordvpn_easy_current_server_matches_recommendations; then
		log 'Current VPN server already matches the selected country/filter'
		return 0
	fi

	log 'Current VPN server does not match the selected country/filter, changing server'
	nordvpn_easy_change_vpn_server reload
}

nordvpn_easy_change_vpn_server() {
	CURRENT_SERVER=$(nordvpn_easy_current_server_station)
	local temp_dir=''
	SERVER_CANDIDATES_FILE=''
	commit_failed=0
	server_changed=0
	candidate_count=0
	candidate_index=0

	log "apply: starting VPN server rotation from current endpoint ${CURRENT_SERVER:-none}"

	nordvpn_easy_mktemp_dir 'recommended-candidates' temp_dir || return 1
	SERVER_CANDIDATES_FILE="$(nordvpn_easy_temp_file_path "$temp_dir" 'recommended.tsv')"
	nordvpn_easy_recommendation_candidates_tsv "$SERVER_LIST_FILE" > "$SERVER_CANDIDATES_FILE" || {
		rm -rf -- "$temp_dir"
		log 'ERROR: INVALID VPN SERVER LIST'
		return 1
	}

	candidate_count="$(wc -l < "$SERVER_CANDIDATES_FILE" 2>/dev/null || printf '%s' '0')"
	log "apply: loaded $candidate_count recommended server candidates for rotation"

	while IFS="$(printf '\t')" read -r HOST_NAME SERVER_STATION PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD; do
		[ -n "$SERVER_STATION" ] || continue
		[ "$CURRENT_SERVER" = "$SERVER_STATION" ] && continue
		candidate_index=$((candidate_index + 1))

		log "apply: trying recommended candidate ${candidate_index}/${candidate_count}: $HOST_NAME ($SERVER_STATION)"

		nordvpn_easy_set_vpn_server_in_uci "$HOST_NAME" "$SERVER_STATION" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD" || continue
		uci commit network || {
			nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" 'could not commit network configuration during recommended server rotation'
			commit_failed=1
			break
		}

		log "VPN server changed to $HOST_NAME ($SERVER_STATION)"

		if nordvpn_easy_apply_server_change_runtime "$1"; then
			server_changed=1
			break
		fi

		log "apply: candidate $HOST_NAME ($SERVER_STATION) did not restore VPN connectivity, moving to the next candidate"
	done < "$SERVER_CANDIDATES_FILE"

	rm -rf -- "$temp_dir"

	if [ "$commit_failed" -eq 1 ]; then
		return 1
	fi

	if [ "$server_changed" -eq 1 ]; then
		return 0
	fi

	if nordvpn_easy_try_configured_fallback_server "$1" 'recommended server rotation exhausted the current candidate list'; then
		return 0
	fi

	log 'NO RECOMMENDED VPN SERVER RESTORED CONNECTIVITY'
	return 1
}

nordvpn_easy_change_manual_server() {
	CURRENT_SERVER=$(nordvpn_easy_current_server_station)
	local temp_dir=''
	SERVER_CANDIDATES_FILE=''
	commit_failed=0
	server_changed=0
	candidate_count=0
	candidate_index=0

	nordvpn_easy_require_manual_server_preference || return 1
	fetch_server_catalog 0 "$VPN_COUNTRY" || return 1

	log "apply: starting manual VPN server rotation from current endpoint ${CURRENT_SERVER:-none}"

	nordvpn_easy_mktemp_dir 'manual-candidates' temp_dir || return 1
	SERVER_CANDIDATES_FILE="$(nordvpn_easy_temp_file_path "$temp_dir" 'manual.tsv')"
	nordvpn_easy_server_catalog_candidates_tsv "$SERVER_CATALOG_FILE" > "$SERVER_CANDIDATES_FILE" || {
		rm -rf -- "$temp_dir"
		log 'ERROR: INVALID SERVER CATALOG'
		return 1
	}

	candidate_count="$(wc -l < "$SERVER_CANDIDATES_FILE" 2>/dev/null || printf '%s' '0')"
	log "apply: loaded $candidate_count manual server candidates for rotation"

	while IFS="$(printf '\t')" read -r HOST_NAME SERVER_STATION PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD; do
		[ -n "$SERVER_STATION" ] || continue
		[ "$CURRENT_SERVER" = "$SERVER_STATION" ] && continue
		candidate_index=$((candidate_index + 1))

		log "apply: trying manual candidate ${candidate_index}/${candidate_count}: $HOST_NAME ($SERVER_STATION)"

		nordvpn_easy_set_vpn_server_in_uci "$HOST_NAME" "$SERVER_STATION" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD" || continue
		uci commit network || {
			nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" 'could not commit network configuration during manual server rotation'
			commit_failed=1
			break
		}
		if nordvpn_easy_apply_server_change_runtime "$1"; then
			nordvpn_easy_set_server_preference_in_uci "$HOST_NAME" "$SERVER_STATION"
			if ! uci commit nordvpn_easy; then
				log 'WARNING: COULD NOT COMMIT MANUAL SERVER PREFERENCE; KEEPING WORKING RUNTIME SERVER'
			fi

			PREFERRED_SERVER_HOSTNAME="$HOST_NAME"
			PREFERRED_SERVER_STATION="$SERVER_STATION"
			log "Manual preferred VPN server updated to $HOST_NAME ($SERVER_STATION)"
			server_changed=1
			break
		fi

		log "apply: manual candidate $HOST_NAME ($SERVER_STATION) did not restore VPN connectivity, moving to the next candidate"
	done < "$SERVER_CANDIDATES_FILE"

	rm -rf -- "$temp_dir"

	if [ "$commit_failed" -eq 1 ]; then
		return 1
	fi

	if [ "$server_changed" -eq 1 ]; then
		return 0
	fi

	log 'NO MANUAL VPN SERVER RESTORED CONNECTIVITY'
	return 1
}

nordvpn_easy_configure_vpn_interface() {
	nordvpn_easy_require_core_action_helpers get_private_key || return 1
	log "apply: $VPN_IF is not configured and will be created"
	nordvpn_easy_log_vpn_interface_state 'before-create'
	log "apply: creating WireGuard interface $VPN_IF with address $VPN_ADDR and endpoint port $VPN_PORT"

	log 'apply: requesting NordLynx private key'
	get_private_key || return 1
	if nordvpn_easy_server_selection_is_manual; then
		nordvpn_easy_require_core_action_helpers fetch_server_catalog || return 1
		nordvpn_easy_require_manual_server_preference || return 1
		log "apply: manual mode selected; fetching server catalog for ${VPN_COUNTRY:-unset}"
		fetch_server_catalog 0 "$VPN_COUNTRY" || return 1
	else
		log 'apply: automatic mode selected; fetching NordVPN recommendations'
		nordvpn_easy_get_servers_list || return 1
	fi
	log "apply: ensuring firewall zone for ${WAN_IF:-unset} contains ${VPN_IF:-unset}"
	nordvpn_easy_ensure_vpn_in_wan_zone || return 1

	uci -q delete "network.${VPN_IF}"
	uci set "network.${VPN_IF}"='interface'
	uci set "network.${VPN_IF}.proto"='wireguard'
	uci add_list "network.${VPN_IF}.addresses"="$VPN_ADDR"
	uci set "network.${VPN_IF}.private_key"="$PRIVATE_KEY"

	if [ -n "$VPN_DNS1" ] || [ -n "$VPN_DNS2" ]; then
		uci set "network.${VPN_IF}.peerdns"='0'
		[ -n "$VPN_DNS1" ] && uci add_list "network.${VPN_IF}.dns"="$VPN_DNS1"
		[ -n "$VPN_DNS2" ] && uci add_list "network.${VPN_IF}.dns"="$VPN_DNS2"
	else
		uci set "network.${VPN_IF}.peerdns"='1'
	fi

	uci set "network.${VPN_IF}.delegate"='0'
	uci set "network.${VPN_IF}.force_link"='1'

	uci -q delete "network.${VPN_IF}server"
	uci set "network.${VPN_IF}server"="wireguard_${VPN_IF}"
	uci set "network.${VPN_IF}server.endpoint_port"="$VPN_PORT"
	uci set "network.${VPN_IF}server.persistent_keepalive"='25'
	uci set "network.${VPN_IF}server.route_allowed_ips"='1'
	uci add_list "network.${VPN_IF}server.allowed_ips"='0.0.0.0/0'

	if nordvpn_easy_server_selection_is_manual; then
		nordvpn_easy_apply_preferred_server_from_catalog || return 1
	else
		nordvpn_easy_set_first_server_from_list || return 1
	fi

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

nordvpn_easy_bootstrap_if_needed() {
	nordvpn_easy_require_core_action_helpers refresh_countries_cache || return 1
	log "runtime: bootstrap starting for interface $VPN_IF (mode=${SERVER_SELECTION_MODE:-auto}, country=${VPN_COUNTRY:-automatic})"
	nordvpn_easy_log_vpn_interface_state 'bootstrap-start'
	refresh_countries_cache || true
	if [ -n "$VPN_COUNTRY" ]; then
		nordvpn_easy_require_core_action_helpers resolve_country_filter || return 1
		resolve_country_filter || return 1
	fi

	if ! nordvpn_easy_vpn_is_configured; then
		log "runtime: interface $VPN_IF is not configured; entering create path"
		nordvpn_easy_configure_vpn_interface || return 1
	else
		log "runtime: interface $VPN_IF is already configured; ensuring it is enabled and present"
		nordvpn_easy_ensure_vpn_interface_enabled || return 1
	fi

	nordvpn_easy_ensure_vpn_in_wan_zone || return 1
	nordvpn_easy_ensure_vpn_interface_present || return 1
	log "runtime: bootstrap completed for interface $VPN_IF"
	nordvpn_easy_log_vpn_interface_state 'bootstrap-complete'
}

nordvpn_easy_rotate_action() {
	log 'apply: rotate action started'
	nordvpn_easy_bootstrap_if_needed || return 1

	if nordvpn_easy_server_selection_is_manual; then
		log 'apply: changing preferred manual VPN server'
		nordvpn_easy_change_manual_server reload
		return $?
	fi

	nordvpn_easy_get_servers_list || return 1
	log 'apply: changing VPN server'
	nordvpn_easy_change_vpn_server reload
}

nordvpn_easy_check_once() {
	# shellcheck disable=SC3043 # OpenWrt /bin/sh is BusyBox ash, which supports local.
	local failed_pings=0
	local restart_count=0
	local max_interface_restarts="${MAX_INTERFACE_RESTARTS:-3}"
	local retry_delay
	local backoff_steps

	log "healthcheck: starting VPN health-check on interface $VPN_IF (failure_retry_delay=${FAILURE_RETRY_DELAY:-unset}, rotate_threshold=${SERVER_ROTATE_THRESHOLD:-unset}, restart_threshold=${INTERFACE_RESTART_THRESHOLD:-unset}, max_restarts=${max_interface_restarts})"
	if ! nordvpn_easy_server_selection_is_manual; then
		[ -f "$SERVER_LIST_FILE" ] || nordvpn_easy_get_servers_list || true
	fi

	while ! nordvpn_easy_ping_interface "$VPN_IF"; do
		failed_pings=$((failed_pings+1))
		retry_delay="$FAILURE_RETRY_DELAY"
		nordvpn_easy_ping_wan || {
			log "healthcheck: WAN connectivity is down while VPN health-check is failing on $VPN_IF; skipping VPN recovery"
			return 0
		}

		if [ "$failed_pings" -gt "$INTERFACE_RESTART_THRESHOLD" ]; then
			if [ "$restart_count" -ge "$max_interface_restarts" ]; then
				log "healthcheck: ping failed $failed_pings times; restart limit reached for $VPN_IF ($restart_count/$max_interface_restarts)"
				return 1
			fi

			restart_count=$((restart_count+1))
			log "healthcheck: ping failed $failed_pings times; restarting $VPN_IF ($restart_count/$max_interface_restarts)"
			log "healthcheck: requesting ifdown for interface $VPN_IF during recovery"
			ifdown "$VPN_IF"
			sleep "$INTERFACE_RESTART_DELAY"
			log "healthcheck: requesting ifup for interface $VPN_IF during recovery"
			ifup "$VPN_IF"
			sleep "$POST_RESTART_DELAY"
				nordvpn_easy_log_vpn_interface_state 'after-recovery-restart'
			elif [ "$failed_pings" -ge "$SERVER_ROTATE_THRESHOLD" ]; then
				log "healthcheck: ping failed $failed_pings times; evaluating server rotation"

				if nordvpn_easy_server_selection_is_manual; then
					if nordvpn_easy_try_configured_fallback_server restart 'manual server recovery threshold reached'; then
						return 0
					fi

					if nordvpn_easy_has_fallback_server_preference; then
						log 'healthcheck: manual server selection is enabled, but the configured fallback server did not restore connectivity'
					else
						log 'healthcheck: manual server selection is enabled and no fallback server is configured; skipping automatic server rotation'
					fi
				else
					if nordvpn_easy_get_servers_list; then
						log 'healthcheck: changing VPN server after repeated failures'
						nordvpn_easy_change_vpn_server restart && return 0
					else
						log 'healthcheck: refreshing VPN server list failed'
					fi
			fi

			log 'healthcheck: restarting network as part of recovery'
			/etc/init.d/network restart || {
				log 'ERROR: NETWORK RESTART FAILED'
				return 1
			}
			sleep "$POST_RESTART_DELAY"
		fi

		if [ "$failed_pings" -ge "$SERVER_ROTATE_THRESHOLD" ]; then
			backoff_steps=$((failed_pings - SERVER_ROTATE_THRESHOLD + 1))
			while [ "$backoff_steps" -gt 0 ]; do
				retry_delay=$((retry_delay * 2))
				if [ "$retry_delay" -ge "$POST_RESTART_DELAY" ]; then
					retry_delay="$POST_RESTART_DELAY"
					break
				fi
				backoff_steps=$((backoff_steps - 1))
			done
		fi

		sleep "$retry_delay"
	done

	log "healthcheck: VPN health-check passed on interface $VPN_IF"
}
