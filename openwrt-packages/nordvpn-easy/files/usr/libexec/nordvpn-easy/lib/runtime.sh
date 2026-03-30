#!/bin/sh

nordvpn_easy_pluralize_time_unit() {
	local value="$1"
	local singular="$2"
	local plural="$3"

	if [ "$value" -eq 1 ]; then
		printf '%s %s' "$value" "$singular"
	else
		printf '%s %s' "$value" "$plural"
	fi
}

nordvpn_easy_format_relative_age() {
	local total_seconds="$1"
	local days hours minutes seconds output=''

	case "$total_seconds" in
		''|*[!0-9]*)
			total_seconds=0
			;;
	esac

	days=$((total_seconds / 86400))
	hours=$(((total_seconds % 86400) / 3600))
	minutes=$(((total_seconds % 3600) / 60))
	seconds=$((total_seconds % 60))

	if [ "$days" -gt 0 ]; then
		output="$(nordvpn_easy_pluralize_time_unit "$days" 'day' 'days')"
		[ "$hours" -gt 0 ] && output="$output, $(nordvpn_easy_pluralize_time_unit "$hours" 'hour' 'hours')"
	elif [ "$hours" -gt 0 ]; then
		output="$(nordvpn_easy_pluralize_time_unit "$hours" 'hour' 'hours')"
		[ "$minutes" -gt 0 ] && output="$output, $(nordvpn_easy_pluralize_time_unit "$minutes" 'minute' 'minutes')"
	elif [ "$minutes" -gt 0 ]; then
		output="$(nordvpn_easy_pluralize_time_unit "$minutes" 'minute' 'minutes')"
		[ "$seconds" -gt 0 ] && output="$output, $(nordvpn_easy_pluralize_time_unit "$seconds" 'second' 'seconds')"
	else
		output="$(nordvpn_easy_pluralize_time_unit "$seconds" 'second' 'seconds')"
	fi

	printf '%s ago\n' "$output"
}

nordvpn_easy_humanize_handshake_age() {
	local epoch="$1"
	local now diff

	case "$epoch" in
		''|*[!0-9]*)
			printf '%s\n' 'Never'
			return 0
			;;
	esac

	[ "$epoch" -gt 0 ] || {
		printf '%s\n' 'Never'
		return 0
	}

	now="$(date +%s 2>/dev/null)"
	case "$now" in
		''|*[!0-9]*)
			printf '%s\n' 'Unknown'
			return 0
			;;
	esac

	diff=$((now - epoch))
	[ "$diff" -lt 0 ] && diff=0
	nordvpn_easy_format_relative_age "$diff"
}

nordvpn_easy_handshake_epoch_indicates_connection() {
	local epoch="$1"
	local now diff

	case "$epoch" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	[ "$epoch" -gt 0 ] || return 1
	now="$(date +%s 2>/dev/null)"
	case "$now" in
		''|*[!0-9]*)
			return 1
			;;
	esac

	diff=$((now - epoch))
	[ "$diff" -lt 0 ] && diff=0
	[ "$diff" -le 7200 ]
}

nordvpn_easy_format_human_bytes() {
	local bytes="$1"

	case "$bytes" in
		''|*[!0-9]*)
			bytes=0
			;;
	esac

	awk -v bytes="$bytes" '
		BEGIN {
			split("B KiB MiB GiB TiB PiB", units, " ")
			size = bytes + 0
			unit = 1
			while (size >= 1024 && unit < 6) {
				size /= 1024
				unit++
			}

			if (unit == 1)
				printf "%.0f %s\n", size, units[unit]
			else
				printf "%.2f %s\n", size, units[unit]
		}
	'
}

nordvpn_easy_parse_wg_dump_peer() {
	printf '%s\n' "$1" | awk '
		NR == 2 {
			endpoint = ($3 != "" && $3 != "(none)") ? $3 : "N/A"
			handshake = ($5 ~ /^[0-9]+$/) ? $5 : 0
			rx = ($6 ~ /^[0-9]+$/) ? $6 : 0
			tx = ($7 ~ /^[0-9]+$/) ? $7 : 0
			printf "%s\t%s\t%s\t%s\n", endpoint, handshake, rx, tx
			found = 1
			exit
		}
		END {
			if (!found)
				printf "N/A\t0\t0\t0\n"
		}
	'
}
