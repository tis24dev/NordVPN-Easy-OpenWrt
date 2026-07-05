#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

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

assert_contains() {
	haystack="$1"
	needle="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*) ;;
		*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "expected to contain: $needle" >&2
			printf '%s\n' "actual:              $haystack" >&2
			exit 1
			;;
	esac
}

assert_excludes() {
	haystack="$1"
	needle="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "expected NOT to contain: $needle" >&2
			printf '%s\n' "actual:                  $haystack" >&2
			exit 1
			;;
	esac
}

extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn "\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$INIT_SCRIPT"
}

eval "$(extract_function connect)"

# Globals the extracted connect() body references.
UCI_CONFIG='nordvpn_easy'
UCI_SECTION='main'
CONNECT_SETUP_CONFIG_CACHE="$TMP_DIR/connect-setup.conf"
cfg_vpn_country=''

CALL_LOG="$TMP_DIR/call-log.txt"

# Stable mocks shared by all scenarios. S9: connect() no longer touches any
# connect-apply guard/result -- it is lock -> prepare_connect_setup_config_cache ->
# enabled=1 fenced commit -> install_hooks_if_needed -> setup.
load_service_config() { :; }
acquire_runtime_transaction_lock() { return 0; }
log_service_info() { :; }
log_service_error() { :; }
nordvpn_easy_service_debug_summary() { printf '%s' 'cfg-summary'; }
prepare_connect_setup_config_cache() { return 0; }
uci() { return 0; }
# connect() commits enabled=1 through the S7a owner fence (defined in common.sh,
# not sourced here); pass it through to the mocked uci.
nordvpn_easy_fenced_uci_commit() { uci commit "$@"; }

reset_logs() {
	: > "$CALL_LOG"
}

# --- Scenario A: setup fails -> hooks were already installed before setup ----
reset_logs
install_hooks_if_needed() { printf '%s\n' 'install_hooks' >> "$CALL_LOG"; return 0; }
setup() { printf '%s\n' 'setup' >> "$CALL_LOG"; return 1; }

SCENARIO_RC=0
connect || SCENARIO_RC=$?

CALL_ORDER="$(tr '\n' ' ' < "$CALL_LOG")"
assert_eq '1' "$SCENARIO_RC" 'connect returns the setup failure code'
assert_contains "$CALL_ORDER" 'install_hooks setup' 'recovery hooks are installed before setup'

# --- Scenario B: setup succeeds -> hooks still installed before setup --------
reset_logs
install_hooks_if_needed() { printf '%s\n' 'install_hooks' >> "$CALL_LOG"; return 0; }
setup() { printf '%s\n' 'setup' >> "$CALL_LOG"; return 0; }

SCENARIO_RC=0
connect || SCENARIO_RC=$?

CALL_ORDER="$(tr '\n' ' ' < "$CALL_LOG")"
assert_eq '0' "$SCENARIO_RC" 'connect succeeds when setup succeeds'
assert_contains "$CALL_ORDER" 'install_hooks setup' 'hooks precede setup on the success path too'

# --- Scenario C: hook install fails -> setup is not attempted ----------------
reset_logs
install_hooks_if_needed() { printf '%s\n' 'install_hooks' >> "$CALL_LOG"; return 1; }
setup() { printf '%s\n' 'setup' >> "$CALL_LOG"; return 0; }

SCENARIO_RC=0
connect || SCENARIO_RC=$?

CALL_ORDER="$(tr '\n' ' ' < "$CALL_LOG")"
assert_eq '1' "$SCENARIO_RC" 'connect fails when recovery hooks cannot be installed'
assert_contains "$CALL_ORDER" 'install_hooks' 'hook install is attempted'
assert_excludes "$CALL_ORDER" 'setup' 'setup is not attempted when hooks cannot be installed'

printf '%s\n' 'test-init-connect-hooks-order.sh: ok'
