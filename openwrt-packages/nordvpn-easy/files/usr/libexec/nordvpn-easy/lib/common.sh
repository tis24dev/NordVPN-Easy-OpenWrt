#!/bin/sh

nordvpn_easy_log() {
	[ -t 2 ] && printf '*** %s ***\n' "$*" >&2
	if command -v logger >/dev/null 2>&1; then
		logger -t 'nordvpn-easy' "$*" >/dev/null 2>&1 || true
	fi
	return 0
}

nordvpn_easy_log_phase() {
	local phase="$1"
	shift
	local prefix=''

	if [ -n "${ACTION:-}" ] && [ -n "${ACTION_TRACE_ID:-}" ]; then
		prefix="${phase}[${ACTION}/${ACTION_TRACE_ID}]"
	elif [ -n "${ACTION:-}" ]; then
		prefix="${phase}[${ACTION}]"
	else
		prefix="$phase"
	fi

	nordvpn_easy_log "${prefix}: $*"
}

nordvpn_easy_log_blocker() {
	local phase="${1:-runtime}"
	shift

	nordvpn_easy_log_phase "$phase" "BLOCKER: $*"
}

nordvpn_easy_debug_cli_args() {
	if [ $# -eq 0 ]; then
		printf '%s\n' 'none'
		return 0
	fi

	printf '%s' "$1"
	shift

	while [ $# -gt 0 ]; do
		printf ' %s' "$1"
		shift
	done

	printf '\n'
}

nordvpn_easy_curl_rc_meaning() {
	case "$1" in
		0)  printf 'ok' ;;
		6)  printf 'could not resolve host (DNS failure)' ;;
		7)  printf 'failed to connect to host' ;;
		28) printf 'operation timed out' ;;
		35) printf 'SSL/TLS handshake failed' ;;
		52) printf 'empty reply from server' ;;
		56) printf 'receive failure' ;;
		*)  printf 'curl error %s' "$1" ;;
	esac
}

nordvpn_easy_json_escape() {
	printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r/\\r/g'
}

nordvpn_easy_lock_contention_is_nonfatal() {
	case "$ACTION" in
		run|check|refresh_countries)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

nordvpn_easy_require_commands() {
	local cmd

	nordvpn_easy_log 'Validating required system commands'
	for cmd in awk curl ifdown ifup ip jq ping uci; do
		command -v "$cmd" >/dev/null 2>&1 || {
			nordvpn_easy_log_blocker 'runtime' "required command '$cmd' is missing"
			return 1
		}
	done
	nordvpn_easy_log 'Required system commands are available'
}

nordvpn_easy_server_selection_is_manual() {
	[ "$SERVER_SELECTION_MODE" = 'manual' ]
}

nordvpn_easy_server_cache_is_enabled() {
	[ "$SERVER_CACHE_ENABLED" = '1' ]
}

nordvpn_easy_current_server_station() {
	uci -q get "network.${VPN_IF}server.nordvpn_station" 2>/dev/null || \
	uci -q get "network.${VPN_IF}server.endpoint_host" 2>/dev/null
}

nordvpn_easy_set_server_preference_in_uci() {
	uci set "nordvpn_easy.main.preferred_server_hostname"="$1"
	uci set "nordvpn_easy.main.preferred_server_station"="$2"
}

nordvpn_easy_require_manual_server_preference() {
	nordvpn_easy_server_selection_is_manual || return 0

	[ -n "$VPN_COUNTRY" ] || {
		nordvpn_easy_log_blocker 'apply' 'manual server selection requires a VPN_COUNTRY'
		return 1
	}

	[ -n "$PREFERRED_SERVER_HOSTNAME" ] || {
		nordvpn_easy_log_blocker 'apply' 'manual server selection requires a PREFERRED_SERVER_HOSTNAME'
		return 1
	}

	[ -n "$PREFERRED_SERVER_STATION" ] || {
		nordvpn_easy_log_blocker 'apply' 'manual server selection requires a PREFERRED_SERVER_STATION'
		return 1
	}
}

nordvpn_easy_server_cache_ttl_value() {
	case "$SERVER_CACHE_TTL" in
		''|*[!0-9]*)
			printf '%s\n' '86400'
			;;
		*)
			printf '%s\n' "$SERVER_CACHE_TTL"
			;;
	esac
}

nordvpn_easy_release_lock() {
	[ "$LOCK_ACQUIRED" -eq 1 ] || return 0
	rm -rf "$LOCK_DIR"
	LOCK_ACQUIRED=0
	nordvpn_easy_log_phase 'runtime' "execution lock released at $LOCK_DIR"
}

nordvpn_easy_acquire_lock() {
	local lock_pid_file="${LOCK_DIR}/pid"
	local lock_action_file="${LOCK_DIR}/action"
	local lock_pid=''

	if mkdir "$LOCK_DIR" 2>/dev/null; then
		if ! printf '%s\n' "$$" > "$lock_pid_file" || ! printf '%s\n' "$ACTION" > "$lock_action_file"; then
			rm -rf "$LOCK_DIR" 2>/dev/null
			nordvpn_easy_log_blocker 'runtime' "could not write execution lock metadata into $LOCK_DIR"
			return 1
		fi
		LOCK_ACQUIRED=1
		trap 'nordvpn_easy_release_lock' EXIT HUP INT TERM
		nordvpn_easy_log_phase 'runtime' "execution lock acquired at $LOCK_DIR"
		return 0
	fi

	if [ -f "$lock_pid_file" ]; then
		lock_pid="$(cat "$lock_pid_file" 2>/dev/null)"
		if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
			nordvpn_easy_log_blocker 'runtime' "execution lock is already held by PID $lock_pid"
			return 2
		fi
	fi

	nordvpn_easy_log_phase 'runtime' "recovering stale execution lock at $LOCK_DIR"
	rm -rf "$LOCK_DIR" 2>/dev/null || return 1

	mkdir "$LOCK_DIR" 2>/dev/null || return 1
	if ! printf '%s\n' "$$" > "$lock_pid_file" || ! printf '%s\n' "$ACTION" > "$lock_action_file"; then
		rm -rf "$LOCK_DIR" 2>/dev/null
		nordvpn_easy_log_blocker 'runtime' "could not write execution lock metadata into $LOCK_DIR"
		return 1
	fi
	LOCK_ACQUIRED=1
	trap 'nordvpn_easy_release_lock' EXIT HUP INT TERM
	nordvpn_easy_log_phase 'runtime' "recovered and acquired execution lock at $LOCK_DIR"
}

nordvpn_easy_export_diagnostics_log() {
	local service_name="${1:-nordvpn-easy}"
	local tmp_log="/tmp/${service_name}.diagnostics.$$"

	command -v logread >/dev/null 2>&1 || {
		nordvpn_easy_log 'logread command not found'
		return 1
	}

	logread -e "$service_name" > "$tmp_log" || {
		rm -f "$tmp_log"
		return 1
	}

	tail -n 500 "$tmp_log"
	rm -f "$tmp_log"
}
