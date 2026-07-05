#!/bin/sh

# set -u catches unset-variable bugs, but deliberately NOT set -e: the migration
# must never abort partway through and leave the live config half-written. The
# new config is built off to the side and swapped in with a single atomic rename
# at the very end, and the few steps that must succeed are checked explicitly.
set -u

UCI_CONFIG="${NORDVPN_EASY_UCI_CONFIG:-nordvpn_easy}"
UCI_SECTION="${NORDVPN_EASY_UCI_SECTION:-main}"
CONFIG_FILE="${NORDVPN_EASY_CONFIG_FILE:-/etc/config/nordvpn_easy}"
# Keep the old OPKG variable as a compatibility alias for existing test harnesses or local scripts.
LEGACY_CONFIG_FILE="${NORDVPN_EASY_LEGACY_CONFIG_FILE:-${NORDVPN_EASY_OPKG_CONFIG_FILE:-/etc/config/nordvpn_easy-opkg}}"
TEMPLATE_FILE="${NORDVPN_EASY_TEMPLATE_FILE:-/usr/share/nordvpn-easy/defaults/nordvpn_easy}"
LIB_DIR="${NORDVPN_EASY_LIB_DIR:-/usr/libexec/nordvpn-easy/lib}"
SCHEMA_LIB="${LIB_DIR}/schema.sh"
BUILD_DIR=''
# Schema version that introduces the autonomous-recovery cron floor, and the
# default cadence to seed. See seed_recovery_floor_if_needed.
NORDVPN_EASY_RECOVERY_FLOOR_SCHEMA="${NORDVPN_EASY_RECOVERY_FLOOR_SCHEMA:-4}"
NORDVPN_EASY_RECOVERY_FLOOR_SCHEDULE="${NORDVPN_EASY_RECOVERY_FLOOR_SCHEDULE:-*/15 * * * *}"

cleanup() {
	[ -n "$BUILD_DIR" ] && rm -rf -- "$BUILD_DIR"
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

# One-time recovery-floor seeding. A periodic health check must exist by default,
# but BusyBox crond never read the old /etc/cron.d hook, so existing installs ran
# with no autonomous recovery. When this migration crosses the schema version that
# introduces the floor (or on a fresh install), seed a default cron cadence ONLY
# when the user has not set one. The migration short-circuits once the active
# config already carries the current schema version, so this seeds exactly once:
# a user who later clears check_cron_schedule keeps it empty (periodic checks off),
# and a future schema bump (prior >= the floor version) does not re-seed it.
seed_recovery_floor_if_needed() {
	local prior_schema

	[ -z "${snapshot_check_cron_schedule:-}" ] || return 0

	prior_schema="$(read_active_option config_schema_version)"
	case "$prior_schema" in
		''|*[!0-9]*)
			: # fresh install or unreadable prior version -> seed
			;;
		*)
			[ "$prior_schema" -lt "$NORDVPN_EASY_RECOVERY_FLOOR_SCHEMA" ] || return 0
			;;
	esac

	snapshot_check_cron_schedule="$(nordvpn_easy_normalize_value check_cron_schedule "$NORDVPN_EASY_RECOVERY_FLOOR_SCHEDULE")"
}

# Build the fully migrated config off to the side and swap it into place with a
# single atomic rename. The new config is assembled in a sibling workspace on the
# same filesystem as the live config (so the final mv is an atomic rename, not a
# cross-filesystem copy), with uci pointed at that workspace via an isolated
# confdir/delta so the live config is never touched until the swap. A crash or an
# unexpected value at any earlier point leaves the original config fully intact
# instead of a template-only file with the user's settings lost.
build_migrated_config() {
	local config_dir delta_dir migrated option normalized_value

	[ -r "$TEMPLATE_FILE" ] || {
		printf '%s\n' "nordvpn-easy: missing config template $TEMPLATE_FILE" >&2
		return 1
	}

	config_dir="$(dirname "$CONFIG_FILE")"
	mkdir -p "$config_dir" || return 1

	BUILD_DIR="$(mktemp -d "${config_dir}/.nordvpn-easy-migrate.XXXXXX")" || {
		BUILD_DIR=''
		printf '%s\n' "nordvpn-easy: failed to create migration workspace" >&2
		return 1
	}
	delta_dir="${BUILD_DIR}/delta"
	migrated="${BUILD_DIR}/${UCI_CONFIG}"
	mkdir -p "$delta_dir" || return 1

	cp "$TEMPLATE_FILE" "$migrated" || {
		printf '%s\n' "nordvpn-easy: failed to seed migration workspace from template" >&2
		return 1
	}

	uci -c "$BUILD_DIR" -t "$delta_dir" set "${UCI_CONFIG}.${UCI_SECTION}=nordvpn_easy" || {
		printf '%s\n' "nordvpn-easy: failed to initialize migrated config section" >&2
		return 1
	}
	# Best-effort per-option restore: a single unexpected value must not abort the
	# whole migration (that is why set -e is off). Any option uci rejects simply
	# keeps the template default in the built file.
	for option in $(nordvpn_easy_uci_options); do
		eval "normalized_value=\${snapshot_${option}-}"
		normalized_value="$(nordvpn_easy_normalize_value "$option" "$normalized_value")"
		uci -c "$BUILD_DIR" -t "$delta_dir" set "${UCI_CONFIG}.${UCI_SECTION}.${option}=${normalized_value}" ||
			printf '%s\n' "nordvpn-easy: kept template default for option '$option'" >&2
	done

	uci -c "$BUILD_DIR" -t "$delta_dir" -q delete "${UCI_CONFIG}.${UCI_SECTION}.nordvpn_basic_token" >/dev/null 2>&1 || true
	uci -c "$BUILD_DIR" -t "$delta_dir" commit "$UCI_CONFIG" || {
		printf '%s\n' "nordvpn-easy: failed to build migrated config" >&2
		return 1
	}

	[ -s "$migrated" ] || {
		printf '%s\n' "nordvpn-easy: built migrated config is empty; refusing to swap" >&2
		return 1
	}
	chmod 0600 "$migrated" || return 1

	mv "$migrated" "$CONFIG_FILE" || {
		printf '%s\n' "nordvpn-easy: failed to swap migrated config into place" >&2
		return 1
	}

	rm -rf -- "$BUILD_DIR"
	BUILD_DIR=''
}

# Skip the migration entirely when the active config already carries the current
# schema version: re-running it on every postinst would needlessly re-normalize
# values and repeat one-time bumps (e.g. post_restart_delay 60 -> 30).
if [ -r "$CONFIG_FILE" ] && active_option_exists 'config_schema_version' &&
	[ "$(read_active_option 'config_schema_version')" = "$NORDVPN_EASY_SCHEMA_VERSION" ]; then
	rm -f -- "$LEGACY_CONFIG_FILE"
	exit 0
fi

snapshot_existing_config
seed_recovery_floor_if_needed
build_migrated_config || exit 1
rm -f -- "$LEGACY_CONFIG_FILE"
