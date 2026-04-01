#!/bin/sh

NORDVPN_EASY_TEMP_PATHS="${NORDVPN_EASY_TEMP_PATHS:-}"
NORDVPN_EASY_EXIT_TRAP_INSTALLED="${NORDVPN_EASY_EXIT_TRAP_INSTALLED:-0}"

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

nordvpn_easy_install_exit_trap() {
	[ "${NORDVPN_EASY_EXIT_TRAP_INSTALLED:-0}" -eq 1 ] && return 0

	trap 'nordvpn_easy_on_exit' EXIT
	trap 'nordvpn_easy_on_signal 1' HUP
	trap 'nordvpn_easy_on_signal 2' INT
	trap 'nordvpn_easy_on_signal 15' TERM
	NORDVPN_EASY_EXIT_TRAP_INSTALLED=1
}

nordvpn_easy_register_temp_path() {
	local temp_path="$1"

	[ -n "$temp_path" ] || return 1

	case "
$NORDVPN_EASY_TEMP_PATHS
" in
	*"
$temp_path
"*)
		return 0
		;;
	esac

	NORDVPN_EASY_TEMP_PATHS="${NORDVPN_EASY_TEMP_PATHS}${temp_path}
"
}

nordvpn_easy_cleanup_temp_paths() {
	local old_ifs="$IFS"
	local temp_path

	IFS='
'
	for temp_path in $NORDVPN_EASY_TEMP_PATHS; do
		[ -n "$temp_path" ] || continue
		rm -rf -- "$temp_path"
	done
	IFS="$old_ifs"

	NORDVPN_EASY_TEMP_PATHS=''
}

nordvpn_easy_mktemp_dir() {
	local prefix="${1:-runtime}"
	local result_var="${2:-}"
	local workspace_dir=''
	local original_umask=''

	command -v mktemp >/dev/null 2>&1 || {
		nordvpn_easy_log_blocker 'runtime' "required command 'mktemp' is missing"
		return 1
	}

	original_umask="$(umask)"
	umask 077
	workspace_dir="$(mktemp -d "/tmp/nordvpn-easy.${prefix}.XXXXXX" 2>/dev/null)" || {
		umask "$original_umask"
		nordvpn_easy_log_blocker 'runtime' "could not create secure temporary workspace for ${prefix}"
		return 1
	}
	umask "$original_umask"

	nordvpn_easy_register_temp_path "$workspace_dir" || {
		rm -rf -- "$workspace_dir"
		return 1
	}

	if [ -n "$result_var" ]; then
		eval "$result_var='$(printf "%s" "$workspace_dir" | sed "s/'/'\\\\''/g")'"
	else
		printf '%s\n' "$workspace_dir"
	fi
}

nordvpn_easy_temp_file_path() {
	printf '%s/%s\n' "$1" "$2"
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
	for cmd in awk curl ifdown ifup ip jq mktemp ping uci; do
		command -v "$cmd" >/dev/null 2>&1 || {
			nordvpn_easy_log_blocker 'runtime' "required command '$cmd' is missing"
			return 1
		}
	done
	nordvpn_easy_log 'Required system commands are available'
}

nordvpn_easy_lock_age_seconds() {
	local lock_path="$1"
	local started_at="${2:-}"
	local now_ts=0
	local lock_ts=0
	local age=0

	now_ts="$(date +%s 2>/dev/null || printf '0')"
	case "$started_at" in
		''|*[!0-9]*)
			lock_ts="$(stat -c %Y "$lock_path" 2>/dev/null || printf '0')"
			;;
		*)
			lock_ts="$started_at"
			;;
	esac

	case "$now_ts:$lock_ts" in
		*[!0-9:]*|0:*|*:0)
			printf '%s\n' '0'
			return 0
			;;
	esac

	age=$((now_ts - lock_ts))
	[ "$age" -lt 0 ] && age=0
	printf '%s\n' "$age"
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
	[ "${LOCK_ACQUIRED:-0}" -eq 1 ] || return 0
	[ -n "${LOCK_DIR:-}" ] || return 0
	rm -rf "${LOCK_DIR:-}"
	LOCK_ACQUIRED=0
	nordvpn_easy_log_phase 'runtime' "execution lock released at $LOCK_DIR"
}

nordvpn_easy_write_lock_metadata() {
	local lock_dir="$1"
	local lock_pid="$2"
	local lock_action="$3"
	local lock_started_at="$4"
	local lock_state="$5"

	printf '%s\n' "$lock_pid" > "${lock_dir}/pid" || return 1
	printf '%s\n' "$lock_action" > "${lock_dir}/action" || return 1
	printf '%s\n' "$lock_started_at" > "${lock_dir}/started_at" || return 1
	printf '%s\n' "$lock_state" > "${lock_dir}/state" || return 1
}

nordvpn_easy_acquire_lock() {
	local lock_pid_file="${LOCK_DIR}/pid"
	local lock_action_file="${LOCK_DIR}/action"
	local lock_started_at_file="${LOCK_DIR}/started_at"
	local lock_pid=''
	local lock_action=''
	local lock_started_at=''
	local lock_age='0'
	local now_ts=0
	local stale_reason='unknown'

	now_ts="$(date +%s 2>/dev/null || printf '0')"
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		if ! nordvpn_easy_write_lock_metadata "$LOCK_DIR" "$$" "${ACTION:-unknown}" "$now_ts" 'held'; then
			rm -rf "$LOCK_DIR" 2>/dev/null
			nordvpn_easy_log_blocker 'runtime' "could not write execution lock metadata into $LOCK_DIR"
			return 1
		fi
		LOCK_ACQUIRED=1
		nordvpn_easy_install_exit_trap
		nordvpn_easy_log_phase 'runtime' "execution lock acquired at $LOCK_DIR"
		return 0
	fi

	if [ ! -d "$LOCK_DIR" ]; then
		nordvpn_easy_log_blocker 'runtime' "could not create execution lock directory at $LOCK_DIR"
		return 1
	fi

	if [ ! -f "$lock_pid_file" ]; then
		lock_action="$(cat "$lock_action_file" 2>/dev/null)"
		lock_started_at="$(cat "$lock_started_at_file" 2>/dev/null)"
		lock_age="$(nordvpn_easy_lock_age_seconds "$LOCK_DIR" "$lock_started_at")"
		nordvpn_easy_log_blocker 'runtime' "execution lock metadata is incomplete (missing pid metadata, action=${lock_action:-unknown}, age=${lock_age}s)"
		return 2
	else
		lock_pid="$(cat "$lock_pid_file" 2>/dev/null)"
		case "$lock_pid" in
			''|*[!0-9]*)
				stale_reason="invalid pid metadata (${lock_pid:-empty})"
				;;
			*)
				if kill -0 "$lock_pid" 2>/dev/null; then
					lock_action="$(cat "$lock_action_file" 2>/dev/null)"
					lock_started_at="$(cat "$lock_started_at_file" 2>/dev/null)"
					lock_age="$(nordvpn_easy_lock_age_seconds "$LOCK_DIR" "$lock_started_at")"
					nordvpn_easy_log_blocker 'runtime' "execution lock is already held by PID $lock_pid (action=${lock_action:-unknown}, age=${lock_age}s)"
					return 2
				fi
				stale_reason="owner PID $lock_pid is no longer alive"
				;;
		esac
	fi

	nordvpn_easy_log_phase 'runtime' "recovering stale execution lock at $LOCK_DIR (reason: ${stale_reason})"
	rm -rf "$LOCK_DIR" 2>/dev/null || return 1

	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		if [ -d "$LOCK_DIR" ]; then
			nordvpn_easy_log_blocker 'runtime' "lost race recovering stale lock at $LOCK_DIR"
			return 2
		fi
		nordvpn_easy_log_blocker 'runtime' "could not recreate execution lock directory at $LOCK_DIR"
		return 1
	fi
	if ! nordvpn_easy_write_lock_metadata "$LOCK_DIR" "$$" "${ACTION:-unknown}" "$now_ts" 'stale_recovered'; then
		rm -rf "$LOCK_DIR" 2>/dev/null
		nordvpn_easy_log_blocker 'runtime' "could not write execution lock metadata into $LOCK_DIR"
		return 1
	fi

	local verify_pid
	verify_pid="$(cat "$lock_pid_file" 2>/dev/null)"
	if [ "$verify_pid" != "$$" ]; then
		nordvpn_easy_log_blocker 'runtime' "lock ownership verification failed (expected $$, got ${verify_pid:-empty})"
		rm -rf "$LOCK_DIR" 2>/dev/null
		return 2
	fi

	LOCK_ACQUIRED=1
	nordvpn_easy_install_exit_trap
	nordvpn_easy_log_phase 'runtime' "recovered and acquired execution lock at $LOCK_DIR (reason: ${stale_reason})"
}

nordvpn_easy_on_exit() {
	nordvpn_easy_release_lock
	nordvpn_easy_cleanup_temp_paths
}

nordvpn_easy_on_signal() {
	local signal_num="${1:-0}"

	trap - EXIT HUP INT TERM
	nordvpn_easy_on_exit

	case "$signal_num" in
		''|*[!0-9]*)
			exit 1
			;;
		*)
			exit $((128 + signal_num))
			;;
	esac
}

nordvpn_easy_export_diagnostics_log() {
	local service_name="${1:-nordvpn-easy}"
	local temp_dir=''
	local tmp_log=''
	local tail_rc=0

	command -v logread >/dev/null 2>&1 || {
		nordvpn_easy_log 'logread command not found'
		return 1
	}

	nordvpn_easy_mktemp_dir 'diagnostics' temp_dir || return 1
	tmp_log="$(nordvpn_easy_temp_file_path "$temp_dir" "${service_name}.diagnostics.log")"

	logread -e "$service_name" > "$tmp_log" || {
		rm -rf -- "$temp_dir"
		return 1
	}

	tail -n 500 "$tmp_log" || tail_rc=$?
	rm -rf -- "$temp_dir"
	return "$tail_rc"
}
