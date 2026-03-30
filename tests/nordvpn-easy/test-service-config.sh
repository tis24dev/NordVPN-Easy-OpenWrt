#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"
SERVICE_CONFIG_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/service-config.sh"
TMP_DIR="$(mktemp -d)"
UCI_DB="$TMP_DIR/uci"
COMMIT_COUNT=0

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

mkdir -p "$UCI_DB"

# shellcheck disable=SC1090
. "$SCHEMA_LIB"
# shellcheck disable=SC1090
. "$SERVICE_CONFIG_LIB"

assert_eq() {
	expected="$1"
	actual="$2"
	label="$3"

	if [ "$expected" != "$actual" ]; then
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "expected: $expected" >&2
		printf '%s\n' "actual:   $actual" >&2
		exit 1
	fi
}

uci_path() {
	printf '%s/%s\n' "$UCI_DB" "$(printf '%s' "$1" | tr '.=' '__')"
}

uci() {
	quiet=0
	if [ "${1:-}" = '-q' ]; then
		quiet=1
		shift
	fi

	cmd="${1:-}"
	shift || true

	case "$cmd" in
		get)
			file="$(uci_path "$1")"
			[ -f "$file" ] || return 1
			cat "$file"
			;;
		set)
			target="$1"
			key="${target%%=*}"
			value="${target#*=}"
			printf '%s' "$value" > "$(uci_path "$key")"
			;;
		delete)
			rm -f "$(uci_path "$1")"
			;;
		commit)
			COMMIT_COUNT=$((COMMIT_COUNT + 1))
			;;
		*)
			[ "$quiet" -eq 1 ] || printf '%s\n' "unsupported uci command: $cmd" >&2
			return 1
			;;
	esac
}

printf '%s' 'legacy' > "$(uci_path 'nordvpn_easy.main.nordvpn_basic_token')"
printf '%s' 'yes' > "$(uci_path 'nordvpn_easy.main.enabled')"
printf '%s' 'oops' > "$(uci_path 'nordvpn_easy.main.server_cache_ttl')"

nordvpn_easy_migrate_service_config nordvpn_easy main

assert_eq '1' "$(cat "$(uci_path 'nordvpn_easy.main.enabled')")" 'enabled normalized'
assert_eq '86400' "$(cat "$(uci_path 'nordvpn_easy.main.server_cache_ttl')")" 'ttl backfilled'
assert_eq "$NORDVPN_EASY_SCHEMA_VERSION" "$(cat "$(uci_path 'nordvpn_easy.main.config_schema_version')")" 'schema version set'
[ ! -f "$(uci_path 'nordvpn_easy.main.nordvpn_basic_token')" ] || {
	printf '%s\n' 'FAIL: legacy token key was not removed' >&2
	exit 1
}
assert_eq '1' "$COMMIT_COUNT" 'single migration commit'

printf '%s\n' 'test-service-config.sh: ok'
