#!/bin/sh

# Durable apply-transaction journal (SHADOW in this step).
#
# A single flat key=value file under the tmpfs run dir, written atomically
# (mktemp + rename) and DELIBERATELY NOT registered for the lock EXIT-trap
# cleanup, so the in-flight signal survives one rpcd process exiting before the
# next RPC runs. In this step the journal is written alongside the existing
# connect-apply result file but is NOT authoritative: nothing reads it for
# control yet. It validates the write/parse/schema mechanics, and provides the
# (boot_id, status_seq) ordering stamps the LuCI poller uses to discard
# out-of-order status responses.

_NORDVPN_EASY_BOOT_ID=''

nordvpn_easy_journal_path() {
	printf '%s' "${NORDVPN_EASY_JOURNAL_FILE:-${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}/journal}"
}

# A monotone-within-boot ordering stamp: uptime centiseconds. All readers share
# the kernel clock, so it is monotone across processes at ~10ms resolution -- a
# stale status response is always emitted at a lower stamp than a newer one and
# the poller can discard it. Two stamps taken within the same 10ms tick are
# EQUAL (a documented residual: a per-process counter cannot help here because
# next_seq is read through command substitution, whose subshell discards the
# increment; full ordering of same-tick same-phase writes depends on the fencing
# token, a later step). NOT reset on reboot only because uptime resets too --
# that is why ordering is bucketed by boot_id, which always wins.
nordvpn_easy_journal_next_seq() {
	awk 'NR == 1 { printf "%.0f", $1 * 100; found = 1 } END { if (!found) printf "0" }' /proc/uptime 2>/dev/null || printf '0'
}

# Equality discriminator: a different boot_id is always newer (a reboot destroys
# uhttpd, so no pre-reboot response can survive the connection). Cached: constant
# per boot.
nordvpn_easy_journal_boot_id() {
	if [ -z "$_NORDVPN_EASY_BOOT_ID" ]; then
		_NORDVPN_EASY_BOOT_ID="$(tr -d '\n' < /proc/sys/kernel/random/boot_id 2>/dev/null || printf '')"
	fi
	printf '%s' "$_NORDVPN_EASY_BOOT_ID"
}

nordvpn_easy_journal_new_id() {
	tr -d '\n' < /proc/sys/kernel/random/uuid 2>/dev/null && return 0
	printf '%s-%s' "$$" "$(date +%s 2>/dev/null || printf '0')"
}

nordvpn_easy_journal_get() {
	local file
	file="$(nordvpn_easy_journal_path)"
	[ -r "$file" ] || return 1
	sed -n "s/^$1=//p" "$file" 2>/dev/null | head -n1
}

# Write the whole journal document atomically. Callers pass key=value fields;
# schema, boot_id, status_seq and updated_at are stamped here. The temp file is
# never register_temp_path'd, so the EXIT trap leaves the journal across RPCs.
nordvpn_easy_journal_write_full() {
	local file dir tmp seq now kv
	file="$(nordvpn_easy_journal_path)"
	dir="$(dirname "$file")"
	mkdir -p "$dir" 2>/dev/null || return 1
	seq="$(nordvpn_easy_journal_next_seq)"
	now="$(date +%s 2>/dev/null || printf '%s' '0')"
	tmp="$(mktemp "${dir}/.journal.XXXXXX" 2>/dev/null)" || return 1
	{
		printf 'schema=1\n'
		printf 'boot_id=%s\n' "$(nordvpn_easy_journal_boot_id)"
		for kv in "$@"; do
			printf '%s\n' "$kv"
		done
		printf 'status_seq=%s\n' "$seq"
		printf 'updated_at=%s\n' "$now"
	} > "$tmp" || { rm -f -- "$tmp"; return 1; }
	chmod 0600 "$tmp" 2>/dev/null || true
	mv "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

nordvpn_easy_journal_begin() {
	local origin="${1:-apply}"
	local txn_id='' started_at='' existing_phase now
	now="$(date +%s 2>/dev/null || printf '%s' '0')"

	existing_phase="$(nordvpn_easy_journal_get phase 2>/dev/null || printf '')"
	if [ "$existing_phase" = 'applying' ]; then
		# Idempotent re-begin: keep the in-flight transaction identity and start
		# time so a second begin from another owner does not fork the txn.
		txn_id="$(nordvpn_easy_journal_get txn_id 2>/dev/null || printf '')"
		started_at="$(nordvpn_easy_journal_get started_at 2>/dev/null || printf '')"
	fi
	[ -n "$txn_id" ] || txn_id="$(nordvpn_easy_journal_new_id)"
	[ -n "$started_at" ] || started_at="$now"

	nordvpn_easy_journal_write_full \
		'phase=applying' \
		"txn_id=$txn_id" \
		"origin=$origin" \
		"owner_pid=$$" \
		"started_at=$started_at" \
		'finished_at=' \
		'rc=' \
		'country='
}

nordvpn_easy_journal_finish() {
	local rc="${1:-1}"
	local country="${2:-}"
	local txn_id origin started_at phase now
	now="$(date +%s 2>/dev/null || printf '%s' '0')"

	txn_id="$(nordvpn_easy_journal_get txn_id 2>/dev/null || printf '')"
	origin="$(nordvpn_easy_journal_get origin 2>/dev/null || printf '')"
	started_at="$(nordvpn_easy_journal_get started_at 2>/dev/null || printf '')"

	case "$rc" in
		''|*[!0-9]*) phase='failed' ;;
		*) if [ "$rc" -eq 0 ]; then phase='done'; else phase='failed'; fi ;;
	esac

	nordvpn_easy_journal_write_full \
		"phase=$phase" \
		"txn_id=$txn_id" \
		"origin=$origin" \
		"owner_pid=$$" \
		"started_at=${started_at:-$now}" \
		"finished_at=$now" \
		"rc=$rc" \
		"country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')"
}
