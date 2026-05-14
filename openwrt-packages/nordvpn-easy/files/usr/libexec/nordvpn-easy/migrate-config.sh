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

read_existing_option() {
	uci -q get "${UCI_CONFIG}.${UCI_SECTION}.${1}" || printf '%s' ''
}

snapshot_existing_config() {
	local option old_value normalized_value

	for option in $(nordvpn_easy_uci_options); do
		old_value="$(read_existing_option "$option")"
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
