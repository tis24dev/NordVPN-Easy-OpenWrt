#!/bin/sh

CONFIG_CONTEXT_LIB_DIR="${NORDVPN_EASY_LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"
CONFIG_CONTEXT_SCHEMA_LIB="${CONFIG_CONTEXT_LIB_DIR}/schema.sh"
CONFIG_CONTEXT_SERVICE_CONFIG_LIB="${CONFIG_CONTEXT_LIB_DIR}/service-config.sh"
CONFIG_CONTEXT_COMMON_LIB="${CONFIG_CONTEXT_LIB_DIR}/common.sh"

# shellcheck disable=SC1090
. "$CONFIG_CONTEXT_SCHEMA_LIB" || exit 1
# shellcheck disable=SC1090
. "$CONFIG_CONTEXT_SERVICE_CONFIG_LIB" || exit 1
# shellcheck disable=SC1090
. "$CONFIG_CONTEXT_COMMON_LIB" || exit 1

NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS=''
NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR=''
NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_PREVIEW=''

nordvpn_easy_assign_shell_var() {
	local var_name="$1"
	local value="$2"

	eval "$var_name='$(nordvpn_easy_shell_quote "$value")'"
}

nordvpn_easy_read_uci_option() {
	local uci_config="$1"
	local uci_section="$2"
	local option="$3"
	local key="${uci_config}.${uci_section}.${option}"
	local value=''

	value="$(uci -q get "$key" 2>/dev/null)" || {
		printf '%s' ''
		return 0
	}

	printf '%s' "$value"
}

nordvpn_easy_load_service_context() {
	local prefix="${1:-cfg_}"
	local uci_config="${2:-nordvpn_easy}"
	local uci_section="${3:-main}"
	local option raw_value normalized_value

	nordvpn_easy_migrate_service_config "$uci_config" "$uci_section" || return 1

	for option in $(nordvpn_easy_uci_options); do
		raw_value="$(nordvpn_easy_read_uci_option "$uci_config" "$uci_section" "$option")"
		normalized_value="$(nordvpn_easy_normalize_value "$option" "$raw_value")"
		nordvpn_easy_assign_shell_var "${prefix}${option}" "$normalized_value"
	done
}

nordvpn_easy_export_runtime_context_from_service() {
	local prefix="${1:-cfg_}"
	local option env_name value desired_enabled

	for option in $(nordvpn_easy_runtime_options); do
		env_name="$(nordvpn_easy_env_name "$option")"
		eval "value=\${${prefix}${option}-}"
		nordvpn_easy_assign_shell_var "$env_name" "$value"
	done

	eval "desired_enabled=\${${prefix}enabled-0}"
	desired_enabled="$(nordvpn_easy_normalize_value 'enabled' "$desired_enabled")"
	nordvpn_easy_assign_shell_var 'DESIRED_ENABLED' "$desired_enabled"
	nordvpn_easy_assign_shell_var 'ENABLED' "$desired_enabled"
}

nordvpn_easy_normalize_runtime_environment() {
	local option env_name current normalized
	local desired_enabled

	for option in $(nordvpn_easy_runtime_options); do
		env_name="$(nordvpn_easy_env_name "$option")"
		eval "current=\${$env_name-}"
		normalized="$(nordvpn_easy_normalize_value "$option" "$current")"
		nordvpn_easy_assign_shell_var "$env_name" "$normalized"
	done

	desired_enabled="${DESIRED_ENABLED-${ENABLED-0}}"
	desired_enabled="$(nordvpn_easy_normalize_value 'enabled' "$desired_enabled")"
	nordvpn_easy_assign_shell_var 'DESIRED_ENABLED' "$desired_enabled"
	nordvpn_easy_assign_shell_var 'ENABLED' "$desired_enabled"
}

nordvpn_easy_load_runtime_context_from_file() {
	local runtime_file="$1"

	[ -f "$runtime_file" ] || return 1

	# shellcheck disable=SC1090
	. "$runtime_file" || return 1
	nordvpn_easy_normalize_runtime_environment
	CONFIG_CONTEXT_SOURCE="file:${runtime_file}"
}

nordvpn_easy_load_runtime_context_from_uci() {
	local uci_config="${1:-nordvpn_easy}"
	local uci_section="${2:-main}"
	local prefix='ctx_'

	nordvpn_easy_load_service_context "$prefix" "$uci_config" "$uci_section" || return 1
	nordvpn_easy_export_runtime_context_from_service "$prefix" || return 1
	CONFIG_CONTEXT_SOURCE="uci:${uci_config}.${uci_section}"
}

nordvpn_easy_load_runtime_context() {
	local runtime_file="${1:-}"
	local uci_config="${2:-nordvpn_easy}"
	local uci_section="${3:-main}"

	if [ -n "$runtime_file" ] && [ -f "$runtime_file" ]; then
		nordvpn_easy_load_runtime_context_from_file "$runtime_file"
	else
		nordvpn_easy_load_runtime_context_from_uci "$uci_config" "$uci_section"
	fi
}

nordvpn_easy_enabled_flag_label() {
	case "$(nordvpn_easy_normalize_value 'enabled' "$1")" in
		1)
			printf '%s\n' 'checked/on'
			;;
		*)
			printf '%s\n' 'unchecked/off'
			;;
	esac
}

nordvpn_easy_debug_value_or_default() {
	if [ -n "$1" ]; then
		printf '%s\n' "$1"
	else
		printf '%s\n' "$2"
	fi
}

nordvpn_easy_service_debug_summary() {
	local prefix="${1:-cfg_}"
	local enabled mode country preferred_station preferred_hostname wan_if vpn_if token

	eval "enabled=\${${prefix}enabled-0}"
	eval "mode=\${${prefix}server_selection_mode-}"
	eval "country=\${${prefix}vpn_country-}"
	eval "preferred_station=\${${prefix}preferred_server_station-}"
	eval "preferred_hostname=\${${prefix}preferred_server_hostname-}"
	eval "wan_if=\${${prefix}wan_if-}"
	eval "vpn_if=\${${prefix}vpn_if-}"
	eval "token=\${${prefix}nordvpn_token-}"

	printf '%s' "enabled=${enabled:-0} ($(nordvpn_easy_enabled_flag_label "${enabled:-0}")), "
	printf '%s' "mode=$(nordvpn_easy_debug_value_or_default "${mode:-}" 'auto'), "
	printf '%s' "country=$(nordvpn_easy_debug_value_or_default "${country:-}" 'automatic'), "
	printf '%s' "preferred_station=$(nordvpn_easy_debug_value_or_default "${preferred_station:-}" 'automatic'), "
	printf '%s' "preferred_hostname=$(nordvpn_easy_debug_value_or_default "${preferred_hostname:-}" 'automatic'), "
	printf '%s' "wan_if=$(nordvpn_easy_debug_value_or_default "${wan_if:-}" 'unset'), "
	printf '%s' "vpn_if=$(nordvpn_easy_debug_value_or_default "${vpn_if:-}" 'unset'), "
	printf '%s' "token=$([ -n "${token:-}" ] && printf '%s' 'present' || printf '%s' 'missing')"
}

nordvpn_easy_runtime_env_debug_summary() {
	printf '%s' "enabled=${DESIRED_ENABLED:-0} ($(nordvpn_easy_enabled_flag_label "${DESIRED_ENABLED:-0}")), "
	printf '%s' "mode=$(nordvpn_easy_debug_value_or_default "${SERVER_SELECTION_MODE:-}" 'auto'), "
	printf '%s' "country=$(nordvpn_easy_debug_value_or_default "${VPN_COUNTRY:-}" 'automatic'), "
	printf '%s' "preferred_station=$(nordvpn_easy_debug_value_or_default "${PREFERRED_SERVER_STATION:-}" 'automatic'), "
	printf '%s' "preferred_hostname=$(nordvpn_easy_debug_value_or_default "${PREFERRED_SERVER_HOSTNAME:-}" 'automatic'), "
	printf '%s' "wan_if=$(nordvpn_easy_debug_value_or_default "${WAN_IF:-}" 'unset'), "
	printf '%s' "vpn_if=$(nordvpn_easy_debug_value_or_default "${VPN_IF:-}" 'unset'), "
	printf '%s' "vpn_addr=$(nordvpn_easy_debug_value_or_default "${VPN_ADDR:-}" 'unset'), "
	printf '%s' "vpn_port=$(nordvpn_easy_debug_value_or_default "${VPN_PORT:-}" 'unset'), "
	printf '%s' "token=$([ -n "${NORDVPN_TOKEN:-}" ] && printf '%s' 'present' || printf '%s' 'missing')"
}

nordvpn_easy_write_runtime_option() {
	local target_file="$1"
	local key="$2"
	local value="$3"

	printf "%s='%s'\n" "$key" "$(nordvpn_easy_shell_quote "$value")" >> "$target_file"
}

nordvpn_easy_runtime_expected_value_from_service() {
	local prefix="${1:-cfg_}"
	local option="$2"
	local value=''

	if [ "$option" = 'enabled' ]; then
		eval "value=\${${prefix}enabled-0}"
	else
		eval "value=\${${prefix}${option}-}"
	fi

	nordvpn_easy_normalize_value "$option" "$value"
}

nordvpn_easy_runtime_file_key_state() {
	local runtime_file="$1"
	local key="$2"
	local raw_value=''

	[ -f "$runtime_file" ] || {
		printf '%s\n' 'missing-file'
		return 0
	}

	raw_value="$(
		awk -v key="$key" '
			index($0, key "=") == 1 {
				print substr($0, length(key) + 2)
				exit
			}
		' "$runtime_file"
	)"

	if [ -z "$raw_value" ]; then
		printf '%s\n' 'missing'
	elif [ "$raw_value" = "''" ]; then
		printf '%s\n' 'empty'
	else
		printf '%s\n' 'present'
	fi
}

nordvpn_easy_runtime_file_key_preview() {
	local runtime_file="$1"
	local preview=''

	[ -f "$runtime_file" ] || {
		printf '%s\n' 'none'
		return 0
	}

	preview="$(
		awk -F= '
			NR <= 8 {
				if (count > 0)
					printf ","
				printf "%s", $1
				count++
			}
			END {
				if (count == 0)
					printf "none"
			}
		' "$runtime_file"
	)"

	printf '%s\n' "$preview"
}

nordvpn_easy_runtime_file_debug_summary() {
	local runtime_file="$1"

	printf '%s' "file_token=$(nordvpn_easy_runtime_file_key_state "$runtime_file" 'NORDVPN_TOKEN'), "
	printf '%s' "file_wan_if=$(nordvpn_easy_runtime_file_key_state "$runtime_file" 'WAN_IF'), "
	printf '%s' "file_vpn_if=$(nordvpn_easy_runtime_file_key_state "$runtime_file" 'VPN_IF'), "
	printf '%s' "file_vpn_addr=$(nordvpn_easy_runtime_file_key_state "$runtime_file" 'VPN_ADDR'), "
	printf '%s' "file_vpn_port=$(nordvpn_easy_runtime_file_key_state "$runtime_file" 'VPN_PORT')"
}

nordvpn_easy_validate_runtime_config() {
	local runtime_file="$1"
	local prefix="${2:-cfg_}"
	local missing_keys=''
	local key_state=''
	local roundtrip_result=''
	local env_key=''
	local option=''

	NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS='failed'
	NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR=''
	NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_PREVIEW="$(nordvpn_easy_runtime_file_key_preview "$runtime_file")"

	[ -f "$runtime_file" ] || {
		NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR='rendered runtime config file is missing'
		return 1
	}

	for env_key in DESIRED_ENABLED ENABLED $(nordvpn_easy_runtime_env_keys); do
		key_state="$(nordvpn_easy_runtime_file_key_state "$runtime_file" "$env_key")"
		if [ "$key_state" = 'missing' ] || [ "$key_state" = 'missing-file' ]; then
			missing_keys="${missing_keys} ${env_key}"
		fi
	done

	if [ -n "$missing_keys" ]; then
		NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR="missing rendered keys:${missing_keys# }"
		return 1
	fi

	roundtrip_result="$(
		(
			for env_key in DESIRED_ENABLED ENABLED $(nordvpn_easy_runtime_env_keys); do
				unset "$env_key"
			done

			# shellcheck disable=SC1090
			. "$runtime_file" || {
				printf '%s\n' 'source_failed'
				exit 0
			}

			env_key='DESIRED_ENABLED'
			[ "${DESIRED_ENABLED-__missing__}" = "$(nordvpn_easy_runtime_expected_value_from_service "$prefix" 'enabled')" ] || {
				printf '%s\n' "$env_key"
				exit 0
			}

			env_key='ENABLED'
			[ "${ENABLED-__missing__}" = "$(nordvpn_easy_runtime_expected_value_from_service "$prefix" 'enabled')" ] || {
				printf '%s\n' "$env_key"
				exit 0
			}

			for option in $(nordvpn_easy_runtime_options); do
				env_key="$(nordvpn_easy_env_name "$option")"
				eval "actual_value=\${$env_key-__missing__}"
				expected_value="$(nordvpn_easy_runtime_expected_value_from_service "$prefix" "$option")"
				[ "$actual_value" = "$expected_value" ] || {
					printf '%s\n' "$env_key"
					exit 0
				}
			done

			printf '%s\n' 'ok'
		)
	)"

	if [ "$roundtrip_result" != 'ok' ]; then
		NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR="round-trip mismatch for ${roundtrip_result}"
		return 1
	fi

	NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS='ok'
	NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR=''
	return 0
}

nordvpn_easy_runtime_config_validation_summary() {
	local status="${NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_STATUS:-unknown}"
	local reason="${NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_ERROR:-none}"
	local preview="${NORDVPN_EASY_RUNTIME_CONFIG_VALIDATION_PREVIEW:-none}"

	printf '%s' "render_validation=${status}, reason=${reason}, lhs_preview=${preview}"
}

nordvpn_easy_render_runtime_config() {
	local target_config="$1"
	local prefix="${2:-cfg_}"
	local result_var="${3:-}"
	local temp_dir=''
	local target_tmp=''
	local option env_name value desired_enabled
	local written_options=0
	local original_umask=''

	original_umask="$(umask)"
	umask 077
	mkdir -p "$(dirname "$target_config")" || return 1
	nordvpn_easy_mktemp_dir 'runtime-config' temp_dir || {
		umask "$original_umask"
		return 1
	}
	target_tmp="$(nordvpn_easy_temp_file_path "$temp_dir" "$(basename "$target_config").tmp")"
	: > "$target_tmp" || {
		rm -rf -- "$temp_dir"
		umask "$original_umask"
		return 1
	}

	eval "desired_enabled=\${${prefix}enabled-0}"
	desired_enabled="$(nordvpn_easy_normalize_value 'enabled' "$desired_enabled")"
	nordvpn_easy_write_runtime_option "$target_tmp" 'DESIRED_ENABLED' "$desired_enabled" || {
		rm -rf -- "$temp_dir"
		umask "$original_umask"
		return 1
	}
	nordvpn_easy_write_runtime_option "$target_tmp" 'ENABLED' "$desired_enabled" || {
		rm -rf -- "$temp_dir"
		umask "$original_umask"
		return 1
	}
	written_options=$((written_options + 2))

	for option in $(nordvpn_easy_runtime_options); do
		env_name="$(nordvpn_easy_env_name "$option")"
		eval "value=\${${prefix}${option}-}"
		nordvpn_easy_write_runtime_option "$target_tmp" "$env_name" "$value" || {
			rm -rf -- "$temp_dir"
			umask "$original_umask"
			return 1
		}
		written_options=$((written_options + 1))
	done

	mv "$target_tmp" "$target_config" || {
		rm -rf -- "$temp_dir"
		umask "$original_umask"
		return 1
	}
	rm -rf -- "$temp_dir"
	umask "$original_umask"

	if [ -n "$result_var" ]; then
		nordvpn_easy_assign_shell_var "$result_var" "$written_options"
	else
		printf '%s\n' "$written_options"
	fi
}
