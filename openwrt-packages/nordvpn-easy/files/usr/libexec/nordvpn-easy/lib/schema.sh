#!/bin/sh

NORDVPN_EASY_SCHEMA_VERSION="${NORDVPN_EASY_SCHEMA_VERSION:-2}"
NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE="${NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE:-render-contract-v2}"

nordvpn_easy_shell_quote() {
	printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

nordvpn_easy_uci_options() {
	cat <<'EOF'
enabled
nordvpn_token
wan_if
vpn_if
vpn_country
server_selection_mode
preferred_server_hostname
preferred_server_station
server_cache_enabled
server_cache_ttl
vpn_port
vpn_addr
vpn_dns1
vpn_dns2
check_cron_schedule
enable_hotplug
failure_retry_delay
server_rotate_threshold
interface_restart_threshold
max_interface_restarts
interface_restart_delay
post_restart_delay
config_schema_version
EOF
}

nordvpn_easy_backend_payload_signature() {
	printf '%s\n' "$NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE"
}

nordvpn_easy_runtime_bindings() {
	cat <<'EOF'
nordvpn_token NORDVPN_TOKEN
wan_if WAN_IF
vpn_if VPN_IF
vpn_country VPN_COUNTRY
server_selection_mode SERVER_SELECTION_MODE
preferred_server_hostname PREFERRED_SERVER_HOSTNAME
preferred_server_station PREFERRED_SERVER_STATION
server_cache_enabled SERVER_CACHE_ENABLED
server_cache_ttl SERVER_CACHE_TTL
vpn_port VPN_PORT
vpn_addr VPN_ADDR
vpn_dns1 VPN_DNS1
vpn_dns2 VPN_DNS2
check_cron_schedule CHECK_CRON_SCHEDULE
enable_hotplug ENABLE_HOTPLUG
failure_retry_delay FAILURE_RETRY_DELAY
server_rotate_threshold SERVER_ROTATE_THRESHOLD
interface_restart_threshold INTERFACE_RESTART_THRESHOLD
max_interface_restarts MAX_INTERFACE_RESTARTS
interface_restart_delay INTERFACE_RESTART_DELAY
post_restart_delay POST_RESTART_DELAY
EOF
}

nordvpn_easy_runtime_options() {
	nordvpn_easy_runtime_bindings | awk '{ print $1 }'
}

nordvpn_easy_runtime_env_keys() {
	nordvpn_easy_runtime_bindings | awk '{ print $2 }'
}

nordvpn_easy_default() {
	case "$1" in
		enabled) printf '%s\n' '0' ;;
		nordvpn_token) printf '%s\n' '' ;;
		wan_if) printf '%s\n' 'wan' ;;
		vpn_if) printf '%s\n' 'wg0' ;;
		vpn_country) printf '%s\n' '' ;;
		server_selection_mode) printf '%s\n' 'auto' ;;
		preferred_server_hostname) printf '%s\n' '' ;;
		preferred_server_station) printf '%s\n' '' ;;
		server_cache_enabled) printf '%s\n' '1' ;;
		server_cache_ttl) printf '%s\n' '86400' ;;
		vpn_port) printf '%s\n' '51820' ;;
		vpn_addr) printf '%s\n' '10.5.0.2/32' ;;
		vpn_dns1) printf '%s\n' '103.86.99.99' ;;
		vpn_dns2) printf '%s\n' '103.86.96.96' ;;
		check_cron_schedule) printf '%s\n' '* * * * *' ;;
		enable_hotplug) printf '%s\n' '1' ;;
		failure_retry_delay) printf '%s\n' '6' ;;
		server_rotate_threshold) printf '%s\n' '5' ;;
		interface_restart_threshold) printf '%s\n' '10' ;;
		max_interface_restarts) printf '%s\n' '3' ;;
		interface_restart_delay) printf '%s\n' '10' ;;
		post_restart_delay) printf '%s\n' '60' ;;
		config_schema_version) printf '%s\n' "$NORDVPN_EASY_SCHEMA_VERSION" ;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_is_bool_option() {
	case "$1" in
		enabled|server_cache_enabled|enable_hotplug)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_is_uint_option() {
	case "$1" in
		server_cache_ttl|vpn_port|failure_retry_delay|server_rotate_threshold|interface_restart_threshold|max_interface_restarts|interface_restart_delay|post_restart_delay)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_env_name() {
	nordvpn_easy_runtime_bindings | awk -v option="$1" '
		$1 == option {
			print $2
			found = 1
			exit
		}
		END {
			exit(found ? 0 : 1)
		}
	'
}

nordvpn_easy_normalize_bool() {
	case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
		1|true|yes|on)
			printf '%s\n' '1'
			;;
		*)
			printf '%s\n' '0'
			;;
	esac
}

nordvpn_easy_normalize_value() {
	local option="$1"
	local value="$2"
	local default_value=''

	default_value="$(nordvpn_easy_default "$option" 2>/dev/null || printf '%s' '')"

	if nordvpn_easy_is_bool_option "$option"; then
		nordvpn_easy_normalize_bool "$value"
		return 0
	fi

	if nordvpn_easy_is_uint_option "$option"; then
		case "$value" in
			''|*[!0-9]*)
				printf '%s\n' "$default_value"
				;;
			*)
				printf '%s\n' "$value"
				;;
		esac
		return 0
	fi

	case "$option" in
		wan_if|vpn_if|vpn_addr)
			if [ -n "$value" ]; then
				printf '%s\n' "$value"
			else
				printf '%s\n' "$default_value"
			fi
			;;
		server_selection_mode)
			case "$value" in
				manual)
					printf '%s\n' 'manual'
					;;
				*)
					printf '%s\n' 'auto'
					;;
			esac
			;;
		config_schema_version)
			printf '%s\n' "$NORDVPN_EASY_SCHEMA_VERSION"
			;;
		*)
			printf '%s\n' "$value"
			;;
	esac
}

nordvpn_easy_apply_env_defaults() {
	local option env_name default_value current

	for option in $(nordvpn_easy_runtime_options); do
		env_name="$(nordvpn_easy_env_name "$option")"
		default_value="$(nordvpn_easy_default "$option" 2>/dev/null || printf '%s' '')"
		eval "current=\${$env_name-__NORDVPN_EASY_UNSET__}"

		if [ "$current" = '__NORDVPN_EASY_UNSET__' ] || [ -z "$current" ]; then
			eval "$env_name='$(nordvpn_easy_shell_quote "$default_value")'"
		fi
	done
}
