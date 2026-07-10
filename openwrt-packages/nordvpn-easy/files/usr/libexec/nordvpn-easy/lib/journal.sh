#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


# Durable apply-transaction journal (AUTHORITATIVE).
#
# A single flat key=value file under the tmpfs run dir, written atomically
# (mktemp + rename) and DELIBERATELY NOT registered for the lock EXIT-trap
# cleanup, so the in-flight signal survives one rpcd process exiting before the
# next RPC runs. The supervisor is the authoritative writer: it opens/adopts a
# transaction and stamps the terminal phase, and the LuCI supervised-apply poll
# reads convergence off journal_phase. It also provides the (boot_id, status_seq)
# ordering stamps the LuCI poller uses to discard out-of-order status responses.

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
		# schema 2 formally carries the supervisor phase-record fields
		# (target_fingerprint, phase, phase_attempt, phase_deadline, fetch_done,
		# last_error) in addition to the schema-1 begin/finish fields. write_full is
		# a pass-through, so no reader is required to change; the bump is a forward
		# signal only (nothing gates on it -- the journal is still SHADOW).
		printf 'schema=2\n'
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

# Merge key=value fields into the existing journal, PRESERVING every other field
# (write_full replaces the whole document; this keeps the transaction identity --
# txn_id/started_at/origin/owner_pid -- while a phase advances). The re-stamped
# fields (schema/boot_id/status_seq/updated_at) and any key the caller overwrites
# are dropped from the kept set; write_full re-stamps them. If the journal does not
# exist yet this degenerates to a plain write of the caller's fields.
nordvpn_easy_journal_set() {
	local file line lkey new_keys=' '
	file="$(nordvpn_easy_journal_path)"

	# The keys the caller is setting (space-padded for whole-word matching).
	for line in "$@"; do
		new_keys="${new_keys}${line%%=*} "
	done

	if [ -r "$file" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			lkey="${line%%=*}"
			[ -n "$lkey" ] || continue
			case "$lkey" in
				schema|boot_id|status_seq|updated_at) continue ;;
			esac
			case "$new_keys" in
				*" $lkey "*) continue ;;
			esac
			set -- "$@" "$line"
		done < "$file"
	fi

	nordvpn_easy_journal_write_full "$@"
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
