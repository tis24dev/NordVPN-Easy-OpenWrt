#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# Lightweight public IP detection for LuCI polls and rpcd.
# Always performs a live detect_public_ip() curl lookup; avoids init.d render_runtime_config.

PUBLIC_COUNTRY_API="${PUBLIC_COUNTRY_API:-https://api.country.is}"
PUBLIC_LOOKUP_LOG_MODE="${PUBLIC_LOOKUP_LOG_MODE:-verbose}"
NORDVPN_EASY_RUN_DIR="${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}"
NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE="${NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE:-$NORDVPN_EASY_RUN_DIR/public_verification}"

nordvpn_easy_public_ip_valid_ip() {
	local o='(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})'
	local ipv4="${o}\\.${o}\\.${o}\\.${o}"
	local h='[0-9A-Fa-f]{1,4}'
	local ipv6="(${h}:){7}${h}|(${h}:){1,7}:|(${h}:){1,6}:${h}|(${h}:){1,5}(:${h}){1,2}|(${h}:){1,4}(:${h}){1,3}|(${h}:){1,3}(:${h}){1,4}|(${h}:){1,2}(:${h}){1,5}|${h}:(:${h}){1,6}|:((:${h}){1,7}|:)"

	printf '%s' "$1" | grep -Eq "^(${ipv4}|${ipv6})$"
}

nordvpn_easy_public_ip_valid_country_code() {
	printf '%s' "$1" | grep -Eq '^[A-Z]{2}$'
}

nordvpn_easy_public_ip_log() {
	[ "${PUBLIC_LOOKUP_LOG_MODE:-verbose}" = 'quiet' ] || nordvpn_easy_log_phase "${LOG_PHASE:-poll}" "$@"
}

nordvpn_easy_public_ip_write_cache_file() {
	local cache_file="$1"
	local cache_value="$2"
	local cache_dir

	[ -n "$cache_file" ] || return 1
	cache_dir="$(dirname "$cache_file")"
	mkdir -p "$cache_dir" || return 1
	printf '%s\n' "$cache_value" > "${cache_file}.$$" || {
		rm -f "${cache_file}.$$"
		return 1
	}
	mv "${cache_file}.$$" "$cache_file"
}

nordvpn_easy_public_ip_write_keyval_cache() {
	local cache_dir cache_tmp

	cache_dir="$(dirname "$NORDVPN_EASY_PUBLIC_IP_CACHE")"
	mkdir -p "$cache_dir" || return 1
	cache_tmp="${NORDVPN_EASY_PUBLIC_IP_CACHE}.$$"
	{
		printf 'ip=%s\n' "$PUBLIC_IP"
		printf 'detected_at=%s\n' "${PUBLIC_IP_DETECTED_AT:-0}"
		printf 'detected_at_iso=%s\n' "$PUBLIC_IP_DETECTED_AT_ISO"
		printf 'source=%s\n' "$PUBLIC_IP_SOURCE"
	} > "$cache_tmp" || {
		rm -f "$cache_tmp"
		return 1
	}
	mv "$cache_tmp" "$NORDVPN_EASY_PUBLIC_IP_CACHE"
}

nordvpn_easy_public_verification_write() {
	local status="${1:-unknown}"
	local expected_country="${2:-}"
	local actual_country="${3:-}"
	local message="${4:-}"
	local checked_at='0'
	local cache_dir cache_tmp

	case "$status" in
		ok|pending|failed|mismatch|unknown)
			;;
		*)
			status='unknown'
			;;
	esac

	if [ "$status" != 'pending' ]; then
		checked_at="$(date +%s 2>/dev/null || printf '%s' '0')"
	fi

	cache_dir="$(dirname "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE")"
	mkdir -p "$cache_dir" || return 1
	cache_tmp="${NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE}.$$"
	{
		printf 'status=%s\n' "$status"
		printf 'checked_at=%s\n' "$checked_at"
		printf 'expected_country=%s\n' "$expected_country"
		printf 'actual_country=%s\n' "$actual_country"
		printf 'ip=%s\n' "${PUBLIC_IP:-}"
		printf 'source=%s\n' "${PUBLIC_IP_SOURCE:-}"
		printf 'message=%s\n' "$message"
	} > "$cache_tmp" || {
		rm -f "$cache_tmp"
		return 1
	}
	mv "$cache_tmp" "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE"
}

# Emit a single diagnostics-log line when the country-match outcome actually
# changes (status, selected country, or detected exit country), so the automatic
# log records the transition once instead of repeating it on every poll. Returns
# without logging when nothing changed.
nordvpn_easy_log_country_match_transition() {
	local new_status="$1"
	local expected="$2"
	local actual="$3"
	local old_status="$4"
	local old_expected="$5"
	local old_actual="$6"

	if [ "$new_status" = "$old_status" ] &&
		[ "$expected" = "$old_expected" ] &&
		[ "$actual" = "$old_actual" ]; then
		return 0
	fi

	nordvpn_easy_public_ip_log "country match changed: ${old_status:-unknown} -> ${new_status} (selected=${expected:-automatic}, exit=${actual:-unknown})"
}

nordvpn_easy_public_ip_endpoint_is_known() {
	case "$1" in
		https://ifconfig.me/ip|https://api.ipify.org|https://icanhazip.com)
			return 0
			;;
	esac

	return 1
}

nordvpn_easy_public_ip_clear_own_last_error() {
	local last_error=''

	[ -n "${NORDVPN_EASY_LAST_ERROR_CACHE:-}" ] || return 0
	[ -r "$NORDVPN_EASY_LAST_ERROR_CACHE" ] || return 0
	last_error="$(sed -n '1p' "$NORDVPN_EASY_LAST_ERROR_CACHE" 2>/dev/null || true)"
	case "$last_error" in
		public_ip\ failed*)
			nordvpn_easy_public_ip_write_cache_file "$NORDVPN_EASY_LAST_ERROR_CACHE" '' >/dev/null 2>&1 || true
			;;
	esac
}

nordvpn_easy_detect_public_ip() {
	local curl_out curl_rc preferred_source tried_urls=''

	nordvpn_easy_public_ip_log "public_ip_check: starting IPv4-only public IP lookup (system DNS: $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'))"
	preferred_source="$(sed -n 's/^source=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"

	for PUBLIC_IP_URL in \
		"$preferred_source" \
		'https://ifconfig.me/ip' \
		'https://api.ipify.org' \
		'https://icanhazip.com'
	do
		[ -n "$PUBLIC_IP_URL" ] || continue
		nordvpn_easy_public_ip_endpoint_is_known "$PUBLIC_IP_URL" || continue
		case "|$tried_urls|" in
			*"|$PUBLIC_IP_URL|"*)
				continue
				;;
		esac
		tried_urls="${tried_urls}|${PUBLIC_IP_URL}"

		nordvpn_easy_public_ip_log "public_ip_check: trying $PUBLIC_IP_URL"
		curl_out=$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$PUBLIC_IP_URL" 2>/dev/null | tr -d '\r\n')
		curl_rc=$?

		if [ "$curl_rc" -ne 0 ]; then
			nordvpn_easy_public_ip_log "public_ip_check: curl failed for $PUBLIC_IP_URL (curl_rc=$curl_rc: $(nordvpn_easy_curl_rc_meaning "$curl_rc"))"
			continue
		fi

		if [ -z "$curl_out" ]; then
			nordvpn_easy_public_ip_log "public_ip_check: curl succeeded (rc=0) but response body is empty for $PUBLIC_IP_URL"
			continue
		fi

		if ! nordvpn_easy_public_ip_valid_ip "$curl_out"; then
			nordvpn_easy_public_ip_log "public_ip_check: response from $PUBLIC_IP_URL is not a valid IP address (got '${curl_out}')"
			continue
		fi

		nordvpn_easy_public_ip_log "public_ip_check: got '$curl_out' from $PUBLIC_IP_URL"
		PUBLIC_IP="$curl_out"
		PUBLIC_IP_SOURCE="$PUBLIC_IP_URL"
		return 0
	done

	nordvpn_easy_public_ip_log 'ERROR: COULD NOT RETRIEVE PUBLIC IP — all endpoints failed'
	return 1
}

nordvpn_easy_update_public_ip_cache() {
	local previous_ip previous_detected_at previous_detected_at_iso previous_source
	local detected_at detected_at_iso should_write='0'

	PUBLIC_IP=''
	PUBLIC_IP_SOURCE=''
	PUBLIC_IP_CHANGED='0'
	PUBLIC_IP_DETECTED_AT='0'
	PUBLIC_IP_DETECTED_AT_ISO=''

	previous_ip="$(sed -n 's/^ip=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
	previous_detected_at="$(sed -n 's/^detected_at=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
	previous_detected_at_iso="$(sed -n 's/^detected_at_iso=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"
	previous_source="$(sed -n 's/^source=//p' "$NORDVPN_EASY_PUBLIC_IP_CACHE" 2>/dev/null | sed -n '1p')"

	nordvpn_easy_detect_public_ip || return $?

	if [ "$PUBLIC_IP" != "$previous_ip" ]; then
		PUBLIC_IP_CHANGED='1'
		should_write='1'
	elif [ -z "$previous_detected_at_iso" ] || [ "$previous_detected_at" = '0' ] || [ -z "$previous_source" ]; then
		should_write='1'
	fi

	if [ "$should_write" = '1' ]; then
		detected_at="$(date +%s 2>/dev/null || printf '%s' '0')"
		detected_at_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' '')"
		PUBLIC_IP_DETECTED_AT="$detected_at"
		PUBLIC_IP_DETECTED_AT_ISO="$detected_at_iso"
		nordvpn_easy_public_ip_write_keyval_cache || return 1
		if [ "$PUBLIC_IP_CHANGED" = '1' ]; then
			nordvpn_easy_public_ip_write_cache_file "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" '' || return 1
		fi
	else
		PUBLIC_IP_DETECTED_AT="$previous_detected_at"
		PUBLIC_IP_DETECTED_AT_ISO="$previous_detected_at_iso"
		PUBLIC_IP_SOURCE="$previous_source"
	fi

	PUBLIC_IP_DETECTED_AT="$(nordvpn_easy_wg_runtime_non_negative_int "$PUBLIC_IP_DETECTED_AT")"
	return 0
}

nordvpn_easy_emit_public_ip_snapshot() {
	cat <<EOF
{
  "ip": "$(nordvpn_easy_json_escape "$PUBLIC_IP")",
  "changed": $([ "${PUBLIC_IP_CHANGED:-0}" = '1' ] && printf '%s' 'true' || printf '%s' 'false'),
  "detected_at": $(nordvpn_easy_wg_runtime_non_negative_int "${PUBLIC_IP_DETECTED_AT:-0}"),
  "detected_at_iso": "$(nordvpn_easy_json_escape "$PUBLIC_IP_DETECTED_AT_ISO")",
  "source": "$(nordvpn_easy_json_escape "$PUBLIC_IP_SOURCE")",
  "country": "$(nordvpn_easy_json_escape "$PUBLIC_COUNTRY")"
}
EOF
}

nordvpn_easy_lookup_public_country_by_ip() {
	LOOKUP_IP="$1"
	local curl_raw curl_rc country_raw api_host nslookup_out resolved_ip

	[ -n "$LOOKUP_IP" ] || {
		nordvpn_easy_public_ip_log 'ERROR: PUBLIC IP IS EMPTY - CANNOT LOOK UP COUNTRY'
		return 1
	}

	api_host=$(printf '%s' "$PUBLIC_COUNTRY_API" | sed 's|https://||')

	nordvpn_easy_public_ip_log "lookup_public_country_by_ip: system DNS servers: $(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')"
	nordvpn_easy_public_ip_log "lookup_public_country_by_ip: resolving $api_host via Quad9 DNS (9.9.9.9) to bypass VPN DNS filtering"

	nslookup_out=$(nslookup "$api_host" 9.9.9.9 2>&1)
	resolved_ip=$(printf '%s\n' "$nslookup_out" \
		| awk '/^Address/ && !/9\.9\.9\.9/ && /[0-9]\.[0-9]/ {print $NF; exit}')

	nordvpn_easy_public_ip_log "lookup_public_country_by_ip: Quad9 nslookup output: $(printf '%s' "$nslookup_out" | tr '\n' '|')"

	if [ -n "$resolved_ip" ]; then
		nordvpn_easy_public_ip_log "lookup_public_country_by_ip: resolved $api_host → $resolved_ip via Quad9 DNS — will use --resolve to bypass system DNS"
	else
		nordvpn_easy_public_ip_log "lookup_public_country_by_ip: Quad9 DNS resolution failed for $api_host — falling back to system DNS (may fail if VPN DNS blocks it)"
	fi

	nordvpn_easy_public_ip_log "lookup_public_country_by_ip: querying ${PUBLIC_COUNTRY_API}/${LOOKUP_IP} (IPv4-only$([ -n "$resolved_ip" ] && printf ', resolve hint: %s' "$resolved_ip"))"

	if [ -n "$resolved_ip" ]; then
		curl_raw=$(curl -4 --resolve "${api_host}:443:${resolved_ip}" -fsS --connect-timeout 5 --max-time 10 "${PUBLIC_COUNTRY_API}/${LOOKUP_IP}" 2>/dev/null)
	else
		curl_raw=$(curl -4 -fsS --connect-timeout 5 --max-time 10 "${PUBLIC_COUNTRY_API}/${LOOKUP_IP}" 2>/dev/null)
	fi
	curl_rc=$?

	if [ "$curl_rc" -ne 0 ]; then
		nordvpn_easy_public_ip_log "ERROR: COULD NOT LOOK UP COUNTRY FOR PUBLIC IP $LOOKUP_IP — curl failed (curl_rc=$curl_rc: $(nordvpn_easy_curl_rc_meaning "$curl_rc")$([ -z "$resolved_ip" ] && printf '; system DNS was used, Quad9 bypass had failed'))"
		return 1
	fi

	if [ -z "$curl_raw" ]; then
		nordvpn_easy_public_ip_log "ERROR: COULD NOT LOOK UP COUNTRY FOR PUBLIC IP $LOOKUP_IP — curl succeeded (rc=0) but response body is empty"
		return 1
	fi

	nordvpn_easy_public_ip_log "lookup_public_country_by_ip: raw response for $LOOKUP_IP: $curl_raw"

	if ! country_raw=$(printf '%s' "$curl_raw" | jq -er '.country // empty' 2>/dev/null); then
		nordvpn_easy_public_ip_log "ERROR: COULD NOT PARSE COUNTRY FROM RESPONSE FOR $LOOKUP_IP (raw='$curl_raw')"
		return 1
	fi

	if [ -z "$country_raw" ]; then
		nordvpn_easy_public_ip_log "ERROR: COULD NOT PARSE COUNTRY FROM RESPONSE FOR $LOOKUP_IP (raw='$curl_raw')"
		return 1
	fi

	PUBLIC_COUNTRY=$(printf '%s' "$country_raw" | tr 'a-z' 'A-Z')
	nordvpn_easy_public_ip_valid_country_code "$PUBLIC_COUNTRY" || {
		nordvpn_easy_public_ip_log "ERROR: INVALID COUNTRY LOOKUP RESPONSE FOR PUBLIC IP $LOOKUP_IP (parsed='$PUBLIC_COUNTRY', raw='$curl_raw')"
		return 1
	}

	nordvpn_easy_public_ip_log "lookup_public_country_by_ip: resolved $LOOKUP_IP → $PUBLIC_COUNTRY"
	printf '%s\n' "$PUBLIC_COUNTRY"
}

nordvpn_easy_refresh_public_country_cache() {
	local cached_country=''
	local refresh_reason=''

	cached_country="$(sed -n '1p' "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" 2>/dev/null || true)"
	if [ "${PUBLIC_IP_CHANGED:-0}" = '1' ]; then
		refresh_reason='public IP changed'
	elif ! nordvpn_easy_public_ip_valid_country_code "$cached_country"; then
		refresh_reason='country cache is missing or invalid'
	fi

	if [ -n "$refresh_reason" ]; then
		nordvpn_easy_public_ip_log "public_country_check: $refresh_reason; looking up country for public IP ${PUBLIC_IP:-unknown}"
		PUBLIC_COUNTRY=$(nordvpn_easy_lookup_public_country_by_ip "$PUBLIC_IP") || {
			PUBLIC_COUNTRY=''
			return 1
		}

		nordvpn_easy_public_ip_write_cache_file "$NORDVPN_EASY_PUBLIC_COUNTRY_CACHE" "${PUBLIC_COUNTRY:-}" || return 1
		nordvpn_easy_public_ip_clear_own_last_error
	else
		PUBLIC_COUNTRY="$cached_country"
		nordvpn_easy_public_ip_log "public_country_check: using cached country $PUBLIC_COUNTRY for unchanged public IP ${PUBLIC_IP:-unknown}"
	fi

	return 0
}

# Run live public IP detection, refresh country only when the IP changed or the
# country cache is stale, then print the JSON snapshot to stdout.
nordvpn_easy_run_public_ip_check() {
	local mode="${1:-quiet}"
	local rc=0
	local expected_country=''
	local verification_status='ok'
	local verification_message=''
	local prev_status='' prev_expected='' prev_actual=''

	case "$mode" in
		quiet|verbose) PUBLIC_LOOKUP_LOG_MODE="$mode" ;;
		*) PUBLIC_LOOKUP_LOG_MODE='verbose' ;;
	esac

	LOG_PHASE='poll'
	ACTION='public_ip'
	ACTION_TRACE_ID="$(date +%s 2>/dev/null || printf '%s' '0').$$"
	expected_country="$(printf '%s' "${NORDVPN_EASY_EXPECTED_PUBLIC_COUNTRY:-${VPN_COUNTRY:-}}" | tr 'a-z' 'A-Z')"

	# Snapshot the previously recorded country-match outcome before this poll
	# overwrites it, so we only log a transition line when it actually changes.
	if [ -r "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" ]; then
		prev_status="$(sed -n 's/^status=//p' "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" 2>/dev/null | sed -n '1p')"
		prev_expected="$(sed -n 's/^expected_country=//p' "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" 2>/dev/null | sed -n '1p')"
		prev_actual="$(sed -n 's/^actual_country=//p' "$NORDVPN_EASY_PUBLIC_VERIFICATION_CACHE" 2>/dev/null | sed -n '1p')"
	fi

	nordvpn_easy_public_ip_log "public_ip request starting (mode=${PUBLIC_LOOKUP_LOG_MODE})"
	command -v curl >/dev/null 2>&1 || {
		nordvpn_easy_public_ip_log 'curl IS MISSING, PLEASE INSTALL'
		nordvpn_easy_public_verification_write 'failed' "$expected_country" '' 'curl is missing' >/dev/null 2>&1 || true
		return 1
	}

	nordvpn_easy_public_verification_write 'pending' "$expected_country" '' 'public IP check running' >/dev/null 2>&1 || true
	nordvpn_easy_update_public_ip_cache
	rc=$?
	if [ "$rc" -eq 0 ]; then
		if nordvpn_easy_refresh_public_country_cache >/dev/null 2>&1; then
			if [ -n "$expected_country" ] && [ "$PUBLIC_COUNTRY" != "$expected_country" ]; then
				verification_status='mismatch'
				verification_message="public IP country ${PUBLIC_COUNTRY:-unknown} does not match selected country $expected_country"
				nordvpn_easy_public_ip_log "WARNING: $verification_message"
			else
				verification_status='ok'
				verification_message='public country check passed'
			fi
			nordvpn_easy_log_country_match_transition "$verification_status" "$expected_country" "$PUBLIC_COUNTRY" "$prev_status" "$prev_expected" "$prev_actual"
			nordvpn_easy_public_verification_write "$verification_status" "$expected_country" "$PUBLIC_COUNTRY" "$verification_message" >/dev/null 2>&1 || true
		else
			verification_message="could not geolocate public IP ${PUBLIC_IP:-unknown}"
			nordvpn_easy_public_verification_write 'failed' "$expected_country" '' "$verification_message" >/dev/null 2>&1 || true
			nordvpn_easy_public_ip_log "WARNING: $verification_message"
		fi
		nordvpn_easy_public_ip_clear_own_last_error
		nordvpn_easy_emit_public_ip_snapshot
		nordvpn_easy_public_ip_log 'public_ip request completed successfully'
	else
		nordvpn_easy_public_verification_write 'failed' "$expected_country" '' "public_ip failed (rc=$rc)" >/dev/null 2>&1 || true
		nordvpn_easy_public_ip_log "ERROR: public_ip request failed (rc=$rc)"
	fi

	return "$rc"
}
