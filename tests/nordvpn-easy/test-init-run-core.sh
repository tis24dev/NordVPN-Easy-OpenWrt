#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/init.d/nordvpn-easy"
TMP_DIR="$(mktemp -d)"
CORE_CAPTURE="$TMP_DIR/core-args.txt"
VALIDATION_MODE='pass'

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

load_service_config() { :; }
log_service_info() { :; }
log_service_error() { :; }
nordvpn_easy_debug_cli_args() { printf '%s\n' 'none'; }
nordvpn_easy_service_debug_summary() { printf '%s\n' 'enabled=1 (checked/on), token=present'; }
nordvpn_easy_runtime_file_debug_summary() { printf '%s\n' 'file_token=present'; }
nordvpn_easy_runtime_config_validation_summary() { printf '%s\n' 'render_validation=ok'; }
nordvpn_easy_service_backend_payload_summary() { printf '%s\n' 'service_payload=render-contract-v2, lib_payload=render-contract-v2, payload_match=1'; }
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

cat > "$TMP_DIR/core.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$CORE_CAPTURE"
exit 0
EOF
chmod +x "$TMP_DIR/core.sh"

CORE_SCRIPT="$TMP_DIR/core.sh"

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
