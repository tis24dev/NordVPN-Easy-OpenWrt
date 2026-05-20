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
			formatActionsLabel(actions) {
				return actions.join(' + ');
			},
			humanizeAction(action) {
				return String(action || '');
			}
		},
		managerStore: {
			PHASES: {},
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

const healthyRuntime = {
	interface: 'wg0',
	runtime_disabled: false,
	interface_disabled: false,
	runtime_configured: true
};

const disabledRuntime = {
	interface: 'wg0',
	runtime_disabled: true,
	interface_disabled: true,
	runtime_configured: true
};

const missingRuntime = {
	interface: 'wg0',
	runtime_disabled: false,
	interface_disabled: false,
	runtime_configured: false
};

const unknownRuntime = {};

assert.equal(typeof managerActions.normalizeSubmittedConfig, 'function', 'normalizeSubmittedConfig is exported');
assert.equal(typeof managerActions.runApplyCycle, 'function', 'runApplyCycle is exported');
assert.equal(typeof managerActions.deriveServerSelectionDrift, 'function', 'deriveServerSelectionDrift is exported');
assert.equal(typeof managerActions.maybeAutoReconcileSelectionDrift, 'function', 'maybeAutoReconcileSelectionDrift is exported');
assert.equal(typeof managerActions.mergeSavedConfigWithSubmittedValues, 'function', 'mergeSavedConfigWithSubmittedValues is exported');
assert.equal(typeof managerActions.syncSubmittedRuntimeConfigToUci, 'function', 'syncSubmittedRuntimeConfigToUci is exported');
assert.equal(typeof managerActions.renderLocalStatusSnapshot, 'function', 'renderLocalStatusSnapshot is exported');

{
	const merged = managerActions.mergeSavedConfigWithSubmittedValues({
		enabled: true,
		country: 'IE',
		mode: 'auto',
		preferredStation: ''
	}, {
		country: 'NG',
		mode: 'auto',
		enabled: true,
		preferredStation: ''
	});

	assert.equal(merged.country, 'NG', 'form country overrides stale disk country in saved runtime config');
	assert.equal(merged.mode, 'auto', 'form mode is preserved in merged saved runtime config');
	assert.equal(merged.enabled, true, 'form enabled flag is preserved in merged saved runtime config');
}

assert.deepEqual(
	normalizeValue(managerActions.normalizeSubmittedConfig({
		country: 'UY',
		mode: 'manual',
		enabled: true,
		preferredStation: 'uy123'
	})),
	{
		country: 'UY',
		mode: 'manual',
		enabled: true,
		preferredStation: 'uy123'
	},
	'manual config with country and server is preserved'
);

assert.deepEqual(
	normalizeValue(managerActions.normalizeSubmittedConfig({
		country: '',
		mode: 'manual',
		enabled: true,
		preferredStation: 'uy123'
	})),
	{
		country: '',
		mode: 'auto',
		enabled: true,
		preferredStation: ''
	},
	'incomplete manual selection falls back to automatic mode'
);

assert.deepEqual(
	normalizeValue(managerActions.normalizeSubmittedConfig({
		country: 'UY',
		mode: 'manual',
		enabled: true,
		preferredStation: ''
	})),
	{
		country: 'UY',
		mode: 'auto',
		enabled: true,
		preferredStation: ''
	},
	'manual mode without preferred server falls back to automatic mode'
);

assert.equal(managerData.parseEnabledFlag(undefined), false, 'missing enabled option is treated as disabled');
assert.equal(managerData.parseEnabledFlag('0'), false, 'explicit disabled value is treated as disabled');
assert.equal(managerData.parseEnabledFlag('1'), true, 'explicit enabled value is treated as enabled');

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

async function testUpdateLocalStatusMarksSnapshotsStaleOnFailedResponse() {
	const actions = buildUpdateLocalStatusHarness({
		execService() {
			return Promise.resolve({ code: 1, stdout: '', stderr: 'status_json failed' });
		}
	});
	const state = buildUpdateLocalStatusState();
	const status = await actions.updateLocalStatus(state);

	assert.deepEqual(normalizeValue(status), {}, 'failed status_json responses fall back to empty runtime status');
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
	assert.deepEqual(indicators.vpn, { state: 'starting', label: 'Activating' }, 'busy status renders an activating VPN indicator');
	assert.equal(countryMatchUpdates, 1, 'busy status updates country-match indicator once');
	assert.equal(serverSelectionUpdates, 1, 'busy status updates server-selection controls once');
}

function testSaveApplyTransitionSuppressesConnectedAndDrift() {
	const diagnosticsBanners = [];
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
			replaceStatusText(id, value) {},
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
		currentOperationStatus: 'busy:configuration',
		pendingOperationLabel: 'configuration',
		saveApplyInProgress: true,
		phase: 'saving',
		currentDiagnosticsSummary: driftSummary
	};

	actions.renderLocalStatusSnapshot(state, status);
	actions.renderDiagnosticsSnapshot(state, driftSummary, true);

	assert.deepEqual(
		diagnosticsBanners.vpn,
		{ state: 'stopping', label: 'Applying changes' },
		'Save & Apply transition shows interrupted connection instead of connected'
	);
	assert.equal(
		diagnosticsBanners.summaryHidden,
		true,
		'drift banner stays hidden until Save & Apply finishes'
	);
	assert.equal(
		actions.driftEvaluationAllowed(state),
		false,
		'drift evaluation is disabled during Save & Apply'
	);

	state.saveApplyInProgress = false;
	state.pendingOperationLabel = '';
	state.phase = 'idle';

	assert.equal(
		actions.driftEvaluationAllowed(state),
		true,
		'drift evaluation resumes after Save & Apply completes'
	);
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
		vpn_country: (opts.savedCountry != null) ? opts.savedCountry : 'UY',
		server_selection_mode: opts.savedMode || 'auto',
		preferred_server_station: opts.savedPreferredStation || '',
		nordvpn_token: opts.savedToken || 'saved-token'
	}, opts.uciValues || {});
	const uciSets = [];
	const notifications = [];
	const confirmations = [];
	const runtimeActions = [];
	const serviceCalls = [];
	const phaseTransitions = [];
	const pollingTransitions = [];
	const debugNotifications = [];
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

	const actions = loadManagerActionsModule({
		managerData: {
			normalizeCountryCode(value) {
				return String(value || '').trim().toUpperCase();
			},
			parseEnabledFlag(value) {
				return [ '1', 'true', 'yes', 'on' ].indexOf(String(value != null ? value : '0').trim().toLowerCase()) !== -1;
			},
			parseLocalStatus(raw) {
				return JSON.parse(raw || '{}');
			}
		},
		managerFormat: {
			formatServerLabel(server) {
				return [ server.country_code, server.city, server.hostname, server.load + '%' ].filter(Boolean).join(' - ');
			},
			formatActionsLabel(actions) {
				return actions.join(' + ');
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
			suspendPolling(state) {
				pollingTransitions.push('suspend');
				state.pollingSuspended = true;
			},
			resumePolling(state) {
				pollingTransitions.push('resume');
				state.pollingSuspended = false;
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
			showConfirmationModal(title, lines) {
				confirmations.push({
					title: String(title),
					lines: lines.map(String)
				});
				return Promise.resolve(opts.confirmed !== false);
			},
			replaceStatusText() {},
			setManagerControlsDisabled() {},
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
						stdout: JSON.stringify(opts.statusPayload || {
							desired_enabled: true,
							runtime_disabled: false,
							interface_disabled: false,
							runtime_configured: true,
							operation_status: 'idle',
							selected_country: uciValues.vpn_country || 'UY',
							server_selection_mode: uciValues.server_selection_mode || 'auto',
							preferred_server_station: uciValues.preferred_server_station || ''
						}),
						stderr: ''
					});
				}

				if (action === 'public_ip')
					return Promise.resolve({ code: 1, stdout: '', stderr: '' });

				return Promise.resolve({ code: 0, stdout: '', stderr: '' });
			},
			runAction(action) {
				runtimeActions.push([ action ]);

				if (opts.runActionsReject && action === 'connect')
					return Promise.reject(opts.runActionsReject);

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
			runActions(actions) {
				runtimeActions.push(actions.slice());
				return opts.runActionsReject
					? Promise.reject(opts.runActionsReject)
					: Promise.resolve({ success: true });
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
		confirmations: confirmations,
		runtimeActions: runtimeActions,
		serviceCalls: serviceCalls,
		phaseTransitions: phaseTransitions,
		pollingTransitions: pollingTransitions,
		debugNotifications: debugNotifications,
		calls: calls
	};
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
			server_selection_mode: 'auto',
			preferred_server_hostname: '',
			preferred_server_station: ''
		}
	});

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1');
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
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'connect' ] ], 'incomplete manual selection still runs the unified apply cycle');
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1');
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1').catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(harness.calls.handleSave, 1, 'enable flow saves the form once');
	assert.equal(harness.calls.apply, 0, 'save flow does not use the legacy LuCI apply path');
	assert.equal(rejected && rejected.message, 'uci reload failed', 'post-save sync failure rejects with the original error');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ] ], 'post-save sync failure keeps the initial cleanup stop');
	assert.equal(harness.state.pendingOperationLabel, '', 'post-save sync failure clears pending state');
	assert.equal(harness.pollingTransitions[harness.pollingTransitions.length - 1], 'resume', 'post-save sync failure resumes polling');
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1').catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(rejected, syncError, 'post-apply sync failure rejects with the original error');
	assert.equal(harness.state.pendingOperationLabel, '', 'post-apply sync failure clears the applying label');
	assert.equal(harness.pollingTransitions[harness.pollingTransitions.length - 1], 'resume', 'post-apply sync failure resumes polling');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'post-apply sync failure refreshes local status');
	assert.ok(harness.serviceCalls.indexOf('public_ip') !== -1, 'post-apply sync failure refreshes public IP state');
	assert.match(harness.notifications[harness.notifications.length - 1].message, /Save & Apply failed: uci reload failed/, 'post-apply sync failure reports a readable notification');
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1');
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
	assert.equal(harness.confirmations.length, 0, 'unified apply flow does not ask for runtime confirmation');
	assert.equal(harness.calls.handleSave, 1, 'manual-to-auto changes save the form once');
	assert.equal(harness.calls.apply, 0, 'manual-to-auto changes do not use the legacy LuCI apply path');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'connect' ] ], 'manual-to-auto changes run stop then connect');
	assert.equal(harness.viewState.initialMode, 'auto', 'view state tracks saved automatic mode');
	assert.equal(harness.viewState.initialPreferredStation, '', 'view state clears saved preferred station');
	assert.equal(harness.state.pendingOperationLabel, '', 'runtime action completion clears pending operation label');
	assert.equal(harness.pollingTransitions[0], 'suspend', 'save/apply suspends polling while committing');
	assert.equal(harness.pollingTransitions[harness.pollingTransitions.length - 1], 'resume', 'save/apply resumes polling after runtime handling');
	assert.ok(harness.phaseTransitions.indexOf('saving') !== -1, 'save/apply enters saving phase');
	assert.ok(harness.phaseTransitions.indexOf('runtime_busy') !== -1, 'runtime reconnect enters runtime-busy phase');
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1');
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'connect' ] ], 'unchanged enabled config cleanly reconnects a disabled runtime after Save & Apply');
	assert.equal(harness.state.pendingOperationLabel, '', 'reconnect completion clears pending operation label');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'reconnect flow refreshes status before choosing runtime action');
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1');
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(
		normalizeValue(harness.runtimeActions),
		[ [ 'stop_vpn' ], [ 'connect' ], [ 'stop_vpn' ], [ 'connect' ] ],
		'peer drift after Save & Apply reruns one clean stop/connect cycle'
	);
}

async function testHandleSaveApplyRecoversAbortedRuntimeActionWhenStatusConverges() {
	const abortError = new Error('connect failed with exit code -1: XHR request aborted by browser');
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		runActionsReject: abortError,
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1');
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'connect' ] ],
		'aborted runtime XHR still runs stop then connect');
	assert.equal(harness.state.pendingOperationLabel, '', 'aborted runtime recovery clears pending operation label');
	assert.equal(harness.pollingTransitions[harness.pollingTransitions.length - 1], 'resume', 'aborted runtime recovery resumes polling');
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
	const runError = new Error('connect failed with exit code 1: backend failed');
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		previousCountry: 'AT',
		currentEnabled: true,
		currentMode: 'auto',
		currentCountry: 'UY',
		savedCountry: 'UY',
		runActionsReject: runError,
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

	await harness.actions.handleSaveApply(harness.viewState, harness.state, {}, '1').catch(function(err) {
		rejected = err;
	});
	await Promise.resolve();
	await Promise.resolve();

	assert.equal(rejected, runError, 'non-abort runtime failure rejects with the original error');
	assert.deepEqual(normalizeValue(harness.runtimeActions), [ [ 'stop_vpn' ], [ 'connect' ] ],
		'non-abort runtime failure still attempted stop then connect');
	assert.ok(harness.notifications.some(function(entry) {
		return entry.type === 'error' && /backend failed/.test(entry.message);
	}), 'non-abort runtime failure still reports an error notification');
}

async function testAutoReconcileRunsForCountryDrift() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
		statusPayload: {
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			operation_status: 'idle',
			operation_lock_state: 'none',
			selected_country: 'AU',
			server_selection_mode: 'auto',
			current_server_country: 'AU',
			current_server_station: 'au123'
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

	assert.ok(harness.runtimeActions.length >= 2, 'country drift runs at least stop then connect');
	assert.equal(harness.runtimeActions[0][0], 'stop_vpn', 'country drift starts with stop_vpn');
	assert.equal(harness.runtimeActions[1][0], 'connect', 'country drift follows with connect');
	assert.equal(harness.state.pendingOperationLabel, '', 'auto reconcile clears the pending label after completion');
	assert.ok(harness.phaseTransitions.indexOf('runtime_busy') !== -1, 'auto reconcile enters runtime-busy phase');
	assert.ok(harness.serviceCalls.indexOf('status_json') !== -1, 'auto reconcile refreshes status after completion');
	assert.ok(harness.serviceCalls.indexOf('public_ip') !== -1, 'auto reconcile refreshes public IP after completion');
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
	const driftStatus = {
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

	harness.state.appliedCountryCode = 'AU';
	harness.state.currentLocalStatus = driftStatus;
	harness.state.saveApplyInProgress = true;
	harness.state.phase = 'saving';

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, driftStatus);

	assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'auto reconcile does not run during Save & Apply');

	harness.state.saveApplyInProgress = false;
	harness.state.phase = 'idle';
	harness.state.runtimeActionCooldownUntil = Date.now() + 60000;

	await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, driftStatus);

	assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'auto reconcile does not run during runtime action cooldown');
}

async function testAutoReconcileThrottlesSuccessfulNoChange() {
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
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

	assert.ok(harness.runtimeActions.length >= 2, 'successful reconnect that leaves the same drift still runs the apply cycle');
	assert.equal(harness.state.lastAutoReconcileFailureKey, 'auto:AU:BM', 'unchanged success records the drift key');
	assert.match(harness.notifications[harness.notifications.length - 1].message, /still out of sync/, 'unchanged success reports a readable sync error');
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
			state: Object.assign({ appliedEnabled: true, appliedCountryCode: 'AU' }, testCase.state || {})
		});

		harness.state.currentLocalStatus = testCase.status;
		await harness.actions.maybeAutoReconcileSelectionDrift(harness.state, testCase.status);
		assert.deepEqual(normalizeValue(harness.runtimeActions), [], 'auto reconcile skips ' + testCase.label);
	}
}

async function testAutoReconcileThrottlesRepeatedFailures() {
	const runError = new Error('reconnect exploded');
	const harness = buildHandleSaveApplyHarness({
		previousEnabled: true,
		savedCountry: 'AU',
		runActionsReject: runError,
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

	assert.ok(harness.runtimeActions.length >= 2, 'failed auto reconnect still runs the apply cycle once');
	assert.match(harness.notifications[harness.notifications.length - 1].message, /Automatic runtime sync failed: reconnect exploded/, 'auto reconnect failure is reported once');
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

Promise.resolve().then(async function() {
	await testUpdateLocalStatusMarksSnapshotsStaleOnFailedResponse();
	await testUpdateLocalStatusMarksSnapshotsStaleOnRejectedExec();
	testRenderLocalStatusSnapshotClearsDisabledPlaceholders();
	await testPublicLookupsReturnEarlyWhenRuntimeDisabled();
	await testPublicIpPollUpdatesCountryFromSingleSnapshot();
	await testPublicIpChangeReplacesCountryFromSnapshot();
	testRenderLocalStatusSnapshotHandlesBusyOperation();
	testSaveApplyTransitionSuppressesConnectedAndDrift();
	await testHandleSaveApplyFallsBackToAutomaticWhenManualSelectionIncomplete();
	await testHandleSaveApplyStopsAfterStopWhenDisabled();
	await testHandleSaveApplyTimesOutWhenPostSaveSyncNeverFinishes();
	await testHandleSaveApplyClearsBusyStateWhenPostApplySyncFails();
	await testHandleSaveApplyAutoModeClearsManualSelectionAndReconnects();
	await testHandleSaveApplyReconcilesDisabledRuntimeAfterSave();
	await testHandleSaveApplyQueuesReconnectWhenSavedCountryDriftsFromPeer();
	await testHandleSaveApplyRecoversAbortedRuntimeActionWhenStatusConverges();
	await testHandleSaveApplyDoesNotRecoverNonAbortRuntimeActionFailure();
	await testAutoReconcileRunsForCountryDrift();
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
