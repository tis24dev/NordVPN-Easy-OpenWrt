#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
TMP_DIR="$(mktemp -d)"
CORE_CAPTURE="$TMP_DIR/core-args.txt"
INFO_CAPTURE="$TMP_DIR/info.log"
ERROR_CAPTURE="$TMP_DIR/error.log"
VALIDATION_MODE='pass'
CORE_EXIT_RC='0'
export CORE_EXIT_RC
NORDVPN_EASY_RC_BUSY='75'

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

extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn "\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$INIT_SCRIPT"
}

eval "$(extract_function run_core_action)"
eval "$(extract_function connect)"
eval "$(extract_function disconnect)"
eval "$(extract_function stop_vpn)"
eval "$(extract_function reconnect)"
eval "$(extract_function reconcile)"

REMOVE_HOOKS_COUNT=0
remove_hooks() {
	REMOVE_HOOKS_COUNT=$((REMOVE_HOOKS_COUNT + 1))
	return 0
}

load_config_context_library() { :; }
load_service_config() { :; }
log_service_info() { printf '%s\n' "$1" >> "$INFO_CAPTURE"; }
log_service_error() { printf '%s\n' "$1" >> "$ERROR_CAPTURE"; }
nordvpn_easy_debug_cli_args() { printf '%s\n' 'none'; }
nordvpn_easy_service_debug_summary() { printf '%s\n' 'enabled=1 (checked/on), token=present'; }
nordvpn_easy_runtime_file_debug_summary() { printf '%s\n' 'file_token=present'; }
nordvpn_easy_runtime_config_validation_summary() { printf '%s\n' 'render_validation=ok'; }
nordvpn_easy_service_backend_payload_summary() { printf '%s\n' 'service_payload=render-contract-v3, lib_payload=render-contract-v3, payload_match=1'; }
nordvpn_easy_mktemp_dir() {
	local result_var="$2"
	local temp_dir

	temp_dir="$(mktemp -d "$TMP_DIR/action.XXXXXX")"
	eval "$result_var='$(printf "%s" "$temp_dir" | sed "s/'/'\\\\''/g")'"
}
nordvpn_easy_temp_file_path() {
	printf '%s/%s\n' "$1" "$2"
}
nordvpn_easy_render_runtime_config() {
	printf '%s\n' "DESIRED_ENABLED='1'" > "$1"
	if [ -n "${3:-}" ]; then
		eval "$3=1"
	else
		printf '%s\n' '1'
	fi
}
nordvpn_easy_validate_runtime_config() {
	if [ "$VALIDATION_MODE" = 'fail' ]; then
		return 1
	fi
	return 0
}

UCI_SET_VALUES=''
UCI_COMMIT_COUNT=0
NETWORK_PROTO=''
NETWORK_DISABLED=''
SETUP_COUNT=0
SETUP_RC=0
INSTALL_HOOKS_COUNT=0
DISABLE_RUNTIME_COUNT=0
UCI_CONFIG='nordvpn_easy'
UCI_SECTION='main'
uci() {
	if [ "${1:-}" = '-q' ]; then
		shift
	fi

	case "$1" in
		get)
			case "$2" in
				network.wg0.proto)
					[ -n "$NETWORK_PROTO" ] || return 1
					printf '%s\n' "$NETWORK_PROTO"
					return 0
					;;
				network.wg0.disabled)
					[ -n "$NETWORK_DISABLED" ] || return 1
					printf '%s\n' "$NETWORK_DISABLED"
					return 0
					;;
			esac
			return 1
			;;
		set)
			UCI_SET_VALUES="${UCI_SET_VALUES}${2};"
			return 0
			;;
		commit)
			UCI_COMMIT_COUNT=$((UCI_COMMIT_COUNT + 1))
			return 0
			;;
	esac
	return 1
}
setup() {
	SETUP_COUNT=$((SETUP_COUNT + 1))
	return "$SETUP_RC"
}
install_hooks() {
	INSTALL_HOOKS_COUNT=$((INSTALL_HOOKS_COUNT + 1))
	return 0
}
disable_vpn_runtime() {
	DISABLE_RUNTIME_COUNT=$((DISABLE_RUNTIME_COUNT + 1))
	return 0
}

cfg_enabled=0
cfg_nordvpn_token=''
cfg_vpn_if='wg0'
SETUP_RC=1
RC=0
connect || RC=$?
assert_eq '1' "$RC" 'connect propagates setup failure'
assert_eq '1' "$SETUP_COUNT" 'connect runs setup once'
assert_eq '0' "$INSTALL_HOOKS_COUNT" 'connect does not install hooks when setup fails'
case "$UCI_SET_VALUES" in
	*nordvpn_easy.main.enabled=1\;*)
		;;
	*)
		printf '%s\n' 'FAIL: connect should set enabled=1 before setup' >&2
		exit 1
		;;
esac

SETUP_RC=0
SETUP_COUNT=0
INSTALL_HOOKS_COUNT=0
RC=0
connect || RC=$?
assert_eq '0' "$RC" 'connect succeeds when setup and hook installation succeed'
assert_eq '1' "$SETUP_COUNT" 'successful connect runs setup once'
assert_eq '1' "$INSTALL_HOOKS_COUNT" 'successful connect installs hooks once'

cfg_enabled=1
cat > "$TMP_DIR/core.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CORE_CAPTURE"
exit "\${CORE_EXIT_RC:-0}"
EOF
chmod +x "$TMP_DIR/core.sh"
CORE_SCRIPT="$TMP_DIR/core.sh"
CORE_EXIT_RC='1'
INSTALL_HOOKS_COUNT=0
SETUP_COUNT=0
REMOVE_HOOKS_COUNT=0
rm -f "$CORE_CAPTURE"
RC=0
reconnect || RC=$?
assert_eq '1' "$RC" 'reconnect propagates stop_vpn failure'
grep -qx "stop_vpn" "$CORE_CAPTURE" || {
	printf '%s\n' "FAIL: reconnect should run stop_vpn before connect: $(cat "$CORE_CAPTURE")" >&2
	exit 1
}
assert_eq '0' "$SETUP_COUNT" 'reconnect does not run connect when stop_vpn fails'
assert_eq '0' "$INSTALL_HOOKS_COUNT" 'reconnect does not install hooks when stop_vpn fails'

CORE_EXIT_RC='0'
INSTALL_HOOKS_COUNT=0
SETUP_COUNT=0
REMOVE_HOOKS_COUNT=0
rm -f "$CORE_CAPTURE"
RC=0
reconnect || RC=$?
assert_eq '0' "$RC" 'reconnect succeeds when stop_vpn, connect, and hook installation succeed'
grep -qx "stop_vpn" "$CORE_CAPTURE" || {
	printf '%s\n' "FAIL: reconnect should run stop_vpn: $(cat "$CORE_CAPTURE")" >&2
	exit 1
}
assert_eq '1' "$SETUP_COUNT" 'successful reconnect runs connect/setup after stop_vpn'
assert_eq '1' "$INSTALL_HOOKS_COUNT" 'successful reconnect installs hooks once'
assert_eq '0' "$REMOVE_HOOKS_COUNT" 'reconnect leaves hook lifecycle to connect/disconnect'

cfg_enabled=0
DISABLE_RUNTIME_COUNT=0
UCI_SET_VALUES=''
RC=0
disconnect || RC=$?
assert_eq '0' "$RC" 'disconnect succeeds when runtime disable succeeds'
assert_eq '1' "$DISABLE_RUNTIME_COUNT" 'disconnect disables runtime once'
case "$UCI_SET_VALUES" in
	*nordvpn_easy.main.enabled=0\;*)
		;;
	*)
		printf '%s\n' 'FAIL: disconnect should set enabled=0 before disabling runtime' >&2
		exit 1
		;;
esac

cfg_enabled=0
cfg_nordvpn_token='token-secret'
cfg_vpn_if='wg0'
DISABLE_RUNTIME_COUNT=0
RC=0
reconcile || RC=$?
assert_eq '0' "$RC" 'reconcile succeeds while ensuring disabled runtime'
assert_eq '1' "$DISABLE_RUNTIME_COUNT" 'reconcile disables runtime when saved config is disabled'

cfg_enabled=1
cfg_nordvpn_token=''
DISABLE_RUNTIME_COUNT=0
SETUP_COUNT=0
RC=0
reconcile || RC=$?
assert_eq '1' "$RC" 'reconcile rejects enabled config without token'
assert_eq '0' "$SETUP_COUNT" 'reconcile does not start setup when token is missing'

cfg_enabled=1
cfg_nordvpn_token='token-secret'
cfg_vpn_if='wg0'
NETWORK_PROTO=''
NETWORK_DISABLED=''
SETUP_RC=0
SETUP_COUNT=0
INSTALL_HOOKS_COUNT=0
UCI_SET_VALUES=''
RC=0
reconcile || RC=$?
assert_eq '0' "$RC" 'reconcile connects when WireGuard interface is missing'
assert_eq '1' "$SETUP_COUNT" 'reconcile runs setup through connect when runtime is missing'
assert_eq '1' "$INSTALL_HOOKS_COUNT" 'reconcile installs hooks after reconnecting missing runtime'
case "$UCI_SET_VALUES" in
	*nordvpn_easy.main.enabled=1\;*)
		;;
	*)
		printf '%s\n' 'FAIL: reconcile connect path should keep enabled=1' >&2
		exit 1
		;;
esac

cfg_enabled=1
cfg_nordvpn_token='token-secret'
cfg_vpn_if='wg0'
NETWORK_PROTO='wireguard'
NETWORK_DISABLED=''
INSTALL_HOOKS_COUNT=0
CORE_EXIT_RC='0'
rm -f "$CORE_CAPTURE"
: > "$INFO_CAPTURE"
: > "$ERROR_CAPTURE"
RC=0
reconcile || RC=$?
assert_eq '0' "$RC" 'reconcile succeeds through core reconcile when runtime is already configured'
CORE_ARGS="$(cat "$CORE_CAPTURE")"
case "$CORE_ARGS" in
	"reconcile --config $TMP_DIR"/action.*"/nordvpn-easy.reconcile.conf")
		;;
	*)
		printf '%s\n' "FAIL: configured reconcile should run the core reconcile action: $CORE_ARGS" >&2
		exit 1
		;;
esac
assert_eq '1' "$INSTALL_HOOKS_COUNT" 'configured reconcile installs hooks after successful runtime sync'

rm -f "$CORE_CAPTURE"
: > "$INFO_CAPTURE"
: > "$ERROR_CAPTURE"
run_core_action status_json

CORE_ARGS="$(cat "$CORE_CAPTURE")"
case "$CORE_ARGS" in
	"status_json --config $TMP_DIR"/action.*"/nordvpn-easy.status_json.conf")
		;;
	*)
		printf '%s\n' "FAIL: core action did not receive expected --config argument: $CORE_ARGS" >&2
		exit 1
		;;
esac

CONFIG_PATH_FROM_ARGS="${CORE_ARGS#status_json --config }"
[ ! -f "$CONFIG_PATH_FROM_ARGS" ] || {
	printf '%s\n' 'FAIL: temporary action config should be cleaned up after core execution' >&2
	exit 1
}
[ ! -s "$INFO_CAPTURE" ] || {
	printf '%s\n' 'FAIL: quiet status_json core action should not emit info logs on success' >&2
	exit 1
}

rm -f "$CORE_CAPTURE"
: > "$INFO_CAPTURE"
run_core_action setup

CORE_ARGS="$(cat "$CORE_CAPTURE")"
case "$CORE_ARGS" in
	"setup --config $TMP_DIR"/action.*"/nordvpn-easy.setup.conf")
		;;
	*)
		printf '%s\n' "FAIL: setup core action did not receive expected --config argument: $CORE_ARGS" >&2
		exit 1
		;;
esac
[ -s "$INFO_CAPTURE" ] || {
	printf '%s\n' 'FAIL: setup core action should emit info logs on success' >&2
	exit 1
}

rm -f "$CORE_CAPTURE"
: > "$INFO_CAPTURE"
: > "$ERROR_CAPTURE"
CORE_EXIT_RC='75'
NORDVPN_EASY_RC_BUSY='75'
RC=0
run_core_action check || RC=$?
assert_eq '75' "$RC" 'run_core_action propagates busy rc for manual actions'
grep -q "skipped because another operation is running" "$INFO_CAPTURE" || {
	printf '%s\n' 'FAIL: busy core action should emit a skipped info log' >&2
	exit 1
}
[ ! -s "$ERROR_CAPTURE" ] || {
	printf '%s\n' 'FAIL: busy core action should not emit error logs' >&2
	exit 1
}

: > "$INFO_CAPTURE"
RUN_CORE_ACTION_BUSY_IS_OK='1'
RC=0
run_core_action check || RC=$?
assert_eq '0' "$RC" 'run_core_action maps busy rc to success for automated callers'
unset RUN_CORE_ACTION_BUSY_IS_OK
CORE_EXIT_RC='0'

rm -f "$CORE_CAPTURE"
VALIDATION_MODE='fail'
RC=0
run_core_action status_json || RC=$?
assert_eq '1' "$RC" 'run_core_action fails when rendered config validation fails'
[ ! -f "$CORE_CAPTURE" ] || {
	printf '%s\n' 'FAIL: core action should not run when validation fails' >&2
	exit 1
}

printf '%s\n' 'test-init-run-core.sh: ok'
