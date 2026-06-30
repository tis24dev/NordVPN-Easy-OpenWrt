#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, setTimeout, clearTimeout, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const managerActionsPath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'nordvpn-easy',
	'manager-actions.js'
);
const managerDataPath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'nordvpn-easy',
	'manager-data.js'
);

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function() {
			let index = 0;
			const args = arguments;

			return String(this).replace(/%[sd]/g, function() {
				const value = args[index++];
				return String(value);
			});
		},
		configurable: true
	});
}

function loadManagerDataModule() {
	const source = fs.readFileSync(managerDataPath, 'utf8');

	return vm.runInNewContext(`(function(){\n${source}\n})();`, {
		baseclass: {
			extend(api) {
				return api;
			}
		}
	}, {
		filename: managerDataPath
	});
}

const managerData = loadManagerDataModule();

// The rpcd readonly-status fail-safe stub omits most fields on purpose;
// parseLocalStatus must fill safe (down) defaults so a context-load + emitter
// double-failure never reads as connected or mid-apply.
{
	const fallback = managerData.parseLocalStatus(
		'{"updated_at":1,"state":"failed","desired_enabled":false,"enabled":false,"runtime_disabled":true,"interface_disabled":true,"runtime_configured":false,"connected":false,"vpn_status":"error","operation_status":"idle","last_error":"failed to load runtime context from UCI"}'
	);
	assert.equal(fallback.connected, false, 'rpcd fail-safe stub parses as disconnected');
	assert.equal(fallback.connect_apply_pending, false, 'rpcd fail-safe stub defaults connect-apply pending to false');
	assert.equal(fallback.public_verification_status, 'unknown', 'rpcd fail-safe stub defaults public verification to unknown');
}

function loadManagerActionsModule(overrides) {
	const source = fs.readFileSync(managerActionsPath, 'utf8');
	const context = {
		baseclass: {
			extend(api) {
				return api;
			}
		},
		managerData: {
			normalizeCountryCode(value) {
				return String(value || '').trim().toUpperCase();
			},
			runtimeStatusIsBusy(status) {
				return managerData.runtimeStatusIsBusy(status);
			},
			emptyServerCatalog() {
				return { servers: [] };
			},
			buildServerCatalogIndex() {
				return {};
			},
			parseServerCatalog() {
				return { servers: [] };
			},
			parseLocalStatus() {
				return {};
			},
			emptyDiagnosticsSummary() {
				return managerData.emptyDiagnosticsSummary();
			},
			parseDiagnosticsSummary(raw) {
				return managerData.parseDiagnosticsSummary(raw);
			},
			diagnosticsHasAlert(summary) {
				return managerData.diagnosticsHasAlert(summary);
			},
			hideSelectionDriftDiagnostics(summary) {
				return managerData.hideSelectionDriftDiagnostics(summary);
			}
		},
		managerFormat: {
			formatServerLabel(server) {
				return String((server && server.hostname) || (server && server.station) || '');
			},
			humanizeAction(action) {
				return String(action || '');
			}
		},
		managerStore: {
			PHASES: {},
			clearInFlight() {},
			runExclusive() {
				throw new Error('runExclusive should not be used in this test');
			}
		},
		managerUI: {
			updateDiagnosticsBanner() {}
		},
		service: {},
		ui: {},
		uci: {},
		document: {},
		window: {},
		Blob: function() {},
		_: function(message) {
			return String(message);
		},
		E: function() {
			return null;
		},
		console: console,
		Date: Date,
		setTimeout: setTimeout,
		clearTimeout: clearTimeout,
		Promise: Promise
	};

	if (overrides) {
		Object.keys(overrides).forEach(function(key) {
			if (
				context[key] &&
				typeof context[key] === 'object' &&
				!Array.isArray(context[key]) &&
				overrides[key] &&
				typeof overrides[key] === 'object' &&
				!Array.isArray(overrides[key])
			) {
				context[key] = Object.assign({}, context[key], overrides[key]);
				return;
			}

			context[key] = overrides[key];
		});
	}

	return {
		managerActions: vm.runInNewContext(`
			if (!String.prototype.format) {
				Object.defineProperty(String.prototype, 'format', {
					value: function() {
						let index = 0;
						const args = arguments;

						return String(this).replace(/%[sd]/g, function() {
							const value = args[index++];
							return String(value);
						});
					},
					configurable: true
				});
			}
			(function(){\n${source}\n})();
		`, context, {
			filename: managerActionsPath
		}),
		context: context
	};
}

const managerActions = loadManagerActionsModule().managerActions;

function normalizeValue(value) {
	return JSON.parse(JSON.stringify(value));
}

function delay(ms) {
	return new Promise(function(resolve) {
		setTimeout(resolve, ms);
	});
}

const healthyRuntime = {
	interface: 'wg0',
	runtime_disabled: false,
	interface_disabled: false,
	runtime_configured: true
};

assert.equal(typeof managerActions.runApplyCycle, 'function', 'runApplyCycle is exported');
assert.equal(typeof managerActions.renderLocalStatusSnapshot, 'function', 'renderLocalStatusSnapshot is exported');

assert.equal(managerData.parseEnabledFlag(undefined), false, 'missing enabled option is treated as disabled');
assert.equal(managerData.parseEnabledFlag('0'), false, 'explicit disabled value is treated as disabled');
assert.equal(managerData.parseEnabledFlag('1'), true, 'explicit enabled value is treated as enabled');
assert.equal(managerData.runtimeStatusIsBusy({ operation_status: 'idle' }), false, 'idle runtime status is not busy');
assert.equal(managerData.runtimeStatusIsBusy({ operation_status: 'busy:connect' }), true, 'busy:action runtime status is busy');
assert.equal(managerData.runtimeStatusIsBusy({ operation_status: 'idle', operation_lock_state: 'held' }), true, 'held operation lock is busy');

function buildUpdateLocalStatusHarness(serviceOverrides) {
	return loadManagerActionsModule({
		managerData: {
			parseLocalStatus(raw) {
				return JSON.parse(raw || '{}');
			}
		},
		managerStore: {
			PHASES: { RUNTIME_BUSY: 'runtime_busy' },
			runExclusive(_state, _key, factory) {
				return Promise.resolve().then(factory);
			},
			clearError() {},
			setError() {},
			syncPhase() {},
			setPhase() {}
		},
		managerUI: {
			ids: {
				CURRENT_SERVER_STATUS_ID: 'current',
				PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer',
				OPERATION_STATUS_ID: 'operation',
				LAST_ERROR_STATUS_ID: 'last_error',
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText() {},
			setManagerControlsDisabled() {},
			setVpnStatusIndicator() {},
			updateCountryMatchStatus() {},
			updateServerSelectionState() {},
			currentServerSummaryFromStatus() {
				return '';
			},
			preferredServerSummaryFromStatus() {
				return '';
			},
			isDisableRequested() {
				return false;
			}
		},
		service: Object.assign({
			parseExecJsonResponse(res, fallback) {
				if (!res || res.code !== 0)
					return fallback;

				return JSON.parse(res.stdout || '');
			}
		}, serviceOverrides || {})
	}).managerActions;
}

function buildUpdateLocalStatusState() {
	return {
		pollingSuspended: false,
		currentLocalStatus: Object.assign({}, healthyRuntime, { desired_enabled: true, operation_status: 'idle' }),
		currentLocalStatusFresh: true,
		currentLocalStatusLastUpdated: 1234,
		pendingOperationLabel: '',
		currentOperationStatus: 'idle',
		appliedEnabled: true,
		currentPublicIp: '',
		currentPublicCountry: '',
		appliedCountryCode: 'UY'
	};
}

async function testUpdateLocalStatusPreservesSnapshotOnFailedResponse() {
	const actions = buildUpdateLocalStatusHarness({
		execService() {
			return Promise.resolve({ code: 1, stdout: '', stderr: 'status_json failed' });
		}
	});
	const state = buildUpdateLocalStatusState();
	const previousStatus = Object.assign({}, state.currentLocalStatus);
	const status = await actions.updateLocalStatus(state);

	assert.deepEqual(normalizeValue(status), normalizeValue(previousStatus), 'failed status_json responses keep the last known runtime status for display');
	assert.deepEqual(normalizeValue(state.currentLocalStatus), normalizeValue(previousStatus), 'failed status_json responses do not overwrite currentLocalStatus with an empty snapshot');
	assert.equal(state.appliedEnabled, true, 'failed status_json responses do not mark the applied configuration disabled');
	assert.equal(state.appliedCountryCode, 'UY', 'failed status_json responses preserve the applied country');
	assert.equal(state.currentLocalStatusFresh, false, 'failed status_json responses mark runtime status as stale');
	assert.equal(state.currentLocalStatusLastUpdated, 0, 'failed status_json responses clear the freshness timestamp');
}

async function testUpdateLocalStatusMarksSnapshotsStaleOnRejectedExec() {
	const actions = buildUpdateLocalStatusHarness({
		execService() {
			return Promise.reject(new Error('rpcd unavailable'));
		}
	});
	const state = buildUpdateLocalStatusState();
	const status = await actions.updateLocalStatus(state);

	assert.deepEqual(normalizeValue(status), normalizeValue(buildUpdateLocalStatusState().currentLocalStatus), 'rejected status_json keeps the last known runtime status for display');
	assert.equal(state.currentLocalStatusFresh, false, 'rejected status_json marks runtime status as stale');
	assert.equal(state.currentLocalStatusLastUpdated, 0, 'rejected status_json clears the freshness timestamp');
}

function testStatusResponseIsOutOfOrderOrdering() {
	const state = { lastStatusBootId: 'boot-a', lastStatusSeq: 2000 };

	assert.equal(managerActions.statusResponseIsOutOfOrder(state, 'boot-a', 1000), true, 'a lower seq in the same boot is out of order');
	assert.equal(managerActions.statusResponseIsOutOfOrder(state, 'boot-a', 2000), false, 'an equal seq is not out of order');
	assert.equal(managerActions.statusResponseIsOutOfOrder(state, 'boot-a', 3000), false, 'a higher seq is in order');
	assert.equal(managerActions.statusResponseIsOutOfOrder(state, 'boot-b', 5), false, 'a different boot_id is always newer');
	assert.equal(managerActions.statusResponseIsOutOfOrder({}, 'boot-a', 1), false, 'with no recorded baseline nothing is out of order');
}

async function testUpdateLocalStatusDiscardsOutOfOrderResponses() {
	function statusRes(extra) {
		return {
			code: 0,
			stdout: JSON.stringify(Object.assign({}, healthyRuntime, {
				desired_enabled: false,
				operation_status: 'idle'
			}, extra)),
			stderr: ''
		};
	}

	const responses = [
		statusRes({ selected_country: 'IT', boot_id: 'boot-a', status_seq: 2000 }),
		statusRes({ selected_country: 'DE', boot_id: 'boot-a', status_seq: 1000 }),
		statusRes({ selected_country: 'FR', boot_id: 'boot-a', status_seq: 3000 }),
		statusRes({ selected_country: 'ES', boot_id: 'boot-b', status_seq: 5 })
	];
	let i = 0;
	const actions = buildUpdateLocalStatusHarness({
		execService(action) {
			if (action === 'status_json')
				return Promise.resolve(responses[i++]);

			return Promise.resolve({ code: 0, stdout: '{}', stderr: '' });
		}
	});
	const state = buildUpdateLocalStatusState();

	const s1 = await actions.updateLocalStatus(state);
	assert.equal(String(s1.selected_country || ''), 'IT', 'the first response is applied');
	assert.equal(state.lastStatusBootId, 'boot-a', 'the ordering baseline boot_id is recorded');
	assert.equal(state.lastStatusSeq, 2000, 'the ordering baseline status_seq is recorded');

	const s2 = await actions.updateLocalStatus(state);
	assert.equal(String(s2.selected_country || ''), 'IT', 'a stale lower-seq response returns the last known status, not the stale one');
	assert.equal(String((state.currentLocalStatus || {}).selected_country || ''), 'IT', 'a stale response does not overwrite currentLocalStatus');
	assert.equal(state.lastStatusSeq, 2000, 'a stale response does not advance the baseline');

	const s3 = await actions.updateLocalStatus(state);
	assert.equal(String(s3.selected_country || ''), 'FR', 'a newer-seq response is applied');
	assert.equal(state.lastStatusSeq, 3000, 'the baseline advances on a newer response');

	const s4 = await actions.updateLocalStatus(state);
	assert.equal(String(s4.selected_country || ''), 'ES', 'a different boot_id is treated as newer and applied');
	assert.equal(state.lastStatusBootId, 'boot-b', 'the baseline boot_id updates on a new boot');
}

function testRenderLocalStatusSnapshotClearsDisabledPlaceholders() {
	const replacements = {};
	const indicators = {};
	const controls = [];
	const actions = loadManagerActionsModule({
		managerData: {
			normalizeCountryCode(value) {
				return String(value || '').trim().toUpperCase();
			},
			parseLocalStatus(raw) {
				return JSON.parse(raw || '{}');
			}
		},
		managerStore: {
			PHASES: { RUNTIME_BUSY: 'runtime_busy' },
			syncPhase(state) {
				state.phase = 'synced';
			},
			setPhase(state, phase) {
				state.phase = phase;
			}
		},
		managerUI: {
			ids: {
				CURRENT_SERVER_STATUS_ID: 'current',
				PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer',
				OPERATION_STATUS_ID: 'operation',
				LAST_ERROR_STATUS_ID: 'last_error',
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			setManagerControlsDisabled(disabled) {
				controls.push(!!disabled);
			},
			setVpnStatusIndicator(state, label) {
				indicators.vpn = { state: state, label: String(label) };
			},
			updateCountryMatchStatus() {},
			updateServerSelectionState() {},
			currentServerSummaryFromStatus(status) {
				return status.desired_enabled ? 'Configured' : 'Disabled';
			},
			preferredServerSummaryFromStatus() {
				return 'Automatic / Best recommended';
			},
			isDisableRequested() {
				return false;
			}
		}
	}).managerActions;
	const status = {
		desired_enabled: false,
		runtime_disabled: true,
		interface_disabled: true,
		runtime_configured: false,
		server_selection_mode: 'auto',
		vpn_status: 'inactive',
		operation_status: 'idle',
		endpoint: 'N/A',
		latest_handshake: 'Never',
		transfer_rx: '0 B',
		transfer_tx: '0 B',
		public_ip_cached: '198.51.100.10',
		public_country_cached: 'US',
		last_error: ''
	};
	const state = {
		appliedEnabled: false,
		appliedCountryCode: '',
		currentLocalStatus: status,
		currentOperationStatus: 'idle',
		pendingOperationLabel: '',
		currentPublicIp: '203.0.113.20',
		currentPublicCountry: 'IT'
	};

	actions.renderLocalStatusSnapshot(state, status);

	assert.equal(replacements.current, 'Disabled', 'disabled status replaces the current-server placeholder');
	assert.equal(replacements.preferred, 'Automatic / Best recommended', 'disabled status replaces the preferred-server placeholder');
	assert.equal(replacements.endpoint, 'N/A', 'disabled status renders a deterministic endpoint value');
	assert.equal(replacements.handshake, 'Never', 'disabled status renders a deterministic handshake value');
	assert.equal(replacements.transfer, '0 B / 0 B', 'disabled status renders deterministic transfer counters');
	assert.equal(replacements.operation, 'Idle', 'disabled status renders a deterministic operation value');
	assert.equal(replacements.last_error, 'None', 'disabled status renders an empty error as none');
	assert.equal(replacements.public_ip, 'Unavailable', 'disabled status does not expose stale public IP data');
	assert.equal(replacements.public_country, 'Unavailable', 'disabled status does not expose stale public country data');
	assert.equal(state.currentPublicIp, '', 'disabled rendering clears live public IP state');
	assert.equal(state.currentPublicCountry, '', 'disabled rendering clears live public country state');
	assert.deepEqual(indicators.vpn, { state: 'inactive', label: 'Disabled' }, 'disabled status renders the VPN indicator as disabled');
	assert.deepEqual(controls, [ false ], 'disabled idle status leaves manager controls enabled');
}

function testRenderLocalStatusSnapshotHonestDuringApply() {
	const indicators = {};
	const serverFlags = [];
	const fields = {};
	const actions = loadManagerActionsModule({
		managerData: {
			normalizeCountryCode(value) { return String(value || '').trim().toUpperCase(); },
			parseLocalStatus(raw) { return JSON.parse(raw || '{}'); }
		},
		managerStore: {
			PHASES: { RUNTIME_BUSY: 'runtime_busy', SAVING: 'saving' },
			syncPhase(state) { state.phase = 'synced'; },
			setPhase(state, phase) { state.phase = phase; }
		},
		managerUI: {
			ids: {
				CURRENT_SERVER_STATUS_ID: 'current', PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint', HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer', OPERATION_STATUS_ID: 'operation',
				LAST_ERROR_STATUS_ID: 'last_error', PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) { fields[id] = value; },
			setManagerControlsDisabled() {},
			setVpnStatusIndicator(state, label) { indicators.vpn = { state: state, label: String(label) }; },
			updateCountryMatchStatus() {},
			updateServerSelectionState() {},
			// Capture whether the transition flag is set when Current Server renders.
			currentServerSummaryFromStatus(status, state) { serverFlags.push(!!state.applyTransitionActive); return 'srv'; },
			preferredServerSummaryFromStatus() { return 'auto'; },
			isDisableRequested() { return false; }
		}
	}).managerActions;

	// Optimistically stale snapshot: during the teardown window the backend still
	// reports the OLD tunnel as connected (handshake within the 180s window), but
	// it is not fresh (age 9999), so convergence has NOT succeeded.
	const status = {
		desired_enabled: true, runtime_disabled: false, interface_disabled: false,
		runtime_configured: true, connected: true, vpn_status: 'active', state: 'connected',
		operation_status: 'idle', handshake_age_seconds: 9999,
		current_server_hostname: 'at107.nordvpn.com', current_server_station: 'at107',
		current_server_country: 'AT', endpoint: 'at107.nordvpn.com:51820',
		latest_handshake: '1 minute ago', transfer_rx: '1 B', transfer_tx: '1 B',
		public_ip_cached: '', public_country_cached: '', last_error: ''
	};
	const state = {
		appliedEnabled: true, appliedCountryCode: 'AT', saveApplyInProgress: true,
		applyPhase: 'stop_vpn', applyTransitionActive: false,
		currentLocalStatus: status, currentOperationStatus: 'idle',
		pendingOperationLabel: '', currentPublicIp: '', currentPublicCountry: ''
	};

	actions.renderLocalStatusSnapshot(state, status);
	// Connection shows the ACTUAL vpn_status even mid-apply: the old tunnel is
	// genuinely up (vpn_status active) during the stop phase, so it reads
	// Connected -- not a forced apply-time "Connecting". The Operation Status row
	// separately conveys what is being applied.
	assert.deepEqual(indicators.vpn, { state: 'active', label: 'Connected' },
		'Connection shows the real vpn_status (Connected) during an apply, not a forced Connecting');
	// The detail rows show the real values, consistent with the Connection state.
	assert.equal(fields.endpoint, 'at107.nordvpn.com:51820', 'Endpoint shows the real value during an apply');
	assert.equal(fields.handshake, '1 minute ago', 'Last handshake shows the real value during an apply');
	assert.equal(fields.transfer, '1 B / 1 B', 'Tunnel activity shows the real value during an apply');

	// As the teardown proceeds the backend reports vpn_status=stopping; Connection
	// follows it instead of pretending to keep connecting.
	actions.renderLocalStatusSnapshot(state, Object.assign({}, status, { vpn_status: 'stopping', connected: false }));
	assert.deepEqual(indicators.vpn, { state: 'stopping', label: 'Stopping' },
		'Connection follows vpn_status to Stopping during the teardown');

	// Then the new tunnel comes up as starting -> Connecting.
	actions.renderLocalStatusSnapshot(state, Object.assign({}, status, { vpn_status: 'starting', connected: false }));
	assert.deepEqual(indicators.vpn, { state: 'starting', label: 'Connecting' },
		'Connection follows vpn_status to Connecting while the new tunnel establishes');
}

async function testPublicLookupsReturnEarlyWhenRuntimeDisabled() {
	const networkCalls = [];
	const lockCalls = [];
	const replacements = {};
	let countryMatchUpdates = 0;
	const actions = loadManagerActionsModule({
		managerStore: {
			runExclusive(_state, key, factory) {
				lockCalls.push(key);
				return Promise.resolve().then(factory);
			}
		},
		managerUI: {
			ids: {
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			updateCountryMatchStatus() {
				countryMatchUpdates++;
			},
			isDisableRequested() {
				return false;
			}
		},
		service: {
			execService(action) {
				networkCalls.push(action);
				return Promise.reject(new Error('network request should not run while public lookups are disabled'));
			}
		}
	}).managerActions;
	const state = {
		pollingSuspended: false,
		appliedEnabled: false,
		currentLocalStatus: {
			desired_enabled: false,
			runtime_disabled: true,
			interface_disabled: true
		},
		currentPublicIp: '203.0.113.20',
		currentPublicCountry: 'IT'
	};

	await actions.updatePublicIp(state, { force: true });

	assert.deepEqual(networkCalls, [], 'disabled public lookups do not invoke service exec');
	assert.deepEqual(lockCalls, [], 'disabled public lookups return before acquiring operation locks');
	assert.equal(replacements.public_ip, 'Unavailable', 'disabled public IP lookup renders unavailable');
	assert.equal(replacements.public_country, 'Unavailable', 'disabled public country lookup renders unavailable');
	assert.equal(state.currentPublicIp, '', 'disabled public IP lookup clears live IP state');
	assert.equal(state.currentPublicCountry, '', 'disabled public country lookup clears live country state');
	assert.equal(countryMatchUpdates, 1, 'disabled public lookups refresh country-match status without network calls');
}

async function testPublicIpPollUpdatesCountryFromSingleSnapshot() {
	const serviceCalls = [];
	const replacements = {};
	let countryMatchUpdates = 0;
	const actions = loadManagerActionsModule({
		managerStore: {
			runExclusive(_state, key, factory) {
				serviceCalls.push('lock:' + key);
				return Promise.resolve().then(factory);
			}
		},
		managerUI: {
			ids: {
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			updateCountryMatchStatus() {
				countryMatchUpdates++;
			},
			isDisableRequested() {
				return false;
			}
		},
		service: {
			parseExecJsonResponse(res, fallback) {
				try {
					return JSON.parse((res && res.stdout) || '');
				} catch (e) {
					return fallback;
				}
			},
			execService(action) {
				serviceCalls.push(action);
				if (action === 'public_ip') {
					return Promise.resolve({
						code: 0,
						stdout: JSON.stringify({
							ip: '203.0.113.20',
							changed: false,
							detected_at: 42,
							detected_at_iso: '2026-05-20T16:00:00Z',
							source: 'https://ifconfig.me/ip',
							country: 'IT'
						}),
						stderr: ''
					});
				}

				return Promise.reject(new Error('country lookup should not run when IP is unchanged'));
			}
		}
	}).managerActions;
	const state = {
		pollingSuspended: false,
		appliedEnabled: true,
		currentLocalStatus: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false
		},
		currentPublicIp: '203.0.113.20',
		currentPublicCountry: ''
	};

	await actions.updatePublicIp(state);

	assert.deepEqual(serviceCalls, [ 'lock:publicIp', 'public_ip' ],
		'public IP poll uses one backend action');
	assert.equal(replacements.public_ip, '203.0.113.20', 'unchanged public IP still updates the display');
	assert.equal(replacements.public_country, 'IT', 'public IP snapshot updates the country display');
	assert.equal(countryMatchUpdates, 1, 'public IP snapshot refreshes country-match once');
}

async function testPublicIpChangeReplacesCountryFromSnapshot() {
	const serviceCalls = [];
	const replacements = {};
	let countryMatchUpdates = 0;
	const actions = loadManagerActionsModule({
		managerStore: {
			runExclusive(_state, key, factory) {
				serviceCalls.push('lock:' + key);
				return Promise.resolve().then(factory);
			}
		},
		managerUI: {
			ids: {
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			updateCountryMatchStatus() {
				countryMatchUpdates++;
			},
			isDisableRequested() {
				return false;
			}
		},
		service: {
			parseExecJsonResponse(res, fallback) {
				try {
					return JSON.parse((res && res.stdout) || '');
				} catch (e) {
					return fallback;
				}
			},
			execService(action, args) {
				serviceCalls.push([ action, args || [] ]);
				if (action === 'public_ip') {
					return Promise.resolve({
						code: 0,
						stdout: JSON.stringify({
							ip: '198.51.100.55',
							changed: true,
							detected_at: 43,
							detected_at_iso: '2026-05-20T16:00:05Z',
							source: 'https://ifconfig.me/ip',
							country: 'UY'
						}),
						stderr: ''
					});
				}
				return Promise.reject(new Error('unexpected service action: ' + action));
			}
		}
	}).managerActions;
	const state = {
		pollingSuspended: false,
		appliedEnabled: true,
		currentLocalStatus: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false
		},
		currentPublicIp: '203.0.113.20',
		currentPublicCountry: 'IT'
	};

	await actions.updatePublicIp(state);

	assert.deepEqual(normalizeValue(serviceCalls), [
		'lock:publicIp',
		[ 'public_ip', [] ]
	], 'changed public IP is handled by one backend call');
	assert.equal(replacements.public_ip, '198.51.100.55', 'changed public IP updates the display');
	assert.equal(replacements.public_country, 'UY', 'changed public IP renders the refreshed country');
	assert.equal(state.currentPublicCountry, 'UY', 'changed public IP stores the refreshed country');
	assert.equal(countryMatchUpdates, 1, 'changed public IP refreshes country-match after the snapshot');
}

function testRenderLocalStatusSnapshotHandlesBusyOperation() {
	const replacements = {};
	const indicators = {};
	const controls = [];
	const phaseTransitions = [];
	let countryMatchUpdates = 0;
	let serverSelectionUpdates = 0;
	const actions = loadManagerActionsModule({
		managerData: {
			normalizeCountryCode(value) {
				return String(value || '').trim().toUpperCase();
			},
			parseLocalStatus(raw) {
				return JSON.parse(raw || '{}');
			}
		},
		managerStore: {
			PHASES: { RUNTIME_BUSY: 'runtime_busy' },
			setPhase(state, phase) {
				phaseTransitions.push(phase);
				state.phase = phase;
			},
			syncPhase() {
				throw new Error('busy render must not sync idle phase');
			}
		},
		managerUI: {
			ids: {
				CURRENT_SERVER_STATUS_ID: 'current',
				PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer',
				OPERATION_STATUS_ID: 'operation',
				LAST_ERROR_STATUS_ID: 'last_error',
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			setManagerControlsDisabled(disabled) {
				controls.push(!!disabled);
			},
			setVpnStatusIndicator(state, label) {
				indicators.vpn = { state: state, label: String(label) };
			},
			updateCountryMatchStatus() {
				countryMatchUpdates++;
			},
			updateServerSelectionState() {
				serverSelectionUpdates++;
			},
			currentServerSummaryFromStatus() {
				return 'uy123.nordvpn.com';
			},
			preferredServerSummaryFromStatus() {
				return 'Automatic / Best recommended';
			},
			isDisableRequested() {
				return false;
			}
		}
	}).managerActions;
	const status = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		server_selection_mode: 'auto',
		vpn_status: 'inactive',
		operation_status: 'busy',
		endpoint: '203.0.113.10:51820',
		latest_handshake: 'Never',
		transfer_rx: '0 B',
		transfer_tx: '0 B',
		last_error: ''
	};
	const state = {
		appliedEnabled: true,
		appliedCountryCode: 'UY',
		currentLocalStatus: status,
		currentOperationStatus: 'busy',
		pendingOperationLabel: '',
		currentPublicIp: '',
		currentPublicCountry: ''
	};

	actions.renderLocalStatusSnapshot(state, status);

	assert.equal(replacements.operation, 'Applying...', 'busy status renders the generic applying label');
	assert.equal(replacements.current, 'uy123.nordvpn.com', 'busy status still renders runtime details');
	assert.equal(replacements.endpoint, '203.0.113.10:51820', 'busy status keeps endpoint visible');
	assert.deepEqual(controls, [ true ], 'busy status disables manager controls');
	assert.deepEqual(phaseTransitions, [ 'runtime_busy' ], 'busy status moves the UI into runtime-busy phase');
	assert.deepEqual(indicators.vpn, { state: 'inactive', label: 'Disconnected' },
		'busy operation status does not mask vpn_status from the runtime snapshot');
	assert.equal(countryMatchUpdates, 1, 'busy status updates country-match indicator once');
	assert.equal(serverSelectionUpdates, 1, 'busy status updates server-selection controls once');
}

function testRenderLocalStatusSnapshotUsesHeldLockAction() {
	const replacements = {};
	const actions = loadManagerActionsModule({
		managerStore: {
			PHASES: {
				RUNTIME_BUSY: 'runtime_busy'
			},
			setPhase() {},
			syncPhase() {}
		},
		managerUI: {
			ids: {
				OPERATION_STATUS_ID: 'operation',
				CURRENT_SERVER_STATUS_ID: 'current',
				PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer',
				LAST_ERROR_STATUS_ID: 'last_error',
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			setManagerControlsDisabled() {},
			setVpnStatusIndicator() {},
			updateCountryMatchStatus() {},
			updateServerSelectionState() {},
			currentServerSummaryFromStatus() {
				return 'server';
			},
			preferredServerSummaryFromStatus() {
				return 'preferred';
			},
			isDisableRequested() {
				return false;
			}
		}
	}).managerActions;
	const status = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		vpn_status: 'starting',
		operation_status: 'idle',
		operation_lock_state: 'held',
		operation_lock_action: 'setup',
		endpoint: '203.0.113.10:51820',
		latest_handshake: 'Never',
		transfer_rx: '0 B',
		transfer_tx: '0 B',
		last_error: ''
	};
	const state = {
		appliedEnabled: true,
		currentLocalStatus: status,
		currentOperationStatus: 'idle',
		saveApplyInProgress: false
	};

	actions.renderLocalStatusSnapshot(state, status);

	assert.equal(
		replacements.operation,
		'Applying (setup)...',
		'held lock action is shown even when operation_status is idle'
	);
}

async function testStatusRpcFailureDoesNotRenderDisabled() {
	const replacements = {};
	let indicator = null;
	const actions = loadManagerActionsModule({
		managerStore: {
			PHASES: {},
			runExclusive(_state, _key, factory) {
				return Promise.resolve().then(factory);
			},
			clearError() {},
			setError(state, err) {
				state.lastError = (err && err.message) ? err.message : String(err);
			}
		},
		managerUI: {
			ids: {
				CURRENT_SERVER_STATUS_ID: 'current',
				PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer',
				OPERATION_STATUS_ID: 'operation',
				LAST_ERROR_STATUS_ID: 'last_error',
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			replaceStatusText(id, value) {
				replacements[id] = String(value);
			},
			setManagerControlsDisabled() {},
			setVpnStatusIndicator(state, label) {
				indicator = { state: state, label: String(label) };
			},
			updateCountryMatchStatus() {},
			updateServerSelectionState() {}
		},
		service: {
			execService() {
				return Promise.reject(new Error('backend RPC unavailable'));
			}
		}
	}).managerActions;
	const state = {
		appliedEnabled: true,
		currentLocalStatus: null,
		currentLocalStatusLastUpdated: 0,
		inFlight: {}
	};

	await actions.updateLocalStatus(state, { force: true });

	assert.equal(replacements.current, 'Unavailable', 'missing backend status does not render a disabled server');
	assert.equal(replacements.operation, 'Unknown', 'missing backend status renders unknown operation status');
	assert.equal(replacements.last_error, 'backend RPC unavailable', 'missing backend status exposes the backend error');
	assert.deepEqual(indicator, { state: 'error', label: 'Unavailable' }, 'missing backend status renders an unavailable connection');
	assert.equal(state.currentLocalStatus.desired_enabled, true, 'synthetic unavailable status keeps the saved enabled intent');
}

function testSaveApplyTransitionSuppressesConnectedAndDrift() {
	const diagnosticsBanners = {};
	const actions = loadManagerActionsModule({
		managerStore: {
			PHASES: {
				SAVING: 'saving',
				RUNTIME_BUSY: 'runtime_busy'
			},
			setPhase(state, phase) {
				state.phase = phase;
			}
		},
		managerUI: {
			ids: {
				OPERATION_STATUS_ID: 'operation',
				CURRENT_SERVER_STATUS_ID: 'current',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake'
			},
			replaceStatusText(id, value) {
				diagnosticsBanners[id] = String(value);
			},
			setManagerControlsDisabled() {},
			setVpnStatusIndicator(state, label) {
				diagnosticsBanners.vpn = { state: state, label: String(label) };
			},
			updateCountryMatchStatus() {},
			updateServerSelectionState() {},
			currentServerSummaryFromStatus() {
				return 'TH - Bangkok - th30.nordvpn.com';
			},
			preferredServerSummaryFromStatus() {
				return 'Automatic / Best recommended';
			},
			isDisableRequested() {
				return false;
			},
			updateDiagnosticsBanner(summary) {
				diagnosticsBanners.summary = summary;
				diagnosticsBanners.summaryHidden = !managerData.diagnosticsHasAlert(summary);
			}
		}
	}).managerActions;
	const driftSummary = {
		primary_finding: {
			code: 'selection.drift',
			message: 'country drift',
			action: 'Run Save & Apply',
			severity: 'warning',
			priority: 150
		},
		findings: [
			{
				code: 'selection.drift',
				message: 'country drift',
				action: 'Run Save & Apply',
				severity: 'warning',
				priority: 150
			}
		]
	};
	const status = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		vpn_status: 'active',
		connected: true,
		operation_status: 'idle',
		selected_country: 'ES',
		current_server_country: 'TH',
		endpoint: '45.80.184.45:51820',
		latest_handshake: '1 minute ago',
		transfer_rx: '43 KiB',
		transfer_tx: '30 KiB',
		last_error: ''
	};
	const state = {
		appliedEnabled: true,
		appliedCountryCode: 'ES',
		currentLocalStatus: status,
		currentOperationStatus: 'idle',
		pendingOperationLabel: '',
		saveApplyInProgress: true,
		applyPhase: 'configuration',
		phase: 'saving',
		currentDiagnosticsSummary: driftSummary
	};

	actions.renderLocalStatusSnapshot(state, status);
	actions.renderDiagnosticsSnapshot(state, driftSummary, true);

	assert.equal(
		diagnosticsBanners.operation,
		'Applying (configuration)...',
		'Save & Apply shows the local apply phase when backend status is still idle'
	);
	assert.deepEqual(
		diagnosticsBanners.vpn,
		{ state: 'active', label: 'Connected' },
		'Connection shows the real vpn_status during Save & Apply, not a forced Connecting'
	);
	assert.equal(
		diagnosticsBanners.summaryHidden,
		true,
		'drift banner stays hidden until Save & Apply finishes'
	);

	state.saveApplyInProgress = false;
	state.pendingOperationLabel = '';
	state.phase = 'idle';

	actions.renderDiagnosticsSnapshot(state, driftSummary, true);
	assert.equal(
		managerData.diagnosticsHasAlert(diagnosticsBanners.summary),
		true,
		'selection.drift is shown only after Save & Apply completes'
	);
}

function buildHandleSaveApplyHarness(options) {
	const opts = options || {};
	const selectedServer = opts.selectedServer || {
		hostname: 'uy123.nordvpn.com',
		station: 'uy123',
		city: 'Montevideo',
		country_code: 'UY',
		country_name: 'Uruguay',
		load: '12',
		public_key: 'pub'
	};
	const uciValues = Object.assign({
		enabled: (opts.savedEnabled != null) ? opts.savedEnabled : '1',
		vpn_country: (opts.previousCountry != null && opts.previousCountry !== '')
			? opts.previousCountry
			: ((opts.savedCountry != null) ? opts.savedCountry : 'UY'),
		server_selection_mode: opts.previousMode || opts.savedMode || 'auto',
		preferred_server_station: (opts.previousPreferredStation != null && opts.previousPreferredStation !== '')
			? opts.previousPreferredStation
			: ((opts.savedPreferredStation != null) ? opts.savedPreferredStation : ''),
		nordvpn_token: opts.savedToken || 'saved-token'
	}, opts.uciValues || {});
	const uciSets = [];
	const notifications = [];
	const runtimeActions = [];
	const serviceCalls = [];
	const phaseTransitions = [];
	const controlsDisabledCalls = [];
	const debugNotifications = [];
	let runtimeStatusPayload = null;
	const calls = {
		handleSave: 0,
		apply: 0,
		applyEndpoint: 0,
		commit: 0,
		changes: 0,
		setIndicator: [],
		uciLoad: 0,
		uciUnload: 0
	};
	let uciAppliedHandler = null;

	function defaultStatusPayload() {
		const targetCountry = String(
			opts.convergedCountry ||
			opts.currentCountry ||
			opts.savedCountry ||
			uciValues.vpn_country ||
			'UY'
		).trim().toUpperCase();

		return {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: targetCountry,
			server_selection_mode: uciValues.server_selection_mode || 'auto',
			preferred_server_station: uciValues.preferred_server_station || '',
			current_server_country: targetCountry,
			connected: true,
			vpn_status: 'active',
			state: 'connected',
			handshake_age_seconds: 5
		};
	}

	function currentStatusPayload() {
		return Object.assign({}, defaultStatusPayload(), opts.statusPayload || {}, runtimeStatusPayload || {});
	}

	function markConnectConverged() {
		if (opts.connectConvergence === false)
			return;

		const targetCountry = String(
			opts.convergedCountry ||
			opts.currentCountry ||
			opts.savedCountry ||
			uciValues.vpn_country ||
			'UY'
		).trim().toUpperCase();

		runtimeStatusPayload = Object.assign({}, currentStatusPayload(), {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: targetCountry,
			current_server_country: targetCountry,
			connected: true,
			vpn_status: 'active',
			state: 'connected',
			handshake_age_seconds: 5,
			last_error: ''
		});
	}

	const actions = loadManagerActionsModule({
		managerData: Object.assign({
			normalizeCountryCode(value) {
				return String(value || '').trim().toUpperCase();
			},
			parseEnabledFlag(value) {
				return [ '1', 'true', 'yes', 'on' ].indexOf(String(value != null ? value : '0').trim().toLowerCase()) !== -1;
			},
			parseLocalStatus(raw) {
				return JSON.parse(raw || '{}');
			},
			runtimeStatusIsBusy(status) {
				return managerData.runtimeStatusIsBusy(status);
			}
		}, {
			emptyServerCatalog() {
				return { servers: [] };
			},
			buildServerCatalogIndex() {
				return {};
			},
			parseServerCatalog() {
				return { servers: [] };
			},
			emptyDiagnosticsSummary() {
				return managerData.emptyDiagnosticsSummary();
			},
			parseDiagnosticsSummary(raw) {
				return managerData.parseDiagnosticsSummary(raw);
			},
			diagnosticsHasAlert(summary) {
				return managerData.diagnosticsHasAlert(summary);
			},
			hideSelectionDriftDiagnostics(summary) {
				return managerData.hideSelectionDriftDiagnostics(summary);
			}
		}),
		managerFormat: {
			formatServerLabel(server) {
				return [ server.country_code, server.city, server.hostname, server.load + '%' ].filter(Boolean).join(' - ');
			},
			humanizeAction(action) {
				return String(action || '');
			}
		},
		managerStore: {
			PHASES: {
				BOOTING: 'booting',
				SAVING: 'saving',
				RUNTIME_BUSY: 'runtime_busy',
				IDLE: 'idle',
				DISABLED: 'disabled',
				ERROR: 'error'
			},
			runExclusive(_state, _key, factory) {
				return Promise.resolve().then(factory);
			},
			clearInFlight() {},
			clearError(state) {
				state.lastError = '';
			},
			setError(state, err) {
				state.lastError = (err && err.message) ? err.message : String(err || '');
			},
			setPhase(state, phase) {
				phaseTransitions.push(phase);
				state.phase = phase;
			},
			syncPhase() {}
		},
		managerUI: {
			ids: {
				TOKEN_FIELD_ID: 'token',
				CURRENT_SERVER_STATUS_ID: 'current',
				PREFERRED_SERVER_STATUS_ID: 'preferred',
				ENDPOINT_STATUS_ID: 'endpoint',
				HANDSHAKE_STATUS_ID: 'handshake',
				TRANSFER_STATUS_ID: 'transfer',
				OPERATION_STATUS_ID: 'operation',
				LAST_ERROR_STATUS_ID: 'last_error',
				PUBLIC_IP_STATUS_ID: 'public_ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public_country'
			},
			getInputElement() {
				return null;
			},
			getEnabledCheckboxElement() {
				return {
					checked: opts.currentEnabled !== false
				};
			},
			getSelectedMode() {
				return opts.currentMode || 'auto';
			},
			getSelectedCountry() {
				return opts.currentCountry || '';
			},
			getSelectedPreferredStation() {
				return opts.preferredStation || '';
			},
			replaceStatusText() {},
			setManagerControlsDisabled(disabled) {
				controlsDisabledCalls.push(!!disabled);
			},
			setVpnStatusIndicator() {},
			updateCountryMatchStatus() {},
			updateServerSelectionState() {},
			currentServerSummaryFromStatus() {
				return 'current server';
			},
			preferredServerSummaryFromStatus() {
				return 'preferred server';
			},
			isDisableRequested() {
				return false;
			}
		},
		service: {
			parseExecJsonResponse(res, fallback) {
				if (!res || res.code !== 0)
					return fallback;

				return JSON.parse(res.stdout || '{}');
			},
			execService(action) {
				serviceCalls.push(action);

				if (action === 'status_json') {
					return Promise.resolve({
						code: 0,
						stdout: JSON.stringify(currentStatusPayload()),
						stderr: ''
					});
				}

				if (action === 'public_ip')
					return Promise.resolve({ code: 1, stdout: '', stderr: '' });

				return Promise.resolve({ code: 0, stdout: '', stderr: '' });
			},
			runAction(action) {
				runtimeActions.push([ action ]);

				if (opts.startConnectActionReject && action === 'start_connect')
					return Promise.reject(opts.startConnectActionReject);

				if (opts.startConnectActionResult && action === 'start_connect')
					return Promise.resolve(opts.startConnectActionResult);

				if (action === 'start_connect')
					markConnectConverged();

				if (opts.connectActionReject && action === 'connect')
					return Promise.reject(opts.connectActionReject);

				return Promise.resolve({
					action: action,
					code: 0,
					success: true,
					message: ''
				});
			},
			resultToError(result) {
				return new Error(String((result && result.message) || 'runtime action failed'));
			},
			notifyInfo(message) {
				notifications.push({ type: 'info', message: String(message) });
			},
			notifyError(err) {
				notifications.push({ type: 'error', message: (err && err.message) ? err.message : String(err) });
			}
		},
		ui: {
			addNotification(_title, body, level) {
				debugNotifications.push({ body: body, level: level });
			},
			changes: {
				apply() {
					calls.apply++;
					if (opts.emitUciApplied !== false) {
						Promise.resolve().then(function() {
							if (uciAppliedHandler)
								uciAppliedHandler();
						});
					}
					return Promise.resolve();
				},
				setIndicator(value) {
					calls.setIndicator.push(value);
				}
			}
		},
		L: {
			env: {
				sessionid: 'test-session',
				token: 'test-token'
			},
			url() {
				return Array.prototype.slice.call(arguments).join('/');
			}
		},
		request: {
			request(url, options) {
				calls.applyEndpoint++;
				assert.equal(url, 'admin/uci/apply_unchecked', 'Save & Apply uses the LuCI unchecked apply endpoint');
				assert.equal(options && options.method, 'post', 'LuCI apply endpoint is called with POST');
				assert.equal(options && options.query && options.query.sid, 'test-session', 'LuCI apply endpoint carries the active session id');
				return Promise.resolve({ status: opts.applyStatus || 204 });
			}
		},
		rpc: {
			declare(spec) {
				if (spec.object === 'uci' && spec.method === 'commit') {
					return function(config) {
						calls.commit++;

						if (opts.commitReject)
							return Promise.reject(opts.commitReject);

						assert.equal(config, 'nordvpn_easy', 'Save & Apply commits only nordvpn_easy');
						return Promise.resolve(0);
					};
				}

				throw new Error('unexpected rpc declaration');
			}
		},
		uci: {
			get(_config, _section, option) {
				return uciValues[option];
			},
			set(_config, _section, option, value) {
				uciSets.push({ option: option, value: value });
				uciValues[option] = value;
				return true;
			},
			unload() {
				calls.uciUnload++;
			},
			load() {
				calls.uciLoad++;
				if (opts.uciLoadReject)
					return Promise.reject(opts.uciLoadReject);
				if (opts.uciLoadPromise)
					return opts.uciLoadPromise;
				return Promise.resolve();
			},
			changes() {
				calls.changes++;
				return Promise.resolve(opts.pendingChanges || {});
			}
		},
		document: {
			addEventListener(name, handler) {
				if (name === 'uci-applied')
					uciAppliedHandler = handler;
			},
			removeEventListener(name, handler) {
				if (name === 'uci-applied' && uciAppliedHandler === handler)
					uciAppliedHandler = null;
			}
		},
		setTimeout: opts.timeoutMs
			? function(callback) {
				return setTimeout(callback, opts.timeoutMs);
			}
			: setTimeout
	}).managerActions;
	const state = Object.assign({
		pollingSuspended: false,
		currentLocalStatus: Object.assign({}, healthyRuntime, {
			desired_enabled: true,
			operation_status: 'idle',
			selected_country: 'UY'
		}),
		currentLocalStatusFresh: opts.currentLocalStatusFresh !== false,
		currentLocalStatusLastUpdated: 100,
		currentOperationStatus: 'idle',
		pendingOperationLabel: '',
		appliedEnabled: opts.previousEnabled !== false,
		appliedCountryCode: opts.previousCountry || 'UY',
		currentPublicIp: '',
		currentPublicCountry: '',
		serverCatalogIndex: Object.assign({ uy123: selectedServer }, opts.serverCatalogIndex || {}),
		inFlight: {}
	}, opts.state || {});
	const viewState = {
		initialEnabled: opts.previousEnabled !== false,
		initialCountry: opts.previousCountry || 'UY',
		initialMode: opts.previousMode || 'auto',
		initialPreferredStation: opts.previousPreferredStation || '',
		_uciAppliedHandler: null,
		handleSave() {
			calls.handleSave++;
			return Promise.resolve();
		}
	};

	return {
		actions: actions,
		viewState: viewState,
		state: state,
		uciSets: uciSets,
		notifications: notifications,
		runtimeActions: runtimeActions,
		serviceCalls: serviceCalls,
		phaseTransitions: phaseTransitions,
		debugNotifications: debugNotifications,
		controlsDisabledCalls: controlsDisabledCalls,
		calls: calls
	};
}

async function testHandleSaveApplyManualWithoutPreferredFallsBackToAuto() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		currentMode: 'manual',
		currentCountry: 'UY',
		preferredStation: '',
		currentEnabled: true,
		uciValues: {
			nordvpn_token: 'token',
			enabled: '1',
			vpn_country: 'UY',
			server_selection_mode: 'manual',
			preferred_server_hostname: 'old.example',
			preferred_server_station: 'uy999'
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(
		harness.uciSets.find(function(entry) {
			return entry.option === 'server_selection_mode';
		}).value,
		'auto',
		'manual mode without preferred server stores automatic selection'
	);
	assert.equal(
		harness.uciSets.find(function(entry) {
			return entry.option === 'preferred_server_station';
		}).value,
		'',
		'manual mode without preferred server clears preferred station'
	);
}

async function testHandleSaveApplyFormCountryOverridesStaleDiskCountry() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'IE',
		currentMode: 'auto',
		currentCountry: 'NG',
		currentEnabled: true,
		savedCountry: 'IE',
		uciValues: {
			nordvpn_token: 'token',
			enabled: '1',
			vpn_country: 'IE',
			server_selection_mode: 'auto'
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(
		harness.uciSets.filter(function(entry) {
			return entry.option === 'vpn_country';
		}),
		[{ option: 'vpn_country', value: 'NG' }],
		'form country overrides stale disk country during Save & Apply'
	);
}

async function testHandleSaveApplyFallsBackToAutomaticWhenManualSelectionIncomplete() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		currentMode: 'manual',
		currentCountry: '',
		preferredStation: 'uy123',
		currentEnabled: true,
		uciValues: {
			nordvpn_token: 'token',
			enabled: '1',
			vpn_country: '',
			server_selection_mode: 'manual',
			preferred_server_hostname: '',
			preferred_server_station: ''
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(harness.calls.handleSave, 1, 'incomplete manual selection still saves the form');
	assert.deepEqual(
		harness.uciSets.filter(function(entry) {
			return entry.option === 'server_selection_mode';
		}),
		[{ option: 'server_selection_mode', value: 'auto' }],
		'incomplete manual selection stores automatic server selection mode'
	);
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ], 'incomplete manual selection still runs the unified apply cycle');
}

async function testHandleSaveApplyStopsAfterStopWhenDisabled() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		currentEnabled: false,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedEnabled: '0',
		uciValues: {
			nordvpn_token: 'token',
			enabled: '0',
			vpn_country: 'UY',
			server_selection_mode: 'auto'
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ] ], 'disabled Save & Apply stops after cleanup without connect');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'info' && /VPN remains disabled/.test(entry.message);
	}), 'disabled Save & Apply reports disabled success message');
}

async function testHandleSaveApplyTimesOutWhenPostSaveSyncNeverFinishes() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: false,
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: '',
		savedEnabled: '1',
		savedCountry: '',
		uciLoadReject: new Error('uci reload failed'),
		timeoutMs: 25
	});
	let rejected = null;

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}).catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(harness.calls.handleSave, 1, 'enable flow saves the form once');
	assert.equal(harness.calls.apply, 0, 'save flow does not use the legacy LuCI apply path');
	assert.equal(rejected && rejected.message, 'uci reload failed', 'post-save sync failure rejects with the original error');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'post-save sync failure does not stop VPN before configuration is saved');
	assert.equal(harness.state.pendingOperationLabel, '', 'post-save sync failure clears pending state');
}

async function testHandleSaveApplyClearsBusyStateWhenPostApplySyncFails() {
	const syncError = new Error('uci reload failed');
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		uciLoadReject: syncError,
		timeoutMs: 25
	});
	let rejected = null;

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}).catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(rejected, syncError, 'post-apply sync failure rejects with the original error');
	assert.equal(harness.state.pendingOperationLabel, '', 'post-apply sync failure clears the applying label');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'post-apply sync failure refreshes local status');
	assert.match(harness.notifications[harness.notifications.length - 1].message, /Save & Apply failed: uci reload failed/, 'post-apply sync failure reports a readable notification');
}

async function testHandleSaveApplyIgnoresLateApplyCycleAfterTimeout() {
	let releaseLoad;
	const delayedLoad = new Promise(function(resolve) {
		releaseLoad = resolve;
	});
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedEnabled: '1',
		uciLoadPromise: delayedLoad,
		timeoutMs: 10
	});
	let rejected = null;
	const applyPromise = harness.actions.handleSaveApply(harness.viewState, harness.state, {}).catch(function(err) {
		rejected = err;
	});

	await delay(25);
	await applyPromise;

	assert.equal(rejected && rejected.message, 'Configuration apply timed out.', 'Save & Apply rejects with timeout');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [],
		'timed-out apply cycle does not stop or connect before delayed load resolves');
	assert.equal(harness.state.currentApplyAttempt, null, 'timeout clears the active apply attempt token');
	assert.equal(
		harness.controlsDisabledCalls[harness.controlsDisabledCalls.length - 1],
		false,
		'timeout settle re-enables the manager controls instead of leaving them stuck disabled'
	);

	releaseLoad();
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [],
		'late apply cycle resolution does not stop or reconnect after timeout');
	assert.equal(harness.notifications.filter(function(entry) {
		return entry.type === 'info' && /connected/.test(entry.message);
	}).length, 0, 'late apply cycle resolution does not show a success notification');
}

async function testHandleSaveApplyAutoModeClearsManualSelectionAndReconnects() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'UY',
		previousMode: 'manual',
		previousPreferredStation: 'uy123',
		currentMode: 'auto',
		currentCountry: 'UY',
		currentEnabled: true,
		savedMode: 'auto',
		savedPreferredStation: ''
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(
		harness.uciSets.filter(function(entry) {
			return entry.option === 'preferred_server_hostname' || entry.option === 'preferred_server_station';
		}),
		[
			{ option: 'preferred_server_hostname', value: '' },
			{ option: 'preferred_server_station', value: '' }
		],
		'returning to automatic mode clears manual preferred server UCI fields'
	);
	assert.equal(harness.calls.handleSave, 1, 'manual-to-auto changes save the form once');
	assert.equal(harness.calls.apply, 0, 'manual-to-auto changes do not use the legacy LuCI apply path');
	assert.equal(harness.calls.applyEndpoint, 0, 'manual-to-auto changes do not call the global LuCI apply endpoint');
	assert.equal(harness.calls.commit, 1, 'manual-to-auto changes commit nordvpn_easy directly');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ], 'manual-to-auto changes clear caches before connect apply');
	assert.equal(harness.viewState.initialMode, 'auto', 'view state tracks saved automatic mode');
	assert.equal(harness.viewState.initialPreferredStation, '', 'view state clears saved preferred station');
	assert.equal(harness.state.pendingOperationLabel, '', 'runtime action completion clears pending operation label');
	assert.ok(harness.phaseTransitions.indexOf('saving') !== -1, 'save/apply enters saving phase');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'save/apply refreshes local status during the flow');
}

async function testHandleSaveApplyReconcilesDisabledRuntimeAfterSave() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'UY',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedEnabled: '1',
		savedCountry: 'UY',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: true,
			interface_disabled: true,
			runtime_configured: true,
			operation_status: 'idle',
			selected_country: 'UY',
			server_selection_mode: 'auto',
			preferred_server_station: ''
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'begin_connect_apply' ], [ 'stop_vpn' ], [ 'start_connect' ] ], 'unchanged enabled config runs stop then connect after Save & Apply');
	assert.equal(harness.state.pendingOperationLabel, '', 'apply cycle completion clears pending operation label');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'apply cycle refreshes status after runtime actions');
}

async function testHandleSaveApplyQueuesReconnectWhenSavedCountryDriftsFromPeer() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AU',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'AU',
		savedCountry: 'AU',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			selected_country: 'AU',
			server_selection_mode: 'auto',
			current_server_country: 'BZ',
			current_server_station: '45.95.162.3'
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(
		normalizeValue(harness.runtimeActions),
		[ [ 'begin_connect_apply' ], [ 'stop_vpn' ], [ 'start_connect' ] ],
		'Save & Apply runs a single stop/start_connect cycle; post-apply drift is left to background reconcile'
	);
}

async function testHandleSaveApplyConvergesWhenConnectApplyResultReportsSuccess() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'BG',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'RO',
		savedCountry: 'RO',
		connectConvergence: false,
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'RO',
			current_server_country: 'RO',
			connected: true,
			vpn_status: 'active',
			state: 'connected',
			handshake_age_seconds: 12,
			connect_apply_pending: false,
			connect_apply_finished: true,
			connect_apply_success: true,
			connect_apply_rc: 0,
			connect_apply_country: 'RO',
			connect_apply_started_at: Math.floor(Date.now() / 1000),
			connect_apply_finished_at: Math.floor(Date.now() / 1000)
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ],
		'country change clears server caches before connect apply');
	assert.equal(harness.state.saveApplyInProgress, false, 'apply ends only after the live tunnel is ready');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'info' && /applied your configuration and connected/.test(entry.message);
	}), 'live tunnel readiness reports unified success');
}

async function testHandleSaveApplyConvergesViaStartConnectAndStatusPolling() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'UY',
			server_selection_mode: 'auto',
			current_server_country: 'UY',
			current_server_station: 'uy123',
			connected: true,
			vpn_status: 'active',
			state: 'connected',
			handshake_age_seconds: 8
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ],
		'Save & Apply dispatches start_connect then polls status');
	assert.equal(harness.state.pendingOperationLabel, '', 'status convergence clears pending operation label');
	assert.equal(harness.state.applyTargetEnabled, null, 'status convergence clears the pending enabled target');
	assert.equal(harness.notifications.filter(function(entry) {
		return entry.type === 'error';
	}).length, 0, 'status convergence does not show a false error notification');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'info' && /applied your configuration and connected/.test(entry.message);
	}), 'status convergence reports the unified apply success message');
	assert.equal(harness.notifications.filter(function(entry) {
		return entry.type === 'info' && /applied your configuration and connected/.test(entry.message);
	}).length, 1, 'status convergence reports the apply success exactly once (idempotent finish)');
	assert.ok(harness.serviceCalls.filter(function(action) {
		return action === 'status_json';
	}).length >= 2, 'status convergence polls status after start_connect dispatch');
}

async function testHandleSaveApplyStartConnectBusyFailsImmediately() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		startConnectActionResult: {
			action: 'start_connect',
			code: 75,
			success: false,
			busy: true,
			skipped: true,
			reason: 'operation_busy',
			holder_action: 'setup',
			message: 'operation busy'
		}
	});
	let rejected = null;

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}).catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.ok(rejected, 'busy start_connect rejects apply');
	assert.match(String(rejected.message), /already running|busy|setup/i, 'busy start_connect reports holder context');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ],
		'busy start_connect is attempted after stop_vpn');
}

async function testHandleSaveApplyStartConnectRuntimeErrorFromStatus() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		connectConvergence: false,
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'UY',
			server_selection_mode: 'auto',
			current_server_country: 'UY',
			vpn_status: 'error',
			last_error: 'backend failed',
			connected: false
		}
	});
	let rejected = null;

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}).catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.ok(rejected, 'runtime error status rejects apply');
	assert.match(String(rejected.message), /backend failed/, 'runtime error status surfaces backend message');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ],
		'runtime error still attempted stop then start_connect');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'error' && /backend failed/.test(entry.message);
	}), 'runtime error reports an error notification');
}

async function testHandleSaveApplyRecoversAbortedRuntimeActionWhenStatusConverges() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'UY',
			server_selection_mode: 'auto',
			current_server_country: 'UY',
			current_server_station: 'uy123',
			connected: true,
			vpn_status: 'active'
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {});
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ],
		'legacy recovery test name kept for start_connect apply cycle');
	assert.equal(harness.state.pendingOperationLabel, '', 'aborted runtime recovery clears pending operation label');
	assert.equal(harness.notifications.filter(function(entry) {
		return entry.type === 'error';
	}).length, 0, 'aborted runtime recovery does not show a false error notification');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'info' && /applied your configuration and connected/.test(entry.message);
	}), 'aborted runtime recovery reports the unified apply success message');
	assert.ok(harness.serviceCalls.filter(function(action) {
		return action === 'status_json';
	}).length >= 2, 'aborted runtime recovery polls status after the interrupted request');
}

async function testHandleSaveApplyDoesNotRecoverNonAbortRuntimeActionFailure() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		startConnectActionResult: {
			action: 'start_connect',
			code: 1,
			success: false,
			busy: false,
			message: 'backend failed'
		},
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'UY',
			server_selection_mode: 'auto',
			current_server_country: 'UY',
			connected: true,
			vpn_status: 'active'
		}
	});
	let rejected = null;

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}).catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.ok(rejected, 'non-success start_connect rejects apply');
	assert.match(String(rejected.message), /backend failed/, 'non-success start_connect reports backend failure');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'begin_connect_apply' ], [ 'start_connect' ] ],
		'non-success start_connect still attempted stop then start_connect');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'error' && /backend failed/.test(entry.message);
	}), 'non-success start_connect still reports an error notification');
}

async function testAutoReconcileRunsForCountryDrift() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
		convergedCountry: 'AU',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'AU',
			server_selection_mode: 'auto',
			current_server_country: 'BM',
			current_server_station: 'bm3'
		}
	});

	harness.state.appliedCountryCode = 'AU';
	harness.state.currentLocalStatus = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		operation_status: 'idle',
		operation_lock_state: 'none',
		selected_country: 'AU',
		server_selection_mode: 'auto',
		current_server_country: 'BM',
		current_server_station: 'bm3'
	};

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, harness.state.currentLocalStatus);

	assert.ok(harness.runtimeActions.length >= 3, 'country drift runs at least stop_vpn, begin_connect_apply then start_connect');
	assert.equal(harness.runtimeActions[0][0], 'stop_vpn', 'country drift clears stale server caches before connect apply');
	assert.equal(harness.runtimeActions[1][0], 'begin_connect_apply', 'country drift marks connect apply pending after cache clear');
	assert.equal(harness.runtimeActions[2][0], 'start_connect', 'country drift follows with start_connect');
	assert.equal(harness.state.pendingOperationLabel, '', 'auto reconcile clears the pending label after completion');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'auto reconcile refreshes status after completion');
}

async function testAutoReconcileSkipsWhileSaveApplyInProgress() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			selected_country: 'AU',
			server_selection_mode: 'auto',
			current_server_country: 'BO',
			current_server_station: '45.134.189.1'
		}
	});

	harness.state.appliedCountryCode = 'AU';
	harness.state.currentLocalStatus = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		operation_status: 'idle',
		selected_country: 'AU',
		server_selection_mode: 'auto',
		current_server_country: 'BO',
		current_server_station: '45.134.189.1'
	};
	harness.state.saveApplyInProgress = true;
	harness.state.phase = 'saving';

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, harness.state.currentLocalStatus);

	assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'auto reconcile does not run during Save & Apply');

	harness.state.saveApplyInProgress = false;
	harness.state.phase = 'idle';
	harness.state.runtimeActionCooldownUntil = Date.now() + 60000;

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, harness.state.currentLocalStatus);

	assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'auto reconcile does not run during runtime action cooldown');
}

async function testAutoReconcileThrottlesSuccessfulNoChange() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
		convergedCountry: 'AU',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'AU',
			server_selection_mode: 'auto',
			current_server_country: 'BM',
			current_server_station: 'bm3'
		}
	});
	const driftStatus = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		operation_status: 'idle',
		operation_lock_state: 'none',
		selected_country: 'AU',
		server_selection_mode: 'auto',
		current_server_country: 'BM',
		current_server_station: 'bm3'
	};

	harness.state.appliedCountryCode = 'AU';
	harness.state.currentLocalStatus = driftStatus;

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, driftStatus);
	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, harness.state.currentLocalStatus);

	assert.ok(harness.runtimeActions.length >= 3, 'drift reconcile runs begin_connect_apply, stop_vpn, then start_connect once');
	assert.equal(harness.state.lastAutoReconcileFailureKey, '', 'status convergence clears the drift failure key');
	assert.equal(harness.runtimeActions.length, 3, 'second auto reconcile is skipped once drift is cleared');
}

async function testAutoReconcileSkipsNonDriftCases() {
	const cases = [
		{
			label: 'busy runtime',
			status: {
				desired_enabled: true,
				runtime_disabled: false,
				interface_disabled: false,
				runtime_configured: true,
				operation_status: 'busy:check',
				operation_lock_state: 'held',
				selected_country: 'AU',
				server_selection_mode: 'auto',
				current_server_country: 'BM',
				current_server_station: 'bm3'
			}
		},
		{
			label: 'disabled runtime',
			state: { appliedEnabled: false },
			status: {
				desired_enabled: false,
				runtime_disabled: true,
				interface_disabled: true,
				runtime_configured: true,
				operation_status: 'idle',
				selected_country: 'AU',
				server_selection_mode: 'auto',
				current_server_country: 'BM',
				current_server_station: 'bm3'
			}
		},
		{
			label: 'automatic country',
			status: {
				desired_enabled: true,
				runtime_disabled: false,
				interface_disabled: false,
				runtime_configured: true,
				operation_status: 'idle',
				selected_country: '',
				server_selection_mode: 'auto',
				current_server_country: 'BM',
				current_server_station: 'bm3'
			}
		},
		{
			label: 'aligned country',
			status: {
				desired_enabled: true,
				runtime_disabled: false,
				interface_disabled: false,
				runtime_configured: true,
				operation_status: 'idle',
				selected_country: 'AU',
				server_selection_mode: 'auto',
				current_server_country: 'AU',
				current_server_station: 'au123'
			}
		},
		{
			label: 'manual missing preference',
			status: {
				desired_enabled: true,
				runtime_disabled: false,
				interface_disabled: false,
				runtime_configured: true,
				operation_status: 'idle',
				selected_country: 'AU',
				server_selection_mode: 'manual',
				preferred_server_station: '',
				current_server_station: 'au123'
			}
		}
	];

	for (const testCase of cases) {
		const harness = buildHandleSaveApplyHarness({
			previousEnabled: true,
			savedCountry: 'AU',
			statusPayload: testCase.status,
			state: Object.assign({ appliedEnabled: true, appliedCountryCode: 'AU' }, testCase.state || {})
		});

		harness.state.currentLocalStatus = testCase.status;
		await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, testCase.status);
		assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'auto reconcile skips ' + testCase.label);
	}
}

async function testAutoReconcileThrottlesRepeatedFailures() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
		startConnectActionResult: {
			action: 'start_connect',
			code: 1,
			success: false,
			message: 'connect exploded'
		},
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'AU',
			server_selection_mode: 'auto',
			current_server_country: 'BM',
			current_server_station: 'bm3'
		}
	});
	const driftStatus = {
		desired_enabled: true,
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		operation_status: 'idle',
		operation_lock_state: 'none',
		selected_country: 'AU',
		server_selection_mode: 'auto',
		current_server_country: 'BM',
		current_server_station: 'bm3'
	};

	harness.state.appliedCountryCode = 'AU';
	harness.state.currentLocalStatus = driftStatus;

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, driftStatus);
	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, driftStatus);

	assert.ok(harness.runtimeActions.length >= 2, 'failed auto apply cycle still runs once');
	assert.match(harness.notifications[harness.notifications.length - 1].message, /Automatic runtime sync failed: connect exploded/, 'auto apply cycle failure is reported once');
	assert.equal(harness.notifications.length, 1, 'throttled auto reconcile does not repeat notifications');
	assert.equal(harness.state.lastAutoReconcileFailureKey, 'auto:AU:BM', 'throttle records the drift key');
}

function testDiagnosticsHasAlertHonorsPrimaryFinding() {
	const empty = managerData.emptyDiagnosticsSummary();

	assert.equal(managerData.diagnosticsHasAlert(empty), false, 'empty diagnostics summary has no alert');
	assert.equal(managerData.diagnosticsHasAlert({
		primary_finding: { code: 'none', message: '', action: '' }
	}), false, 'none primary finding has no alert');
	assert.equal(managerData.diagnosticsHasAlert({
		primary_finding: { code: 'runtime.no_handshake', message: 'x', action: 'y' }
	}), true, 'actionable primary finding triggers alert');
}

function testParseDiagnosticsSummaryNormalizesPayload() {
	const parsed = managerData.parseDiagnosticsSummary({
		generated_at: 42,
		primary_finding: { code: 'routing.blackhole_default_via_vpn', message: 'm', action: 'a' },
		findings: [
			{ code: 'runtime.no_handshake', message: 'hs', action: 'fix', severity: 'critical', priority: 80 }
		],
		status: { state: 'connected', connected: true },
		health: { wireguard_connected: false },
		connectivity: { routing_blackhole_risk: 'yes' },
		caches: { last_error: '' }
	});

	assert.equal(parsed.generated_at, 42, 'parseDiagnosticsSummary keeps generated_at');
	assert.equal(parsed.primary_finding.code, 'routing.blackhole_default_via_vpn', 'parseDiagnosticsSummary keeps primary code');
	assert.equal(parsed.findings.length, 1, 'parseDiagnosticsSummary normalizes findings array');
	assert.equal(parsed.findings[0].severity, 'critical', 'parseDiagnosticsSummary keeps finding severity');
	assert.equal(parsed.findings[0].priority, 80, 'parseDiagnosticsSummary keeps finding priority');
	assert.equal(parsed.connectivity.routing_blackhole_risk, 'yes', 'parseDiagnosticsSummary keeps connectivity block');
	assert.equal(parsed.status && parsed.status.state, 'connected', 'parseDiagnosticsSummary keeps status block');
	assert.equal(parsed.caches && parsed.caches.last_error, '', 'parseDiagnosticsSummary keeps caches block');
}

function testHideSelectionDriftDiagnosticsPicksMostUrgentRemaining() {
	const parsed = managerData.parseDiagnosticsSummary({
		generated_at: 99,
		primary_finding: {
			code: 'selection.drift',
			message: 'country drift',
			action: 'Run Save & Apply',
			severity: 'warning',
			priority: 150
		},
		findings: [
			{
				code: 'selection.drift',
				message: 'country drift',
				action: 'Run Save & Apply',
				severity: 'warning',
				priority: 150
			},
			{
				code: 'runtime.no_peers',
				message: 'WireGuard runtime has no peers',
				action: 'Run Setup',
				severity: 'critical',
				priority: 70
			},
			{
				code: 'config.interface_incomplete',
				message: 'wireguard interface is incomplete',
				action: 'Complete interface keys',
				severity: 'warning',
				priority: 100
			}
		]
	});
	const adjusted = managerData.hideSelectionDriftDiagnostics(parsed);

	assert.equal(adjusted.primary_finding.code, 'runtime.no_peers', 'hideSelectionDriftDiagnostics promotes lowest-priority remaining finding');
	assert.equal(adjusted.primary_finding.priority, 70, 'hideSelectionDriftDiagnostics keeps promoted finding priority');
	assert.equal(adjusted.findings.length, 2, 'hideSelectionDriftDiagnostics removes only selection.drift findings');
	assert.equal(adjusted.findings.some(function(finding) {
		return finding.code === 'selection.drift';
	}), false, 'hideSelectionDriftDiagnostics filters drift from findings list');
}

function testForcedCatalogRefreshUsesADistinctSlot() {
	const keys = [];
	const actions = loadManagerActionsModule({
		managerData: {
			normalizeCountryCode(v) { return String(v || '').trim().toUpperCase(); },
			runtimeStatusIsBusy() { return false; },
			parseServerCatalog() { return { servers: [], country_code: 'DE' }; },
			buildServerCatalogIndex() { return {}; },
			emptyServerCatalog() { return { servers: [] }; }
		},
		managerStore: {
			runExclusive(_state, key, factory) { keys.push(key); return Promise.resolve(factory && factory()); }
		},
		managerUI: {
			ids: { SERVER_FIELD_ID: 'srv' },
			getSelectElement() { return null; },
			renderServerChoices() {},
			updateServerSelectionState() {},
			getSelectedCountry() { return 'DE'; },
			getSelectedPreferredStation() { return ''; }
		},
		service: { execService() { return Promise.resolve({ code: 0, stdout: '{}' }); } }
	}).managerActions;
	const state = { latestServerCatalogRequestId: 0, currentLocalStatus: {}, currentServerCatalog: { servers: [] }, serverCatalogIndex: {} };

	// The exclusive key is captured synchronously when runExclusive is invoked.
	actions.loadServerCatalog(state, 'DE', false);
	actions.loadServerCatalog(state, 'DE', true);

	assert.deepEqual(keys, [ 'catalog:DE', 'catalog:force:DE' ],
		'a forced catalog refresh uses a distinct exclusive slot from a non-forced fetch');
}

function testManualApplyConvergenceRequiresStation() {
	const actions = loadManagerActionsModule({
		managerData: {
			normalizeCountryCode(v) { return String(v || '').trim().toUpperCase(); }
		}
	}).managerActions;

	const base = {
		current_server_country: 'IT',
		current_server_station: 'it100.nordvpn.com',
		connected: true,
		vpn_status: 'active',
		state: 'connected',
		handshake_age_seconds: 30
	};
	const manualSaved = { enabled: true, country: 'IT', mode: 'manual', preferredStation: 'it100.nordvpn.com' };

	assert.equal(actions.applyRuntimeConvergenceSucceeded(manualSaved, base, {}), true,
		'manual apply converges when the current station equals the preferred station');

	const otherStation = Object.assign({}, base, { current_server_station: 'it200.nordvpn.com' });
	assert.equal(actions.applyRuntimeConvergenceSucceeded(manualSaved, otherStation, {}), false,
		'manual apply does NOT converge while a same-country but different station is current');

	const autoSaved = { enabled: true, country: 'IT', mode: 'auto', preferredStation: '' };
	assert.equal(actions.applyRuntimeConvergenceSucceeded(autoSaved, otherStation, {}), true,
		'auto apply converges on country regardless of the current station');
}

function testCountryMatchTimingLogIsLabOptIn() {
	const posts = [];
	const localStorage = {
		enabled: false,
		getItem(key) {
			return key === 'nordvpnEasyTimingLog' && this.enabled ? '1' : null;
		}
	};
	const actions = loadManagerActionsModule({
		localStorage: localStorage,
		request: {
			post(url, payload, options) {
				posts.push({ url: url, payload: payload, options: options });
				return Promise.resolve({ ok: true });
			}
		}
	}).managerActions;

	actions.postCountryMatchLog({ indicator: 'mismatch', expected: 'SE', actual: 'DE' });
	assert.equal(posts.length, 0, 'Country Match transitions do not post to the timing CGI without the lab flag');

	localStorage.enabled = true;
	actions.postCountryMatchLog({ indicator: 'mismatch', expected: 'SE', actual: 'DE' });
	assert.equal(posts.length, 1, 'Country Match transitions post when the lab timing flag is enabled');
	assert.equal(posts[0].url, '/cgi-bin/nordvpn-easy-timing-log', 'Country Match timing log uses the lab CGI endpoint');
	assert.equal(posts[0].payload.event, 'country_match', 'Country Match timing log keeps the diagnostics event marker');
}

Promise.resolve().then(async function() {
	testCountryMatchTimingLogIsLabOptIn();
	testManualApplyConvergenceRequiresStation();
	testForcedCatalogRefreshUsesADistinctSlot();
	await testUpdateLocalStatusPreservesSnapshotOnFailedResponse();
	await testUpdateLocalStatusMarksSnapshotsStaleOnRejectedExec();
	testStatusResponseIsOutOfOrderOrdering();
	await testUpdateLocalStatusDiscardsOutOfOrderResponses();
	testRenderLocalStatusSnapshotClearsDisabledPlaceholders();
	testRenderLocalStatusSnapshotHonestDuringApply();
	await testPublicLookupsReturnEarlyWhenRuntimeDisabled();
	await testPublicIpPollUpdatesCountryFromSingleSnapshot();
	await testPublicIpChangeReplacesCountryFromSnapshot();
	testRenderLocalStatusSnapshotHandlesBusyOperation();
	testRenderLocalStatusSnapshotUsesHeldLockAction();
	await testStatusRpcFailureDoesNotRenderDisabled();
	testSaveApplyTransitionSuppressesConnectedAndDrift();
	await testHandleSaveApplyManualWithoutPreferredFallsBackToAuto();
	await testHandleSaveApplyFormCountryOverridesStaleDiskCountry();
	await testHandleSaveApplyFallsBackToAutomaticWhenManualSelectionIncomplete();
	await testHandleSaveApplyStopsAfterStopWhenDisabled();
	await testHandleSaveApplyTimesOutWhenPostSaveSyncNeverFinishes();
	await testHandleSaveApplyClearsBusyStateWhenPostApplySyncFails();
	await testHandleSaveApplyIgnoresLateApplyCycleAfterTimeout();
	await testHandleSaveApplyAutoModeClearsManualSelectionAndReconnects();
	await testHandleSaveApplyReconcilesDisabledRuntimeAfterSave();
	await testHandleSaveApplyQueuesReconnectWhenSavedCountryDriftsFromPeer();
	await testHandleSaveApplyConvergesWhenConnectApplyResultReportsSuccess();
	await testHandleSaveApplyConvergesViaStartConnectAndStatusPolling();
	await testHandleSaveApplyStartConnectBusyFailsImmediately();
	await testHandleSaveApplyStartConnectRuntimeErrorFromStatus();
	await testHandleSaveApplyRecoversAbortedRuntimeActionWhenStatusConverges();
	await testHandleSaveApplyDoesNotRecoverNonAbortRuntimeActionFailure();
	await testAutoReconcileRunsForCountryDrift();
	await testAutoReconcileSkipsWhileSaveApplyInProgress();
	await testAutoReconcileThrottlesSuccessfulNoChange();
	await testAutoReconcileSkipsNonDriftCases();
	await testAutoReconcileThrottlesRepeatedFailures();
	testDiagnosticsHasAlertHonorsPrimaryFinding();
	testParseDiagnosticsSummaryNormalizesPayload();
	testHideSelectionDriftDiagnosticsPicksMostUrgentRemaining();
	console.log('test-manager-actions.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
