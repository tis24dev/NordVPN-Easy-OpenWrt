#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


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

# --- status_json: single live emit, no per-poll cache write (E-hybrid) ---
# The status poll path must emit the status document live and must NOT write the
# status cache (a post-action forensic snapshot, written by the action epilogue,
# never on a poll). S9: the connect-apply guard branch is gone -- there is a single
# unconditional live emit path.
RUN_DIR="$TMP_DIR/run"
mkdir -p "$RUN_DIR"

# Single live emit; one wg dump; no cache; valid JSON with no connect_apply_* keys.
: > "$TMP_DIR/cmds"
rm -f "$RUN_DIR/status.json"
rc=0
PATH="$BIN:$PATH" \
	NORDVPN_EASY_LIB_DIR="$LIB_DIR" \
	NORDVPN_EASY_LOCK_DIR="$TMP_DIR/lock" \
	NORDVPN_EASY_RUN_DIR="$RUN_DIR" \
	sh "$CORE" status_json --config "$TMP_DIR/setup-no-token.conf" > "$TMP_DIR/status-out" 2>/dev/null || rc=$?
rm -rf "$TMP_DIR/lock"
[ "$rc" -eq 0 ] || fail 'status_json should succeed (rc=0)'
jq -er '.interface == "wg_test_dispatch"' "$TMP_DIR/status-out" >/dev/null \
	|| fail 'status_json must emit valid JSON with the interface'
jq -er 'has("connect_apply_pending") | not' "$TMP_DIR/status-out" >/dev/null \
	|| fail 'status_json must NOT emit any connect_apply_* keys (removed in S9)'
dumps="$(grep -c '^wg show wg_test_dispatch dump$' "$TMP_DIR/cmds" || true)"
[ "$dumps" = '1' ] || fail "status_json must collect the WireGuard dump once, got $dumps"
[ ! -e "$RUN_DIR/status.json" ] || fail 'status_json poll must NOT write the status cache'
# Status honesty: an idle status_json carries the additive journal_sub_phase key as
# an empty string (a supervised apply is the only path that populates it), locking in
# the operation!=busy:supervise gate.
jq -er '.journal_sub_phase == ""' "$TMP_DIR/status-out" >/dev/null \
	|| fail 'idle status_json must carry journal_sub_phase as an empty string'

printf '%s\n' 'test-core-dispatch.sh: ok'
