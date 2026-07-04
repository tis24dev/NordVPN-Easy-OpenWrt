#!/bin/sh
# shellcheck disable=SC2317
# core.sh exports compatibility and orchestration helpers consumed indirectly by
# sourced lib/*.sh modules. Recent shellcheck versions flag these helpers as
# unreachable even though they are valid entrypoints for the sourced modules.

# Use NORDVPN_TOKEN with the token you get from https://my.nordaccount.com/dashboard/nordvpn/access-tokens/

LIB_DIR="${NORDVPN_EASY_LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"
CONFIG_CONTEXT_LIB="${LIB_DIR}/config-context.sh"
CATALOG_LIB="${LIB_DIR}/catalog.sh"
RUNTIME_LIB="${LIB_DIR}/runtime.sh"
WIREGUARD_LIB="${LIB_DIR}/wireguard.sh"
DIAGNOSTICS_LIB="${LIB_DIR}/diagnostics.sh"
ACTIONS_LIB="${LIB_DIR}/actions.sh"

VPN_INTERFACE_PRESENT_DELAY="${VPN_INTERFACE_PRESENT_DELAY:-10}"

# Sourced runtime libraries read these globals after core.sh initializes them.
# shellcheck disable=SC2034
SERVER_LIST_FILE='/tmp/nordvpn.json'
COUNTRIES_CACHE_FILE='/tmp/nordvpn-easy-countries.json'
COUNTRIES_CACHE_TS_FILE='/tmp/nordvpn-easy-countries.timestamp'
SERVER_CATALOG_FILE='/tmp/nordvpn-easy-servers.json'
SERVER_CATALOG_TS_FILE='/tmp/nordvpn-easy-servers.timestamp'
COUNTRIES_CACHE_TTL="${COUNTRIES_CACHE_TTL:-86400}"
NORDVPN_API='https://api.nordvpn.com/v1'
COUNTRIES_URL="${NORDVPN_API}/servers/countries"
# Consumed by the lazily sourced public-ip library.
# shellcheck disable=SC2034
PUBLIC_COUNTRY_API='https://api.country.is'   # Third-party API, no auth required; returns JSON like {"country":"XX"} with an ISO country code.
# shellcheck disable=SC2034
SERVER_RECOMMENDATIONS_URL_BASE="${NORDVPN_API}/servers/recommendations?filters[servers_technologies][identifier]=wireguard_udp&limit=10"
SERVER_CATALOG_URL_BASE="${NORDVPN_API}/servers?filters[servers_technologies][identifier]=wireguard_udp&limit=5000"
CREDENTIALS_URL="${NORDVPN_API}/users/services/credentials"
LOCK_DIR='/tmp/nordvpn-easy.lock'
NORDVPN_EASY_RC_BUSY="${NORDVPN_EASY_RC_BUSY:-75}"
NORDVPN_EASY_RC_RUNTIME_DRIFT="${NORDVPN_EASY_RC_RUNTIME_DRIFT:-2}"
RESOLVED_COUNTRY_ID=''
RESOLVED_COUNTRY_NAME=''
RESOLVED_COUNTRY_CODE=''
RESOLVED_COUNTRY_QUERY=''
CONFIG_PATH=''
CONFIG_PATH_REQUIRED=0
# shellcheck disable=SC2034
LOCK_ACQUIRED=0
SERVER_CATALOG_QUERY=''
SERVER_CATALOG_FORCE='0'
# Consumed by the lazily sourced public-ip library.
# shellcheck disable=SC2034
PUBLIC_LOOKUP_LOG_MODE='verbose'
CORE_QUIET_ACTION=0
CORE_BACKEND_PAYLOAD_SIGNATURE='render-contract-v3'

NORDVPN_EASY_RUN_DIR="${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}"
NORDVPN_EASY_STATUS_CACHE="${NORDVPN_EASY_STATUS_CACHE:-$NORDVPN_EASY_RUN_DIR/status.json}"
NORDVPN_EASY_PUBLIC_IP_CACHE="${NORDVPN_EASY_PUBLIC_IP_CACHE:-$NORDVPN_EASY_RUN_DIR/public_ip}"
NORDVPN_EASY_PUBLIC_COUNTRY_CACHE="${NORDVPN_EASY_PUBLIC_COUNTRY_CACHE:-$NORDVPN_EASY_RUN_DIR/public_country}"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="${NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE:-$NORDVPN_EASY_RUN_DIR/public_verification}"
NORDVPN_EASY_LAST_ERROR_CACHE="${NORDVPN_EASY_LAST_ERROR_CACHE:-$NORDVPN_EASY_RUN_DIR/last_error}"

core_source_files() {
  local core_lib

  for core_lib in "$@"; do
    # shellcheck disable=SC1090
    . "$core_lib" || return 1
  done
}

core_source_libs_for_action() {
  # config-context.sh sources schema.sh, service-config.sh, and common.sh.
  core_source_files "$CONFIG_CONTEXT_LIB" || return 1

  case "$1" in
    stop_vpn)
      core_source_files "$RUNTIME_LIB" "$WIREGUARD_LIB" "$ACTIONS_LIB"
      ;;
    operation_status|vpn_status|status_json)
      # runtime.sh's vpn_status path calls nordvpn_easy_wg_handshake_epoch, which
      # is defined in wireguard.sh; load it so status does not fail "not found".
      core_source_files "$RUNTIME_LIB" "$WIREGUARD_LIB"
      ;;
    public_ip)
      core_source_files "$RUNTIME_LIB" "${LIB_DIR}/public-ip.sh"
      ;;
    diagnostics_log|diagnostics_summary)
      core_source_files "$RUNTIME_LIB" "$WIREGUARD_LIB" "$DIAGNOSTICS_LIB"
      ;;
    refresh_countries|refresh_countries_force|server_catalog)
      core_source_files "$CATALOG_LIB" "$RUNTIME_LIB"
      ;;
    *)
      core_source_files \
        "$CATALOG_LIB" \
        "$RUNTIME_LIB" \
        "${LIB_DIR}/public-ip.sh" \
        "$WIREGUARD_LIB" \
        "$DIAGNOSTICS_LIB" \
        "$ACTIONS_LIB"
      ;;
  esac
}

log () {
  nordvpn_easy_log_phase "${LOG_PHASE:-runtime}" "$@"
}

backend_payload_summary () {
  local lib_payload='unavailable'
  local payload_match='0'

  lib_payload="$(nordvpn_easy_backend_payload_signature 2>/dev/null || printf '%s' 'unavailable')"
  [ "$CORE_BACKEND_PAYLOAD_SIGNATURE" = "$lib_payload" ] && payload_match='1'

  printf '%s' "core_payload=${CORE_BACKEND_PAYLOAD_SIGNATURE}, lib_payload=${lib_payload}, payload_match=${payload_match}"
}

curl_rc_meaning () {
  nordvpn_easy_curl_rc_meaning "$@"
}

usage () {
  cat <<EOF
Usage: $0 [check|stop_vpn|reconnect|reconcile|setup|rotate|refresh_countries|refresh_countries_force|server_catalog|public_ip|operation_status|vpn_status|status_json|diagnostics_log|diagnostics_summary|run|help] [--config config_file] [extra_args]

Commands:
  check   Run one VPN health-check cycle (default)
  stop_vpn  Stop the VPN interface, clear server caches, and remove WireGuard runtime config
  reconnect  Compatibility alias for stop_vpn followed by setup (prefer stop_vpn + connect)
  reconcile  Synchronize runtime state with the selected server configuration
  setup   Configure the WireGuard interface and firewall if needed
  rotate  Download a fresh server list and switch server
  refresh_countries  Refresh the cached NordVPN country list if needed
  refresh_countries_force  Force-refresh the cached NordVPN country list
  server_catalog [country_query] [force]
          Print the cached or refreshed NordVPN WireGuard server catalog JSON
  public_ip  Check the current public IP, update runtime caches on change, and print a JSON snapshot
  operation_status  Print whether a NordVPN Easy operation is running
  vpn_status  Print VPN runtime status (active|inactive|starting|stopping|error)
  status_json  Print runtime status as JSON
  diagnostics_log  Print filtered NordVPN Easy log output
  diagnostics_summary  Print structured diagnostics summary as JSON
  run     Backward-compatible alias for check
  help    Show this message

If --config is omitted, runtime context is loaded directly from UCI.
EOF
}

lock_contention_is_nonfatal () {
  nordvpn_easy_lock_contention_is_nonfatal "$@"
}

validate_setup_runtime () {
  MISSING_FIELDS=''

  [ -n "$NORDVPN_TOKEN" ] || MISSING_FIELDS="${MISSING_FIELDS} NORDVPN_TOKEN"
  [ -n "$WAN_IF" ] || MISSING_FIELDS="${MISSING_FIELDS} WAN_IF"
  [ -n "$VPN_IF" ] || MISSING_FIELDS="${MISSING_FIELDS} VPN_IF"
  [ -n "$VPN_ADDR" ] || MISSING_FIELDS="${MISSING_FIELDS} VPN_ADDR"
  [ -n "$VPN_PORT" ] || MISSING_FIELDS="${MISSING_FIELDS} VPN_PORT"

  if [ -n "$MISSING_FIELDS" ]; then
    if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "setup prerequisites missing:${MISSING_FIELDS} ($(nordvpn_easy_runtime_env_debug_summary); $(nordvpn_easy_runtime_file_debug_summary "$CONFIG_PATH"))"
    else
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "setup prerequisites missing:${MISSING_FIELDS} ($(nordvpn_easy_runtime_env_debug_summary))"
    fi
    return 1
  fi

  if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    log "Setup/runtime prerequisites verified ($(nordvpn_easy_runtime_env_debug_summary); $(nordvpn_easy_runtime_file_debug_summary "$CONFIG_PATH"))"
  else
    log "Setup/runtime prerequisites verified ($(nordvpn_easy_runtime_env_debug_summary))"
  fi

  if [ -n "$NORDVPN_TOKEN" ] && ! nordvpn_easy_token_shape_is_canonical "$NORDVPN_TOKEN"; then
    log "WARNING: NORDVPN_TOKEN does not look like a 64-character access token (len=${#NORDVPN_TOKEN}); if apply fails with an auth error, regenerate it at my.nordaccount.com"
  fi

  return 0
}

validate_stop_runtime () {
  MISSING_FIELDS=''

  [ -n "$WAN_IF" ] || MISSING_FIELDS="${MISSING_FIELDS} WAN_IF"
  [ -n "$VPN_IF" ] || MISSING_FIELDS="${MISSING_FIELDS} VPN_IF"

  if [ -n "$MISSING_FIELDS" ]; then
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "stop prerequisites missing:${MISSING_FIELDS}"
    return 1
  fi

  log "Stop/runtime prerequisites verified (wan_if=${WAN_IF:-unset}, vpn_if=${VPN_IF:-unset}, interface_restart_delay=${INTERFACE_RESTART_DELAY:-10})"
}

load_stop_config () {
  local uci_config='nordvpn_easy'
  local uci_section='main'
  local option raw_value normalized_value env_name

  if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    nordvpn_easy_load_runtime_context_from_file "$CONFIG_PATH" || {
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "failed to source runtime configuration from $CONFIG_PATH ($(backend_payload_summary))"
      return 1
    }
    [ "$CORE_QUIET_ACTION" -eq 1 ] || log "Loaded stop runtime configuration from $CONFIG_PATH (wan_if=${WAN_IF:-unset}, vpn_if=${VPN_IF:-unset}, interface_restart_delay=${INTERFACE_RESTART_DELAY:-10}; $(backend_payload_summary))"
    return 0
  elif [ "$CONFIG_PATH_REQUIRED" -eq 1 ]; then
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "required config file $CONFIG_PATH was not found ($(backend_payload_summary))"
    return 1
  fi

  for option in enabled wan_if vpn_if interface_restart_delay; do
    raw_value="$(nordvpn_easy_read_uci_option "$uci_config" "$uci_section" "$option")"
    normalized_value="$(nordvpn_easy_normalize_value "$option" "$raw_value")"
    if [ "$option" = 'enabled' ]; then
      nordvpn_easy_assign_shell_var 'DESIRED_ENABLED' "$normalized_value"
      nordvpn_easy_assign_shell_var 'ENABLED' "$normalized_value"
    else
      env_name="$(nordvpn_easy_env_name "$option")"
      nordvpn_easy_assign_shell_var "$env_name" "$normalized_value"
    fi
  done

  CONFIG_CONTEXT_SOURCE="uci:${uci_config}.${uci_section}:stop"
  [ "$CORE_QUIET_ACTION" -eq 1 ] || log "Loaded stop runtime configuration from ${CONFIG_CONTEXT_SOURCE} (wan_if=${WAN_IF:-unset}, vpn_if=${VPN_IF:-unset}, interface_restart_delay=${INTERFACE_RESTART_DELAY:-10}; $(backend_payload_summary))"
}

load_config () {
  if [ "$ACTION" = 'stop_vpn' ]; then
    load_stop_config
    return $?
  fi

  if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
    nordvpn_easy_load_runtime_context_from_file "$CONFIG_PATH" || {
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "failed to source runtime configuration from $CONFIG_PATH ($(backend_payload_summary))"
      return 1
    }
    [ "$CORE_QUIET_ACTION" -eq 1 ] || log "Loaded runtime configuration from $CONFIG_PATH ($(nordvpn_easy_runtime_env_debug_summary); $(nordvpn_easy_runtime_file_debug_summary "$CONFIG_PATH"); $(backend_payload_summary))"
  elif [ "$CONFIG_PATH_REQUIRED" -eq 1 ]; then
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "required config file $CONFIG_PATH was not found ($(backend_payload_summary))"
    return 1
  else
    nordvpn_easy_load_runtime_context_from_uci || {
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "failed to load runtime configuration from UCI ($(backend_payload_summary))"
      return 1
    }
    [ "$CORE_QUIET_ACTION" -eq 1 ] || log "Loaded runtime configuration from ${CONFIG_CONTEXT_SOURCE:-uci} ($(nordvpn_easy_runtime_env_debug_summary); $(backend_payload_summary))"
  fi
}

require_commands () {
  local previous_log_mode="${NORDVPN_EASY_REQUIRE_COMMANDS_LOG_MODE:-verbose}"
  [ "${CORE_QUIET_ACTION:-0}" -eq 1 ] && NORDVPN_EASY_REQUIRE_COMMANDS_LOG_MODE='quiet'
  nordvpn_easy_require_commands "$@"
  local rc=$?
  NORDVPN_EASY_REQUIRE_COMMANDS_LOG_MODE="$previous_log_mode"
  return "$rc"
}

require_stop_commands () {
  local cmd

  [ "${CORE_QUIET_ACTION:-0}" -eq 1 ] || log 'Validating required stop commands'
  for cmd in awk ifdown ip uci; do
    command -v "$cmd" >/dev/null 2>&1 || {
      nordvpn_easy_log_blocker 'runtime' "required command '$cmd' is missing"
      return 1
    }
  done
  [ "${CORE_QUIET_ACTION:-0}" -eq 1 ] || log 'Required stop commands are available'
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

current_server_country () {
  nordvpn_easy_current_server_country "$@"
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

pick_ping_ip () {
  # Keep this static: analyzer-friendly and no eval for a fixed probe list.
  case "$(awk 'BEGIN { srand(); print int(rand() * 20) }')" in
    0)  printf '%s\n' '8.8.8.8' ;;
    1)  printf '%s\n' '8.8.4.4' ;;
    2)  printf '%s\n' '1.1.1.1' ;;
    3)  printf '%s\n' '1.0.0.1' ;;
    4)  printf '%s\n' '208.67.222.222' ;;
    5)  printf '%s\n' '208.67.220.220' ;;
    6)  printf '%s\n' '9.9.9.9' ;;
    7)  printf '%s\n' '149.112.112.112' ;;
    8)  printf '%s\n' '195.46.39.39' ;;
    9)  printf '%s\n' '195.46.39.40' ;;
    10) printf '%s\n' '45.90.28.165' ;;
    11) printf '%s\n' '45.90.30.165' ;;
    12) printf '%s\n' '156.154.70.1' ;;
    13) printf '%s\n' '156.154.71.1' ;;
    14) printf '%s\n' '8.26.56.26' ;;
    15) printf '%s\n' '8.20.247.20' ;;
    16) printf '%s\n' '64.6.64.6' ;;
    17) printf '%s\n' '64.6.65.6' ;;
    18) printf '%s\n' '209.244.0.3' ;;
    *)  printf '%s\n' '209.244.0.4' ;;
  esac
}

ping_interface () {
  nordvpn_easy_ping_interface "$@"
}

curl_config_escape () {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/#/\\#/g'
}

fetch_credentials_json () {
  local credentials_temp_dir=''
  local credentials_body_file=''
  local credentials_stderr_file=''
  local credentials_http_file=''
  local credentials_curl_rc=0

  CREDENTIALS_JSON=''
  NORDVPN_EASY_CREDENTIALS_CURL_RC=''
  NORDVPN_EASY_CREDENTIALS_HTTP_CODE=''
  NORDVPN_EASY_CREDENTIALS_CURL_ERROR=''

  nordvpn_easy_mktemp_dir 'credentials' credentials_temp_dir || {
    NORDVPN_EASY_CREDENTIALS_CURL_RC='1'
    NORDVPN_EASY_CREDENTIALS_CURL_ERROR='could not create credentials request temp directory'
    return 1
  }
  credentials_body_file="$(nordvpn_easy_temp_file_path "$credentials_temp_dir" 'credentials.json')"
  credentials_stderr_file="$(nordvpn_easy_temp_file_path "$credentials_temp_dir" 'credentials.stderr')"
  credentials_http_file="$(nordvpn_easy_temp_file_path "$credentials_temp_dir" 'credentials.http')"

  {
    printf '%s\n' 'silent'
    printf '%s\n' 'show-error'
    printf '%s\n' 'fail'
    printf '%s\n' 'connect-timeout = 15'
    printf '%s\n' 'max-time = 30'
    printf 'url = "%s"\n' "$(curl_config_escape "$CREDENTIALS_URL")"

    printf 'user = "token:%s"\n' "$(curl_config_escape "$NORDVPN_TOKEN")"
  } | curl --config - -o "$credentials_body_file" -w '%{http_code}' > "$credentials_http_file" 2> "$credentials_stderr_file"
  credentials_curl_rc=$?

  NORDVPN_EASY_CREDENTIALS_CURL_RC="$credentials_curl_rc"
  NORDVPN_EASY_CREDENTIALS_HTTP_CODE="$(cat "$credentials_http_file" 2>/dev/null || printf '%s' '000')"
  [ -n "$NORDVPN_EASY_CREDENTIALS_HTTP_CODE" ] || NORDVPN_EASY_CREDENTIALS_HTTP_CODE='000'
  NORDVPN_EASY_CREDENTIALS_CURL_ERROR="$(
    sed -n '1,3p' "$credentials_stderr_file" 2>/dev/null |
      tr '\r\n' '  ' |
      nordvpn_easy_sanitize_diagnostics_stream
  )"

  if [ "$credentials_curl_rc" -ne 0 ]; then
    rm -rf -- "$credentials_temp_dir"
    return "$credentials_curl_rc"
  fi

  CREDENTIALS_JSON="$(cat "$credentials_body_file" 2>/dev/null)" || {
    rm -rf -- "$credentials_temp_dir"
    NORDVPN_EASY_CREDENTIALS_CURL_RC='1'
    NORDVPN_EASY_CREDENTIALS_CURL_ERROR='could not read credentials response body'
    return 1
  }

  rm -rf -- "$credentials_temp_dir"
}

get_private_key_error_message () {
  local rc="$1"
  local code="$2"

  # fetch_credentials_json uses rc=1 for LOCAL setup/read failures (the temp dir
  # or the response body), where the API was never actually unreachable -- do not
  # mislabel those as a network outage. The specific cause is carried separately
  # in the curl_error tail (NORDVPN_EASY_CREDENTIALS_CURL_ERROR).
  if [ "$rc" = '1' ]; then
    printf '%s' 'NordVPN Easy could not prepare the credentials request locally (temporary file or response handling failed); the VPN was left unchanged. Check the router free space/permissions and retry.'
    return 0
  fi

  if [ "$rc" != '22' ]; then
    printf '%s' 'Could not reach the NordVPN API to fetch the NordLynx key. This is usually a temporary network/DNS/TLS problem on the router WAN; the VPN was left unchanged and apply will retry.'
    return 0
  fi

  case "$code" in
    400|401)
      printf '%s' 'NordVPN rejected the access token (HTTP '"$code"'). Regenerate the token at my.nordaccount.com (Services > set up NordVPN manually > access token) and update it in NordVPN Easy. The existing VPN configuration was left in place.'
      ;;
    403)
      printf '%s' 'NordVPN denied access to the credentials service (HTTP 403). The token may lack an active NordVPN subscription/service; verify the account at my.nordaccount.com.'
      ;;
    429)
      printf '%s' 'NordVPN is rate-limiting credential requests (HTTP 429). This is temporary; wait a few minutes before applying again. The VPN was left unchanged.'
      ;;
    5??)
      printf '%s' 'NordVPN API returned a server error (HTTP '"$code"'). This is a temporary problem on NordVPN side; the VPN was left unchanged and apply will retry.'
      ;;
    *)
      printf '%s' 'NordVPN API returned an unexpected response (HTTP '"$code"') while fetching the NordLynx key. The VPN was left unchanged.'
      ;;
  esac
}

get_private_key () {
  local credentials_message=''
  local credentials_response_bytes='0'

  if [ -n "$NORDVPN_TOKEN" ]; then
    log 'apply: requesting NordLynx private key from NordVPN API'
    fetch_credentials_json || {
      credentials_message="could not retrieve NordLynx private key from NordVPN API: $(get_private_key_error_message "${NORDVPN_EASY_CREDENTIALS_CURL_RC:-1}" "${NORDVPN_EASY_CREDENTIALS_HTTP_CODE:-000}") (curl_rc=${NORDVPN_EASY_CREDENTIALS_CURL_RC:-1}: $(curl_rc_meaning "${NORDVPN_EASY_CREDENTIALS_CURL_RC:-1}"), http_code=${NORDVPN_EASY_CREDENTIALS_HTTP_CODE:-000}"
      [ -n "${NORDVPN_EASY_CREDENTIALS_CURL_ERROR:-}" ] && credentials_message="${credentials_message}, curl_error=${NORDVPN_EASY_CREDENTIALS_CURL_ERROR}"
      credentials_message="${credentials_message})"
      nordvpn_easy_record_last_error "$credentials_message"
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "$credentials_message"
      return 1
    }
  else
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" 'NORDVPN_TOKEN is not defined'
    return 1
  fi

  PRIVATE_KEY=$(printf '%s' "$CREDENTIALS_JSON" | jq -er '.nordlynx_private_key // empty' 2>/dev/null)
  credentials_response_bytes="$(printf '%s' "$CREDENTIALS_JSON" | wc -c | awk '{ print $1 }')"
  CREDENTIALS_JSON=''
  if ! nordvpn_easy_valid_wireguard_key "$PRIVATE_KEY"; then
    PRIVATE_KEY=''
    credentials_message="invalid NordLynx private key response received from NordVPN API (http_code=${NORDVPN_EASY_CREDENTIALS_HTTP_CODE:-000}, response_bytes=${credentials_response_bytes:-0})"
    nordvpn_easy_record_last_error "$credentials_message"
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "$credentials_message"
    return 1
  fi

  log 'apply: NordLynx private key retrieved successfully'
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
  COUNTRIES_TEMP_DIR=''
  COUNTRIES_RAW_TMP=''
  COUNTRIES_CACHE_TMP=''
  COUNTRIES_TS_TMP=''
  COUNTRIES_CURL_STDERR=''
  COUNTRIES_CURL_RC=0
  COUNTRIES_CURL_ERROR=''
  COUNTRIES_FAILURE_REASON=''

  if [ "$FORCE_REFRESH" -ne 1 ] && countries_cache_is_fresh; then
    log "Using cached NordVPN country list from $COUNTRIES_CACHE_FILE"
    return 0
  fi

  if [ "$FORCE_REFRESH" -eq 1 ]; then
    log 'Force-refreshing NordVPN country list cache'
  else
    log 'Refreshing NordVPN country list cache'
  fi

  nordvpn_easy_mktemp_dir 'countries-cache' COUNTRIES_TEMP_DIR || return 1
  COUNTRIES_RAW_TMP="$(nordvpn_easy_temp_file_path "$COUNTRIES_TEMP_DIR" 'countries-api.json')"
  COUNTRIES_CACHE_TMP="$(nordvpn_easy_temp_file_path "$COUNTRIES_TEMP_DIR" 'countries.json')"
  COUNTRIES_TS_TMP="$(nordvpn_easy_temp_file_path "$COUNTRIES_TEMP_DIR" 'countries.timestamp')"
  COUNTRIES_CURL_STDERR="$(nordvpn_easy_temp_file_path "$COUNTRIES_TEMP_DIR" 'curl-stderr.log')"

  curl -fsS --connect-timeout 15 --max-time 30 -o "$COUNTRIES_RAW_TMP" "$COUNTRIES_URL" 2>"$COUNTRIES_CURL_STDERR" || {
    COUNTRIES_CURL_RC=$?
    COUNTRIES_CURL_ERROR="$(nordvpn_easy_curl_error_summary "$COUNTRIES_CURL_STDERR")"
    COUNTRIES_FAILURE_REASON="country list refresh failed (curl_rc=$COUNTRIES_CURL_RC: $(curl_rc_meaning "$COUNTRIES_CURL_RC")"
    [ -n "$COUNTRIES_CURL_ERROR" ] && COUNTRIES_FAILURE_REASON="$COUNTRIES_FAILURE_REASON, curl_error=$COUNTRIES_CURL_ERROR"
    COUNTRIES_FAILURE_REASON="$COUNTRIES_FAILURE_REASON)"
    rm -rf -- "$COUNTRIES_TEMP_DIR"
    if [ -f "$COUNTRIES_CACHE_FILE" ]; then
      log "WARNING: $COUNTRIES_FAILURE_REASON; using existing cache"
      return 0
    fi
    nordvpn_easy_record_last_error "could not refresh country list cache ($COUNTRIES_FAILURE_REASON)"
    log "ERROR: COULD NOT REFRESH COUNTRY LIST CACHE ($COUNTRIES_FAILURE_REASON)"
    return 1
  }

  jq -ce '
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
  ' "$COUNTRIES_RAW_TMP" > "$COUNTRIES_CACHE_TMP" 2>/dev/null || {
    rm -rf -- "$COUNTRIES_TEMP_DIR"
    if [ -f "$COUNTRIES_CACHE_FILE" ]; then
      log 'WARNING: country list refresh produced invalid JSON; using existing cache'
      return 0
    fi
    nordvpn_easy_record_last_error 'country list refresh produced invalid JSON and no existing cache is available'
    log 'ERROR: COULD NOT REFRESH COUNTRY LIST CACHE (invalid JSON response)'
    return 1
  }

  date +%s > "$COUNTRIES_TS_TMP" || {
    rm -rf -- "$COUNTRIES_TEMP_DIR"
    if [ -f "$COUNTRIES_CACHE_FILE" ]; then
      log 'WARNING: country cache timestamp write failed; using existing cache'
      return 0
    fi
    log 'ERROR: COULD NOT WRITE COUNTRY CACHE TIMESTAMP'
    return 1
  }

  mv "$COUNTRIES_CACHE_TMP" "$COUNTRIES_CACHE_FILE" || {
    rm -rf -- "$COUNTRIES_TEMP_DIR"
    if [ -f "$COUNTRIES_CACHE_FILE" ]; then
      log 'WARNING: country cache update failed; using existing cache'
      return 0
    fi
    log 'ERROR: COULD NOT UPDATE COUNTRY LIST CACHE'
    return 1
  }

  mv "$COUNTRIES_TS_TMP" "$COUNTRIES_CACHE_TS_FILE" || {
    rm -rf -- "$COUNTRIES_TEMP_DIR"
    if [ -f "$COUNTRIES_CACHE_FILE" ]; then
      log 'WARNING: country cache timestamp update failed; using existing cache'
      return 0
    fi
    log 'ERROR: COULD NOT UPDATE COUNTRY CACHE TIMESTAMP'
    return 1
  }

  rm -rf -- "$COUNTRIES_TEMP_DIR"
  log "NordVPN country list cache updated at $COUNTRIES_CACHE_FILE"
}

valid_public_ip () {
  nordvpn_easy_public_ip_valid_ip "$@"
}

valid_country_code () {
  nordvpn_easy_public_ip_valid_country_code "$@"
}

public_lookup_log () {
  nordvpn_easy_public_ip_log "$@"
}

nordvpn_easy_runtime_lock_is_busy () {
  nordvpn_easy_load_lock_metadata "${LOCK_DIR:-/tmp/nordvpn-easy.lock}"
  [ "${OPERATION_LOCK_STATE:-none}" = 'held' ] || return 1
  [ "${OPERATION_LOCK_PID:-}" != "$$" ] || return 1
}

nordvpn_easy_lock_holder_summary () {
  printf 'holder_action=%s, holder_pid=%s, holder_age_seconds=%s' \
    "${OPERATION_LOCK_ACTION:-unknown}" \
    "${OPERATION_LOCK_PID:-unknown}" \
    "${OPERATION_LOCK_AGE_SECONDS:-0}"
}

nordvpn_easy_write_runtime_cache_value () {
  local cache_file="$1"
  local cache_value="$2"
  local cache_dir

  [ -n "$cache_file" ] || return 1
  cache_dir="$(dirname "$cache_file")"
  mkdir -p "$cache_dir" || return 1
  printf '%s\n' "$cache_value" > "${cache_file}.$$" || {
    rm -f "${cache_file}.$$"
    return 1
  }
  mv "${cache_file}.$$" "$cache_file"
}

nordvpn_easy_record_last_error () {
  nordvpn_easy_write_runtime_cache_value "${NORDVPN_EASY_LAST_ERROR_CACHE:-/tmp/run/nordvpn-easy/last_error}" "$*" >/dev/null 2>&1 || true
  NORDVPN_EASY_LAST_ERROR_RECORDED=1
}

write_public_ip_cache () {
  nordvpn_easy_public_ip_write_keyval_cache
}

detect_public_ip () {
  nordvpn_easy_detect_public_ip
}

update_public_ip_cache () {
  nordvpn_easy_update_public_ip_cache
}

emit_public_ip_cache_snapshot () {
  nordvpn_easy_emit_public_ip_snapshot
}

lookup_public_country_by_ip () {
  nordvpn_easy_lookup_public_country_by_ip "$@"
}

refresh_public_country_cache_for_current_ip () {
  nordvpn_easy_refresh_public_country_cache
}

verify_public_country_selection () {
  local expected_country=''

  expected_country="$(printf '%s' "${RESOLVED_COUNTRY_CODE:-${VPN_COUNTRY:-}}" | tr 'a-z' 'A-Z')"
  nordvpn_easy_public_verification_write 'pending' "$expected_country" '' 'public IP check running' >/dev/null 2>&1 || true

  update_public_ip_cache || {
    log 'WARNING: COULD NOT RETRIEVE PUBLIC IP FOR COUNTRY CHECK'
    nordvpn_easy_public_verification_write 'failed' "$expected_country" '' 'could not retrieve public IP' >/dev/null 2>&1 || true
    return 0
  }

  refresh_public_country_cache_for_current_ip || {
    log "WARNING: COULD NOT LOOK UP COUNTRY FOR PUBLIC IP $PUBLIC_IP"
    nordvpn_easy_public_verification_write 'failed' "$expected_country" '' "could not geolocate public IP $PUBLIC_IP" >/dev/null 2>&1 || true
    return 0
  }

  if [ -z "$VPN_COUNTRY" ]; then
    log "Public country check: $PUBLIC_IP geolocates to $PUBLIC_COUNTRY with automatic country selection"
    nordvpn_easy_public_verification_write 'ok' '' "$PUBLIC_COUNTRY" 'public country check passed' >/dev/null 2>&1 || true
    return 0
  fi

  resolve_country_filter || {
    log "WARNING: COULD NOT RESOLVE SELECTED COUNTRY '$VPN_COUNTRY' FOR PUBLIC COUNTRY CHECK"
    nordvpn_easy_public_verification_write 'failed' "$expected_country" "$PUBLIC_COUNTRY" "could not resolve selected country $VPN_COUNTRY" >/dev/null 2>&1 || true
    return 0
  }

  if [ "$PUBLIC_COUNTRY" = "$RESOLVED_COUNTRY_CODE" ]; then
    log "Public country check passed: $PUBLIC_IP geolocates to $PUBLIC_COUNTRY and matches selected country $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    nordvpn_easy_public_verification_write 'ok' "$RESOLVED_COUNTRY_CODE" "$PUBLIC_COUNTRY" 'public country check passed' >/dev/null 2>&1 || true
  else
    log "WARNING: Public country mismatch: $PUBLIC_IP geolocates to $PUBLIC_COUNTRY while selected country is $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    nordvpn_easy_public_verification_write 'mismatch' "$RESOLVED_COUNTRY_CODE" "$PUBLIC_COUNTRY" "public IP country $PUBLIC_COUNTRY does not match selected country $RESOLVED_COUNTRY_CODE" >/dev/null 2>&1 || true
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
  ' "$COUNTRIES_CACHE_FILE" 2>/dev/null) || COUNTRY_MATCH=''

  IFS="$(printf '\t')" read -r RESOLVED_COUNTRY_ID RESOLVED_COUNTRY_NAME RESOLVED_COUNTRY_CODE <<EOF
$COUNTRY_MATCH
EOF

  if [ -z "$RESOLVED_COUNTRY_ID" ]; then
    # The country could not be resolved from the cache -- either it is absent
    # from a readable cache (jq returns an empty row) or the cache could not be
    # parsed (jq fails). In both cases a syntactically valid country code is
    # still usable by filtering recommendations by code instead of the API
    # country id, rather than failing the whole operation.
    if valid_country_code "$COUNTRY_QUERY"; then
      RESOLVED_COUNTRY_ID=''
      RESOLVED_COUNTRY_NAME='unknown in NordVPN country cache'
      RESOLVED_COUNTRY_CODE=$(printf '%s' "$COUNTRY_QUERY" | tr 'a-z' 'A-Z')
      RESOLVED_COUNTRY_QUERY="$COUNTRY_QUERY"
      log "WARNING: COUNTRY '$RESOLVED_COUNTRY_CODE' is not in the NordVPN country cache; recommendations will be filtered by country code instead of API country id"
      return 0
    fi
    log "ERROR: COUNTRY '$COUNTRY_QUERY' NOT FOUND"
    return 1
  fi

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

server_catalog_cache_matches_query () {
  TARGET_QUERY="$1"

  [ -f "$SERVER_CATALOG_FILE" ] || return 1

  jq -er --arg query "$TARGET_QUERY" '
    (.servers | type == "array") and
    (.servers | length > 0) and
    (
      ($query == "") or
      ((.country_id | tostring) == $query) or
      ((.country_code // "" | ascii_downcase) == ($query | ascii_downcase)) or
      ((.country_name // "" | ascii_downcase) == ($query | ascii_downcase))
    )
  ' "$SERVER_CATALOG_FILE" >/dev/null 2>&1
}

fetch_server_catalog () {
  FORCE_REFRESH="${1:-0}"
  COUNTRY_QUERY="${2:-$VPN_COUNTRY}"
  SERVER_CATALOG_TEMP_DIR=''
  SERVER_CATALOG_TMP=''
  SERVER_CATALOG_TS_TMP=''
  SERVER_CATALOG_RAW_TMP=''
  SERVER_CATALOG_URL=''

  [ -n "$COUNTRY_QUERY" ] || {
    log 'ERROR: SERVER CATALOG REQUEST REQUIRES A COUNTRY FILTER'
    return 1
  }

  resolve_country_filter "$COUNTRY_QUERY" || return 1

  if [ -z "$RESOLVED_COUNTRY_ID" ]; then
    log "WARNING: cannot refresh server catalog without API country id for ${RESOLVED_COUNTRY_CODE:-$COUNTRY_QUERY}"
    return 1
  fi

  if [ "$FORCE_REFRESH" -ne 1 ] && server_catalog_cache_is_fresh "$RESOLVED_COUNTRY_ID"; then
    log "Using cached NordVPN server catalog from $SERVER_CATALOG_FILE for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    return 0
  fi

  SERVER_CATALOG_URL="${SERVER_CATALOG_URL_BASE}&filters[country_id]=$RESOLVED_COUNTRY_ID"
  log "Refreshing NordVPN server catalog for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"

  nordvpn_easy_mktemp_dir 'server-catalog' SERVER_CATALOG_TEMP_DIR || return 1
  SERVER_CATALOG_TMP="$(nordvpn_easy_temp_file_path "$SERVER_CATALOG_TEMP_DIR" 'catalog.json')"
  SERVER_CATALOG_TS_TMP="$(nordvpn_easy_temp_file_path "$SERVER_CATALOG_TEMP_DIR" 'catalog.timestamp')"
  SERVER_CATALOG_RAW_TMP="$(nordvpn_easy_temp_file_path "$SERVER_CATALOG_TEMP_DIR" 'catalog.raw')"
  curl -g -fsS --connect-timeout 15 --max-time 45 -o "$SERVER_CATALOG_RAW_TMP" "$SERVER_CATALOG_URL" || {
      rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
      if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
        log "WARNING: server catalog download failed for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE); using existing cache"
        return 0
      fi
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "could not download server catalog for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    return 1
  }

  [ -s "$SERVER_CATALOG_RAW_TMP" ] || {
    rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
    if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
      log "WARNING: empty server catalog response for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE); using existing cache"
      return 0
    fi
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "empty server catalog response for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
    return 1
  }

  nordvpn_easy_build_server_catalog_json "$RESOLVED_COUNTRY_ID" "$RESOLVED_COUNTRY_CODE" "$RESOLVED_COUNTRY_NAME" \
    < "$SERVER_CATALOG_RAW_TMP" > "$SERVER_CATALOG_TMP" 2>/dev/null || {
      rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
      if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
        log "WARNING: server catalog transform failed for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE); using existing cache"
        return 0
      fi
      nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "could not transform server catalog for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
      return 1
    }

  nordvpn_easy_server_catalog_has_servers "$SERVER_CATALOG_TMP" || {
    rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
    if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
      log "WARNING: no WireGuard servers found for '$COUNTRY_QUERY'; using existing cache"
      return 0
    fi
    nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "no WireGuard servers found for country '$COUNTRY_QUERY'"
    return 1
  }

  date +%s > "$SERVER_CATALOG_TS_TMP" || {
    rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
    if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
      log "WARNING: server catalog timestamp write failed for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE); using existing cache"
      return 0
    fi
    log 'ERROR: COULD NOT WRITE SERVER CATALOG TIMESTAMP'
    return 1
  }

  mv "$SERVER_CATALOG_TMP" "$SERVER_CATALOG_FILE" || {
    rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
    if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
      log "WARNING: server catalog cache update failed for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE); using existing cache"
      return 0
    fi
    log 'ERROR: COULD NOT UPDATE SERVER CATALOG CACHE'
    return 1
  }

  mv "$SERVER_CATALOG_TS_TMP" "$SERVER_CATALOG_TS_FILE" || {
    rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
    if server_catalog_cache_matches_country "$RESOLVED_COUNTRY_ID"; then
      log "WARNING: server catalog timestamp update failed for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE); using existing cache"
      return 0
    fi
    log 'ERROR: COULD NOT UPDATE SERVER CATALOG TIMESTAMP'
    return 1
  }

  rm -rf -- "$SERVER_CATALOG_TEMP_DIR"
  log "NordVPN server catalog updated at $SERVER_CATALOG_FILE for $RESOLVED_COUNTRY_NAME ($RESOLVED_COUNTRY_CODE)"
}

find_preferred_server_in_catalog () {
  nordvpn_easy_find_preferred_server_in_catalog "$@"
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

ensure_vpn_firewall () {
  nordvpn_easy_ensure_vpn_firewall "$@"
}

set_vpn_server_in_uci () {
  nordvpn_easy_set_vpn_server_in_uci "$@"
}

set_first_server_from_list () {
  nordvpn_easy_set_first_server_from_list "$@"
}

reconcile_action () {
  nordvpn_easy_reconcile_action "$@"
}

provision_vpn () {
  nordvpn_easy_provision_vpn "$@"
}

# Atomic stop + fresh provision; used by the reconnect action and by the
# reconcile reprovision fallback so both run within a single held lock.
reprovision_vpn () {
  nordvpn_easy_stop_vpn_for_server_change &&
  provision_vpn connect_fresh
}

configure_vpn_interface () {
  nordvpn_easy_configure_vpn_interface "$@"
}

rotate_action () {
  nordvpn_easy_rotate_action "$@"
}

check_once () {
  nordvpn_easy_check_once "$@"
}

ACTION='check'
ACTION_TRACE_ID=''
ACTION_STARTED_AT=''

if [ $# -gt 0 ]; then
  case "$1" in
    check|stop_vpn|reconnect|reconcile|setup|rotate|refresh_countries|refresh_countries_force|server_catalog|public_ip|operation_status|vpn_status|status_json|diagnostics_log|diagnostics_summary|supervise|run|help)
      ACTION="$1"
      shift
      ;;
  esac
fi

# Used by common.sh logging helpers sourced above.
# shellcheck disable=SC2034
ACTION_TRACE_ID="$(date +%s 2>/dev/null || printf '%s' '0').$$"
ACTION_STARTED_AT="$(date +%s 2>/dev/null || printf '%s' '0')"

if [ $# -gt 0 ]; then
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      CONFIG_PATH_REQUIRED=1
      shift
      [ $# -gt 0 ] && shift
      ;;
    /*|./*|../*|*.conf)
      CONFIG_PATH="$1"
      CONFIG_PATH_REQUIRED=1
      shift
      ;;
  esac
fi

if [ -z "$CONFIG_PATH" ] && [ -n "${NORDVPN_CONFIG_FILE:-}" ]; then
  CONFIG_PATH="$NORDVPN_CONFIG_FILE"
  CONFIG_PATH_REQUIRED=1
fi

case "$ACTION:${1:-}" in
  status_json:*|operation_status:*|vpn_status:*|diagnostics_log:*|diagnostics_summary:*|public_ip:quiet)
    CORE_QUIET_ACTION=1
    ;;
esac

case "$ACTION" in
  help)
    usage
    exit 0
    ;;
esac

core_source_libs_for_action "$ACTION" || exit 1
nordvpn_easy_apply_env_defaults

load_config || exit 1
NORDVPN_EASY_LAST_ERROR_RECORDED=0

if [ "$ACTION" = 'public_ip' ]; then
  nordvpn_easy_run_public_ip_check "${1:-verbose}"
  exit $?
fi

if [ "$ACTION" = 'operation_status' ]; then
  LOG_PHASE='runtime'
  nordvpn_easy_operation_status_value "$LOCK_DIR"
  exit $?
fi

if [ "$ACTION" = 'vpn_status' ]; then
  LOG_PHASE='runtime'
  nordvpn_easy_vpn_status_value "${DESIRED_ENABLED:-0}" "$VPN_IF"
  exit $?
fi

if [ "$ACTION" = 'status_json' ]; then
  LOG_PHASE='runtime'
  # Single live emit. nordvpn_easy_emit_status_json reads the connect-apply guard
  # (-> connect_apply_pending) and the connect-apply-result file fresh, so this is a
  # full emit that honors the "full emit while the guard exists" contract with no
  # special branch. The status cache is a post-action forensic snapshot (written by
  # the action epilogue and connect-apply finish), never read on the poll path, so
  # it is not written here.
  nordvpn_easy_emit_status_json
  exit $?
fi

if [ "$ACTION" = 'diagnostics_log' ]; then
  LOG_PHASE='service'
  [ "$CORE_QUIET_ACTION" -eq 1 ] || log 'diagnostics log export requested'
  NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES=0
  nordvpn_easy_export_diagnostics_log 'nordvpn-easy'
  exit $?
fi

if [ "$ACTION" = 'diagnostics_summary' ]; then
  LOG_PHASE='service'
  [ "$CORE_QUIET_ACTION" -eq 1 ] || log 'diagnostics summary requested'
  if [ "$CORE_QUIET_ACTION" -eq 1 ]; then
    NORDVPN_EASY_DIAGNOSTICS_ACTIVE_PROBES=0
  fi
  nordvpn_easy_emit_diagnostics_summary_json "$VPN_IF"
  exit $?
fi

if [ "$ACTION" = 'server_catalog' ]; then
  SERVER_CATALOG_QUERY="${1:-$VPN_COUNTRY}"
  SERVER_CATALOG_FORCE="${2:-0}"
  if nordvpn_easy_runtime_lock_is_busy; then
    if server_catalog_cache_matches_query "$SERVER_CATALOG_QUERY"; then
      log "server_catalog request skipped because another runtime operation is running ($(nordvpn_easy_lock_holder_summary)); returned cached catalog"
      nordvpn_easy_emit_server_catalog_json "$SERVER_CATALOG_FILE" "$SERVER_CATALOG_TS_FILE" "$(server_cache_ttl_value)"
      exit 0
    fi

    log "SKIPPED: action 'server_catalog' skipped because another runtime operation is running ($(nordvpn_easy_lock_holder_summary))"
    exit "$NORDVPN_EASY_RC_BUSY"
  fi
fi

case "$ACTION" in
  stop_vpn)
    require_stop_commands || exit 1
    ;;
  *)
    require_commands || exit 1
    ;;
esac

log "action dispatch starting (args=$(nordvpn_easy_debug_cli_args "$@"), config_source=${CONFIG_CONTEXT_SOURCE:-unknown}, vpn_if=${VPN_IF:-unset}, desired_enabled=${DESIRED_ENABLED:-0})"

acquire_lock
LOCK_STATUS=$?
if [ "$LOCK_STATUS" -ne 0 ]; then
  if [ "$LOCK_STATUS" -eq 2 ]; then
    nordvpn_easy_load_lock_metadata "$LOCK_DIR"
    log "SKIPPED: action '$ACTION' skipped because another runtime operation is running ($(nordvpn_easy_lock_holder_summary))"
    exit "$NORDVPN_EASY_RC_BUSY"
  else
    log "ERROR: ACTION '$ACTION' FAILED TO ACQUIRE EXECUTION LOCK AT $LOCK_DIR"
  fi
  exit 1
fi

ACTION_RC=0

case "$ACTION" in
  run|check)
    check_once
    ACTION_RC=$?
    ;;
  supervise)
    # 2nd structural flag gate (S7 inc 5c): the supervised apply state machine runs
    # ONLY under orchestrator=supervisor and ONLY for the enable apply; disable and
    # legacy stay on the existing path. Placed after acquire_lock so the in-lock TTL
    # reaper has already fired at head.
    if [ "$(nordvpn_easy_orchestrator_mode)" != 'supervisor' ] || [ "${DESIRED_ENABLED:-0}" != '1' ]; then
      log 'supervise: orchestrator=legacy or disable requested; staying on legacy path (no-op)'
      ACTION_RC=0
    else
      nordvpn_easy_supervise
      ACTION_RC=$?
    fi
    ;;
  reconcile)
    VALID_RC=0
    validate_setup_runtime || VALID_RC=$?
    if [ "$VALID_RC" -ne 0 ]; then
      ACTION_RC="$VALID_RC"
    else
      reconcile_action
      ACTION_RC=$?
      if [ "$ACTION_RC" -eq "$NORDVPN_EASY_RC_RUNTIME_DRIFT" ]; then
        log 'reconcile: runtime drift remained after reconcile action; reprovisioning (stop_vpn + connect_fresh) under the held lock'
        reprovision_vpn
        ACTION_RC=$?
      fi
    fi
    ;;
  stop_vpn)
    if validate_stop_runtime; then
      if [ -f "${NORDVPN_EASY_CONNECT_APPLY_GUARD:-/tmp/run/nordvpn-easy/connect-apply-guard}" ] ||
        [ "${NORDVPN_EASY_CONNECT_APPLY:-0}" = '1' ]; then
        nordvpn_easy_stop_vpn_for_connect_apply
      else
        nordvpn_easy_stop_vpn_for_server_change
      fi
      ACTION_RC=$?
    else
      ACTION_RC=1
    fi
    ;;
  reconnect)
    validate_setup_runtime &&
    reprovision_vpn &&
    log 'NordVPN reconnect completed (stop_vpn + connect_fresh)'
    ACTION_RC=$?
    ;;
  setup)
    if validate_setup_runtime; then
      if [ "${NORDVPN_EASY_CONNECT_APPLY:-0}" = '1' ]; then
        provision_vpn connect_apply &&
        log 'NordVPN configuration is ready (connect apply)'
      else
        provision_vpn connect_fresh &&
        log 'NordVPN configuration is ready'
      fi
      ACTION_RC=$?
    else
      ACTION_RC=1
    fi
    ;;
  rotate)
    rotate_action
    ACTION_RC=$?
    ;;
  refresh_countries)
    refresh_countries_cache
    ACTION_RC=$?
    ;;
  refresh_countries_force)
    refresh_countries_cache 1
    ACTION_RC=$?
    ;;
  server_catalog)
    fetch_server_catalog "$SERVER_CATALOG_FORCE" "$SERVER_CATALOG_QUERY" &&
      nordvpn_easy_emit_server_catalog_json "$SERVER_CATALOG_FILE" "$SERVER_CATALOG_TS_FILE" "$(server_cache_ttl_value)"
    ACTION_RC=$?
    ;;
  *)
    usage
    exit 1
    ;;
esac

ACTION_FINISHED_AT="$(date +%s 2>/dev/null || printf '%s' '0')"
ACTION_DURATION="$ACTION_FINISHED_AT"
case "$ACTION_STARTED_AT" in
  ''|*[!0-9]*)
    ACTION_DURATION='unknown'
    ;;
  *)
    case "$ACTION_FINISHED_AT" in
      ''|*[!0-9]*)
        ACTION_DURATION='unknown'
        ;;
      *)
        ACTION_DURATION=$((ACTION_FINISHED_AT - ACTION_STARTED_AT))
        ;;
    esac
    ;;
esac

nordvpn_easy_write_status_cache >/dev/null 2>&1 || true

if [ "$ACTION_RC" -eq 0 ]; then
  nordvpn_easy_write_runtime_cache_value "${NORDVPN_EASY_LAST_ERROR_CACHE:-/tmp/run/nordvpn-easy/last_error}" '' >/dev/null 2>&1 || true
  log "action '$ACTION' completed successfully (duration=${ACTION_DURATION}s)"
else
  if [ "${NORDVPN_EASY_LAST_ERROR_RECORDED:-0}" -ne 1 ]; then
    nordvpn_easy_record_last_error "action '$ACTION' failed (rc=$ACTION_RC)"
  fi
  nordvpn_easy_log_blocker "${LOG_PHASE:-runtime}" "action '$ACTION' failed (duration=${ACTION_DURATION}s, rc=$ACTION_RC)"
fi

exit "$ACTION_RC"
