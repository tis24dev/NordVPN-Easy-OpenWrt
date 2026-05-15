#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
MIGRATOR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/migrate-config.sh"
SCHEMA_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/schema.sh"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TEMPLATE_FILE="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/share/nordvpn-easy/defaults/nordvpn_easy"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
FAKE_UCI_STORE_DIR="$TMP_DIR/uci-store"
FAKE_UCI_CONFIG_FILE="$TMP_DIR/etc/config/nordvpn_easy"
FAKE_UCI_OPTIONS_FILE="$TMP_DIR/options"
FAKE_LEGACY_CONFIG_FILE="$TMP_DIR/etc/config/nordvpn_easy-opkg"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

mkdir -p "$FAKE_BIN" "$FAKE_UCI_STORE_DIR" "$(dirname "$FAKE_UCI_CONFIG_FILE")"

# shellcheck disable=SC1090
. "$SCHEMA_LIB"
nordvpn_easy_uci_options | sed 's/^[[:space:]]*//' > "$FAKE_UCI_OPTIONS_FILE"

cat > "$FAKE_BIN/uci" <<'EOF'
#!/bin/sh

set -eu

[ "${1:-}" = '-q' ] && shift
cmd="${1:-}"
shift || true

store_dir="${FAKE_UCI_STORE_DIR:?}"
config_file="${FAKE_UCI_CONFIG_FILE:?}"
options_file="${FAKE_UCI_OPTIONS_FILE:?}"

option_from_key() {
	key="$1"
	case "$key" in
		*.*.*) printf '%s\n' "${key##*.}" ;;
		*) printf '%s\n' '__section__' ;;
	esac
}

case "$cmd" in
	get)
		option="$(option_from_key "$1")"
		if [ "$option" = '__section__' ]; then
			[ -f "$store_dir/__section__" ] || exit 1
			cat "$store_dir/__section__"
			exit 0
		fi
		[ -f "$store_dir/$option" ] || exit 1
		cat "$store_dir/$option"
		;;
	set)
		target="$1"
		key="${target%%=*}"
		value="${target#*=}"
		option="$(option_from_key "$key")"
		mkdir -p "$store_dir"
		printf '%s' "$value" > "$store_dir/$option"
		;;
	delete)
		option="$(option_from_key "$1")"
		rm -f "$store_dir/$option"
		;;
	commit)
		mkdir -p "$(dirname "$config_file")"
		{
			printf "config nordvpn_easy 'main'\n"
			while IFS= read -r option; do
				[ -n "$option" ] || continue
				[ -f "$store_dir/$option" ] || continue
				printf "\toption %s '%s'\n" "$option" "$(cat "$store_dir/$option")"
			done < "$options_file"
		} > "$config_file"
		;;
	*)
		printf '%s\n' "unsupported fake uci command: $cmd" >&2
		exit 1
		;;
esac
EOF
chmod +x "$FAKE_BIN/uci"

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

assert_file_has_line() {
	expected_line="$1"
	file_path="$2"
	label="$3"

	grep -Fx "$expected_line" "$file_path" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "missing line: $expected_line" >&2
		exit 1
	}
}

assert_file_missing_line() {
	unexpected_line="$1"
	file_path="$2"
	label="$3"

	! grep -Fx "$unexpected_line" "$file_path" >/dev/null 2>&1 || {
		printf '%s\n' "FAIL: $label" >&2
		printf '%s\n' "unexpected line: $unexpected_line" >&2
		exit 1
	}
}

reset_fake_uci() {
	rm -rf "$FAKE_UCI_STORE_DIR"
	mkdir -p "$FAKE_UCI_STORE_DIR" "$(dirname "$FAKE_UCI_CONFIG_FILE")"
}

set_store_value() {
	printf '%s' "$2" > "$FAKE_UCI_STORE_DIR/$1"
}

run_migrator() {
	config_file="$FAKE_UCI_CONFIG_FILE"
	legacy_config_file="$FAKE_LEGACY_CONFIG_FILE"

	PATH="$FAKE_BIN:$PATH" \
	FAKE_UCI_STORE_DIR="$FAKE_UCI_STORE_DIR" \
	FAKE_UCI_CONFIG_FILE="$config_file" \
	FAKE_UCI_OPTIONS_FILE="$FAKE_UCI_OPTIONS_FILE" \
	NORDVPN_EASY_CONFIG_FILE="$config_file" \
	NORDVPN_EASY_LEGACY_CONFIG_FILE="$legacy_config_file" \
	NORDVPN_EASY_TEMPLATE_FILE="$TEMPLATE_FILE" \
	NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
	"$MIGRATOR"
}

reset_fake_uci
rm -f "$FAKE_UCI_CONFIG_FILE" "$FAKE_LEGACY_CONFIG_FILE"
run_migrator

[ -f "$FAKE_UCI_CONFIG_FILE" ] || {
	printf '%s\n' 'FAIL: first install did not create generated UCI config' >&2
	exit 1
}

assert_file_has_line "	option enabled '0'" "$FAKE_UCI_CONFIG_FILE" 'first install writes default enabled flag'
assert_file_has_line "	option vpn_if 'wg0'" "$FAKE_UCI_CONFIG_FILE" 'first install writes default VPN interface'
assert_file_has_line "	option config_schema_version '$NORDVPN_EASY_SCHEMA_VERSION'" "$FAKE_UCI_CONFIG_FILE" 'first install writes current schema version'

reset_fake_uci
cat > "$FAKE_UCI_CONFIG_FILE" <<'EOF'
config nordvpn_easy 'main'
	option enabled 'yes'
	option nordvpn_token 'secret-token'
	option nordvpn_basic_token 'legacy-token'
	option vpn_country 'AT'
	option server_selection_mode 'manual'
	option preferred_server_hostname 'at12.nordvpn.com'
	option preferred_server_station 'at12'
	option wan_if 'wan6'
	option server_cache_ttl 'not-a-number'
	option wireguard_mtu '1420'
	option kill_switch_enabled 'on'
EOF
set_store_value '__section__' 'nordvpn_easy'
set_store_value 'enabled' 'yes'
set_store_value 'nordvpn_token' 'secret-token'
set_store_value 'nordvpn_basic_token' 'legacy-token'
set_store_value 'vpn_country' 'AT'
set_store_value 'server_selection_mode' 'manual'
set_store_value 'preferred_server_hostname' 'at12.nordvpn.com'
set_store_value 'preferred_server_station' 'at12'
set_store_value 'wan_if' 'wan6'
set_store_value 'server_cache_ttl' 'not-a-number'
set_store_value 'wireguard_mtu' '1420'
set_store_value 'kill_switch_enabled' 'on'
printf '%s\n' 'stale legacy conffile' > "$FAKE_LEGACY_CONFIG_FILE"

run_migrator

assert_file_has_line "	option enabled '1'" "$FAKE_UCI_CONFIG_FILE" 'upgrade normalizes enabled flag'
assert_file_has_line "	option nordvpn_token 'secret-token'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves NordVPN token'
assert_file_has_line "	option vpn_country 'AT'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves selected country'
assert_file_has_line "	option server_selection_mode 'manual'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves server selection mode'
assert_file_has_line "	option preferred_server_hostname 'at12.nordvpn.com'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves manual server hostname'
assert_file_has_line "	option preferred_server_station 'at12'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves manual server station'
assert_file_has_line "	option wan_if 'wan6'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves WAN interface'
assert_file_has_line "	option server_cache_ttl '86400'" "$FAKE_UCI_CONFIG_FILE" 'upgrade normalizes invalid numeric values'
assert_file_has_line "	option wireguard_mtu '1420'" "$FAKE_UCI_CONFIG_FILE" 'upgrade preserves valid WireGuard MTU'
assert_file_has_line "	option kill_switch_enabled '1'" "$FAKE_UCI_CONFIG_FILE" 'upgrade normalizes kill switch flag'
assert_file_has_line "	option fallback_server_station ''" "$FAKE_UCI_CONFIG_FILE" 'upgrade adds new fallback option from template/schema'
assert_file_has_line "	option config_schema_version '$NORDVPN_EASY_SCHEMA_VERSION'" "$FAKE_UCI_CONFIG_FILE" 'upgrade writes current schema version'
assert_file_missing_line "	option nordvpn_basic_token 'legacy-token'" "$FAKE_UCI_CONFIG_FILE" 'upgrade removes legacy basic token option'

[ ! -e "$FAKE_LEGACY_CONFIG_FILE" ] || {
	printf '%s\n' 'FAIL: migrator did not remove stale nordvpn_easy-opkg file' >&2
	exit 1
}

reset_fake_uci
cat > "$FAKE_LEGACY_CONFIG_FILE" <<'EOF'
config nordvpn_easy 'main'
	option enabled 'yes'
	option nordvpn_token 'legacy-secret-token'
	option vpn_country 'BM'
	option server_selection_mode 'manual'
	option preferred_server_hostname "bm1.nordvpn.com"
	option preferred_server_station 'bm1'
	option check_cron_schedule '*/5 * * * *'
	option wireguard_mtu '1412'
EOF

run_migrator

assert_file_has_line "	option enabled '1'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery normalizes enabled flag'
assert_file_has_line "	option nordvpn_token 'legacy-secret-token'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery preserves NordVPN token'
assert_file_has_line "	option vpn_country 'BM'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery preserves selected country'
assert_file_has_line "	option server_selection_mode 'manual'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery preserves manual mode'
assert_file_has_line "	option preferred_server_hostname 'bm1.nordvpn.com'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery parses double-quoted hostname'
assert_file_has_line "	option preferred_server_station 'bm1'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery preserves manual station'
assert_file_has_line "	option check_cron_schedule '*/5 * * * *'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery preserves cron schedule'
assert_file_has_line "	option wireguard_mtu '1412'" "$FAKE_UCI_CONFIG_FILE" 'legacy recovery preserves WireGuard MTU'

[ ! -e "$FAKE_LEGACY_CONFIG_FILE" ] || {
	printf '%s\n' 'FAIL: migrator did not remove recovered nordvpn_easy-opkg file' >&2
	exit 1
}

reset_fake_uci
set_store_value '__section__' 'nordvpn_easy'
set_store_value 'enabled' '1'
set_store_value 'nordvpn_token' 'active-secret-token'
set_store_value 'vpn_country' 'CH'
cat > "$FAKE_LEGACY_CONFIG_FILE" <<'EOF'
config nordvpn_easy 'main'
	option enabled 'yes'
	option nordvpn_token 'stale-legacy-token'
	option vpn_country 'AT'
EOF

run_migrator

assert_file_has_line "	option nordvpn_token 'active-secret-token'" "$FAKE_UCI_CONFIG_FILE" 'active config wins over stale legacy token'
assert_file_has_line "	option vpn_country 'CH'" "$FAKE_UCI_CONFIG_FILE" 'active config wins over stale legacy country'

[ ! -e "$FAKE_LEGACY_CONFIG_FILE" ] || {
	printf '%s\n' 'FAIL: migrator did not remove stale nordvpn_easy-opkg after active config won' >&2
	exit 1
}

printf '%s\n' 'test-migrate-config.sh: ok'
