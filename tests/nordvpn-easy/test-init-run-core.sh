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
	' "${2:-$INIT_SCRIPT}"
}

COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
eval "$(extract_function nordvpn_easy_register_temp_path "$COMMON_LIB")"
eval "$(extract_function nordvpn_easy_cleanup_temp_paths "$COMMON_LIB")"
NORDVPN_EASY_TEMP_PATHS=''

eval "$(extract_function run_core_action)"
eval "$(extract_function connect_apply_guard_begin)"
eval "$(extract_function connect_apply_guard_end)"
eval "$(extract_function prepare_connect_setup_config_cache)"
eval "$(extract_function begin_connect_apply)"
eval "$(extract_function abort_connect_apply)"
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
TRANSACTION_LOCK_RC=0
acquire_runtime_transaction_lock() { return "${TRANSACTION_LOCK_RC:-0}"; }
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
RUN_STATE_DIR="$TMP_DIR/run-state"
CONNECT_SETUP_CONFIG_CACHE="${RUN_STATE_DIR}/connect-setup.conf"
CONNECT_APPLY_GUARD="${RUN_STATE_DIR}/connect-apply-guard"
CONNECT_APPLY_RESULT="${RUN_STATE_DIR}/connect-apply-result"
RUNTIME_LOCK_DIR="$TMP_DIR/runtime-lock"
nordvpn_easy_connect_apply_result_begin() {
	mkdir -p "$(dirname "$CONNECT_APPLY_RESULT")" 2>/dev/null || true
	printf 'state=pending\nrc=\nfinished_at=\ncountry=\nstarted_at=1\n' > "$CONNECT_APPLY_RESULT"
}
nordvpn_easy_connect_apply_result_finish() { :; }
nordvpn_easy_clear_stale_runtime_lock() { :; }
connect_apply_result_finish() { :; }
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
# connect()/disconnect() commit the enabled flag through the S7a owner fence
# (defined in common.sh, which this test extracts from rather than sources);
# pass it through to the mocked uci.
nordvpn_easy_fenced_uci_commit() { uci commit "$@"; }
setup() {
	SETUP_COUNT=$((SETUP_COUNT + 1))
	return "$SETUP_RC"
}
install_hooks() {
	INSTALL_HOOKS_COUNT=$((INSTALL_HOOKS_COUNT + 1))
	return 0
}
install_hooks_if_needed() {
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
assert_eq '1' "$INSTALL_HOOKS_COUNT" 'connect installs recovery hooks before setup so a setup failure still has a retry path'
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
assert_eq '1' "$INSTALL_HOOKS_COUNT" 'successful connect installs hooks via install_hooks_if_needed once'
[ ! -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s\n' 'FAIL: connect should clear apply guard on success' >&2
	exit 1
}
[ ! -f "$CONNECT_SETUP_CONFIG_CACHE" ] || {
	printf '%s\n' 'FAIL: connect should remove setup config cache after setup' >&2
	exit 1
}

# An invalid config is rejected BEFORE enabled=1 is persisted, so a bad config is
# not recorded as desired-on and then fail every cron retry forever. A transient
# failure after a valid config (the setup-fails case above) still records
# enabled=1 so the cron check can converge the runtime.
VALIDATION_MODE='fail'
UCI_SET_VALUES=''
UCI_COMMIT_COUNT=0
SETUP_COUNT=0
SETUP_RC=0
INSTALL_HOOKS_COUNT=0
RC=0
connect || RC=$?
assert_eq '1' "$RC" 'connect rejects an invalid config'
assert_eq '0' "$SETUP_COUNT" 'connect does not provision an invalid config'
case "$UCI_SET_VALUES" in
	*nordvpn_easy.main.enabled=1\;*)
		printf '%s\n' 'FAIL: connect must not persist enabled=1 for an invalid config' >&2
		exit 1
		;;
esac
VALIDATION_MODE='pass'

cfg_enabled=1
cfg_nordvpn_token='token-secret'
cfg_vpn_if='wg0'
CORE_SCRIPT="$TMP_DIR/core.sh"
CORE_EXIT_RC='1'
cat > "$CORE_SCRIPT" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CORE_CAPTURE"
exit "\${CORE_EXIT_RC:-0}"
EOF
chmod +x "$CORE_SCRIPT"
INSTALL_HOOKS_COUNT=0
SETUP_COUNT=0
REMOVE_HOOKS_COUNT=0
rm -f "$CORE_CAPTURE"
RC=0
reconnect || RC=$?
assert_eq '1' "$RC" 'reconnect propagates the atomic core reconnect failure'
CORE_ARGS="$(cat "$CORE_CAPTURE")"
case "$CORE_ARGS" in
	"reconnect --config $TMP_DIR"/action.*"/nordvpn-easy.reconnect.conf")
		;;
	*)
		printf '%s\n' "FAIL: reconnect should run the single atomic core reconnect action: $CORE_ARGS" >&2
		exit 1
		;;
esac
assert_eq '0' "$SETUP_COUNT" 'reconnect does not orchestrate a separate setup step'
assert_eq '0' "$INSTALL_HOOKS_COUNT" 'reconnect does not install hooks when the core transaction fails'

CORE_EXIT_RC='0'
cat > "$CORE_SCRIPT" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CORE_CAPTURE"
exit "\${CORE_EXIT_RC:-0}"
EOF
chmod +x "$CORE_SCRIPT"
INSTALL_HOOKS_COUNT=0
SETUP_COUNT=0
REMOVE_HOOKS_COUNT=0
rm -f "$CORE_CAPTURE"
RC=0
reconnect || RC=$?
assert_eq '0' "$RC" 'reconnect succeeds when the atomic core reconnect and hook installation succeed'
CORE_ARGS="$(cat "$CORE_CAPTURE")"
case "$CORE_ARGS" in
	"reconnect --config $TMP_DIR"/action.*"/nordvpn-easy.reconnect.conf")
		;;
	*)
		printf '%s\n' "FAIL: reconnect should run the single atomic core reconnect action: $CORE_ARGS" >&2
		exit 1
		;;
esac
assert_eq '0' "$SETUP_COUNT" 'reconnect does not orchestrate a separate setup step'
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

mkdir -p "$RUN_STATE_DIR"
nordvpn_easy_render_runtime_config "$CONNECT_SETUP_CONFIG_CACHE" 'cfg_' _written_options
export NORDVPN_EASY_SETUP_CONFIG_CACHE="$CONNECT_SETUP_CONFIG_CACHE"
rm -f "$CORE_CAPTURE"
: > "$INFO_CAPTURE"
run_core_action setup
unset NORDVPN_EASY_SETUP_CONFIG_CACHE

CORE_ARGS="$(cat "$CORE_CAPTURE")"
case "$CORE_ARGS" in
	"setup --config $CONNECT_SETUP_CONFIG_CACHE")
		;;
	*)
		printf '%s\n' "FAIL: setup should reuse connect cache when present: $CORE_ARGS" >&2
		exit 1
		;;
esac
grep -q 'using cached setup config' "$INFO_CAPTURE" || {
	printf '%s\n' 'FAIL: cached setup should be logged' >&2
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


mkdir -p "$RUN_STATE_DIR"
rm -f "$CONNECT_APPLY_GUARD" "$CONNECT_APPLY_RESULT"
RC=0
begin_connect_apply || RC=$?
assert_eq '0' "$RC" 'begin_connect_apply succeeds'
[ -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s
' 'FAIL: begin_connect_apply should create connect apply guard' >&2
	exit 1
}
case "$(sed -n 's/^state=//p' "$CONNECT_APPLY_RESULT" 2>/dev/null | head -n1)" in
	pending) ;;
	*)
		printf '%s
' 'FAIL: begin_connect_apply should leave connect apply result pending' >&2
		exit 1
		;;
esac
RC=0
abort_connect_apply || RC=$?
assert_eq '0' "$RC" 'abort_connect_apply succeeds'
[ ! -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s
' 'FAIL: abort_connect_apply should remove connect apply guard' >&2
	exit 1
}

# Transaction-lock contention: the mutating verbs must defer with RC_BUSY and
# run no setup / core action / hook work, so a second operation can never
# interleave into the gaps of an in-flight connect/reconnect/reconcile.
TRANSACTION_LOCK_RC="$NORDVPN_EASY_RC_BUSY"

rm -f "$CONNECT_APPLY_GUARD" "$CONNECT_APPLY_RESULT"
RC=0
begin_connect_apply || RC=$?
assert_eq "$NORDVPN_EASY_RC_BUSY" "$RC" 'begin_connect_apply defers with RC_BUSY when the runtime lock is held'
[ ! -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s\n' 'FAIL: busy begin_connect_apply should not create connect apply guard' >&2
	exit 1
}

: > "$CONNECT_APPLY_GUARD"
RC=0
abort_connect_apply || RC=$?
assert_eq "$NORDVPN_EASY_RC_BUSY" "$RC" 'abort_connect_apply defers with RC_BUSY when the runtime lock is held'
[ -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s\n' 'FAIL: busy abort_connect_apply should not remove connect apply guard' >&2
	exit 1
}
rm -f "$CONNECT_APPLY_GUARD"

cfg_enabled=1
cfg_nordvpn_token='token-secret'
cfg_vpn_if='wg0'
SETUP_COUNT=0
INSTALL_HOOKS_COUNT=0
rm -f "$CONNECT_APPLY_GUARD"
RC=0
connect || RC=$?
assert_eq "$NORDVPN_EASY_RC_BUSY" "$RC" 'connect defers with RC_BUSY when the runtime lock is held'
assert_eq '0' "$SETUP_COUNT" 'busy connect does not run setup'
[ ! -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s\n' 'FAIL: busy connect should not begin the connect apply guard' >&2
	exit 1
}

rm -f "$CORE_CAPTURE"
SETUP_COUNT=0
INSTALL_HOOKS_COUNT=0
RC=0
reconnect || RC=$?
assert_eq "$NORDVPN_EASY_RC_BUSY" "$RC" 'reconnect defers with RC_BUSY when the runtime lock is held'
assert_eq '0' "$INSTALL_HOOKS_COUNT" 'busy reconnect does not install hooks'
[ ! -f "$CORE_CAPTURE" ] || {
	printf '%s\n' 'FAIL: busy reconnect should not run any core action' >&2
	exit 1
}

rm -f "$CORE_CAPTURE"
DISABLE_RUNTIME_COUNT=0
SETUP_COUNT=0
INSTALL_HOOKS_COUNT=0
RC=0
reconcile || RC=$?
assert_eq "$NORDVPN_EASY_RC_BUSY" "$RC" 'reconcile defers with RC_BUSY when the runtime lock is held'
assert_eq '0' "$DISABLE_RUNTIME_COUNT" 'busy reconcile does not disable the runtime'
assert_eq '0' "$SETUP_COUNT" 'busy reconcile does not connect/setup'
[ ! -f "$CORE_CAPTURE" ] || {
	printf '%s\n' 'FAIL: busy reconcile should not run any core action' >&2
	exit 1
}

TRANSACTION_LOCK_RC=0

# The connect-apply guard suppresses the cron recovery check while it exists, so
# an interrupted connect-apply (no connect_apply_guard_end) must not leave it
# behind. guard_begin registers the guard with the lock's exit-cleanup, so the
# trap removes it even when guard_end never runs.
NORDVPN_EASY_TEMP_PATHS=''
rm -f "$CONNECT_APPLY_GUARD"
connect_apply_guard_begin
[ -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s\n' 'FAIL: guard_begin should create the connect-apply guard' >&2
	exit 1
}
# Simulate an abnormal exit: guard_end did NOT run; the exit cleanup must remove
# the guard so cron recovery is not suppressed forever.
nordvpn_easy_cleanup_temp_paths
[ ! -f "$CONNECT_APPLY_GUARD" ] || {
	printf '%s\n' 'FAIL: an interrupted connect-apply guard must be cleaned on exit' >&2
	exit 1
}

printf '%s\n' 'test-init-run-core.sh: ok'
