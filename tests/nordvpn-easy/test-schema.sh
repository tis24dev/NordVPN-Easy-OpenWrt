#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"

# shellcheck disable=SC1090
. "$SCHEMA_LIB"

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

assert_eq 'auto' "$(nordvpn_easy_default server_selection_mode)" 'default server selection mode'
assert_eq '86400' "$(nordvpn_easy_default server_cache_ttl)" 'default server cache ttl'
assert_eq '1' "$(nordvpn_easy_normalize_value enabled yes)" 'boolean normalization for yes'
assert_eq '1' "$(nordvpn_easy_normalize_value enabled true)" 'boolean normalization for true'
assert_eq 'manual' "$(nordvpn_easy_normalize_value server_selection_mode manual)" 'manual mode normalization'
assert_eq 'auto' "$(nordvpn_easy_normalize_value server_selection_mode broken)" 'invalid mode normalization'
assert_eq '86400' "$(nordvpn_easy_normalize_value server_cache_ttl not-a-number)" 'invalid ttl normalization'
assert_eq "$NORDVPN_EASY_SCHEMA_VERSION" "$(nordvpn_easy_normalize_value config_schema_version 0)" 'schema version normalization'

unset NORDVPN_TOKEN
unset CHECK_CRON_SCHEDULE
SERVER_CACHE_TTL=''
export SERVER_CACHE_TTL
nordvpn_easy_apply_env_defaults

assert_eq '' "${NORDVPN_TOKEN:-}" 'empty token default'
assert_eq '* * * * *' "$CHECK_CRON_SCHEDULE" 'cron default with spaces'
assert_eq '86400' "$SERVER_CACHE_TTL" 'environment ttl default'

printf '%s\n' 'test-schema.sh: ok'
