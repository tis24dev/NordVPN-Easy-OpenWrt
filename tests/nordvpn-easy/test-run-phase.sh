#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

assert_eq() {
	if [ "$1" != "$2" ]; then
		printf '%s\n' "FAIL: $3" >&2
		printf '%s\n' "expected: $1" >&2
		printf '%s\n' "actual:   $2" >&2
		exit 1
	fi
}

NORDVPN_EASY_JOURNAL_FILE="$TMP_DIR/journal"
# The phase body runs in a background subshell, so shell-variable side effects are
# lost; the test bodies signal through FILES instead.
ATTEMPTS="$TMP_DIR/attempts"
OBSERVED="$TMP_DIR/observed"
# No real backoff sleeping in the test.
NORDVPN_EASY_PHASE_BACKOFF_BASE=0

# shellcheck disable=SC1090
. "$LIB/journal.sh"
# shellcheck disable=SC1090
. "$LIB/supervise.sh"

# --- classifier + backoff units ---------------------------------------------
nordvpn_easy_phase_error_retryable 'network' && : || { echo 'FAIL: network is retryable' >&2; exit 1; }
nordvpn_easy_phase_error_retryable 'network.timeout' && : || { echo 'FAIL: network.* is retryable' >&2; exit 1; }
nordvpn_easy_phase_error_retryable 'config.invalid' && { echo 'FAIL: config must NOT be retryable' >&2; exit 1; } || :
nordvpn_easy_phase_error_retryable '' && { echo 'FAIL: empty must NOT be retryable' >&2; exit 1; } || :
assert_eq '4' "$(NORDVPN_EASY_PHASE_BACKOFF_BASE=2 nordvpn_easy_phase_backoff_seconds 2)" 'backoff base*attempt'
assert_eq '30' "$(NORDVPN_EASY_PHASE_BACKOFF_BASE=2 NORDVPN_EASY_PHASE_BACKOFF_CAP=30 nordvpn_easy_phase_backoff_seconds 100)" 'backoff is capped'

# --- success: rc 0, returns immediately -------------------------------------
phase_ok() { return 0; }
ok_rc=0
nordvpn_easy_run_phase 'validate' 5 1 phase_ok || ok_rc=$?
assert_eq '0' "$ok_rc" 'run_phase returns 0 when the body succeeds'
assert_eq 'validate' "$(nordvpn_easy_journal_get phase)" 'run_phase records the phase name'

# --- the journal boundary (phase + deadline) is written BEFORE the body ------
phase_observe() {
	{ printf '%s ' "$(nordvpn_easy_journal_get phase)"; nordvpn_easy_journal_get phase_deadline; } > "$OBSERVED"
	return 0
}
before="$(date +%s)"
nordvpn_easy_run_phase 'configure' 30 1 phase_observe
obs_phase="$(cut -d' ' -f1 "$OBSERVED")"
obs_deadline="$(cut -d' ' -f2 "$OBSERVED")"
assert_eq 'configure' "$obs_phase" 'the body sees the phase written before it runs'
case "$obs_deadline" in ''|*[!0-9]*) printf '%s\n' "FAIL: phase_deadline not numeric: $obs_deadline" >&2; exit 1 ;; esac
[ "$obs_deadline" -ge "$((before + 30))" ] || { printf '%s\n' "FAIL: deadline must be now+timeout (got $obs_deadline, before $before)" >&2; exit 1; }

# --- network failures retry up to RETRIES with backoff ----------------------
: > "$ATTEMPTS"
phase_net_fail() {
	printf 'x\n' >> "$ATTEMPTS"
	nordvpn_easy_journal_set 'last_error=network.timeout' >/dev/null 2>&1 || true
	return 1
}
net_rc=0
nordvpn_easy_run_phase 'fetch' 5 3 phase_net_fail || net_rc=$?
[ "$net_rc" -ne 0 ] || { echo 'FAIL: a network phase that never succeeds must fail' >&2; exit 1; }
assert_eq '3' "$(wc -l < "$ATTEMPTS" | tr -d ' ')" 'a network failure retries up to RETRIES attempts'

# --- local/config failures fail fast (no retry) -----------------------------
: > "$ATTEMPTS"
phase_cfg_fail() {
	printf 'x\n' >> "$ATTEMPTS"
	nordvpn_easy_journal_set 'last_error=config.invalid' >/dev/null 2>&1 || true
	return 1
}
cfg_rc=0
nordvpn_easy_run_phase 'validate' 5 3 phase_cfg_fail || cfg_rc=$?
[ "$cfg_rc" -ne 0 ] || { echo 'FAIL: a config phase failure must fail' >&2; exit 1; }
assert_eq '1' "$(wc -l < "$ATTEMPTS" | tr -d ' ')" 'a config failure fails fast (no retry)'

# --- watchdog kills an interruptible overrun (best-effort bound) -------------
# `exec sleep` so the killed pid IS the sleeper (no orphaned child).
phase_sleeper() { exec sleep 30; }
wd_start="$(date +%s)"
wd_rc=0
nordvpn_easy_run_phase 'bringup' 1 1 phase_sleeper || wd_rc=$?
wd_end="$(date +%s)"
[ "$wd_rc" -ne 0 ] || { echo 'FAIL: an overrunning body must be killed and fail' >&2; exit 1; }
[ "$((wd_end - wd_start))" -lt 10 ] || { printf '%s\n' "FAIL: watchdog must kill near the 1s timeout, took $((wd_end - wd_start))s" >&2; exit 1; }

# --- a self-completing body does not hang on the watchdog (no double-kill) ---
phase_fast() { return 0; }
fast_start="$(date +%s)"
nordvpn_easy_run_phase 'verify' 30 1 phase_fast
fast_end="$(date +%s)"
[ "$((fast_end - fast_start))" -lt 10 ] || { printf '%s\n' 'FAIL: a fast body must not wait on the watchdog timeout' >&2; exit 1; }

printf '%s\n' 'test-run-phase.sh: ok'
