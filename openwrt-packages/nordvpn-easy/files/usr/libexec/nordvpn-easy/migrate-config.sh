#!/bin/sh

set -eu

UCI_CONFIG="${NORDVPN_EASY_UCI_CONFIG:-nordvpn_easy}"
UCI_SECTION="${NORDVPN_EASY_UCI_SECTION:-main}"
CONFIG_FILE="${NORDVPN_EASY_CONFIG_FILE:-/etc/config/nordvpn_easy}"
OPKG_CONFIG_FILE="${NORDVPN_EASY_OPKG_CONFIG_FILE:-/etc/config/nordvpn_easy-opkg}"
TEMPLATE_FILE="${NORDVPN_EASY_TEMPLATE_FILE:-/usr/share/nordvpn-easy/defaults/nordvpn_easy}"
LIB_DIR="${NORDVPN_EASY_LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"
SCHEMA_LIB="${LIB_DIR}/schema.sh"
TEMP_CONFIG=''

cleanup() {
	[ -n "$TEMP_CONFIG" ] && rm -f -- "$TEMP_CONFIG"
	return 0
}

trap cleanup EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$SCHEMA_LIB" || exit 1

read_active_option() {
	uci -q get "${UCI_CONFIG}.${UCI_SECTION}.${1}" || printf '%s' ''
}

active_option_exists() {
	uci -q get "${UCI_CONFIG}.${UCI_SECTION}.${1}" >/dev/null 2>&1
}

read_uci_file_option() {
	local file_path="$1"
	local option="$2"

	[ -r "$file_path" ] || return 1

	awk -v wanted="$option" '
		function trim(value) {
			sub(/^[[:space:]]+/, "", value)
			sub(/[[:space:]]+$/, "", value)
			return value
		}

		function unquote(value, quote) {
			value = trim(value)
			quote = substr(value, 1, 1)
			if ((quote == "\047" || quote == "\"") && substr(value, length(value), 1) == quote)
				value = substr(value, 2, length(value) - 2)
			return value
		}

		$1 == "config" {
			section_type = unquote($2)
			section_name = unquote($3)
			in_main = (section_type == "nordvpn_easy" && section_name == "main")
		}

		in_main && $1 == "option" && $2 == wanted {
			value = $0
			sub(/^[[:space:]]*option[[:space:]]+[^[:space:]]+[[:space:]]+/, "", value)
			print unquote(value)
			found = 1
			exit
		}

		END {
			exit(found ? 0 : 1)
		}
	' "$file_path"
}

read_opkg_option() {
	read_uci_file_option "$OPKG_CONFIG_FILE" "$1"
}

opkg_option_exists() {
	read_opkg_option "$1" >/dev/null 2>&1
}

source_has_custom_values() {
	local source="$1"
	local option value normalized_value default_value

	for option in $(nordvpn_easy_uci_options); do
		[ "$option" = 'config_schema_version' ] && continue

		case "$source" in
			active)
				active_option_exists "$option" || continue
				value="$(read_active_option "$option")"
				;;
			opkg)
				value="$(read_opkg_option "$option")" || continue
				;;
			*)
				return 1
				;;
		esac

		normalized_value="$(nordvpn_easy_normalize_value "$option" "$value")"
		default_value="$(nordvpn_easy_default "$option" 2>/dev/null || printf '%s' '')"
		[ "$normalized_value" != "$default_value" ] && return 0
	done

	return 1
}

read_snapshot_option() {
	local option="$1"
	local active_has_custom="$2"
	local opkg_has_custom="$3"
	local value

	if [ "$opkg_has_custom" -eq 1 ] && [ "$active_has_custom" -eq 0 ] && value="$(read_opkg_option "$option")"; then
		printf '%s' "$value"
		return 0
	fi

	if active_option_exists "$option"; then
		read_active_option "$option"
		return 0
	fi

	if value="$(read_opkg_option "$option")"; then
		printf '%s' "$value"
		return 0
	fi

	printf '%s' ''
}

snapshot_existing_config() {
	local option old_value normalized_value
	local active_has_custom=0
	local opkg_has_custom=0

	source_has_custom_values active && active_has_custom=1
	source_has_custom_values opkg && opkg_has_custom=1

	for option in $(nordvpn_easy_uci_options); do
		old_value="$(read_snapshot_option "$option" "$active_has_custom" "$opkg_has_custom")"
		normalized_value="$(nordvpn_easy_normalize_value "$option" "$old_value")"
		eval "snapshot_${option}='$(nordvpn_easy_shell_quote "$normalized_value")'"
	done
}

install_template_config() {
	local config_dir

	[ -r "$TEMPLATE_FILE" ] || {
		printf '%s\n' "nordvpn-easy: missing config template $TEMPLATE_FILE" >&2
		return 1
	}

	config_dir="$(dirname "$CONFIG_FILE")"
	mkdir -p "$config_dir"
	TEMP_CONFIG="${CONFIG_FILE}.nordvpn-easy.$$"
	cp "$TEMPLATE_FILE" "$TEMP_CONFIG"
	chmod 0600 "$TEMP_CONFIG"
	mv "$TEMP_CONFIG" "$CONFIG_FILE"
	TEMP_CONFIG=''
}

apply_snapshot_to_uci() {
	local option normalized_value

	uci set "${UCI_CONFIG}.${UCI_SECTION}=nordvpn_easy"
	for option in $(nordvpn_easy_uci_options); do
		eval "normalized_value=\${snapshot_${option}-}"
		normalized_value="$(nordvpn_easy_normalize_value "$option" "$normalized_value")"
		uci set "${UCI_CONFIG}.${UCI_SECTION}.${option}=${normalized_value}"
	done

	uci -q delete "${UCI_CONFIG}.${UCI_SECTION}.nordvpn_basic_token" >/dev/null 2>&1 || true
	uci -q commit "$UCI_CONFIG" || {
		printf '%s\n' "nordvpn-easy: failed to commit migrated config" >&2
		return 1
	}
}

snapshot_existing_config
install_template_config
apply_snapshot_to_uci
rm -f -- "$OPKG_CONFIG_FILE"
