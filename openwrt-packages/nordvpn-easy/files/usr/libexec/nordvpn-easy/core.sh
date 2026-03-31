#!/bin/sh

# Use NORDVPN_TOKEN with the token you get from https://my.nordaccount.com/dashboard/nordvpn/access-tokens/

LIB_DIR='/usr/libexec/nordvpn-easy/lib'
SCHEMA_LIB="${LIB_DIR}/schema.sh"
COMMON_LIB="${LIB_DIR}/common.sh"
CATALOG_LIB="${LIB_DIR}/catalog.sh"
WIREGUARD_LIB="${LIB_DIR}/wireguard.sh"
ACTIONS_LIB="${LIB_DIR}/actions.sh"

# shellcheck disable=SC1090
. "$SCHEMA_LIB" || exit 1
# shellcheck disable=SC1090
. "$COMMON_LIB" || exit 1
# shellcheck disable=SC1090
. "$CATALOG_LIB" || exit 1
# shellcheck disable=SC1090
. "$WIREGUARD_LIB" || exit 1
# shellcheck disable=SC1090
. "$ACTIONS_LIB" || exit 1

nordvpn_easy_apply_env_defaults

VPN_INTERFACE_PRESENT_DELAY="${VPN_INTERFACE_PRESENT_DELAY:-10}"

SERVER_LIST_FILE='/tmp/nordvpn.json'
COUNTRIES_CACHE_FILE='/tmp/nordvpn-easy-countries.json'
COUNTRIES_CACHE_TS_FILE='/tmp/nordvpn-easy-countries.timestamp'
SERVER_CATALOG_FILE='/tmp/nordvpn-easy-servers.json'
SERVER_CATALOG_TS_FILE='/tmp/nordvpn-easy-servers.timestamp'
COUNTRIES_CACHE_TTL="${COUNTRIES_CACHE_TTL:-86400}"
NORDVPN_API='https://api.nordvpn.com/v1'
COUNTRIES_URL="${NORDVPN_API}/servers/countries"
PUBLIC_COUNTRY_API='https://api.country.is'   # Third-party API, no auth required; returns JSON like {"country":"XX"} with an ISO country code.
SERVER_RECOMMENDATIONS_URL_BASE="${NORDVPN_API}/servers/recommendations?filters[servers_technologies][identifier]=wireguard_udp&limit=10"
SERVER_CATALOG_URL_BASE="${NORDVPN_API}/servers?filters[servers_technologies][identifier]=wireguard_udp&limit=5000"
CREDENTIALS_URL="${NORDVPN_API}/users/services/credentials"
DEFAULT_CONFIG_FILE='/var/etc/nordvpn-easy.conf'
LOCK_DIR='/tmp/nordvpn-easy.lock'
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_NAME=''
RESOLVED_COUNTRY_CODE=''
RESOLVED_COUNTRY_QUERY=''
CONFIG_PATH=''
CONFIG_PATH_REQUIRED=0
LOCK_ACQUIRED=0
PUBLIC_COUNTRY_VERIFIED=0
SERVER_CATALOG_QUERY=''
SERVER_CATALOG_FORCE='0'

# List of IPs to randomly ping
IP0='8.8.8.8'
IP1='8.8.4.4'
IP2='1.1.1.1'
IP3='1.0.0.1'
IP4='208.67.222.222'
IP5='208.67.220.220'
IP6='9.9.9.9'
IP7='149.112.112.112'
IP8='195.46.39.39'
IP9='195.46.39.40'
IP10='45.90.28.165'
IP11='45.90.30.165'
IP12='156.154.70.1'
IP13='156.154.71.1'
IP14='8.26.56.26'
IP15='8.20.247.20'
IP16='64.6.64.6'
IP17='64.6.65.6'
IP18='209.244.0.3'
IP19='209.244.0.4'

log () {
  nordvpn_easy_log "$@"
}

curl_rc_meaning () {
  nordvpn_easy_curl_rc_meaning "$@"
}

usage () {
  cat <<EOF
Usage: $0 [check|setup|rotate|refresh_countries|refresh_countries_force|server_catalog|public_ip|public_country|run|help] [config_file] [extra_args]

Commands:
  check   Run one VPN health-check cycle (default)
  setup   Configure the WireGuard interface and firewall if needed
  rotate  Download a fresh server list and switch server
  refresh_countries  Refresh the cached NordVPN country list if needed
  refresh_countries_force  Force-refresh the cached NordVPN country list
  server_catalog [country_query] [force]
          Print the cached or refreshed NordVPN WireGuard server catalog JSON
  public_ip  Print the current public IP as seen from the router
  public_country  Print the detected country code for the current public IP
  run     Backward-compatible alias for check
  help    Show this message

If config_file is omitted, $DEFAULT_CONFIG_FILE is used when present.
EOF
}

lock_contention_is_nonfatal () {
  nordvpn_easy_lock_contention_is_nonfatal "$@"
}

load_config () {
  if [ -f "$CONFIG_PATH" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_PATH"
    log "Loaded runtime configuration from $CONFIG_PATH"
  elif [ "$CONFIG_PATH_REQUIRED" -eq 1 ]; then
    log "ERROR: CONFIG FILE $CONFIG_PATH NOT FOUND"
    return 1
  else
    log "No runtime configuration file found at $CONFIG_PATH, using environment/default values"
  fi
}

require_commands () {
  nordvpn_easy_require_commands "$@"
}

server_selection_is_manual () {
  nordvpn_easy_server_selection_is_manual "$@"
}

server_cache_is_enabled () {
  nordvpn_easy_server_cache_is_enabled "$@"
}

current_server_station () {
  nordvpn_easy_current_server_station "$@"
}

set_server_preference_in_uci () {
  nordvpn_easy_set_server_preference_in_uci "$@"
}

require_manual_server_preference () {
  nordvpn_easy_require_manual_server_preference "$@"
}

server_cache_ttl_value () {
  nordvpn_easy_server_cache_ttl_value "$@"
}

release_lock () {
  nordvpn_easy_release_lock "$@"
}

acquire_lock () {
  nordvpn_easy_acquire_lock "$@"
}

vpn_is_configured () {
  nordvpn_easy_vpn_is_configured "$@"
}

vpn_link_is_present () {
  nordvpn_easy_vpn_link_is_present "$@"
}

log_vpn_interface_state () {
  nordvpn_easy_log_vpn_interface_state "$@"
}

recover_missing_vpn_interface () {
  nordvpn_easy_recover_missing_vpn_interface "$@"
}

ensure_vpn_interface_present () {
  nordvpn_easy_ensure_vpn_interface_present "$@"
}

ensure_vpn_interface_enabled () {
  nordvpn_easy_ensure_vpn_interface_enabled "$@"
}

pick_ping_ip () {
  eval "printf '%s\n' \"\$IP$(awk 'BEGIN { srand(); print int((rand()*10000000)) % 20 }')\""
}

ping_interface () {
  nordvpn_easy_ping_interface "$@"
}

curl_config_escape () {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

fetch_credentials_json () {
  {
    printf '%s\n' 'silent'
    printf '%s\n' 'show-error'
    printf '%s\n' 'fail'
    printf '%s\n' 'connect-timeout = 15'
    printf '%s\n' 'max-time = 30'
    printf 'url = "%s"\n' "$(curl_config_escape "$CREDENTIALS_URL")"

    printf 'user = "token:%s"\n' "$(curl_config_escape "$NORDVPN_TOKEN")"
  } | curl --config -
}

get_private_key () {
  if [ -n "$NORDVPN_TOKEN" ]; then
    log 'Requesting NordLynx private key from NordVPN API'
    CREDENTIALS_JSON=$(fetch_credentials_json) || {
      log 'ERROR: COULD NOT RETRIEVE PRIVATE_KEY'
      return 1
    }
  else
    log 'ERROR: NORDVPN_TOKEN IS NOT DEFINED'
    return 1
  fi

  PRIVATE_KEY=$(printf '%s' "$CREDENTIALS_JSON" | jq -er '.nordlynx_private_key // empty' 2>/dev/null) || {
    log 'ERROR: INVALID PRIVATE_KEY RESPONSE'
    return 1
  }

  log 'NordLynx private key retrieved successfully'
}

countries_cache_is_fresh () {
  [ -f "$COUNTRIES_CACHE_FILE" ] || return 1
  [ -f "$COUNTRIES_CACHE_TS_FILE" ] || return 1

  NOW_TS=$(date +%s 2>/dev/null) || return 1
  CACHE_TS=$(cat "$COUNTRIES_CACHE_TS_FILE" 2>/dev/null) || return 1

  case "$CACHE_TS" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  [ $((NOW_TS - CACHE_TS)) -lt "$COUNTRIES_CACHE_TTL" ]
}

refresh_countries_cache () {
  FORCE_REFRESH="${1:-0}"
  COUNTRIES_CACHE_TMP="${COUNTRIES_CACHE_FILE}.tmp.$$"
  COUNTRIES_TS_TMP="${COUNTRIES_CACHE_TS_FILE}.tmp.$$"

  if [ "$FORCE_REFRESH" -ne 1 ] && countries_cache_is_fresh; then
    log "Using cached NordVPN country list from $COUNTRIES_CACHE_FILE"
    return 0
  fi

  if [ "$FORCE_REFRESH" -eq 1 ]; then
    log 'Force-refreshing NordVPN country list cache'
  else
    log 'Refreshing NordVPN country list cache'
  fi

  curl -fsS --connect-timeout 15 --max-time 30 "$COUNTRIES_URL" | jq -ce '
    [ .[] | select(
        (.id != null) and
        ((.name // "") != "") and
        ((.code // "") != "")
      ) | {
        id: .id,
        name: .name,
        code: .code
      }
    ] | sort_by(.name | ascii_downcase)
  ' > "$COUNTRIES_CACHE_TMP" 2>/dev/null || {
    rm -f "$COUNTRIES_CACHE_TMP" "$COUNTRIES_TS_TMP"
    [ -f "$COUNTRIES_CACHE_FILE" ] && return 0
    log 'ERROR: COULD NOT REFRESH COUNTRY LIST CACHE'
    return 1
  }

  date +%s > "$COUNTRIES_TS_TMP" || {
    rm -f "$COUNTRIES_CACHE_TMP" "$COUNTRIES_TS_TMP"
    [ -f "$COUNTRIES_CACHE_FILE" ] && return 0
    log 'ERROR: COULD NOT WRITE COUNTRY CACHE TIMESTAMP'
    return 1
  }

  mv "$COUNTRIES_CACHE_TMP" "$COUNTRIES_CACHE_FILE" || {
    rm -f "$COUNTRIES_CACHE_TMP" "$COUNTRIES_TS_TMP"
    [ -f "$COUNTRIES_CACHE_FILE" ] && return 0
    log 'ERROR: COULD NOT UPDATE COUNTRY LIST CACHE'
    return 1
  }

  mv "$COUNTRIES_TS_TMP" "$COUNTRIES_CACHE_TS_FILE" || {
    rm -f "$COUNTRIES_TS_TMP"
    [ -f "$COUNTRIES_CACHE_FILE" ] && return 0
    log 'ERROR: COULD NOT UPDATE COUNTRY CACHE TIMESTAMP'
    return 1
  }

  log "NordVPN country list cache updated at $COUNTRIES_CACHE_FILE"
}

valid_public_ip () {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]+$'
}

valid_country_code () {
  printf '%s' "$1" | grep -Eq '^[A-Z]{2}$'
}

get_public_ip () {
  local curl_out curl_rc

  log "get_public_ip: starting IPv4-only public IP lookup (system DNS: $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'))"

  for PUBLIC_IP_URL in \
    'https://api.ipify.org' \
    'https://api64.ipify.org' \
    'https://ipv4.icanhazip.com' \
    'https://ifconfig.me/ip'
  do
    log "get_public_ip: trying $PUBLIC_IP_URL"
    curl_out=$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$PUBLIC_IP_URL" 2>/dev/null | tr -d '\r\n')
    curl_rc=$?

    if [ "$curl_rc" -ne 0 ]; then
      log "get_public_ip: curl failed for $PUBLIC_IP_URL (curl_rc=$curl_rc: $(curl_rc_meaning "$curl_rc"))"
      continue
    fi

    if [ -z "$curl_out" ]; then
      log "get_public_ip: curl succeeded (rc=0) but response body is empty for $PUBLIC_IP_URL — possible VPN transparent proxy interference"
      continue
    fi

    if ! valid_public_ip "$curl_out"; then
      log "get_public_ip: response from $PUBLIC_IP_URL is not a valid IP address (got '${curl_out}')"
      continue
    fi

    log "get_public_ip: got '$curl_out' from $PUBLIC_IP_URL"
    PUBLIC_IP="$curl_out"
    printf '%s\n' "$PUBLIC_IP"
    return 0
  done

  log 'ERROR: COULD NOT RETRIEVE PUBLIC IP — all endpoints failed'
  return 1
}

lookup_public_country_by_ip () {
  LOOKUP_IP="$1"
  local curl_raw curl_rc country_raw

  [ -n "$LOOKUP_IP" ] || {
    log 'ERROR: PUBLIC IP IS EMPTY - CANNOT LOOK UP COUNTRY'
    return 1
  }

  # NordVPN's Threat Protection Lite DNS (103.86.99.99) may block api.country.is.
  # Resolve it via Quad9 DNS (9.9.9.9) first to bypass VPN DNS filtering, then
  # pass the result to curl via --resolve so no system DNS query is needed.
  local api_host
  api_host=$(printf '%s' "$PUBLIC_COUNTRY_API" | sed 's|https://||')

  log "lookup_public_country_by_ip: system DNS servers: $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
  log "lookup_public_country_by_ip: resolving $api_host via Quad9 DNS (9.9.9.9) to bypass VPN DNS filtering"

  local nslookup_out resolved_ip
  nslookup_out=$(nslookup "$api_host" 9.9.9.9 2>&1)
  resolved_ip=$(printf '%s\n' "$nslookup_out" \
    | awk '/^Address/ && !/9\.9\.9\.9/ && /[0-9]\.[0-9]/ {print $NF; exit}')

  log "lookup_public_country_by_ip: Quad9 nslookup output: $(printf '%s' "$nslookup_out" | tr '\n' '|')"

  if [ -n "$resolved_ip" ]; then
    log "lookup_public_country_by_ip: resolved $api_host → $resolved_ip via Quad9 DNS — will use --resolve to bypass system DNS"
  else
    log "lookup_public_country_by_ip: Quad9 DNS resolution failed for $api_host — falling back to system DNS (may fail if VPN DNS blocks it)"
  fi

  log "lookup_public_country_by_ip: querying ${PUBLIC_COUNTRY_API}/${LOOKUP_IP} (IPv4-only$([ -n "$resolved_ip" ] && printf ', resolve hint: %s' "$resolved_ip"))"

  if [ -n "$resolved_ip" ]; then
    curl_raw=$(curl -4 --resolve "${api_host}:443:${resolved_ip}" -fsS --connect-timeout 5 --max-time 10 "${PUBLIC_COUNTRY_API}/${LOOKUP_IP}" 2>/dev/null)
  else
    curl_raw=$(curl -4 -fsS --connect-timeout 5 --max-time 10 "${PUBLIC_COUNTRY_API}/${LOOKUP_IP}" 2>/dev/null)
  fi
  curl_rc=$?

  if [ "$curl_rc" -ne 0 ]; then
    log "ERROR: COULD NOT LOOK UP COUNTRY FOR PUBLIC IP $LOOKUP_IP — curl failed (curl_rc=$curl_rc: $(curl_rc_meaning "$curl_rc")$([ -z "$resolved_ip" ] && printf '; system DNS was used, Quad9 bypass had failed'))"
    return 1
  fi

  if [ -z "$curl_raw" ]; then
    log "ERROR: COULD NOT LOOK UP COUNTRY FOR PUBLIC IP $LOOKUP_IP — curl succeeded (rc=0) but response body is empty"
    return 1
  fi

  log "lookup_public_country_by_ip: raw response for $LOOKUP_IP: $curl_raw"

  if ! country_raw=$(printf '%s' "$curl_raw" | jq -er '.country // empty' 2>/dev/null); then
    log "ERROR: COULD NOT PARSE COUNTRY FROM RESPONSE FOR $LOOKUP_IP (raw='$curl_raw')"
    return 1
  fi

  if [ -z "$country_raw" ]; then
    log "ERROR: COULD NOT PARSE COUNTRY FROM RESPONSE FOR $LOOKUP_IP (raw='$curl_raw')"
    return 1
  fi

  PUBLIC_COUNTRY=$(printf '%s' "$country_raw" | tr '[:lower:]' '[:upper:]')
  valid_country_code "$PUBLIC_COUNTRY" || {
    log "ERROR: INVALID COUNTRY LOOKUP RESPONSE FOR PUBLIC IP $LOOKUP_IP (parsed='$PUBLIC_COUNTRY', raw='$curl_raw')"
    return 1
  }

  log "lookup_public_country_by_ip: resolved $LOOKUP_IP → $PUBLIC_COUNTRY"
  printf '%s\n' "$PUBLIC_COUNTRY"
}

get_public_country () {
  log 'get_public_country: starting public IP and country lookup'
  PUBLIC_IP=$(get_public_ip) || {
    log 'get_public_country: public IP lookup failed — cannot determine country'
    return 1
  }
  log "get_public_country: public IP is $PUBLIC_IP — proceeding to country lookup"
  lookup_public_country_by_ip "$PUBLIC_IP"
}

verify_public_country_selection () {
  PUBLIC_COUNTRY_VERIFIED=1

  PUBLIC_IP=$(get_public_ip) || {
    log 'WARNING: COULD NOT RETRIEVE PUBLIC IP FOR COUNTRY VERIFICATION'
    return 0
  }

  PUBLIC_COUNTRY=$(lookup_public_country_by_ip "$PUBLIC_IP") || {
    log "WARNING: COULD NOT GEOLOCATE PUBLIC IP $PUBLIC_IP"
    return 0
  }

  if [ -z "$VPN_COUNTRY" ]; then
    log "Public IP verification: $PUBLIC_IP geolocates to $PUBLIC_COUNTRY with automatic country selection"
    return 0
  fi

  resolve_country_filter || {
    log "WARNING: COULD NOT RESOLVE SELECTED COUNTRY '$VPN_COUNTRY' FOR PUBLIC IP VERIFICATION"
    return 0
  }

  if [ "$PUBLIC_COUNTRY" = "$RESOLVED_COUNTRY_CODE" ]; then
    log "Public IP verification passed: $PUBLIC_IP geolocates to $PUBLIC_COUNTRY and matches selected country $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
  else
    log "WARNING: Public IP verification mismatch: $PUBLIC_IP geolocates to $PUBLIC_COUNTRY while selected country is $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
  fi
}

resolve_country_filter () {
  COUNTRY_QUERY="${1:-$VPN_COUNTRY}"

  [ -z "$COUNTRY_QUERY" ] && return 0
  if [ -n "$RESOLVED_COUNTRY_ID" ] && [ "$RESOLVED_COUNTRY_QUERY" = "$COUNTRY_QUERY" ]; then
    return 0
  fi

  refresh_countries_cache || {
    log 'ERROR: COULD NOT RETRIEVE COUNTRY LIST'
    return 1
  }

  COUNTRY_MATCH=$(jq -er --arg query "$COUNTRY_QUERY" '
    [ .[] | select(
      ((.id | tostring) == $query) or
      ((.code // "" | ascii_downcase) == ($query | ascii_downcase)) or
      ((.name // "" | ascii_downcase) == ($query | ascii_downcase))
    ) ][0] | [.id, .name, .code] | @tsv
  ' "$COUNTRIES_CACHE_FILE" 2>/dev/null) || {
    log "ERROR: COUNTRY '$COUNTRY_QUERY' NOT FOUND"
    return 1
  }

  IFS="$(printf '\t')" read -r RESOLVED_COUNTRY_ID RESOLVED_COUNTRY_NAME RESOLVED_COUNTRY_CODE <<EOF
$COUNTRY_MATCH
EOF

  [ -n "$RESOLVED_COUNTRY_ID" ] || {
    log "ERROR: COUNTRY '$COUNTRY_QUERY' NOT FOUND"
    return 1
  }

  RESOLVED_COUNTRY_QUERY="$COUNTRY_QUERY"
  log "Filtering VPN servers by country: $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
}

server_catalog_cache_is_fresh () {
  TARGET_COUNTRY_ID="$1"
  TTL_VALUE="$(server_cache_ttl_value)"

  [ -n "$TARGET_COUNTRY_ID" ] || return 1
  server_cache_is_enabled || return 1
  [ -f "$SERVER_CATALOG_FILE" ] || return 1
  [ -f "$SERVER_CATALOG_TS_FILE" ] || return 1

  NOW_TS=$(date +%s 2>/dev/null) || return 1
  CACHE_TS=$(cat "$SERVER_CATALOG_TS_FILE" 2>/dev/null) || return 1

  case "$CACHE_TS" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  [ $((NOW_TS - CACHE_TS)) -lt "$TTL_VALUE" ] || return 1

  jq -er --arg expected "$TARGET_COUNTRY_ID" '
    (.country_id | tostring) == $expected and
    (.servers | type == "array") and
    (.servers | length >= 0)
  ' "$SERVER_CATALOG_FILE" >/dev/null 2>&1
}

server_catalog_cache_matches_country () {
  TARGET_COUNTRY_ID="$1"

  [ -n "$TARGET_COUNTRY_ID" ] || return 1
  [ -f "$SERVER_CATALOG_FILE" ] || return 1

  jq -er --arg expected "$TARGET_COUNTRY_ID" '
    (.country_id | tostring) == $expected and
    (.servers | type == "array") and
    (.servers | length > 0)
  ' "$SERVER_CATALOG_FILE" >/dev/null 2>&1
}

fetch_server_catalog () {
  FORCE_REFRESH="${1:-0}"
  COUNTRY_QUERY="${2:-$VPN_COUNTRY}"
  SERVER_CATALOG_TMP="${SERVER_CATALOG_FILE}.tmp.$$"
  SERVER_CATALOG_TS_TMP="${SERVER_CATALOG_TS_FILE}.tmp.$$"
  SERVER_CATALOG_RAW_TMP="${SERVER_CATALOG_TMP}.raw"
  SERVER_CATALOG_URL=''

  [ -n "$COUNTRY_QUERY" ] || {
    log 'ERROR: SERVER CATALOG REQUEST REQUIRES A COUNTRY FILTER'
    return 1
  }

  resolve_country_filter "$COUNTRY_QUERY" || return 1

  if [ "$FORCE_REFRESH" -ne 1 ] && server_catalog_cache_is_fresh "$RESOLVED_COUNTRY_ID"; then
    log "Using cached NordVPN server catalog from $SERVER_CATALOG_FILE for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    return 0
  fi

  SERVER_CATALOG_URL="${SERVER_CATALOG_URL_BASE}&filters[country_id]=$RESOLVED_COUNTRY_ID"
  log "Refreshing NordVPN server catalog for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"

  curl -g -fsS --connect-timeout 15 --max-time 45 -o "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_URL" || {
      rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_TS_TMP"
      server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
      log "ERROR: COULD NOT DOWNLOAD SERVER CATALOG FOR $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
      return 1
    }

  [ -s "$SERVER_CATALOG_RAW_TMP" ] || {
    rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_TS_TMP"
    server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
    log "ERROR: EMPTY SERVER CATALOG RESPONSE FOR $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    return 1
  }

  nordvpn_easy_build_server_catalog_json "$RESOLVED_COUNTRY_ID" "$RESOLVED_COUNTRY_CODE" "$RESOLVED_COUNTRY_NAME" \
    < "$SERVER_CATALOG_RAW_TMP" > "$SERVER_CATALOG_TMP" 2>/dev/null || {
      rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_TS_TMP"
      server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
      log "ERROR: COULD NOT TRANSFORM SERVER CATALOG FOR $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
      return 1
    }

  rm -f "$SERVER_CATALOG_RAW_TMP"

  nordvpn_easy_server_catalog_has_servers "$SERVER_CATALOG_TMP" || {
    rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_TS_TMP"
    server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
    log "ERROR: NO WIREGUARD SERVERS FOUND FOR COUNTRY '$COUNTRY_QUERY'"
    return 1
  }

  date +%s > "$SERVER_CATALOG_TS_TMP" || {
    rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_TS_TMP"
    server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
    log 'ERROR: COULD NOT WRITE SERVER CATALOG TIMESTAMP'
    return 1
  }

  mv "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_FILE" || {
    rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_TS_TMP"
    server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
    log 'ERROR: COULD NOT UPDATE SERVER CATALOG CACHE'
    return 1
  }

  mv "$SERVER_CATALOG_TS_TMP" "$SERVER_CATALOG_TS_FILE" || {
    rm -f "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_TS_TMP"
    server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID" && return 0
    log 'ERROR: COULD NOT UPDATE SERVER CATALOG TIMESTAMP'
    return 1
  }

  log "NordVPN server catalog updated at $SERVER_CATALOG_FILE for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
}

find_preferred_server_in_catalog () {
  nordvpn_easy_find_preferred_server_in_catalog "$@"
}

preferred_server_matches_current () {
  nordvpn_easy_preferred_server_matches_current "$@"
}

apply_preferred_server_from_catalog () {
  nordvpn_easy_apply_preferred_server_from_catalog "$@"
}

build_server_recommendations_url () {
  nordvpn_easy_build_server_recommendations_url "$@"
}

get_servers_list () {
  nordvpn_easy_get_servers_list "$@"
}

resolve_wan_device () {
  nordvpn_easy_resolve_wan_device "$@"
}

ping_wan () {
  nordvpn_easy_ping_wan "$@"
}

find_firewall_zone_section () {
  nordvpn_easy_find_firewall_zone_section "$@"
}

ensure_vpn_in_wan_zone () {
  nordvpn_easy_ensure_vpn_in_wan_zone "$@"
}

set_vpn_server_in_uci () {
  nordvpn_easy_set_vpn_server_in_uci "$@"
}

set_first_server_from_list () {
  nordvpn_easy_set_first_server_from_list "$@"
}

current_server_matches_recommendations () {
  nordvpn_easy_current_server_matches_recommendations "$@"
}

apply_server_change_runtime () {
  nordvpn_easy_apply_server_change_runtime "$@"
}

change_to_preferred_server () {
  nordvpn_easy_change_to_preferred_server "$@"
}

sync_server_selection () {
  nordvpn_easy_sync_server_selection "$@"
}

change_vpn_server () {
  nordvpn_easy_change_vpn_server "$@"
}

change_manual_server () {
  nordvpn_easy_change_manual_server "$@"
}

configure_vpn_interface () {
  nordvpn_easy_configure_vpn_interface "$@"
}

bootstrap_if_needed () {
  nordvpn_easy_bootstrap_if_needed "$@"
}

rotate_action () {
  nordvpn_easy_rotate_action "$@"
}

check_once () {
  nordvpn_easy_check_once "$@"
}

ACTION='check'

if [ $# -gt 0 ]; then
  case "$1" in
    check|setup|rotate|refresh_countries|refresh_countries_force|server_catalog|public_ip|public_country|run|help)
      ACTION="$1"
      shift
      ;;
  esac
fi

if [ $# -gt 0 ]; then
  CONFIG_PATH="$1"
  CONFIG_PATH_REQUIRED=1
  shift
else
  CONFIG_PATH="${NORDVPN_CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
fi

load_config || exit 1

case "$ACTION" in
  help)
    usage
    exit 0
    ;;
esac

if [ "$ACTION" = 'public_ip' ]; then
  command -v curl >/dev/null 2>&1 || {
    log 'curl IS MISSING, PLEASE INSTALL'
    exit 1
  }

  get_public_ip
  exit $?
fi

if [ "$ACTION" = 'public_country' ]; then
  require_commands || exit 1
  get_public_country
  exit $?
fi

if [ "$ACTION" = 'server_catalog' ]; then
  SERVER_CATALOG_QUERY="${1:-$VPN_COUNTRY}"
  SERVER_CATALOG_FORCE="${2:-0}"
fi

require_commands || exit 1

log "Executing action '$ACTION' for VPN interface $VPN_IF"

# Intentionally exit 0 on lock contention so cron/hotplug do not log an error when another instance already holds the lock.
acquire_lock
LOCK_STATUS=$?
if [ "$LOCK_STATUS" -ne 0 ]; then
  if [ "$LOCK_STATUS" -eq 2 ] && lock_contention_is_nonfatal; then
    exit 0
  fi

  if [ "$LOCK_STATUS" -eq 2 ]; then
    log "ERROR: ACTION '$ACTION' ABORTED BECAUSE ANOTHER NORDVPN-EASY OPERATION IS STILL RUNNING"
  else
    log "ERROR: ACTION '$ACTION' FAILED TO ACQUIRE EXECUTION LOCK AT $LOCK_DIR"
  fi
  exit 1
fi

case "$ACTION" in
  run|check)
    bootstrap_if_needed && check_once
    ;;
  setup)
    bootstrap_if_needed && sync_server_selection && { [ "$PUBLIC_COUNTRY_VERIFIED" -eq 1 ] || verify_public_country_selection; } && log 'NordVPN configuration is ready'
    ;;
  rotate)
    rotate_action
    ;;
  refresh_countries)
    refresh_countries_cache
    ;;
  refresh_countries_force)
    refresh_countries_cache 1
    ;;
  server_catalog)
    fetch_server_catalog "$SERVER_CATALOG_FORCE" "$SERVER_CATALOG_QUERY" &&
      nordvpn_easy_emit_server_catalog_json "$SERVER_CATALOG_FILE" "$SERVER_CATALOG_TS_FILE" "$(server_cache_ttl_value)"
    ;;
  *)
    usage
    exit 1
    ;;
esac
