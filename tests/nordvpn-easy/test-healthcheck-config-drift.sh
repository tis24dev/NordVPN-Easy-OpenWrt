#!/bin/sh
# Copyright (C) 2026 tis24dev
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0


set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
COMMON_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/common.sh"
RUNTIME_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/runtime.sh"
WIREGUARD_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/wireguard.sh"
DIAGNOSTICS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/diagnostics.sh"
ACTIONS_LIB="$ROOT_DIR/openwrt-packages/nordvpn-easy/files/usr/libexec/nordvpn-easy/lib/actions.sh"

# shellcheck disable=SC1090
. "$COMMON_LIB"
# shellcheck disable=SC1090
. "$RUNTIME_LIB"
# shellcheck disable=SC1090
. "$WIREGUARD_LIB"
# shellcheck disable=SC1090
. "$DIAGNOSTICS_LIB"
# shellcheck disable=SC1090
. "$ACTIONS_LIB"

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
			printf '%s\n' "expected to contain: $needle" >&2
			printf '%s\n' "actual:              $haystack" >&2
			exit 1
			;;
	esac
}

assert_excludes() {
	haystack="$1"
	needle="$2"
	label="$3"

	case "$haystack" in
		*"$needle"*)
			printf '%s\n' "FAIL: $label" >&2
			printf '%s\n' "expected NOT to contain: $needle" >&2
			printf '%s\n' "actual:                  $haystack" >&2
			exit 1
			;;
	esac
}

VPN_IF='wg0'

# --- nordvpn_easy_desired_state_signature filters the account token ---------
uci() {
	case "$*" in
		'-q show nordvpn_easy.main')
			printf '%s\n' \
				'nordvpn_easy.main=nordvpn_easy' \
				"nordvpn_easy.main.enabled='1'" \
				"nordvpn_easy.main.nordvpn_token='supersecrettoken'" \
				"nordvpn_easy.main.vpn_country='it'"
			;;
		'-q show network.wg0.disabled')
			printf '%s\n' "network.wg0.disabled='0'"
			;;
		*) return 1 ;;
	esac
}

SIGNATURE_OUTPUT="$(nordvpn_easy_desired_state_signature)"
assert_excludes "$SIGNATURE_OUTPUT" 'supersecrettoken' 'desired-state signature filters the account token'
assert_contains "$SIGNATURE_OUTPUT" "enabled='1'" 'desired-state signature includes the enabled flag'
assert_contains "$SIGNATURE_OUTPUT" "vpn_country='it'" 'desired-state signature includes the country'
assert_contains "$SIGNATURE_OUTPUT" "disabled='0'" 'desired-state signature includes the interface disabled flag'

# --- check_once shared mocks ------------------------------------------------
# Drive the retry-wait path: the VPN ping always fails, WAN is up, and the
# runtime is NOT structurally degraded, so check_once releases the lock, waits,
# reacquires, then decides whether to reprovision.
FAILURE_RETRY_DELAY=0
LOCK_ACQUIRED=1
PROVISION_COUNT=0
SIGNATURE='base'

log() { :; }
nordvpn_easy_ping_interface() { return 1; }
nordvpn_easy_ping_wan() { return 0; }
nordvpn_easy_runtime_needs_provision() { return 1; }
nordvpn_easy_release_lock() { :; }
nordvpn_easy_check_once_finish() { :; }
nordvpn_easy_provision_vpn() { PROVISION_COUNT=$((PROVISION_COUNT + 1)); return 0; }
nordvpn_easy_desired_state_signature() { printf '%s' "$SIGNATURE"; }

# --- Scenario A: config unchanged during the wait -> reprovision ------------
SIGNATURE='base'
PROVISION_COUNT=0
nordvpn_easy_acquire_lock() { return 0; }

LOCK_ACQUIRED=1
nordvpn_easy_check_once

assert_eq '1' "$PROVISION_COUNT" 'unchanged desired state reprovisions after the retry wait'

# --- Scenario B: config drifts during the wait -> yield, no reprovision -----
# The reacquire happens after a user Save & Apply / disconnect landed during the
# wait; model that by flipping the signature inside the (mocked) reacquire.
SIGNATURE='base'
PROVISION_COUNT=0
nordvpn_easy_acquire_lock() { SIGNATURE='changed'; return 0; }

LOCK_ACQUIRED=1
DRIFT_RC=0
nordvpn_easy_check_once || DRIFT_RC=$?

assert_eq '0' "$DRIFT_RC" 'config drift during the retry wait yields successfully'
assert_eq '0' "$PROVISION_COUNT" 'config drift during the retry wait does not reprovision the stale snapshot'

printf '%s\n' 'test-healthcheck-config-drift.sh: ok'
