#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"
GENERATION_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/generation.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "expected: $1" >&2
		printf '%s\n' "actual:   $2" >&2
		exit 1
	fi
}

assert_ne() {
	if [ "$1" = "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "both values: $1" >&2
		exit 1
	fi
}

# Point the runtime-token sentinel at the temp dir before sourcing.
NORDVPN_EASY_RUNTIME_TOKEN_FILE="$TMP_DIR/runtime-token"

# shellcheck disable=SC1090
. "$SCHEMA_LIB"
# shellcheck disable=SC1090
. "$GENERATION_LIB"

# Fake uci backing only applied_fingerprint, with a commit counter.
UCI_STORE="$TMP_DIR/applied_fp"
UCI_COMMIT_COUNT=0
uci() {
	a="$1"
	if [ "$a" = '-q' ]; then
		shift
		a="$1"
	fi
	case "$a" in
		get)
			case "$2" in
				nordvpn_easy.main.applied_fingerprint)
					[ -f "$UCI_STORE" ] && cat "$UCI_STORE" || return 1
					;;
				*) return 1 ;;
			esac
			;;
		set)
			case "$2" in
				nordvpn_easy.main.applied_fingerprint=*)
					printf '%s' "${2#*=}" > "$UCI_STORE"
					;;
				*) return 1 ;;
			esac
			;;
		commit)
			UCI_COMMIT_COUNT=$((UCI_COMMIT_COUNT + 1))
			;;
		*) return 1 ;;
	esac
}

# Desired-config environment (a subset; the rest hash as empty).
NORDVPN_TOKEN='secret-one'
VPN_COUNTRY='IT'
SERVER_SELECTION_MODE='auto'
KILL_SWITCH_ENABLED='1'

FP1="$(nordvpn_easy_config_fingerprint)"
assert_ne '' "$FP1" 'config fingerprint is non-empty (sha256sum present)'

FP_REPEAT="$(nordvpn_easy_config_fingerprint)"
assert_eq "$FP1" "$FP_REPEAT" 'fingerprint is stable for identical desired config'

# Token VALUE must not affect the fingerprint (presence bit only).
NORDVPN_TOKEN='secret-two'
FP_TOKEN_CHANGED="$(nordvpn_easy_config_fingerprint)"
assert_eq "$FP1" "$FP_TOKEN_CHANGED" 'changing the token value does not change the fingerprint'

# Token presence DOES affect the fingerprint.
NORDVPN_TOKEN=''
FP_TOKEN_ABSENT="$(nordvpn_easy_config_fingerprint)"
assert_ne "$FP1" "$FP_TOKEN_ABSENT" 'removing the token (presence bit) changes the fingerprint'
NORDVPN_TOKEN='secret-one'

# A real desired-config change changes the fingerprint.
VPN_COUNTRY='DE'
FP_COUNTRY_CHANGED="$(nordvpn_easy_config_fingerprint)"
assert_ne "$FP1" "$FP_COUNTRY_CHANGED" 'changing the country changes the fingerprint'
VPN_COUNTRY='IT'

# --- mark_applied + boot_needs_bringup -------------------------------------
nordvpn_easy_vpn_link_is_present() { return 0; }

# enabled=0 never needs bring-up.
DESIRED_ENABLED='0'
if nordvpn_easy_boot_needs_bringup; then
	printf '%s\n' 'FAIL: a disabled config must not need bring-up' >&2
	exit 1
fi

# enabled=1 with no sentinel yet -> needs bring-up.
DESIRED_ENABLED='1'
nordvpn_easy_boot_needs_bringup || {
	printf '%s\n' 'FAIL: enabled config without a runtime token must need bring-up' >&2
	exit 1
}

# Record the live runtime; the sentinel and applied_fingerprint are written.
nordvpn_easy_mark_applied "$FP1"
assert_eq "$FP1" "$(cat "$NORDVPN_EASY_RUNTIME_TOKEN_FILE")" 'mark_applied writes the runtime token sentinel'
assert_eq "$FP1" "$(nordvpn_easy_applied_fingerprint)" 'mark_applied persists applied_fingerprint'
assert_eq '1' "$UCI_COMMIT_COUNT" 'mark_applied commits applied_fingerprint once'

# Re-marking the same fingerprint must not write flash again.
nordvpn_easy_mark_applied "$FP1"
assert_eq '1' "$UCI_COMMIT_COUNT" 'mark_applied does not re-commit an unchanged applied_fingerprint'

# Sentinel matches desired config and the link is present -> no bring-up.
if nordvpn_easy_boot_needs_bringup; then
	printf '%s\n' 'FAIL: a caught-up runtime with the link present must not need bring-up' >&2
	exit 1
fi

# The link being absent forces bring-up even when the sentinel matches.
nordvpn_easy_vpn_link_is_present() { return 1; }
nordvpn_easy_boot_needs_bringup || {
	printf '%s\n' 'FAIL: a down link must need bring-up' >&2
	exit 1
}
nordvpn_easy_vpn_link_is_present() { return 0; }

# A desired-config change makes the sentinel stale -> needs bring-up.
VPN_COUNTRY='FR'
nordvpn_easy_boot_needs_bringup || {
	printf '%s\n' 'FAIL: a config change must make the runtime token stale and need bring-up' >&2
	exit 1
}

printf '%s\n' 'test-generation.sh: ok'
