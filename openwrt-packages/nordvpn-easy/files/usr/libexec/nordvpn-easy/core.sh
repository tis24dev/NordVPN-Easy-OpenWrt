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

SERVER_LIST_FILE='/tmp/nordvpn.json'
COUNTRIES_CACHE_FILE='/tmp/nordvpn-easy-countries.json'
COUNTRIES_CACHE_TS_FILE='/tmp/nordvpn-easy-countries.timestamp'
COUNTRIES_CACHE_TTL="${COUNTRIES_CACHE_TTL:-86400}"
NORDVPN_API='https://api.nordvpn.com/v1'
COUNTRIES_URL="${NORDVPN_API}/servers/countries"
SERVER_RECOMMENDATIONS_URL_BASE="${NORDVPN_API}/servers/recommendations?filters\\[servers_technologies\\]\\[identifier\\]=wireguard_udp&limit=10"
CREDENTIALS_URL="${NORDVPN_API}/users/services/credentials"
DEFAULT_CONFIG_FILE='/var/etc/nordvpn-easy.conf'
LOCK_DIR='/tmp/nordvpn-easy.lock'
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_NAME=''
RESOLVED_COUNTRY_CODE=''
CONFIG_PATH=''
CONFIG_PATH_REQUIRED=0
LOCK_ACQUIRED=0

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
  printf '*** %s ***\n' "$*"
}

usage () {
  cat <<EOF
Usage: $0 [check|setup|rotate|refresh_countries|refresh_countries_force|public_ip|run|help] [config_file]

Commands:
  check   Run one VPN health-check cycle (default)
  setup   Configure the WireGuard interface and firewall if needed
  rotate  Download a fresh server list and switch server
  refresh_countries  Refresh the cached NordVPN country list if needed
  refresh_countries_force  Force-refresh the cached NordVPN country list
  public_ip  Print the current public IP as seen from the router
  run     Backward-compatible alias for check
  help    Show this message

If config_file is omitted, $DEFAULT_CONFIG_FILE is used when present.
EOF
}

load_config () {
  if [ -f "$CONFIG_PATH" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_PATH"
  elif [ "$CONFIG_PATH_REQUIRED" -eq 1 ]; then
    log "ERROR: CONFIG FILE $CONFIG_PATH NOT FOUND"
    return 1
  fi
}

require_commands () {
  for cmd in awk curl ifdown ifup ip jq ping uci; do
    command -v "$cmd" >/dev/null 2>&1 || {
      log "$cmd IS MISSING, PLEASE INSTALL"
      return 1
    }
  done
}

release_lock () {
  [ "$LOCK_ACQUIRED" -eq 1 ] || return 0
  rm -rf "$LOCK_DIR"
  LOCK_ACQUIRED=0
}

acquire_lock () {
  LOCK_PID_FILE="$LOCK_DIR/pid"

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    LOCK_ACQUIRED=1
    trap 'release_lock' EXIT HUP INT TERM
    return 0
  fi

  if [ -f "$LOCK_PID_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_PID_FILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
      return 1
    fi
  fi

  # This stale-lock recovery has a small rm/mkdir race, but that is acceptable here:
  # release_lock() owns the whole directory via LOCK_PID_FILE, and concurrent cron/hotplug
  # attempts are designed to fail acquire_lock() and exit successfully instead of surfacing an error.
  rm -rf "$LOCK_DIR" 2>/dev/null || return 1

  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_PID_FILE"
  LOCK_ACQUIRED=1
  trap 'release_lock' EXIT HUP INT TERM
}

vpn_is_configured () {
  [ "$(uci -q get "network.${VPN_IF}.proto" 2>/dev/null)" = 'wireguard' ]
}

ensure_vpn_interface_enabled () {
  [ "$(uci -q get "network.${VPN_IF}.disabled" 2>/dev/null)" = '1' ] || return 0

  uci -q delete "network.${VPN_IF}.disabled"
  uci commit network || {
    log "ERROR: COULD NOT COMMIT NETWORK CONFIGURATION WHILE ENABLING $VPN_IF"
    return 1
  }

  /etc/init.d/network reload || {
    log "ERROR: NETWORK RELOAD FAILED WHILE ENABLING $VPN_IF"
    return 1
  }
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
    return 0
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
}

valid_public_ip () {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:]+$'
}

get_public_ip () {
  for PUBLIC_IP_URL in \
    'https://api.ipify.org' \
    'https://api64.ipify.org' \
    'https://ipv4.icanhazip.com' \
    'https://ifconfig.me/ip'
  do
    PUBLIC_IP=$(curl -fsS --connect-timeout 3 --max-time 5 "$PUBLIC_IP_URL" 2>/dev/null | tr -d '\r\n')

    if [ -n "$PUBLIC_IP" ] && valid_public_ip "$PUBLIC_IP"; then
      printf '%s\n' "$PUBLIC_IP"
      return 0
    fi
  done

  log 'ERROR: COULD NOT RETRIEVE PUBLIC IP'
  return 1
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
    SERVER_RECOMMENDATIONS_URL="${SERVER_RECOMMENDATIONS_URL}&filters\\[country_id\\]=$RESOLVED_COUNTRY_ID"
  fi

  printf '%s\n' "$SERVER_RECOMMENDATIONS_URL"
}

get_servers_list () {
  SERVER_LIST_TMP="${SERVER_LIST_FILE}.tmp.$$"
  SERVER_RECOMMENDATIONS_URL=$(build_server_recommendations_url) || return 1

  curl -fsS --connect-timeout 15 --max-time 30 -o "$SERVER_LIST_TMP" "$SERVER_RECOMMENDATIONS_URL" || {
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

  [ "$FIREWALL_CHANGED" -eq 1 ] || return 0

  uci commit firewall || {
    log 'ERROR: COULD NOT COMMIT FIREWALL CONFIGURATION'
    return 1
  }

  /etc/init.d/firewall restart || {
    log 'ERROR: FIREWALL RESTART FAILED'
    return 1
  }
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

  jq -r '.[] | [.hostname, .station, ([.technologies[]?.metadata[]? | select(.name=="public_key").value][0])] | @tsv' "$SERVER_LIST_FILE" > "$SERVER_CANDIDATES_FILE" 2>/dev/null || {
    rm -f "$SERVER_CANDIDATES_FILE"
    log 'ERROR: INVALID VPN SERVER LIST'
    return 1
  }

  while IFS="$(printf '\t')" read -r HOST_NAME SERVER_IP PUBLIC_KEY; do
    [ -n "$SERVER_IP" ] || continue
    [ "$CURRENT_SERVER" = "$SERVER_IP" ] && continue

    set_vpn_server_in_uci "$HOST_NAME" "$SERVER_IP" "$PUBLIC_KEY" || continue
    uci commit network || {
      rm -f "$SERVER_CANDIDATES_FILE"
      log 'ERROR: COULD NOT COMMIT NETWORK CONFIGURATION'
      return 1
    }

    log "VPN server changed to $HOST_NAME ( $SERVER_IP )"

    if [ "$1" = 'reload' ]; then
      /etc/init.d/network reload || {
        rm -f "$SERVER_CANDIDATES_FILE"
        log 'ERROR: NETWORK RELOAD FAILED'
        return 1
      }
    else
      /etc/init.d/network restart || {
        rm -f "$SERVER_CANDIDATES_FILE"
        log 'ERROR: NETWORK RESTART FAILED'
        return 1
      }
    fi

    sleep "$POST_RESTART_DELAY"

    if ping_interface "$VPN_IF"; then
      rm -f "$SERVER_CANDIDATES_FILE"
      log 'VPN connection restored'
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
}

bootstrap_if_needed () {
  refresh_countries_cache || true
  resolve_country_filter || return 1

  if ! vpn_is_configured; then
    configure_vpn_interface || return 1
  else
    ensure_vpn_interface_enabled || return 1
  fi

  ensure_vpn_in_wan_zone || return 1
}

rotate_action () {
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

  [ -f "$SERVER_LIST_FILE" ] || get_servers_list || true

  while ! ping_interface "$VPN_IF"; do
    failed_pings=$((failed_pings+1))
    retry_delay="$FAILURE_RETRY_DELAY"
    ping_wan || return 0

    if [ "$failed_pings" -gt "$INTERFACE_RESTART_THRESHOLD" ]; then
      if [ "$restart_count" -ge "$max_interface_restarts" ]; then
        log "PING FAILED $failed_pings TIMES - RESTART LIMIT REACHED FOR $VPN_IF ($restart_count/$max_interface_restarts)"
        return 1
      fi

      restart_count=$((restart_count+1))
      log "PING FAILED $failed_pings TIMES - RESTARTING $VPN_IF ($restart_count/$max_interface_restarts)"
      ifdown "$VPN_IF"
      sleep "$INTERFACE_RESTART_DELAY"
      ifup "$VPN_IF"
      sleep "$POST_RESTART_DELAY"
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
}

ACTION='check'

if [ $# -gt 0 ]; then
  case "$1" in
    check|setup|rotate|refresh_countries|refresh_countries_force|public_ip|run|help)
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

require_commands || exit 1

# Intentionally exit 0 on lock contention so cron/hotplug do not log an error when another instance already holds the lock.
acquire_lock || exit 0

case "$ACTION" in
  run|check)
    bootstrap_if_needed && check_once
    ;;
  setup)
    bootstrap_if_needed && sync_server_selection && log 'NordVPN configuration is ready'
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
