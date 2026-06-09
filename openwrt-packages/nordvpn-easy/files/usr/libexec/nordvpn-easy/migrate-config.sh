#!/bin/sh

set -eu

UCI_CONFIG="${NORDVPN_EASY_UCI_CONFIG:-nordvpn_easy}"
UCI_SECTION="${NORDVPN_EASY_UCI_SECTION:-main}"
CONFIG_FILE="${NORDVPN_EASY_CONFIG_FILE:-/etc/config/nordvpn_easy}"
# Keep the old OPKG variable as a compatibility alias for existing test harnesses or local scripts.
LEGACY_CONFIG_FILE="${NORDVPN_EASY_LEGACY_CONFIG_FILE:-${NORDVPN_EASY_OPKG_CONFIG_FILE:-/etc/config/nordvpn_easy-opkg}}"
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

read_legacy_option() {
	read_uci_file_option "$LEGACY_CONFIG_FILE" "$1"
}

read_snapshot_option() {
	local option="$1"
	local active_value legacy_value normalized_value default_value

	default_value="$(nordvpn_easy_default "$option" 2>/dev/null || printf '%s' '')"

	if active_option_exists "$option"; then
		active_value="$(read_active_option "$option")"
		normalized_value="$(nordvpn_easy_normalize_value "$option" "$active_value")"
		if [ "$option" = 'config_schema_version' ] || [ "$normalized_value" != "$default_value" ]; then
			printf '%s' "$active_value"
			return 0
		fi
	fi

	if legacy_value="$(read_legacy_option "$option")"; then
		printf '%s' "$legacy_value"
		return 0
	fi

	if active_option_exists "$option"; then
		printf '%s' "$active_value"
		return 0
	fi

	printf '%s' ''
}

snapshot_existing_config() {
	local option old_value normalized_value

	for option in $(nordvpn_easy_uci_options); do
		old_value="$(read_snapshot_option "$option")"
		normalized_value="$(nordvpn_easy_normalize_value "$option" "$old_value")"
		if [ "$option" = 'post_restart_delay' ] && [ "$normalized_value" = '60' ]; then
			normalized_value='30'
		fi
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

# Skip the migration entirely when the active config already carries the current
# schema version: re-running it on every postinst would needlessly re-normalize
# values and repeat one-time bumps (e.g. post_restart_delay 60 -> 30).
if [ -r "$CONFIG_FILE" ] && active_option_exists 'config_schema_version' &&
	[ "$(read_active_option 'config_schema_version')" = "$NORDVPN_EASY_SCHEMA_VERSION" ]; then
	exit 0
fi

snapshot_existing_config
install_template_config
apply_snapshot_to_uci
rm -f -- "$LEGACY_CONFIG_FILE"
