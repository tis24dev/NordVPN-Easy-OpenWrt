#!/bin/sh

nordvpn_easy_migrate_service_config() {
	local uci_config="$1"
	local uci_section="$2"
	local section_ref="${uci_config}.${uci_section}"
	local changed=0
	local option old_value default_value normalized_value

	if ! uci -q get "$section_ref" >/dev/null 2>&1; then
		uci set "${section_ref}=nordvpn_easy"
		changed=1
	fi

	if uci -q get "${section_ref}.nordvpn_basic_token" >/dev/null 2>&1; then
		uci -q delete "${section_ref}.nordvpn_basic_token"
		changed=1
	fi

	for option in $(nordvpn_easy_uci_options); do
		default_value="$(nordvpn_easy_default "$option" 2>/dev/null || printf '%s' '')"
		if uci -q get "${section_ref}.${option}" >/dev/null 2>&1; then
			old_value="$(uci -q get "${section_ref}.${option}" 2>/dev/null)"
		else
			old_value=''
		fi

		normalized_value="$(nordvpn_easy_normalize_value "$option" "$old_value")"

		if ! uci -q get "${section_ref}.${option}" >/dev/null 2>&1 || [ "$normalized_value" != "$old_value" ]; then
			if [ -z "$normalized_value" ] && [ -z "$default_value" ]; then
				uci set "${section_ref}.${option}="
			else
				uci set "${section_ref}.${option}=$normalized_value"
			fi
			changed=1
		fi
	done

	if [ "$changed" -eq 1 ]; then
		uci -q commit "$uci_config" || {
			printf '%s\n' "nordvpn-easy: failed to commit migrated config" >&2
			return 1
		}
	fi
}
