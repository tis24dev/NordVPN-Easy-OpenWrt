#!/bin/sh

NORDVPN_EASY_SCHEMA_VERSION="${NORDVPN_EASY_SCHEMA_VERSION:-4}"
NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE="${NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE:-render-contract-v3}"

nordvpn_easy_shell_quote() {
	local value="$1"
	local quoted=''
	local head

	while :; do
		case "$value" in
			*\'*)
				head=${value%%\'*}
				quoted="${quoted}${head}'\\''"
				value=${value#*\'}
				;;
			*)
				printf '%s' "${quoted}${value}"
				return 0
				;;
		esac
	done
}

nordvpn_easy_uci_options() {
	printf '%s\n' \
		'enabled' \
		'nordvpn_token' \
		'wan_if' \
		'vpn_if' \
		'vpn_country' \
		'server_selection_mode' \
		'preferred_server_hostname' \
		'preferred_server_station' \
		'fallback_server_station' \
		'server_cache_enabled' \
		'server_cache_ttl' \
		'vpn_port' \
		'wireguard_persistent_keepalive' \
		'wireguard_mtu' \
		'firewall_mtu_fix' \
		'vpn_addr' \
		'vpn_dns1' \
		'vpn_dns2' \
		'dns_mode' \
		'check_cron_schedule' \
		'enable_hotplug' \
		'hotplug_debounce_seconds' \
		'kill_switch_enabled' \
		'failure_retry_delay' \
		'interface_restart_delay' \
		'post_restart_delay' \
		'config_schema_version'
}

nordvpn_easy_backend_payload_signature() {
	printf '%s\n' "$NORDVPN_EASY_BACKEND_PAYLOAD_SIGNATURE"
}

nordvpn_easy_runtime_bindings() {
	printf '%s\n' \
		'nordvpn_token NORDVPN_TOKEN' \
		'wan_if WAN_IF' \
		'vpn_if VPN_IF' \
		'vpn_country VPN_COUNTRY' \
		'server_selection_mode SERVER_SELECTION_MODE' \
		'preferred_server_hostname PREFERRED_SERVER_HOSTNAME' \
		'preferred_server_station PREFERRED_SERVER_STATION' \
		'fallback_server_station FALLBACK_SERVER_STATION' \
		'server_cache_enabled SERVER_CACHE_ENABLED' \
		'server_cache_ttl SERVER_CACHE_TTL' \
		'vpn_port VPN_PORT' \
		'wireguard_persistent_keepalive WIREGUARD_PERSISTENT_KEEPALIVE' \
		'wireguard_mtu WIREGUARD_MTU' \
		'firewall_mtu_fix FIREWALL_MTU_FIX' \
		'vpn_addr VPN_ADDR' \
		'vpn_dns1 VPN_DNS1' \
		'vpn_dns2 VPN_DNS2' \
		'dns_mode DNS_MODE' \
		'check_cron_schedule CHECK_CRON_SCHEDULE' \
		'enable_hotplug ENABLE_HOTPLUG' \
		'hotplug_debounce_seconds HOTPLUG_DEBOUNCE_SECONDS' \
		'kill_switch_enabled KILL_SWITCH_ENABLED' \
		'failure_retry_delay FAILURE_RETRY_DELAY' \
		'interface_restart_delay INTERFACE_RESTART_DELAY' \
		'post_restart_delay POST_RESTART_DELAY'
}

nordvpn_easy_runtime_options() {
	printf '%s\n' \
		'nordvpn_token' \
		'wan_if' \
		'vpn_if' \
		'vpn_country' \
		'server_selection_mode' \
		'preferred_server_hostname' \
		'preferred_server_station' \
		'fallback_server_station' \
		'server_cache_enabled' \
		'server_cache_ttl' \
		'vpn_port' \
		'wireguard_persistent_keepalive' \
		'wireguard_mtu' \
		'firewall_mtu_fix' \
		'vpn_addr' \
		'vpn_dns1' \
		'vpn_dns2' \
		'dns_mode' \
		'check_cron_schedule' \
		'enable_hotplug' \
		'hotplug_debounce_seconds' \
		'kill_switch_enabled' \
		'failure_retry_delay' \
		'interface_restart_delay' \
		'post_restart_delay'
}

nordvpn_easy_runtime_env_keys() {
	printf '%s\n' \
		'NORDVPN_TOKEN' \
		'WAN_IF' \
		'VPN_IF' \
		'VPN_COUNTRY' \
		'SERVER_SELECTION_MODE' \
		'PREFERRED_SERVER_HOSTNAME' \
		'PREFERRED_SERVER_STATION' \
		'FALLBACK_SERVER_STATION' \
		'SERVER_CACHE_ENABLED' \
		'SERVER_CACHE_TTL' \
		'VPN_PORT' \
		'WIREGUARD_PERSISTENT_KEEPALIVE' \
		'WIREGUARD_MTU' \
		'FIREWALL_MTU_FIX' \
		'VPN_ADDR' \
		'VPN_DNS1' \
		'VPN_DNS2' \
		'DNS_MODE' \
		'CHECK_CRON_SCHEDULE' \
		'ENABLE_HOTPLUG' \
		'HOTPLUG_DEBOUNCE_SECONDS' \
		'KILL_SWITCH_ENABLED' \
		'FAILURE_RETRY_DELAY' \
		'INTERFACE_RESTART_DELAY' \
		'POST_RESTART_DELAY'
}

# The RPC contract level the backend advertises in its status. Surfaced for
# display/diagnostics. Kept an integer so JS can compare it.
nordvpn_easy_rpc_contract_level() {
	# 2 = the async supervised `apply` method + its ACL + the JS callApply consumer all
	# ship; the supervisor is the sole apply path.
	printf '2'
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
			fallback_server_station) printf '%s\n' '' ;;
			server_cache_enabled) printf '%s\n' '1' ;;
			server_cache_ttl) printf '%s\n' '86400' ;;
			vpn_port) printf '%s\n' '51820' ;;
			wireguard_persistent_keepalive) printf '%s\n' '15' ;;
			# Kept empty (= automatic) on purpose. The official NordVPN app pins the
			# NordLynx MTU to 1280, but making that the schema default would let
			# nordvpn_easy_apply_env_defaults cap EVERY existing empty-MTU install to
			# 1280 at the next apply and make 'automatic' unreachable. 1280 is instead
			# seeded for fresh installs only by migrate-config.sh, so an existing
			# install keeps automatic and the user can always clear the field to return
			# to it.
			wireguard_mtu) printf '%s\n' '' ;;
			firewall_mtu_fix) printf '%s\n' '1' ;;
			vpn_addr) printf '%s\n' '10.5.0.2/32' ;;
			# The NordVPN standard resolver pair (verified in the decompiled app,
			# gr.C6330b). It matches the 'standard' branch of
			# nordvpn_easy_resolve_dns_pair; the legacy 103.86.99.99/103.86.96.96 pair
			# is not present in the binary. An explicit user DNS is always preserved on
			# upgrade (the migrator keeps any value that differs from this default).
			vpn_dns1) printf '%s\n' '103.86.96.100' ;;
			vpn_dns2) printf '%s\n' '103.86.99.100' ;;
		# dns_mode selects a NordVPN resolver pair (see nordvpn_easy_resolve_dns_pair).
		# 'custom' keeps the saved vpn_dns1/vpn_dns2, which makes it the safe default
		# for any config that predates the option: an upgrade never overrides a user's
		# DNS, and a fresh install keeps today's behaviour. Threat Protection is opt-in
		# from the Advanced page.
		dns_mode) printf '%s\n' 'custom' ;;
		check_cron_schedule) printf '%s\n' '' ;;
		enable_hotplug) printf '%s\n' '1' ;;
		hotplug_debounce_seconds) printf '%s\n' '30' ;;
		kill_switch_enabled) printf '%s\n' '1' ;;
		failure_retry_delay) printf '%s\n' '6' ;;
		interface_restart_delay) printf '%s\n' '10' ;;
		post_restart_delay) printf '%s\n' '30' ;;
		config_schema_version) printf '%s\n' "$NORDVPN_EASY_SCHEMA_VERSION" ;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_is_bool_option() {
	case "$1" in
			enabled|server_cache_enabled|enable_hotplug|kill_switch_enabled|firewall_mtu_fix)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_is_uint_option() {
	case "$1" in
		server_cache_ttl|vpn_port|hotplug_debounce_seconds|failure_retry_delay|interface_restart_delay|post_restart_delay)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_env_name() {
	case "$1" in
		nordvpn_token) printf '%s\n' 'NORDVPN_TOKEN' ;;
		wan_if) printf '%s\n' 'WAN_IF' ;;
		vpn_if) printf '%s\n' 'VPN_IF' ;;
		vpn_country) printf '%s\n' 'VPN_COUNTRY' ;;
		server_selection_mode) printf '%s\n' 'SERVER_SELECTION_MODE' ;;
		preferred_server_hostname) printf '%s\n' 'PREFERRED_SERVER_HOSTNAME' ;;
		preferred_server_station) printf '%s\n' 'PREFERRED_SERVER_STATION' ;;
		fallback_server_station) printf '%s\n' 'FALLBACK_SERVER_STATION' ;;
		server_cache_enabled) printf '%s\n' 'SERVER_CACHE_ENABLED' ;;
		server_cache_ttl) printf '%s\n' 'SERVER_CACHE_TTL' ;;
		vpn_port) printf '%s\n' 'VPN_PORT' ;;
		wireguard_persistent_keepalive) printf '%s\n' 'WIREGUARD_PERSISTENT_KEEPALIVE' ;;
		wireguard_mtu) printf '%s\n' 'WIREGUARD_MTU' ;;
		firewall_mtu_fix) printf '%s\n' 'FIREWALL_MTU_FIX' ;;
		vpn_addr) printf '%s\n' 'VPN_ADDR' ;;
		vpn_dns1) printf '%s\n' 'VPN_DNS1' ;;
		vpn_dns2) printf '%s\n' 'VPN_DNS2' ;;
		dns_mode) printf '%s\n' 'DNS_MODE' ;;
		check_cron_schedule) printf '%s\n' 'CHECK_CRON_SCHEDULE' ;;
		enable_hotplug) printf '%s\n' 'ENABLE_HOTPLUG' ;;
		hotplug_debounce_seconds) printf '%s\n' 'HOTPLUG_DEBOUNCE_SECONDS' ;;
		kill_switch_enabled) printf '%s\n' 'KILL_SWITCH_ENABLED' ;;
		failure_retry_delay) printf '%s\n' 'FAILURE_RETRY_DELAY' ;;
		interface_restart_delay) printf '%s\n' 'INTERFACE_RESTART_DELAY' ;;
		post_restart_delay) printf '%s\n' 'POST_RESTART_DELAY' ;;
		*) return 1 ;;
	esac
}

nordvpn_easy_normalize_bool() {
	case "$1" in
		1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn])
			printf '%s\n' '1'
			;;
		*)
			printf '%s\n' '0'
			;;
	esac
}

nordvpn_easy_strip_leading_zeros() {
	local digits="$1"

	while [ "${#digits}" -gt 1 ]; do
		case "$digits" in
			0*) digits="${digits#0}" ;;
			*) break ;;
		esac
	done
	printf '%s\n' "$digits"
}

nordvpn_easy_is_valid_ipv4() {
	local ip="$1"
	local octet
	local IFS='.'

	case "$ip" in
		''|*[!0-9.]*) return 1 ;;
	esac

	# shellcheck disable=SC2086
	set -- $ip
	[ "$#" -eq 4 ] || return 1
	for octet in "$@"; do
		case "$octet" in
			''|*[!0-9]*) return 1 ;;
		esac
		[ "$octet" -le 255 ] || return 1
	done
	return 0
}

nordvpn_easy_is_valid_ipv4_cidr() {
	local value="$1"
	local prefix

	case "$value" in
		*/*)
			prefix="${value#*/}"
			value="${value%%/*}"
			case "$prefix" in
				''|*[!0-9]*) return 1 ;;
			esac
			[ "$prefix" -le 32 ] || return 1
			;;
		*)
			return 1
			;;
	esac
	nordvpn_easy_is_valid_ipv4 "$value"
}

nordvpn_easy_normalize_value() {
	local option="$1"
	local value="$2"
	local default_value=''

	default_value="$(nordvpn_easy_default "$option" 2>/dev/null || printf '%s' '')"

	if nordvpn_easy_is_bool_option "$option"; then
		if [ -z "$value" ]; then
			printf '%s\n' "$default_value"
			return 0
		fi
		nordvpn_easy_normalize_bool "$value"
		return 0
	fi

	# Validate network-shaped options at the schema boundary so an invalid value
	# is defaulted here rather than reaching netifd and breaking bring-up.
	case "$option" in
		vpn_port)
			case "$value" in
				''|*[!0-9]*)
					printf '%s\n' "$default_value"
					return 0
					;;
			esac
			value="$(nordvpn_easy_strip_leading_zeros "$value")"
			if [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
				printf '%s\n' "$value"
			else
				printf '%s\n' "$default_value"
			fi
			return 0
			;;
		vpn_addr)
			if nordvpn_easy_is_valid_ipv4_cidr "$value"; then
				printf '%s\n' "$value"
			else
				printf '%s\n' "$default_value"
			fi
			return 0
			;;
		vpn_dns1|vpn_dns2)
			if [ -z "$value" ] || nordvpn_easy_is_valid_ipv4 "$value"; then
				printf '%s\n' "$value"
			else
				printf '%s\n' "$default_value"
			fi
			return 0
			;;
		vpn_country)
			case "$value" in
				'')
					printf '%s\n' ''
					;;
				[A-Za-z][A-Za-z])
					value="$(printf '%s' "$value" | tr 'a-z' 'A-Z')"
					printf '%s\n' "$value"
					;;
				*)
					printf '%s\n' "$default_value"
					;;
			esac
			return 0
			;;
		check_cron_schedule)
			# Reject a multi-line / control-char schedule that would corrupt the
			# cron file; the init service validates the cron shape before install.
			case "$value" in
				*[!\ 0-9*/,-]*)
					printf '%s\n' "$default_value"
					;;
				*)
					printf '%s\n' "$value"
					;;
			esac
			return 0
			;;
	esac

	if nordvpn_easy_is_uint_option "$option"; then
		case "$value" in
			''|*[!0-9]*)
				printf '%s\n' "$default_value"
				;;
			*)
				printf '%s\n' "$(nordvpn_easy_strip_leading_zeros "$value")"
				;;
		esac
		return 0
	fi

	case "$option" in
		wireguard_persistent_keepalive)
			case "$value" in
				''|*[!0-9]*)
					printf '%s\n' "$default_value"
					;;
				*)
					if [ "$value" -le 120 ]; then
						printf '%s\n' "$value"
					else
						printf '%s\n' "$default_value"
					fi
					;;
			esac
			;;
		wireguard_mtu)
			case "$value" in
				'')
					printf '%s\n' ''
					;;
				*[!0-9]*)
					printf '%s\n' "$default_value"
					;;
				*)
					if [ "$value" -ge 1280 ] && [ "$value" -le 1500 ]; then
						printf '%s\n' "$value"
					else
						printf '%s\n' "$default_value"
					fi
					;;
			esac
			;;
		wan_if|vpn_if)
			# These become UCI section names (network.${IF}, firewall lookups), so
			# restrict them to the UCI identifier charset. A value with any other
			# character (dot, slash, space, ...) would address the wrong section or
			# break the uci command, so fall back to the safe default.
			case "$value" in
				''|*[!A-Za-z0-9_]*)
					printf '%s\n' "$default_value"
					;;
				*)
					printf '%s\n' "$value"
					;;
			esac
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
		dns_mode)
			# standard/threat_protection/threat_protection_family map to fixed
			# NordVPN resolver pairs (see nordvpn_easy_resolve_dns_pair); custom keeps
			# vpn_dns1/vpn_dns2. Anything else falls back to the safe default.
			case "$value" in
				standard|threat_protection|threat_protection_family|custom)
					printf '%s\n' "$value"
					;;
				*)
					printf '%s\n' "$default_value"
					;;
			esac
			;;
		config_schema_version)
			printf '%s\n' "$NORDVPN_EASY_SCHEMA_VERSION"
			;;
		nordvpn_token)
			# A token pasted with a trailing newline or an inner line break corrupts the
			# curl Basic-auth header and makes the credentials API answer 400 instead of
			# issuing the NordLynx key. Strip CR/LF/Tab anywhere (a real access token has
			# no internal whitespace) and trim surrounding spaces. No bashisms.
			value="$(printf '%s' "$value" | tr -d '\r\n\t')"
			while :; do
				case "$value" in
					' '*) value="${value# }" ;;
					*' ') value="${value% }" ;;
					*) break ;;
				esac
			done
			printf '%s\n' "$value"
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
