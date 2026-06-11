#!/bin/sh
# Append LuCI timing NDJSON lines (POST body) for debug sessions.
# Must always emit HTTP headers (uhttpd returns 502 otherwise).

LOG_FILE="${NORDVPN_EASY_LUCI_TIMING_LOG:-/tmp/nordvpn-easy-luci-timing.ndjson}"
MAX_BYTES=1048576
# Cap the accepted request body: the only callers post tiny JSON records
# (timing milestones, country-match transitions), so anything larger is junk
# and must not be read into memory (a same-origin-but-unauthenticated CGI).
MAX_BODY_BYTES=8192

nordvpn_easy_timing_respond() {
	local body="$1"

	[ -n "$body" ] || body='{"ok":true}'

	printf 'Status: 200 OK\r\n'
	printf 'Content-Type: application/json\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf '\r\n'
	printf '%s\n' "$body"
}

nordvpn_easy_timing_read_body() {
	local content_length=0
	local body=''

	case "${CONTENT_LENGTH:-}" in
		''|*[!0-9]*) content_length=0 ;;
		*) content_length="$CONTENT_LENGTH" ;;
	esac

	[ "$content_length" -gt 0 ] || return 0
	# Ignore oversized bodies without reading them (DoS guard).
	[ "$content_length" -le "${MAX_BODY_BYTES:-8192}" ] || return 0

	if command -v dd >/dev/null 2>&1; then
		body="$(dd bs=1 count="$content_length" 2>/dev/null | tr -d '\r')"
	elif command -v head >/dev/null 2>&1; then
		body="$(head -c "$content_length" 2>/dev/null | tr -d '\r')"
	else
		IFS= read -r body || body=''
	fi

	printf '%s' "$body"
}

if [ "${REQUEST_METHOD:-}" != 'POST' ]; then
	printf 'Status: 405 Method Not Allowed\r\n'
	printf 'Content-Type: application/json\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf '\r\n'
	printf '%s\n' '{"ok":false,"error":"method_not_allowed"}'
	exit 0
fi

line="$(nordvpn_easy_timing_read_body)"
line="$(printf '%s' "$line" | sed -n '1p')"

if [ -z "$line" ]; then
	nordvpn_easy_timing_respond '{"ok":true,"skipped":true}'
	exit 0
fi

# Mirror Country Match indicator transitions into the system log so the
# automatic diagnostics export (logread / diagnostics_log) records them. Match
# the stable event marker and log the human-readable message; no JSON parser is
# needed, and the controlled message never contains a double quote.
case "$line" in
	*'"event":"country_match"'*)
		cm_message="$(printf '%s' "$line" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')"
		if [ -n "$cm_message" ] && command -v logger >/dev/null 2>&1; then
			logger -t nordvpn-easy "luci: $cm_message"
		fi
		;;
esac

if [ -f "$LOG_FILE" ]; then
	current="$(wc -c < "$LOG_FILE" 2>/dev/null || printf '0')"
	case "$current" in
		''|*[!0-9]*) current=0 ;;
	esac
	if [ "$current" -gt "$MAX_BYTES" ]; then
		mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || rm -f "$LOG_FILE"
	fi
fi

printf '%s\n' "$line" >> "$LOG_FILE" || {
	nordvpn_easy_timing_respond '{"ok":false,"error":"write_failed"}'
	exit 0
}

nordvpn_easy_timing_respond '{"ok":true}'
exit 0
