#!/bin/sh

# Use NORDVPN_TOKEN with the token you get from https://my.nordaccount.com/dashboard/nordvpn/access-tokens/

NORDVPN_TOKEN="${NORDVPN_TOKEN:-}"
WAN_IF="${WAN_IF:-wan}"
VPN_IF="${VPN_IF:-wg0}"
VPN_COUNTRY="${VPN_COUNTRY:-}"                 # optional: country code (IT), country name (Italy) or country id
VPN_PORT="${VPN_PORT:-51820}"                 # NordVPN-recommended default; can be changed via LuCI or env
VPN_ADDR="${VPN_ADDR:-10.5.0.2/32}"           # NordVPN-recommended default; can be changed via LuCI or env
VPN_DNS1="${VPN_DNS1:-103.86.99.99}"          # optional: these are the Threat Protection Lite DNS servers
VPN_DNS2="${VPN_DNS2:-103.86.96.96}"          # optional: these are the Threat Protection Lite DNS servers
CHECK_CRON_SCHEDULE="${CHECK_CRON_SCHEDULE:-* * * * *}"
ENABLE_HOTPLUG="${ENABLE_HOTPLUG:-1}"
FAILURE_RETRY_DELAY="${FAILURE_RETRY_DELAY:-6}"
SERVER_ROTATE_THRESHOLD="${SERVER_ROTATE_THRESHOLD:-5}"
INTERFACE_RESTART_THRESHOLD="${INTERFACE_RESTART_THRESHOLD:-10}"
MAX_INTERFACE_RESTARTS="${MAX_INTERFACE_RESTARTS:-3}"
INTERFACE_RESTART_DELAY="${INTERFACE_RESTART_DELAY:-10}"
POST_RESTART_DELAY="${POST_RESTART_DELAY:-60}"
VPN_INTERFACE_PRESENT_DELAY="${VPN_INTERFACE_PRESENT_DELAY:-10}"

SERVER_LIST_FILE='/tmp/nordvpn.json'
COUNTRIES_CACHE_FILE='/tmp/nordvpn-easy-countries.json'
COUNTRIES_CACHE_TS_FILE='/tmp/nordvpn-easy-countries.timestamp'
COUNTRIES_CACHE_TTL="${COUNTRIES_CACHE_TTL:-86400}"
NORDVPN_API='https://api.nordvpn.com/v1'
COUNTRIES_URL="${NORDVPN_API}/servers/countries"
PUBLIC_COUNTRY_API='https://api.country.is'   # Third-party API, no auth required; returns JSON like {"country":"XX"} with an ISO country code.
SERVER_RECOMMENDATIONS_URL_BASE="${NORDVPN_API}/servers/recommendations?filters[servers_technologies][identifier]=wireguard_udp&limit=10"
CREDENTIALS_URL="${NORDVPN_API}/users/services/credentials"
DEFAULT_CONFIG_FILE='/var/etc/nordvpn-easy.conf'
LOCK_DIR='/tmp/nordvpn-easy.lock'
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_NAME=''
RESOLVED_COUNTRY_CODE=''
CONFIG_PATH=''
CONFIG_PATH_REQUIRED=0
LOCK_ACQUIRED=0
PUBLIC_COUNTRY_VERIFIED=0

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
  [ "${NORDVPN_LOG_STDERR:-1}" != '0' ] && printf '*** %s ***\n' "$*" >&2
  command -v logger >/dev/null 2>&1 && logger -t 'nordvpn-easy' "$*"
}

curl_rc_meaning () {
  case "$1" in
    0)  printf 'ok' ;;
    6)  printf 'could not resolve host (DNS failure)' ;;
    7)  printf 'failed to connect to host' ;;
    28) printf 'operation timed out' ;;
    35) printf 'SSL/TLS handshake failed' ;;
    52) printf 'empty reply from server' ;;
    56) printf 'receive failure' ;;
    *)  printf 'curl error %s' "$1" ;;
  esac
}

usage () {
  cat <<EOF
Usage: $0 [check|setup|rotate|refresh_countries|refresh_countries_force|public_ip|public_country|run|help] [config_file]

Commands:
  check   Run one VPN health-check cycle (default)
  setup   Configure the WireGuard interface and firewall if needed
  rotate  Download a fresh server list and switch server
  refresh_countries  Refresh the cached NordVPN country list if needed
  refresh_countries_force  Force-refresh the cached NordVPN country list
  public_ip  Print the current public IP as seen from the router
  public_country  Print the detected country code for the current public IP
  run     Backward-compatible alias for check
  help    Show this message

If config_file is omitted, $DEFAULT_CONFIG_FILE is used when present.
EOF
}

lock_contention_is_nonfatal () {
  case "$ACTION" in
    run|check|refresh_countries)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
  log 'Validating required system commands'
  for cmd in awk curl ifdown ifup ip jq ping uci; do
    command -v "$cmd" >/dev/null 2>&1 || {
      log "$cmd IS MISSING, PLEASE INSTALL"
      return 1
    }
  done
  log 'Required system commands are available'
}

release_lock () {
  [ "$LOCK_ACQUIRED" -eq 1 ] || return 0
  rm -rf "$LOCK_DIR"
  LOCK_ACQUIRED=0
  log "Released execution lock at $LOCK_DIR"
}

acquire_lock () {
  LOCK_PID_FILE="$LOCK_DIR/pid"
  LOCK_ACTION_FILE="$LOCK_DIR/action"

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    printf '%s\n' "$ACTION" > "$LOCK_ACTION_FILE"
    LOCK_ACQUIRED=1
    trap 'release_lock' EXIT HUP INT TERM
    log "Acquired execution lock at $LOCK_DIR"
    return 0
  fi

  if [ -f "$LOCK_PID_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
      log "Execution lock is already held by PID $LOCK_PID"
      return 2
    fi
  fi

  # This stale-lock recovery has a small rm/mkdir race, but that is acceptable here:
  # release_lock() owns the whole directory via LOCK_PID_FILE, and concurrent cron/hotplug
  # attempts are designed to fail acquire_lock() and exit successfully instead of surfacing an error.
  log "Recovering stale execution lock at $LOCK_DIR"
  rm -rf "$LOCK_DIR" 2>/dev/null || return 1

  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_PID_FILE"
  printf '%s\n' "$ACTION" > "$LOCK_ACTION_FILE"
  LOCK_ACQUIRED=1
  trap 'release_lock' EXIT HUP INT TERM
  log "Recovered and acquired execution lock at $LOCK_DIR"
}

vpn_is_configured () {
  [ "$(uci -q get "network.${VPN_IF}.proto" 2>/dev/null)" = 'wireguard' ]
}

vpn_link_is_present () {
  ip link show dev "$VPN_IF" >/dev/null 2>&1
}

log_vpn_interface_state () {
  STATE_CONTEXT="$1"
  VPN_PROTO=$(uci -q get "network.${VPN_IF}.proto" 2>/dev/null)
  VPN_DISABLED=$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)
  VPN_ENDPOINT=$(uci -q get "network.${VPN_IF}server.endpoint_host" 2>/dev/null)
  VPN_LINK_PRESENT='no'

  ip link show dev "$VPN_IF" >/dev/null 2>&1 && VPN_LINK_PRESENT='yes'

  log "Interface state [$STATE_CONTEXT]: proto=${VPN_PROTO:-absent}, disabled=${VPN_DISABLED:-0}, link_present=$VPN_LINK_PRESENT, endpoint=${VPN_ENDPOINT:-none}"
}

recover_missing_vpn_interface () {
  log "VPN interface $VPN_IF is still not present after ${VPN_INTERFACE_PRESENT_DELAY}s - starting recovery sequence"
  log_vpn_interface_state 'missing-interface-start'

  log "Recovery step 1/3: cycling interface $VPN_IF with ifdown/ifup"
  ifdown "$VPN_IF" >/dev/null 2>&1 || true
  ifup "$VPN_IF" >/dev/null 2>&1 || true
  sleep "$VPN_INTERFACE_PRESENT_DELAY"

  if vpn_link_is_present; then
    log "Recovery step 1/3 succeeded: interface $VPN_IF is present again"
    log_vpn_interface_state 'missing-interface-after-ifup'
    return 0
  fi

  log "Recovery step 2/3: reloading network service because $VPN_IF is still not present"
  /etc/init.d/network reload || {
    log 'ERROR: NETWORK RELOAD FAILED DURING MISSING INTERFACE RECOVERY'
    return 1
  }
  sleep "$VPN_INTERFACE_PRESENT_DELAY"

  if vpn_link_is_present; then
    log "Recovery step 2/3 succeeded: interface $VPN_IF is present again"
    log_vpn_interface_state 'missing-interface-after-reload'
    return 0
  fi

  log "Recovery step 3/3: restarting network service because $VPN_IF is still not present"
  /etc/init.d/network restart || {
    log 'ERROR: NETWORK RESTART FAILED DURING MISSING INTERFACE RECOVERY'
    return 1
  }
  sleep "$VPN_INTERFACE_PRESENT_DELAY"

  if vpn_link_is_present; then
    log "Recovery step 3/3 succeeded: interface $VPN_IF is present again"
    log_vpn_interface_state 'missing-interface-after-restart'
    return 0
  fi

  log "ERROR: VPN interface $VPN_IF is still not present after the full recovery sequence"
  log_vpn_interface_state 'missing-interface-final'
  return 1
}

ensure_vpn_interface_present () {
  if vpn_link_is_present; then
    return 0
  fi

  log "VPN interface $VPN_IF is not present, waiting ${VPN_INTERFACE_PRESENT_DELAY}s before recovery"
  log_vpn_interface_state 'missing-interface-before-wait'
  sleep "$VPN_INTERFACE_PRESENT_DELAY"

  if vpn_link_is_present; then
    log "VPN interface $VPN_IF became present during the wait window"
    log_vpn_interface_state 'missing-interface-after-wait'
    return 0
  fi

  recover_missing_vpn_interface
}

ensure_vpn_interface_enabled () {
  [ "$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)" = '1' ] || return 0

  log "Re-enabling disabled VPN interface $VPN_IF"
  log_vpn_interface_state 'before-enable'
  uci -q delete "network.${VPN_IF}.disabled"
  uci commit network || {
    log "ERROR: COULD NOT COMMIT NETWORK CONFIGURATION WHILE ENABLING $VPN_IF"
    return 1
  }

  /etc/init.d/network reload || {
    log "ERROR: NETWORK RELOAD FAILED WHILE ENABLING $VPN_IF"
    return 1
  }

  ifup "$VPN_IF" || {
    log "ERROR: IFUP FAILED WHILE ENABLING $VPN_IF"
    return 1
  }

  log "VPN interface $VPN_IF has been re-enabled"
  log_vpn_interface_state 'after-enable'
}

pick_ping_ip () {
  eval "printf '%s\n' \"\$IP$(awk 'BEGIN { srand(); print int((rand()*10000000)) % 20 }')\""
}

ping_interface () {
  [ -n "$1" ] || return 1
  ping -q -c 1 -W 5 "$(pick_ping_ip)" -I "$1" >/dev/null 2>&1
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
  local curl_out curl_rc valid_ip_check

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

  country_raw=$(printf '%s' "$curl_raw" | jq -er '.country // empty' 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$country_raw" ]; then
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
  [ -n "$RESOLVED_COUNTRY_ID" ] && return 0
  [ -z "$VPN_COUNTRY" ] && return 0

  refresh_countries_cache || {
    log 'ERROR: COULD NOT RETRIEVE COUNTRY LIST'
    return 1
  }

  COUNTRY_MATCH=$(jq -er --arg query "$VPN_COUNTRY" '
    [ .[] | select(
      ((.id | tostring) == $query) or
      ((.code // "" | ascii_downcase) == ($query | ascii_downcase)) or
      ((.name // "" | ascii_downcase) == ($query | ascii_downcase))
    ) ][0] | [.id, .name, .code] | @tsv
  ' "$COUNTRIES_CACHE_FILE" 2>/dev/null) || {
    log "ERROR: COUNTRY '$VPN_COUNTRY' NOT FOUND"
    return 1
  }

  IFS="$(printf '\t')" read -r RESOLVED_COUNTRY_ID RESOLVED_COUNTRY_NAME RESOLVED_COUNTRY_CODE <<EOF
$COUNTRY_MATCH
EOF

  [ -n "$RESOLVED_COUNTRY_ID" ] || {
    log "ERROR: COUNTRY '$VPN_COUNTRY' NOT FOUND"
    return 1
  }

  log "Filtering VPN servers by country: $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
}

build_server_recommendations_url () {
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

get_servers_list () {
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

resolve_wan_device () {
  WAN_DEVICE=''

  if command -v ubus >/dev/null 2>&1; then
    WAN_DEVICE=$(ubus call "network.interface.${WAN_IF}" status 2>/dev/null | jq -er '.l3_device // .device // empty' 2>/dev/null)
    [ -n "$WAN_DEVICE" ] && return 0
  fi

  WAN_DEVICE=$(uci -q get "network.${WAN_IF}.device" 2>/dev/null)
  [ -n "$WAN_DEVICE" ] && return 0

  WAN_DEVICE=$(uci -q get "network.${WAN_IF}.ifname" 2>/dev/null)
  [ -n "$WAN_DEVICE" ] && return 0

  if ip link show dev "$WAN_IF" >/dev/null 2>&1; then
    WAN_DEVICE="$WAN_IF"
    return 0
  fi

  log "ERROR: COULD NOT RESOLVE DEVICE FOR $WAN_IF"
  return 1
}

ping_wan () {
  resolve_wan_device || return 1
  ping_interface "$WAN_DEVICE"
}

find_firewall_zone_section () {
  TARGET_NETWORK="$1"

  for FIREWALL_SECTION in $(uci show firewall | awk -F= '$2=="zone"{ print $1 }'); do
    ZONE_NETWORKS=$(uci -q get "${FIREWALL_SECTION}.network" 2>/dev/null)

    for ZONE_NETWORK in $ZONE_NETWORKS; do
      [ "$ZONE_NETWORK" = "$TARGET_NETWORK" ] && {
        printf '%s\n' "$FIREWALL_SECTION"
        return 0
      }
    done
  done

  return 1
}

ensure_vpn_in_wan_zone () {
  WAN_ZONE=$(find_firewall_zone_section "$WAN_IF") || {
    log "ERROR: FIREWALL ZONE FOR $WAN_IF NOT FOUND"
    return 1
  }

  FIREWALL_CHANGED=0

  for FIREWALL_SECTION in $(uci show firewall | awk -F= '$2=="zone"{ print $1 }'); do
    [ "$FIREWALL_SECTION" = "$WAN_ZONE" ] && continue

    ZONE_NETWORKS=$(uci -q get "${FIREWALL_SECTION}.network" 2>/dev/null)
    for ZONE_NETWORK in $ZONE_NETWORKS; do
      [ "$ZONE_NETWORK" = "$VPN_IF" ] || continue
      uci -q del_list "${FIREWALL_SECTION}.network"="$VPN_IF"
      FIREWALL_CHANGED=1
      break
    done
  done

  ZONE_HAS_VPN=0
  ZONE_NETWORKS=$(uci -q get "${WAN_ZONE}.network" 2>/dev/null)

  for ZONE_NETWORK in $ZONE_NETWORKS; do
    [ "$ZONE_NETWORK" = "$VPN_IF" ] && {
      ZONE_HAS_VPN=1
      break
    }
  done

  if [ "$ZONE_HAS_VPN" -ne 1 ]; then
    uci add_list "${WAN_ZONE}.network"="$VPN_IF"
    FIREWALL_CHANGED=1
  fi

  if [ "$FIREWALL_CHANGED" -ne 1 ]; then
    log "Firewall zone for $WAN_IF already contains $VPN_IF"
    return 0
  fi

  uci commit firewall || {
    log 'ERROR: COULD NOT COMMIT FIREWALL CONFIGURATION'
    return 1
  }

  /etc/init.d/firewall restart || {
    log 'ERROR: FIREWALL RESTART FAILED'
    return 1
  }

  log "Firewall updated so zone for $WAN_IF includes $VPN_IF"
}

set_vpn_server_in_uci () {
  [ -n "$2" ] || {
    log 'ERROR: VPN SERVER IP IS EMPTY'
    return 1
  }
  [ -n "$3" ] || {
    log "ERROR: VPN PUBLIC KEY IS EMPTY FOR $1"
    return 1
  }

  uci set "network.${VPN_IF}server.description"="$1"
  uci set "network.${VPN_IF}server.endpoint_host"="$2"
  uci set "network.${VPN_IF}server.public_key"="$3"
  log "Prepared VPN peer update for server $1 ($2)"
}

set_first_server_from_list () {
  FIRST_SERVER=$(jq -r '.[0] | [.hostname, .station, ([.technologies[]?.metadata[]? | select(.name=="public_key").value][0])] | @tsv' "$SERVER_LIST_FILE" 2>/dev/null) || {
    log 'ERROR: INVALID VPN SERVER LIST'
    return 1
  }

  [ -n "$FIRST_SERVER" ] || {
    log 'ERROR: VPN SERVER LIST IS EMPTY'
    return 1
  }

  IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY <<EOF
$FIRST_SERVER
EOF

  log "Selected first recommended VPN server $HOST_NAME ($SERVER_IP)"
  set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY"
}

current_server_matches_recommendations () {
  CURRENT_SERVER=$(uci -q get "network.${VPN_IF}server.endpoint_host" 2>/dev/null)

  [ -n "$CURRENT_SERVER" ] || return 1

  jq -e --arg current "$CURRENT_SERVER" '
    [ .[] | select(.station == $current) ] | length > 0
  ' "$SERVER_LIST_FILE" >/dev/null 2>&1
}

sync_server_selection () {
  vpn_is_configured || return 0
  get_servers_list || return 1

  if current_server_matches_recommendations; then
    log 'Current VPN server already matches the selected country/filter'
    return 0
  fi

  log 'Current VPN server does not match the selected country/filter, changing server'
  change_vpn_server reload
}

change_vpn_server () {
  CURRENT_SERVER=$(uci -q get "network.${VPN_IF}server.endpoint_host" 2>/dev/null)
  SERVER_CANDIDATES_FILE="/tmp/nordvpn.candidates.$$"

  log "Starting VPN server rotation from current endpoint ${CURRENT_SERVER:-none}"

  jq -r '.[] | [.hostname, .station, ([.technologies[]?.metadata[]? | select(.name=="public_key").value][0])] | @tsv' "$SERVER_LIST_FILE" > "$SERVER_CANDIDATES_FILE" 2>/dev/null || {
    rm -f "$SERVER_CANDIDATES_FILE"
    log 'ERROR: INVALID VPN SERVER LIST'
    return 1
  }

  while IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY; do
    [ -n "$SERVER_IP" ] || continue
    [ "$CURRENT_SERVER" = "$SERVER_IP" ] && continue

    log "Trying VPN server candidate $HOST_NAME ($SERVER_IP)"

    set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY" || continue
    uci commit network || {
      rm -f "$SERVER_CANDIDATES_FILE"
      log 'ERROR: COULD NOT COMMIT NETWORK CONFIGURATION'
      return 1
    }

    log "VPN server changed to $HOST_NAME ( $SERVER_IP )"

    if [ "$1" = 'reload' ]; then
      log "Cycling VPN interface $VPN_IF to apply the new peer configuration"
      ifdown "$VPN_IF" >/dev/null 2>&1 || true
      sleep "$INTERFACE_RESTART_DELAY"
      ifup "$VPN_IF" || {
        rm -f "$SERVER_CANDIDATES_FILE"
        log "ERROR: IFUP FAILED AFTER CHANGING VPN SERVER ON $VPN_IF"
        return 1
      }
      log "Waiting ${POST_RESTART_DELAY}s after cycling $VPN_IF before validating VPN connectivity"
    else
      /etc/init.d/network restart || {
        rm -f "$SERVER_CANDIDATES_FILE"
        log 'ERROR: NETWORK RESTART FAILED'
        return 1
      }
      log "Waiting ${POST_RESTART_DELAY}s after network restart before validating VPN connectivity"
    fi

    sleep "$POST_RESTART_DELAY"

    if ping_interface "$VPN_IF"; then
      rm -f "$SERVER_CANDIDATES_FILE"
      log 'VPN connection restored'
      verify_public_country_selection
      return 0
    fi

    log 'VPN connection is not OK, trying another server...'
  done < "$SERVER_CANDIDATES_FILE"

  rm -f "$SERVER_CANDIDATES_FILE"
  log 'NO RECOMMENDED VPN SERVER RESTORED CONNECTIVITY'
  return 1
}

configure_vpn_interface () {
  log "$VPN_IF NOT CONFIGURED - IT WILL BE CREATED"
  log "Creating WireGuard interface $VPN_IF with address $VPN_ADDR and endpoint port $VPN_PORT"
  log_vpn_interface_state 'before-create'

  get_private_key || return 1
  get_servers_list || return 1
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

  set_first_server_from_list || return 1

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

bootstrap_if_needed () {
  log "Bootstrapping VPN state for interface $VPN_IF"
  log_vpn_interface_state 'bootstrap-start'
  refresh_countries_cache || true
  resolve_country_filter || return 1

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

rotate_action () {
  log 'Rotate action started'
  bootstrap_if_needed || return 1
  get_servers_list || return 1
  log 'Changing VPN server'
  change_vpn_server reload
}

check_once () {
  # shellcheck disable=SC3043 # OpenWrt /bin/sh is BusyBox ash, which supports local.
  local failed_pings=0
  local restart_count=0
  local max_interface_restarts="${MAX_INTERFACE_RESTARTS:-3}"
  local retry_delay
  local backoff_steps

  log "Starting VPN health-check on interface $VPN_IF"
  [ -f "$SERVER_LIST_FILE" ] || get_servers_list || true

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

      if get_servers_list; then
        log 'Changing VPN server'
        change_vpn_server restart && return 0
      else
        log 'Refreshing VPN server list failed'
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

ACTION='check'

if [ $# -gt 0 ]; then
  case "$1" in
    check|setup|rotate|refresh_countries|refresh_countries_force|public_ip|public_country|run|help)
      ACTION="$1"
      shift
      ;;
  esac
fi

if [ $# -gt 0 ]; then
  CONFIG_PATH="$1"
  CONFIG_PATH_REQUIRED=1
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
  *)
    usage
    exit 1
    ;;
esac
