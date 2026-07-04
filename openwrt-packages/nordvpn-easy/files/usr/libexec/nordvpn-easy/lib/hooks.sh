#!/bin/sh

# NordVPN-Easy recovery-hook installers (cron + hotplug), extracted from the init
# script (S7 increment 5c) so both the init service and the supervisor state machine
# install/refresh the recovery hooks from ONE place instead of the logic living only
# inside init.d. These functions reference the CALLER'S globals -- SERVICE_NAME,
# CRONTAB_PATH, CRON_BLOCK_BEGIN/END, HOTPLUG_PATH, the cfg_* config values, and
# log_service_info/error -- resolved at call time. The init script defines them
# directly; the supervisor provides them via a thin shim. Behaviour is unchanged
# from the in-init.d versions (moved verbatim).

enable_and_restart_cron() {
	# crond only scans /etc/crontabs when the cron service is enabled and running.
	/etc/init.d/cron enable >/dev/null 2>&1 || true
	restart_cron_service
}

# Merge our recovery cron into the shared root crontab as a delimited managed
# block, leaving any other crons untouched. Pass the desired cron line, or an
# empty string to remove our block. Returns 0 when the crontab changed, 2 when
# it was already up to date, 1 on error.
apply_crontab_block() {
	local desired_line="$1"
	local tmp_crontab=''

	mkdir -p "$(dirname "$CRONTAB_PATH")" 2>/dev/null || true
	tmp_crontab="$(mktemp /tmp/nordvpn-easy.crontab.XXXXXX 2>/dev/null)" || {
		log_service_error 'failed to create temporary crontab'
		return 1
	}

	# Copy the existing crontab minus any previous nordvpn-easy block.
	if [ -f "$CRONTAB_PATH" ]; then
		awk -v b="$CRON_BLOCK_BEGIN" -v e="$CRON_BLOCK_END" '
			$0 == b { skip = 1; next }
			$0 == e { skip = 0; next }
			!skip { print }
		' "$CRONTAB_PATH" > "$tmp_crontab" || {
			rm -f -- "$tmp_crontab"
			return 1
		}
	fi

	if [ -n "$desired_line" ]; then
		{
			printf '%s\n' "$CRON_BLOCK_BEGIN"
			printf '%s\n' "$desired_line"
			printf '%s\n' "$CRON_BLOCK_END"
		} >> "$tmp_crontab" || {
			rm -f -- "$tmp_crontab"
			return 1
		}
	fi

	# Retire the legacy /etc/cron.d hook BusyBox crond never executed.
	rm -f "$CRON_PATH" 2>/dev/null || true

	if [ -f "$CRONTAB_PATH" ] && cmp -s "$tmp_crontab" "$CRONTAB_PATH" 2>/dev/null; then
		rm -f -- "$tmp_crontab"
		return 2
	fi

	if [ ! -s "$tmp_crontab" ]; then
		rm -f -- "$tmp_crontab"
		if [ -f "$CRONTAB_PATH" ]; then
			# Our block was the only content: drop the now-empty crontab.
			rm -f "$CRONTAB_PATH"
			return 0
		fi
		# Nothing of ours and no existing crontab: avoid creating an empty file.
		return 2
	fi

	mv "$tmp_crontab" "$CRONTAB_PATH" || {
		rm -f -- "$tmp_crontab"
		return 1
	}
	chmod 0600 "$CRONTAB_PATH" 2>/dev/null || true
	return 0
}

write_desired_cron_hook_to() {
	local target="$1"
	local effective_cron_schedule=''
	local config_ready="${2:-0}"

	if [ "$config_ready" != '1' ]; then
		load_service_config || return 1
	fi

	if [ "${cfg_enabled:-0}" -eq 1 ] && [ -n "$cfg_check_cron_schedule" ]; then
		if ! validate_cron_schedule "$cfg_check_cron_schedule"; then
			return 1
		fi

		effective_cron_schedule="$(normalize_cron_schedule "$cfg_check_cron_schedule")"
		cat > "$target" <<EOF
$effective_cron_schedule [ -f $CONNECT_APPLY_GUARD ] || NORDVPN_EASY_BUSY_IS_OK=1 /etc/init.d/$SERVICE_NAME check 2>&1 | logger -t $SERVICE_NAME-cron
EOF
	else
		: > "$target"
	fi
}

validate_cron_schedule() {
	local schedule="$1"
	local validation_output=''

	if validation_output="$(
		printf '%s' "$schedule" | awk '
		BEGIN {
			valid = 1
			error = ""
			split("59 23 31 12 7", maxv, " ")
			split("0 0 1 1 0", minv, " ")
			split("minute hour day-of-month month day-of-week", field_name, " ")
		}
		function fail(msg) {
			if (valid) {
				valid = 0
				error = msg
			}
		}
		NR > 1 { fail("schedule must be a single line"); exit }
		{
			if (NF != 5) { fail("expected exactly 5 cron fields"); exit }
			for (i = 1; i <= NF; i++) {
				f = $i
				n = split(f, parts, ",")
				for (j = 1; j <= n; j++) {
					p = parts[j]
					if (p == "") {
						fail(sprintf("field %s contains an empty token", field_name[i]))
						continue
					}
					base = p
					if (p ~ /\//) {
						si = index(p, "/")
						stepstr = substr(p, si + 1)
						base = substr(p, 1, si - 1)
						if (stepstr !~ /^[0-9]+$/ || stepstr + 0 < 1 || stepstr + 0 > maxv[i] + 0) {
							fail(sprintf("field %s has invalid step \"%s\"", field_name[i], p))
							continue
						}
					}
					if (base == "*") {
						continue
					} else if (base ~ /^[0-9]+-[0-9]+$/) {
						split(base, rng, "-")
						if (rng[1]+0 < minv[i]+0 || rng[1]+0 > maxv[i]+0)
							fail(sprintf("field %s has out-of-range token \"%s\"", field_name[i], p))
						if (rng[2]+0 < minv[i]+0 || rng[2]+0 > maxv[i]+0)
							fail(sprintf("field %s has out-of-range token \"%s\"", field_name[i], p))
						if (rng[1]+0 > rng[2]+0)
							fail(sprintf("field %s has inverted range \"%s\"", field_name[i], p))
					} else if (base ~ /^[0-9]+$/) {
						if (base+0 < minv[i]+0 || base+0 > maxv[i]+0)
							fail(sprintf("field %s has out-of-range token \"%s\"", field_name[i], p))
					} else {
						fail(sprintf("field %s has invalid token \"%s\"", field_name[i], p))
					}
				}
			}
		}
		END {
			if (!valid)
				printf "%s", error
			exit(valid ? 0 : 1)
		}
	'
	)"; then
		CRON_VALIDATION_ERROR=''
		return 0
	fi

	CRON_VALIDATION_ERROR="$validation_output"
	return 1
}

normalize_cron_minute_field() {
	# Echo the minute field unchanged, unless it fires more often than every 5
	# minutes somewhere (smallest gap between fired minutes < 5, wrap included),
	# in which case echo '*/5'. This throttles dense lists/ranges (e.g. 0-4 or
	# 0,1,2,3,4), not just the */1..4 forms.
	printf '%s' "$1" | awk '
	{
		field = $0
		cnt = 0
		n = split(field, toks, ",")
		for (t = 1; t <= n; t++) {
			tok = toks[t]
			step = 1
			if (tok ~ /\//) {
				si = index(tok, "/")
				step = substr(tok, si + 1) + 0
				tok = substr(tok, 1, si - 1)
				if (step < 1) step = 1
			}
			if (tok == "*") { lo = 0; hi = 59 }
			else if (tok ~ /^[0-9]+-[0-9]+$/) { split(tok, r, "-"); lo = r[1] + 0; hi = r[2] + 0 }
			else if (tok ~ /^[0-9]+$/) { lo = tok + 0; hi = lo }
			else { print field; exit }
			if (lo > hi || lo < 0 || hi > 59) { print field; exit }
			for (m = lo; m <= hi; m += step) {
				if (!(m in seen)) { seen[m] = 1; mins[cnt++] = m }
			}
		}
		if (cnt <= 1) { print field; exit }
		for (a = 1; a < cnt; a++) {
			key = mins[a]; b = a - 1
			while (b >= 0 && mins[b] > key) { mins[b + 1] = mins[b]; b-- }
			mins[b + 1] = key
		}
		mingap = 60
		for (a = 0; a < cnt; a++) {
			nxt = (a + 1 < cnt) ? mins[a + 1] : mins[0] + 60
			gap = nxt - mins[a]
			if (gap < mingap) mingap = gap
		}
		if (mingap < 5) print "*/5"
		else print field
	}'
}

normalize_cron_schedule() {
	local schedule="$1"
	local minute hour dom month dow

	set -f
	# shellcheck disable=SC2086 # Cron validation guarantees exactly five fields.
	set -- $schedule
	set +f
	minute="${1:-}"
	hour="${2:-}"
	dom="${3:-}"
	month="${4:-}"
	dow="${5:-}"

	minute="$(normalize_cron_minute_field "$minute")"
	printf '%s %s %s %s %s\n' "$minute" "$hour" "$dom" "$month" "$dow"
}

install_cron_hook() {
	local config_ready="${1:-0}"
	local tmp_line=''
	local desired_line=''
	local effective_cron_schedule=''
	local rc=0

	if [ "$config_ready" != '1' ]; then
		load_service_config || return 1
	fi

	tmp_line="$(mktemp /tmp/nordvpn-easy.cron.XXXXXX 2>/dev/null)" || {
		log_service_error 'failed to create temporary cron hook file'
		return 1
	}

	if ! write_desired_cron_hook_to "$tmp_line" "$config_ready"; then
		rm -f -- "$tmp_line"
		log_service_error "invalid cron schedule '$cfg_check_cron_schedule' (${CRON_VALIDATION_ERROR:-unknown error}); refusing to update $CRONTAB_PATH"
		return 1
	fi
	desired_line="$(cat "$tmp_line" 2>/dev/null)"
	rm -f -- "$tmp_line"

	if [ -n "$desired_line" ]; then
		effective_cron_schedule="$(normalize_cron_schedule "$cfg_check_cron_schedule")"
		if [ "$effective_cron_schedule" != "$cfg_check_cron_schedule" ]; then
			log_service_info "cron schedule '$cfg_check_cron_schedule' is faster than the 5-minute minimum; using '$effective_cron_schedule'"
		fi
	fi

	apply_crontab_block "$desired_line"
	rc=$?
	case "$rc" in
		0)
			if [ -n "$desired_line" ]; then
				log_service_info "installed cron hook in $CRONTAB_PATH with schedule '$effective_cron_schedule'"
			else
				log_service_info "removed cron hook from $CRONTAB_PATH"
			fi
			enable_and_restart_cron
			;;
		2)
			log_service_info "cron hook unchanged in $CRONTAB_PATH"
			;;
		*)
			return 1
			;;
	esac
	return 0
}

install_hotplug_hook() {
	local config_ready="${1:-0}"
	local tmp_hotplug=''

	if [ "$config_ready" != '1' ]; then
		load_service_config || return 1
	fi
	mkdir -p /etc/hotplug.d/iface

	if [ "${cfg_enabled:-0}" -ne 1 ] || [ "${cfg_enable_hotplug:-0}" -ne 1 ]; then
		if [ -f "$HOTPLUG_PATH" ]; then
			rm -f "$HOTPLUG_PATH"
			log_service_info "removed hotplug hook from $HOTPLUG_PATH"
		else
			log_service_info "removed hotplug hook from $HOTPLUG_PATH"
		fi
		return 0
	fi

	tmp_hotplug="$(mktemp /tmp/nordvpn-easy.hotplug.XXXXXX 2>/dev/null)" || {
		log_service_error 'failed to create temporary hotplug hook file'
		return 1
	}

	cat > "$tmp_hotplug" <<EOF
#!/bin/sh
WAN_IF='$(nordvpn_easy_shell_quote "$cfg_wan_if")'
VPN_IF='$(nordvpn_easy_shell_quote "$cfg_vpn_if")'
DEBOUNCE_SECONDS='$(nordvpn_easy_shell_quote "$cfg_hotplug_debounce_seconds")'
RUN_DIR='/tmp/run/nordvpn-easy'
LOCK_DIR='/tmp/nordvpn-easy.lock'
STAMP_FILE="\$RUN_DIR/hotplug.last"

case "\$ACTION" in
	ifup|ifupdate|ifdown) ;;
	*) exit 0 ;;
esac

[ "\$INTERFACE" = "\$WAN_IF" ] || [ "\$INTERFACE" = "\$VPN_IF" ] || exit 0

case "\$DEBOUNCE_SECONDS" in
	''|*[!0-9]*)
		DEBOUNCE_SECONDS='30'
		;;
esac

mkdir -p "\$RUN_DIR" 2>/dev/null || true
NOW_TS="\$(date +%s 2>/dev/null || printf '%s' '0')"

# S7 inc 7: skip an interface event the supervisor generated itself. Around its
# bring-up the supervisor writes \$RUN_DIR/self-ifevent (iface + a wall-clock expiry);
# while that sentinel names THIS interface and has not expired, the ifup/ifupdate is
# the supervisor's own. This covers the window where the async hotplug fires after the
# apply released the execution lock (the lock-busy check below alone would miss it).
SELF_IFEVENT="\$RUN_DIR/self-ifevent"
if [ -r "\$SELF_IFEVENT" ]; then
	SELF_IFACE=''
	SELF_EXPIRES='0'
	while IFS='=' read -r sk sv; do
		case "\$sk" in
			iface) SELF_IFACE="\$sv" ;;
			expires) SELF_EXPIRES="\$sv" ;;
		esac
	done < "\$SELF_IFEVENT"
	case "\$SELF_EXPIRES" in
		''|*[!0-9]*) SELF_EXPIRES='0' ;;
	esac
	if [ "\$SELF_IFACE" = "\$INTERFACE" ] && [ "\$SELF_EXPIRES" -gt "\$NOW_TS" ]; then
		logger -t $SERVICE_NAME-hotplug "skipped \$ACTION for \$INTERFACE (self-generated by supervisor apply)"
		exit 0
	fi
fi

LAST_TS="\$(cat "\$STAMP_FILE" 2>/dev/null || printf '%s' '0')"
case "\$NOW_TS:\$LAST_TS" in
	*[!0-9:]*|0:*)
		LAST_TS='0'
		;;
esac

if [ "\$LAST_TS" -gt 0 ] && [ \$((NOW_TS - LAST_TS)) -lt "\$DEBOUNCE_SECONDS" ]; then
	logger -t $SERVICE_NAME-hotplug "debounced \$ACTION for \$INTERFACE (last=\${LAST_TS}, debounce=\${DEBOUNCE_SECONDS}s)"
	exit 0
fi

printf '%s\n' "\$NOW_TS" > "\$STAMP_FILE" 2>/dev/null || true

if [ -f "\$RUN_DIR/connect-apply-guard" ]; then
	logger -t $SERVICE_NAME-hotplug "skipped \$ACTION for \$INTERFACE during connect apply"
	exit 0
fi

if [ -r "\$LOCK_DIR/pid" ]; then
	LOCK_PID="\$(cat "\$LOCK_DIR/pid" 2>/dev/null || true)"
	case "\$LOCK_PID" in
		''|*[!0-9]*)
			;;
		*)
			if kill -0 "\$LOCK_PID" 2>/dev/null; then
				LOCK_ACTION="\$(cat "\$LOCK_DIR/action" 2>/dev/null || printf '%s' 'unknown')"
				LOCK_STARTED_AT="\$(cat "\$LOCK_DIR/started_at" 2>/dev/null || printf '%s' '0')"
				case "\$LOCK_STARTED_AT" in
					''|*[!0-9]*)
						LOCK_AGE='0'
						;;
					*)
						LOCK_AGE=\$((NOW_TS - LOCK_STARTED_AT))
						[ "\$LOCK_AGE" -ge 0 ] || LOCK_AGE='0'
						;;
				esac
				logger -t $SERVICE_NAME-hotplug "skipped \$ACTION for \$INTERFACE because runtime operation is busy (holder_action=\$LOCK_ACTION, holder_pid=\$LOCK_PID, holder_age_seconds=\$LOCK_AGE)"
				exit 0
			fi
			;;
	esac
fi

NORDVPN_EASY_BUSY_IS_OK=1 /etc/init.d/$SERVICE_NAME check 2>&1 | logger -t $SERVICE_NAME-hotplug
EOF

	if [ -f "$HOTPLUG_PATH" ] && cmp -s "$tmp_hotplug" "$HOTPLUG_PATH" 2>/dev/null; then
		rm -f -- "$tmp_hotplug"
		log_service_info "hotplug hook unchanged at $HOTPLUG_PATH"
		return 0
	fi

	mv "$tmp_hotplug" "$HOTPLUG_PATH" || {
		rm -f -- "$tmp_hotplug"
		return 1
	}
	chmod 755 "$HOTPLUG_PATH"
	log_service_info "installed hotplug hook at $HOTPLUG_PATH for wan_if=$cfg_wan_if vpn_if=$cfg_vpn_if"
}
