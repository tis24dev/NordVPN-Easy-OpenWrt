#!/bin/sh

nordvpn_easy_find_preferred_server_in_catalog() {
	require_manual_server_preference || return 1
	fetch_server_catalog 0 "$VPN_COUNTRY" || return 1

	PREFERRED_SERVER_LINE=$(jq -er \
		--arg hostname "$PREFERRED_SERVER_HOSTNAME" \
		--arg station "$PREFERRED_SERVER_STATION" '
			[
				.servers[] | select(
					(.station == $station) and
					(($hostname == "") or (.hostname == $hostname))
				)
			][0] | [
				.hostname,
				.station,
				.public_key,
				.country_code,
				.city,
				((.load // 0) | tostring)
			] | @tsv
		' "$SERVER_CATALOG_FILE" 2>/dev/null) || {
			log "ERROR: PREFERRED SERVER $PREFERRED_SERVER_HOSTNAME ($PREFERRED_SERVER_STATION) IS NOT AVAILABLE IN $VPN_COUNTRY"
			return 1
		}
}

nordvpn_easy_preferred_server_matches_current() {
	[ -n "$PREFERRED_SERVER_STATION" ] || return 1
	[ "$(current_server_station)" = "$PREFERRED_SERVER_STATION" ]
}

nordvpn_easy_apply_preferred_server_from_catalog() {
	find_preferred_server_in_catalog || return 1

	IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD <<EOF
$PREFERRED_SERVER_LINE
EOF

	log "Applying preferred VPN server $HOST_NAME ($SERVER_IP) for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
	set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD"
}

nordvpn_easy_build_server_recommendations_url() {
	SERVER_RECOMMENDATIONS_URL="$SERVER_RECOMMENDATIONS_URL_BASE"

	if [ -n "$VPN_COUNTRY" ]; then
		resolve_country_filter || return 1
		SERVER_RECOMMENDATIONS_URL="${SERVER_RECOMMENDATIONS_URL}&filters[country_id]=$RESOLVED_COUNTRY_ID"
		log "Building recommendations URL for country filter $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
	else
		log 'Building recommendations URL with automatic country selection'
	fi

	printf '%s\n' "$SERVER_RECOMMENDATIONS_URL"
}

nordvpn_easy_get_servers_list() {
	SERVER_LIST_TMP="${SERVER_LIST_FILE}.tmp.$$"
	SERVER_RECOMMENDATIONS_URL=$(build_server_recommendations_url) || return 1

	log "Downloading recommended VPN server list to $SERVER_LIST_TMP"

	curl -g -fsS --connect-timeout 15 --max-time 30 -o "$SERVER_LIST_TMP" "$SERVER_RECOMMENDATIONS_URL" || {
		rm -f "$SERVER_LIST_TMP"
		log 'ERROR: COULD NOT RETRIEVE VPN SERVERS'
		return 1
	}

	jq -er '.[0].station // empty' "$SERVER_LIST_TMP" >/dev/null 2>&1 || {
		rm -f "$SERVER_LIST_TMP"
		if [ -n "$VPN_COUNTRY" ]; then
			log "ERROR: NO WIREGUARD SERVERS FOUND FOR COUNTRY '$VPN_COUNTRY'"
		else
			log 'ERROR: INVALID VPN SERVER LIST'
		fi
		return 1
	}

	mv "$SERVER_LIST_TMP" "$SERVER_LIST_FILE" || {
		rm -f "$SERVER_LIST_TMP"
		log 'ERROR: COULD NOT UPDATE VPN SERVER LIST'
		return 1
	}

	SERVER_COUNT=$(jq -r 'length' "$SERVER_LIST_FILE" 2>/dev/null)
	log "VPN server list updated at $SERVER_LIST_FILE with ${SERVER_COUNT:-unknown} entries"
}

nordvpn_easy_set_first_server_from_list() {
	FIRST_SERVER=$(jq -r '.[0] | [
		.hostname,
		.station,
		([.technologies[]?.metadata[]? | select(.name=="public_key").value][0]),
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

	IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD <<EOF
$FIRST_SERVER
EOF

	log "Selected first recommended VPN server $HOST_NAME ($SERVER_IP)"
	set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD"
}

nordvpn_easy_change_to_preferred_server() {
	apply_preferred_server_from_catalog || return 1

	uci commit network || {
		log 'ERROR: COULD NOT COMMIT NETWORK CONFIGURATION'
		return 1
	}

	log "VPN server changed to preferred server $PREFERRED_SERVER_HOSTNAME ($PREFERRED_SERVER_STATION)"
	apply_server_change_runtime "${1:-reload}"
}

nordvpn_easy_sync_server_selection() {
	vpn_is_configured || return 0

	if server_selection_is_manual; then
		require_manual_server_preference || return 1

		if preferred_server_matches_current; then
			log 'Current VPN server already matches the preferred manual server'
			return 0
		fi

		log 'Current VPN server does not match the preferred manual server, applying preference'
		change_to_preferred_server reload
		return $?
	fi

	get_servers_list || return 1

	if current_server_matches_recommendations; then
		log 'Current VPN server already matches the selected country/filter'
		return 0
	fi

	log 'Current VPN server does not match the selected country/filter, changing server'
	change_vpn_server reload
}

nordvpn_easy_change_vpn_server() {
	CURRENT_SERVER=$(current_server_station)
	SERVER_CANDIDATES_FILE="/tmp/nordvpn.candidates.$$"
	commit_failed=0
	server_changed=0

	log "Starting VPN server rotation from current endpoint ${CURRENT_SERVER:-none}"

	nordvpn_easy_recommendation_candidates_tsv "$SERVER_LIST_FILE" > "$SERVER_CANDIDATES_FILE" || {
		rm -f "$SERVER_CANDIDATES_FILE"
		log 'ERROR: INVALID VPN SERVER LIST'
		return 1
	}

	while IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD; do
		[ -n "$SERVER_IP" ] || continue
		[ "$CURRENT_SERVER" = "$SERVER_IP" ] && continue

		log "Trying VPN server candidate $HOST_NAME ($SERVER_IP)"

		set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD" || continue
		uci commit network || {
			log 'ERROR: COULD NOT COMMIT NETWORK CONFIGURATION'
			commit_failed=1
			break
		}

		log "VPN server changed to $HOST_NAME ( $SERVER_IP )"

		if apply_server_change_runtime "$1"; then
			server_changed=1
			break
		fi
	done < "$SERVER_CANDIDATES_FILE"

	rm -f "$SERVER_CANDIDATES_FILE"

	if [ "$commit_failed" -eq 1 ]; then
		return 1
	fi

	if [ "$server_changed" -eq 1 ]; then
		return 0
	fi

	log 'NO RECOMMENDED VPN SERVER RESTORED CONNECTIVITY'
	return 1
}

nordvpn_easy_change_manual_server() {
	CURRENT_SERVER=$(current_server_station)
	SERVER_CANDIDATES_FILE="/tmp/nordvpn-manual.candidates.$$"
	commit_failed=0
	server_changed=0

	require_manual_server_preference || return 1
	fetch_server_catalog 0 "$VPN_COUNTRY" || return 1

	log "Starting manual VPN server rotation from current endpoint ${CURRENT_SERVER:-none}"

	nordvpn_easy_server_catalog_candidates_tsv "$SERVER_CATALOG_FILE" > "$SERVER_CANDIDATES_FILE" || {
		rm -f "$SERVER_CANDIDATES_FILE"
		log 'ERROR: INVALID SERVER CATALOG'
		return 1
	}

	while IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY COUNTRY_CODE CITY_NAME SERVER_LOAD; do
		[ -n "$SERVER_IP" ] || continue
		[ "$CURRENT_SERVER" = "$SERVER_IP" ] && continue

		log "Trying manual VPN server candidate $HOST_NAME ($SERVER_IP)"

		set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY" "$COUNTRY_CODE" "$CITY_NAME" "$SERVER_LOAD" || continue
		uci commit network || {
			log 'ERROR: COULD NOT COMMIT NETWORK CONFIGURATION'
			commit_failed=1
			break
		}
		if apply_server_change_runtime "$1"; then
			set_server_preference_in_uci "$HOST_NAME" "$SERVER_IP"
			uci commit nordvpn_easy || {
				log 'ERROR: COULD NOT COMMIT MANUAL SERVER PREFERENCE'
				continue
			}

			PREFERRED_SERVER_HOSTNAME="$HOST_NAME"
			PREFERRED_SERVER_STATION="$SERVER_IP"
			log "Manual preferred VPN server updated to $HOST_NAME ($SERVER_IP)"
			server_changed=1
			break
		fi
	done < "$SERVER_CANDIDATES_FILE"

	rm -f "$SERVER_CANDIDATES_FILE"

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
	log "$VPN_IF NOT CONFIGURED - IT WILL BE CREATED"
	log_vpn_interface_state 'before-create'
	log "Creating WireGuard interface $VPN_IF with address $VPN_ADDR and endpoint port $VPN_PORT"

	get_private_key || return 1
	if server_selection_is_manual; then
		require_manual_server_preference || return 1
		fetch_server_catalog 0 "$VPN_COUNTRY" || return 1
	else
		get_servers_list || return 1
	fi
	ensure_vpn_in_wan_zone || return 1

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

	if server_selection_is_manual; then
		apply_preferred_server_from_catalog || return 1
	else
		set_first_server_from_list || return 1
	fi

	uci set "network.${WAN_IF}.metric"='1024'
	uci commit network || {
		log 'ERROR: COULD NOT COMMIT NETWORK CONFIGURATION'
		return 1
	}

	/etc/init.d/network restart || {
		log 'ERROR: NETWORK RESTART FAILED'
		return 1
	}

	log "$VPN_IF CREATED"
	log_vpn_interface_state 'after-create'
}

nordvpn_easy_bootstrap_if_needed() {
	log "Bootstrapping VPN state for interface $VPN_IF"
	log_vpn_interface_state 'bootstrap-start'
	refresh_countries_cache || true
	if [ -n "$VPN_COUNTRY" ]; then
		resolve_country_filter || return 1
	fi

	if ! vpn_is_configured; then
		configure_vpn_interface || return 1
	else
		ensure_vpn_interface_enabled || return 1
	fi

	ensure_vpn_in_wan_zone || return 1
	ensure_vpn_interface_present || return 1
	log "Bootstrap completed for interface $VPN_IF"
	log_vpn_interface_state 'bootstrap-complete'
}

nordvpn_easy_rotate_action() {
	log 'Rotate action started'
	bootstrap_if_needed || return 1

	if server_selection_is_manual; then
		log 'Changing preferred manual VPN server'
		change_manual_server reload
		return $?
	fi

	get_servers_list || return 1
	log 'Changing VPN server'
	change_vpn_server reload
}

nordvpn_easy_check_once() {
	# shellcheck disable=SC3043 # OpenWrt /bin/sh is BusyBox ash, which supports local.
	local failed_pings=0
	local restart_count=0
	local max_interface_restarts="${MAX_INTERFACE_RESTARTS:-3}"
	local retry_delay
	local backoff_steps

	log "Starting VPN health-check on interface $VPN_IF"
	if ! server_selection_is_manual; then
		[ -f "$SERVER_LIST_FILE" ] || get_servers_list || true
	fi

	while ! ping_interface "$VPN_IF"; do
		failed_pings=$((failed_pings+1))
		retry_delay="$FAILURE_RETRY_DELAY"
		ping_wan || {
			log "WAN connectivity is down while VPN health-check is failing on $VPN_IF; skipping VPN recovery"
			return 0
		}

		if [ "$failed_pings" -gt "$INTERFACE_RESTART_THRESHOLD" ]; then
			if [ "$restart_count" -ge "$max_interface_restarts" ]; then
				log "PING FAILED $failed_pings TIMES - RESTART LIMIT REACHED FOR $VPN_IF ($restart_count/$max_interface_restarts)"
				return 1
			fi

			restart_count=$((restart_count+1))
			log "PING FAILED $failed_pings TIMES - RESTARTING $VPN_IF ($restart_count/$max_interface_restarts)"
			log "Requesting ifdown for interface $VPN_IF during recovery"
			ifdown "$VPN_IF"
			sleep "$INTERFACE_RESTART_DELAY"
			log "Requesting ifup for interface $VPN_IF during recovery"
			ifup "$VPN_IF"
			sleep "$POST_RESTART_DELAY"
			log_vpn_interface_state 'after-recovery-restart'
		elif [ "$failed_pings" -ge "$SERVER_ROTATE_THRESHOLD" ]; then
			log "PING FAILED $failed_pings TIMES"

			if server_selection_is_manual; then
				log 'Manual server selection is enabled; skipping automatic server rotation'
			else
				if get_servers_list; then
					log 'Changing VPN server'
					change_vpn_server restart && return 0
				else
					log 'Refreshing VPN server list failed'
				fi
			fi

			log 'Restarting network'
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
				[ "$retry_delay" -gt "$POST_RESTART_DELAY" ] && retry_delay="$POST_RESTART_DELAY"
				backoff_steps=$((backoff_steps - 1))
			done
		fi

		sleep "$retry_delay"
	done

	log "VPN health-check passed on interface $VPN_IF"
}
