#!/bin/sh

# Supervisor phase runner (S7). nordvpn_easy_run_phase is DEFINED here but has NO
# callers yet: the supervised state machine that drives it lands in a later
# increment (it stays dead code, gated behind orchestrator=supervisor, until then).
#
# run_phase records a journal phase boundary (preserving the transaction identity),
# runs the phase body under a best-effort watchdog, and retries only
# network-classified failures with a capped backoff. The watchdog bounds an
# INTERRUPTIBLE overrun; it cannot kill a D-state syscall -- the TTL reaper (in the
# lock acquire path) is the authoritative bound for a wedged worker. A body forked
# behind the subshell may briefly outlive a kill; that is acceptable best-effort.

# Classify a phase failure from the journal's last_error. A 'network.*' error is
# transient (retry); local/config/unknown fail fast (a bad token or invalid config
# will not fix itself by retrying, and blind retries just churn).
nordvpn_easy_phase_error_retryable() {
	case "${1:-}" in
		network|network.*) return 0 ;;
		*) return 1 ;;
	esac
}

# Capped backoff (seconds) for attempt N. Base is overridable so tests do not sleep.
nordvpn_easy_phase_backoff_seconds() {
	local attempt="${1:-1}"
	local base cap val
	base="${NORDVPN_EASY_PHASE_BACKOFF_BASE:-2}"
	cap="${NORDVPN_EASY_PHASE_BACKOFF_CAP:-30}"
	case "$attempt" in ''|*[!0-9]*) attempt=1 ;; esac
	case "$base" in ''|*[!0-9]*) base=2 ;; esac
	case "$cap" in ''|*[!0-9]*) cap=30 ;; esac
	val=$((base * attempt))
	[ "$val" -gt "$cap" ] && val="$cap"
	printf '%s' "$val"
}

# run_phase NAME TIMEOUT RETRIES FN
#   NAME     journal phase name written before the body runs
#   TIMEOUT  seconds the watchdog allows the body before it is killed
#   RETRIES  max attempts (>=1); only network-classified failures are retried
#   FN       the phase body (a function name); rc 0 = success
# Returns 0 on success, else the last attempt's rc.
nordvpn_easy_run_phase() {
	local name="$1"
	local timeout="$2"
	local retries="$3"
	local fn="$4"
	local attempt=1 rc now deadline last_error fpid wpid backoff

	case "$timeout" in ''|*[!0-9]*) timeout=60 ;; esac
	case "$retries" in ''|*[!0-9]*) retries=1 ;; esac
	[ "$retries" -ge 1 ] || retries=1

	while :; do
		now="$(date +%s 2>/dev/null || printf '0')"
		case "$now" in ''|*[!0-9]*) now=0 ;; esac
		deadline=$((now + timeout))

		# Journal boundary BEFORE the body, so a concurrent status/reaper sees the
		# phase and its deadline. Merge to keep the txn identity; best-effort (the
		# journal is shadow until the state machine makes it authoritative).
		if command -v nordvpn_easy_journal_set >/dev/null 2>&1; then
			nordvpn_easy_journal_set \
				"phase=$name" \
				"phase_attempt=$attempt" \
				"phase_deadline=$deadline" >/dev/null 2>&1 || true
		fi

		# Run the body in the background and cap it with a POLLING watchdog: it wakes
		# every second and exits the instant the body is gone, so it never blocks the
		# cleanup for the full timeout (a plain `sleep $timeout` watchdog would, if the
		# post-body kill raced and missed it). It kills the body only on a real
		# overrun. Best-effort: it cannot kill a D-state syscall (the TTL reaper is the
		# authoritative bound). wait's non-zero is handled under `set -e` (|| rc=$?).
		rc=0
		"$fn" & fpid=$!
		(
			wd_n=0
			while [ "$wd_n" -lt "$timeout" ] && kill -0 "$fpid" 2>/dev/null; do
				sleep 1
				wd_n=$((wd_n + 1))
			done
			kill -0 "$fpid" 2>/dev/null && kill "$fpid" 2>/dev/null
		) & wpid=$!
		wait "$fpid" 2>/dev/null || rc=$?
		kill "$wpid" 2>/dev/null || true
		wait "$wpid" 2>/dev/null || true

		[ "$rc" -eq 0 ] && return 0

		last_error="$(nordvpn_easy_journal_get last_error 2>/dev/null || printf '')"
		if nordvpn_easy_phase_error_retryable "$last_error" && [ "$attempt" -lt "$retries" ]; then
			backoff="$(nordvpn_easy_phase_backoff_seconds "$attempt")"
			case "$backoff" in ''|*[!0-9]*) backoff=0 ;; esac
			[ "$backoff" -gt 0 ] && sleep "$backoff"
			attempt=$((attempt + 1))
			continue
		fi
		return "$rc"
	done
}
