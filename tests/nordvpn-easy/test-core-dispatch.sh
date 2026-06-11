#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

fail() {
	printf '%s\n' "FAIL: $1" >&2
	printf '%s\n' '--- logger calls ---' >&2
	cat "$TMP_DIR/cmds" >&2 2>/dev/null || true
	exit 1
}

BIN="$TMP_DIR/bin"
mkdir -p "$BIN"
# Stub every mutating/system command so a wrongly-proceeding action cannot touch
# the host; the logger stub captures the backend's log lines for assertions.
for c in curl uci ip wg ifup ifdown ping logger; do
	cat > "$BIN/$c" <<EOF
#!/bin/sh
printf '%s %s\n' "$c" "\$*" >> "$TMP_DIR/cmds"
exit 0
EOF
	chmod +x "$BIN/$c"
done

run_core() {
	: > "$TMP_DIR/cmds"
	rc=0
	PATH="$BIN:$PATH" \
		NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
		NORDVPN_EASY_LOCK_DIR="$TMP_DIR/lock" \
		NORDVPN_EASY_RUN_DIR="$TMP_DIR/run" \
		sh "$CORE" "$1" --config "$2" > "$TMP_DIR/out" 2>&1 || rc=$?
	rm -rf "$TMP_DIR/lock"
	return "$rc"
}

# A setup config that is valid except for a missing NORDVPN_TOKEN. The token has
# no schema default, so apply_env_defaults cannot fill it and validate_setup_runtime
# must fail. VPN_IF is a throwaway name so a regression could not touch a real
# interface. This exercises the real core.sh action dispatch (not a stub).
cat > "$TMP_DIR/setup-no-token.conf" <<'EOF'
DESIRED_ENABLED='1'
NORDVPN_TOKEN=''
WAN_IF='wan'
VPN_IF='wg_test_dispatch'
VPN_ADDR='10.5.0.2/32'
VPN_PORT='51820'
EOF

rc=0
run_core setup "$TMP_DIR/setup-no-token.conf" || rc=$?

[ "$rc" -ne 0 ] || fail 'setup with a missing token must fail (rc=0)'
grep -qi 'setup prerequisites missing' "$TMP_DIR/cmds" || fail 'setup should log the missing-prerequisite blocker'
# The gate: provisioning must NOT start once validation has failed.
if grep -qi 'provisioning VPN interface' "$TMP_DIR/cmds"; then
	fail 'provisioning must NOT start when setup validation fails'
fi

rc=0
run_core reconcile "$TMP_DIR/setup-no-token.conf" || rc=$?

[ "$rc" -ne 0 ] || fail 'reconcile with a missing token must fail (rc=0)'
grep -qi 'setup prerequisites missing' "$TMP_DIR/cmds" || fail 'reconcile should log the missing-prerequisite blocker'
if grep -qi 'provisioning VPN interface' "$TMP_DIR/cmds"; then
	fail 'reconcile must NOT reprovision when setup validation fails'
fi

printf '%s\n' 'test-core-dispatch.sh: ok'
