#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
CGI="$ROOT_DIR/openwrt-packages/luci-app-nordvpn-easy/htdocs/luci-static/resources/nordvpn-easy/nordvpn-easy-timing-log.cgi"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}

trap cleanup EXIT HUP INT TERM

FAKE_BIN="$TMP_DIR/bin"
LOGGER_CAP="$TMP_DIR/logger.txt"
NDJSON="$TMP_DIR/timing.ndjson"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/logger" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$LOGGER_CAP"
EOF
chmod +x "$FAKE_BIN/logger"

fail() {
	printf '%s\n' "FAIL: $1" >&2
	exit 1
}

post() {
	body="$1"
	: > "$LOGGER_CAP"
	printf '%s' "$body" | \
		PATH="$FAKE_BIN:$PATH" \
		NORDVPN_EASY_LUCI_TIMING_LOG="$NDJSON" \
		REQUEST_METHOD='POST' \
		CONTENT_LENGTH="${#body}" \
		sh "$CGI" >/dev/null 2>&1
}

get() {
	: > "$LOGGER_CAP"
	PATH="$FAKE_BIN:$PATH" \
		NORDVPN_EASY_LUCI_TIMING_LOG="$NDJSON" \
		REQUEST_METHOD='GET' \
		CONTENT_LENGTH='0' \
		sh "$CGI" >/dev/null 2>&1
}

get
[ ! -s "$LOGGER_CAP" ] || fail 'GET must not reach the system log'
[ ! -s "$NDJSON" ] || fail 'GET must not append to the timing log'

# A Country Match transition event is mirrored to the system log via logger,
# tagged nordvpn-easy so diagnostics_log (logread) captures it.
post '{"location":"countryMatch","event":"country_match","message":"country match indicator -> mismatch (selected=SE, exit=DE)","data":{},"timestamp":1}'
grep -q 'nordvpn-easy' "$LOGGER_CAP" || fail 'country_match event should be logged with the nordvpn-easy tag'
grep -qF 'country match indicator -> mismatch (selected=SE, exit=DE)' "$LOGGER_CAP" || fail 'country_match logger line should carry the human-readable message'

# A non country_match line is appended to the NDJSON but never written to the
# system log.
post '{"location":"runApplyCycleConnectPhase","event":"connect","data":{},"timestamp":2}'
[ ! -s "$LOGGER_CAP" ] || fail 'non country_match events must not reach the system log'
grep -qF '"event":"connect"' "$NDJSON" || fail 'timing events are still appended to the NDJSON log'

# An oversized body is rejected without being read/appended/logged (DoS guard).
: > "$NDJSON"
big="$(awk 'BEGIN { while (n++ < 9000) printf "a" }')"
post "$big"
[ ! -s "$LOGGER_CAP" ] || fail 'oversized body must not reach the system log'
[ ! -s "$NDJSON" ] || fail 'oversized body must not be appended to the NDJSON log'

printf '%s\n' 'test-timing-log-cgi.sh: ok'
