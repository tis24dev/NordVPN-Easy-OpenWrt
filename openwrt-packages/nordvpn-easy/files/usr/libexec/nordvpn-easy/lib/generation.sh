#!/bin/sh

# Config-identity helpers for the supervised orchestrator.
#
# The desired config is identified by a CONTENT FINGERPRINT (equality only, never
# ordered): two identical desired configs hash the same, and any persisted
# user-facing change changes the hash. This replaces a hand-incremented counter,
# so concurrent identical saves converge and a CLI `uci commit` is detected
# without an explicit bump.
#
# These helpers operate on the loaded runtime environment (the NORDVPN_* vars set
# from UCI by the config context), so computing a fingerprint costs no extra uci
# forks on the status hot path.

NORDVPN_EASY_RUNTIME_TOKEN_FILE="${NORDVPN_EASY_RUNTIME_TOKEN_FILE:-${NORDVPN_EASY_RUN_DIR:-/tmp/run/nordvpn-easy}/runtime-token}"

# Pinned hasher. No sha256sum/md5sum agility flip: the fingerprint is an identity,
# so the algorithm must be stable across runs. Fail (non-zero) if it is absent so
# callers refuse to trust an identity computed by a different algorithm.
nordvpn_easy_fingerprint_hash() {
	command -v sha256sum >/dev/null 2>&1 || return 1
	sha256sum | cut -d' ' -f1
}

# Content fingerprint of the desired config, from the loaded runtime environment.
# The account token contributes only a presence bit (its value never enters the
# hash); config_schema_version is excluded because it is not a runtime option.
nordvpn_easy_config_fingerprint() {
	local option env_name value
	{
		for option in $(nordvpn_easy_runtime_options); do
			env_name="$(nordvpn_easy_env_name "$option" 2>/dev/null)" || continue
			eval "value=\${${env_name}-}"
			if [ "$option" = 'nordvpn_token' ]; then
				if [ -n "$value" ]; then
					printf '%s=present\n' "$option"
				else
					printf '%s=absent\n' "$option"
				fi
			else
				printf '%s=%s\n' "$option" "$value"
			fi
		done
	} | nordvpn_easy_fingerprint_hash
}

nordvpn_easy_applied_fingerprint() {
	uci -q get 'nordvpn_easy.main.applied_fingerprint' 2>/dev/null || printf ''
}

nordvpn_easy_runtime_token_value() {
	cat "$NORDVPN_EASY_RUNTIME_TOKEN_FILE" 2>/dev/null || printf ''
}

# Record that the live runtime now matches the given desired fingerprint:
# persist applied_fingerprint in UCI flash ONLY when it advanced (bounded flash
# wear), and write the live runtime-token sentinel in tmpfs (which vanishes on
# reboot, so a boot always re-evaluates whether bring-up is still needed).
nordvpn_easy_mark_applied() {
	local fingerprint="$1"
	local current dir tmp

	[ -n "$fingerprint" ] || return 1

	current="$(nordvpn_easy_applied_fingerprint)"
	if [ "$current" != "$fingerprint" ]; then
		if uci set "nordvpn_easy.main.applied_fingerprint=${fingerprint}" 2>/dev/null &&
			uci commit nordvpn_easy 2>/dev/null; then
			command -v nordvpn_easy_harden_secret_config_perms >/dev/null 2>&1 &&
				nordvpn_easy_harden_secret_config_perms nordvpn_easy >/dev/null 2>&1 || true
		fi
	fi

	dir="$(dirname "$NORDVPN_EASY_RUNTIME_TOKEN_FILE")"
	mkdir -p "$dir" 2>/dev/null || return 1
	tmp="$(mktemp "${dir}/.runtime-token.XXXXXX" 2>/dev/null)" || return 1
	printf '%s\n' "$fingerprint" > "$tmp" || { rm -f -- "$tmp"; return 1; }
	chmod 0600 "$tmp" 2>/dev/null || true
	mv "$tmp" "$NORDVPN_EASY_RUNTIME_TOKEN_FILE" || { rm -f -- "$tmp"; return 1; }
}

# Whether a boot/reconcile must (re)provision: the desired state is enabled but
# the live runtime sentinel is absent or stale (reboot wiped tmpfs, or the config
# changed), or the wg interface is not present. enabled=0 never needs bring-up.
#
# NOTE (S3): defined and emitted for observability; no control path keys on it
# yet. The async supervisor wires it into the boot/recover flow later.
nordvpn_easy_boot_needs_bringup() {
	local desired_enabled="${DESIRED_ENABLED:-0}"
	local vpn_if="${VPN_IF:-wg0}"
	local token live

	[ "$desired_enabled" = '1' ] || return 1

	token="$(nordvpn_easy_runtime_token_value)"
	[ -n "$token" ] || return 0

	live="$(nordvpn_easy_config_fingerprint)"
	[ -n "$live" ] && [ "$token" = "$live" ] || return 0

	if command -v nordvpn_easy_vpn_link_is_present >/dev/null 2>&1; then
		nordvpn_easy_vpn_link_is_present "$vpn_if" || return 0
	fi
	return 1
}
