#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
LIB_DIR="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
COMMON_LIB="$LIB_DIR/common.sh"
CORE="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/core.sh"

# shellcheck disable=SC1090
. "$COMMON_LIB"

# Pull only the helper functions under test out of core.sh, without sourcing the
# whole script (its action-dispatch tail would acquire the runtime lock and exit).
# Extracting them (rather than copying) keeps this test in lockstep with the
# production definitions, so a regression there is caught here.
extract_function() {
	awk -v fn="$1" '
		$0 ~ ("^" fn " ?\\(\\)") { capture = 1 }
		capture { print }
		capture && /^}/ { exit }
	' "$2"
}
eval "$(extract_function curl_rc_meaning "$CORE")"
eval "$(extract_function get_private_key_error_message "$CORE")"
eval "$(extract_function get_private_key "$CORE")"

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
			printf '%s\n' "needle:   $needle" >&2
			printf '%s\n' "haystack: $haystack" >&2
			exit 1
			;;
	esac
}

assert_not_contains() {
	haystack="$1"
	needle="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "forbidden needle: $needle" >&2
			printf '%s\n' "haystack:         $haystack" >&2
			exit 1
			;;
	esac
}

# --- nordvpn_easy_token_shape_is_canonical (warn-only shape check) ---
TOKEN_64="$(printf '%064d' 0 | tr '0' 'a')"
nordvpn_easy_token_shape_is_canonical "$TOKEN_64" || {
	printf '%s\n' 'FAIL: a 64-char lowercase-hex token must be canonical' >&2
	exit 1
}
SHAPE_RC=0
nordvpn_easy_token_shape_is_canonical "$(printf '%063d' 0 | tr '0' 'a')" || SHAPE_RC=$?
assert_eq '1' "$SHAPE_RC" 'a 63-char token is not canonical'
SHAPE_RC=0
nordvpn_easy_token_shape_is_canonical "$(printf '%064d' 0 | tr '0' 'A')" || SHAPE_RC=$?
assert_eq '1' "$SHAPE_RC" 'an uppercase-hex token is not canonical'
SHAPE_RC=0
nordvpn_easy_token_shape_is_canonical '' || SHAPE_RC=$?
assert_eq '1' "$SHAPE_RC" 'an empty token is not canonical'

# --- get_private_key branched, actionable error messages ---
# Capture the recorded/logged message instead of touching the real cache/logger.
CAPTURED_MESSAGE=''
nordvpn_easy_record_last_error() {
	CAPTURED_MESSAGE="$*"
	NORDVPN_EASY_LAST_ERROR_RECORDED=1
}
nordvpn_easy_log_blocker() {
	shift 2>/dev/null || true
	CAPTURED_MESSAGE="$*"
}
log() { :; }

# Drive get_private_key through its fetch-failure branch by stubbing the fetch to
# populate the curl result globals and fail, exactly like the real curl path.
STUB_RC='0'
STUB_CODE='000'
STUB_ERR=''
fetch_credentials_json() {
	NORDVPN_EASY_CREDENTIALS_CURL_RC="$STUB_RC"
	NORDVPN_EASY_CREDENTIALS_HTTP_CODE="$STUB_CODE"
	NORDVPN_EASY_CREDENTIALS_CURL_ERROR="$STUB_ERR"
	return 1
}

NORDVPN_TOKEN='deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
LOG_PHASE='runtime'

run_case() {
	STUB_RC="$1"
	STUB_CODE="$2"
	STUB_ERR="${3:-}"
	CAPTURED_MESSAGE=''
	RC=0
	get_private_key || RC=$?
	[ "$RC" -ne 0 ] || {
		printf '%s\n' "FAIL: get_private_key must fail when the fetch fails (rc=$1 code=$2)" >&2
		exit 1
	}
}

# HTTP 400 / 401: invalid token -> regenerate-the-token wording.
run_case 22 400
assert_contains "$CAPTURED_MESSAGE" 'rejected the access token' 'HTTP 400 reports a rejected token'
assert_contains "$CAPTURED_MESSAGE" 'could not retrieve NordLynx private key' 'HTTP 400 keeps the stable diagnostics phrase'
run_case 22 401
assert_contains "$CAPTURED_MESSAGE" 'rejected the access token' 'HTTP 401 reports a rejected token'

# HTTP 403: account/subscription problem.
run_case 22 403
assert_contains "$CAPTURED_MESSAGE" '403' 'HTTP 403 message mentions the code'
assert_contains "$CAPTURED_MESSAGE" 'subscription' 'HTTP 403 message mentions the subscription'

# HTTP 429: rate limiting -> temporary.
run_case 22 429
assert_contains "$CAPTURED_MESSAGE" 'rate-limit' 'HTTP 429 message mentions rate-limiting'
assert_contains "$CAPTURED_MESSAGE" 'temporary' 'HTTP 429 message says it is temporary'

# 5xx (rc=22): server-side error -> temporary.
run_case 22 500
assert_contains "$CAPTURED_MESSAGE" 'server error' 'HTTP 500 message reports a server error'
assert_contains "$CAPTURED_MESSAGE" 'temporary' 'HTTP 500 message says it is temporary'
run_case 22 503
assert_contains "$CAPTURED_MESSAGE" 'server error' 'HTTP 503 message reports a server error'

# Transport failures (rc != 22) -> temporary network wording, NOT a token error.
run_case 28 000
assert_contains "$CAPTURED_MESSAGE" 'temporary network' 'curl timeout (rc=28) reports a temporary network problem'
assert_not_contains "$CAPTURED_MESSAGE" 'rejected the access token' 'curl timeout must NOT claim the token was rejected'
run_case 6 000
assert_contains "$CAPTURED_MESSAGE" 'temporary network' 'curl DNS failure (rc=6) reports a temporary network problem'
assert_not_contains "$CAPTURED_MESSAGE" 'rejected the access token' 'curl DNS failure must NOT claim the token was rejected'

# rc=22 with no usable HTTP code -> unexpected-response fallback.
run_case 22 000
assert_contains "$CAPTURED_MESSAGE" 'unexpected response' 'rc=22 http=000 falls back to the unexpected-response message'

# --- redaction guard: the token must never appear in any recorded message ---
run_case 22 400
assert_not_contains "$CAPTURED_MESSAGE" "$NORDVPN_TOKEN" 'recorded message must never contain the token'
run_case 28 000
assert_not_contains "$CAPTURED_MESSAGE" "$NORDVPN_TOKEN" 'transport-error message must never contain the token'
NORDVPN_TOKEN='deadbeefdeadbeef'
run_case 22 403
assert_not_contains "$CAPTURED_MESSAGE" "$NORDVPN_TOKEN" 'message must never contain a short token either'

printf '%s\n' 'test-credentials-errors.sh: ok'
