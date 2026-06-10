#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/etc/uci-defaults/99-nordvpn-easy-rpcd-timeout"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

assert_eq() {
	[ "$1" = "$2" ] || { printf '%s\n' "FAIL: $3 (expected '$1', got '$2')" >&2; exit 1; }
}

BIN="$TMP_DIR/bin"
STORE="$TMP_DIR/uci-store"
mkdir -p "$BIN"

# Minimal fake uci backed by one file per dotted key.
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
[ "$1" = '-q' ] && shift
cmd="$1"; shift || true
store="${FAKE_UCI_DIR:?}"
mkdir -p "$store"
kf() { printf '%s/%s' "$store" "$(printf '%s' "$1" | tr '/.@[]' '_____')"; }
case "$cmd" in
	get) f="$(kf "$1")"; [ -f "$f" ] || exit 1; cat "$f" ;;
	set) k="${1%%=*}"; v="${1#*=}"; printf '%s' "$v" > "$(kf "$k")" ;;
	add) printf '%s' "$2" > "$(kf "$1.@$2[0]")" ;;
	commit) printf 'commit %s\n' "$1" >> "$store/.commits" ;;
	*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/uci"

run_default() {
	rm -rf "$STORE"
	mkdir -p "$STORE"
	# seed pre-existing keys passed as "key=value" args
	for kv in "$@"; do
		k="${kv%%=*}"; v="${kv#*=}"
		printf '%s' "$v" > "$STORE/$(printf '%s' "$k" | tr '/.@[]' '_____')"
	done
	PATH="$BIN:$PATH" FAKE_UCI_DIR="$STORE" sh "$SCRIPT"
}

get_val() {
	f="$STORE/$(printf '%s' "$1" | tr '/.@[]' '_____')"
	[ -f "$f" ] && cat "$f" || printf '%s' '<absent>'
}

# Case 1: rpcd section missing -> created and timeout bumped to 180, committed.
run_default
assert_eq '180' "$(get_val 'rpcd.@rpcd[0].timeout')" 'absent rpcd timeout is bumped to 180'
[ -f "$STORE/.commits" ] && grep -q 'commit rpcd' "$STORE/.commits" || { printf '%s\n' 'FAIL: a change must commit rpcd' >&2; exit 1; }

# Case 2: an already-higher rpcd timeout is left untouched (no clobber, no commit).
run_default 'rpcd.@rpcd[0]=rpcd' 'rpcd.@rpcd[0].timeout=300'
assert_eq '300' "$(get_val 'rpcd.@rpcd[0].timeout')" 'a higher rpcd timeout is preserved'
[ ! -f "$STORE/.commits" ] || { printf '%s\n' 'FAIL: an unchanged config must not commit' >&2; exit 1; }

# Case 3: uhttpd present with low timeouts -> both bumped to 180.
run_default 'rpcd.@rpcd[0]=rpcd' 'rpcd.@rpcd[0].timeout=200' 'uhttpd.main=uhttpd' 'uhttpd.main.script_timeout=60' 'uhttpd.main.network_timeout=60'
assert_eq '200' "$(get_val 'rpcd.@rpcd[0].timeout')" 'rpcd timeout at 200 is preserved'
assert_eq '180' "$(get_val 'uhttpd.main.script_timeout')" 'low uhttpd script_timeout is bumped to 180'
assert_eq '180' "$(get_val 'uhttpd.main.network_timeout')" 'low uhttpd network_timeout is bumped to 180'

printf '%s\n' 'test-uci-defaults-timeout.sh: ok'
