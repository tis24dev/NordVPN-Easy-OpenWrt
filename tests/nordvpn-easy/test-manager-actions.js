#!/usr/bin/env node

'use strict';

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
		managerUI: {},
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

const managerActions = loadManagerActionsModule().managerActions;
const managerData = loadManagerDataModule();

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

assert.equal(typeof managerActions.hasServerSelectionChanged, 'function', 'hasServerSelectionChanged is exported');
assert.equal(typeof managerActions.deriveRuntimeActionPlan, 'function', 'deriveRuntimeActionPlan is exported');
assert.equal(typeof managerActions.renderLocalStatusSnapshot, 'function', 'renderLocalStatusSnapshot is exported');
assert.equal(managerData.parseEnabledFlag(undefined), false, 'missing enabled option is treated as disabled');
assert.equal(managerData.parseEnabledFlag('0'), false, 'explicit disabled value is treated as disabled');
assert.equal(managerData.parseEnabledFlag('1'), true, 'explicit enabled value is treated as enabled');

assert.equal(
	managerActions.hasServerSelectionChanged('AT', 'UY', 'auto', 'auto', '', ''),
	true,
	'country change is detected as server-selection change'
);

assert.equal(
	managerActions.hasServerSelectionChanged('AT', 'AT', 'auto', 'manual', '', 'us123'),
	true,
	'mode change is detected as server-selection change'
);

assert.equal(
	managerActions.hasServerSelectionChanged('UY', 'UY', 'manual', 'manual', 'uy123', 'uy456'),
	true,
	'manual preferred server change is detected as server-selection change'
);

assert.equal(
	managerActions.hasServerSelectionChanged('UY', 'UY', 'auto', 'auto', 'uy123', 'uy456'),
	false,
	'preferred server changes outside manual mode do not trigger restart logic'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(false, true, '', 'UY', 'auto', 'auto', '', '', healthyRuntime)),
	{
		actions: [ 'connect' ],
		successMessage: 'NordVPN Easy enabled: setup completed and hooks installed.',
		serverSelectionChanged: true
	},
	'disabled to enabled uses transactional connect'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, false, 'AT', 'AT', 'auto', 'auto', '', '', healthyRuntime)),
	{
		actions: [ 'disconnect' ],
		successMessage: 'NordVPN Easy disabled: VPN interface stopped and hooks removed.',
		serverSelectionChanged: false
	},
	'enabled to disabled uses transactional disconnect'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'AT', 'UY', 'auto', 'auto', '', '', healthyRuntime)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy restarted and synchronized the automatic server selection.',
		serverSelectionChanged: true
	},
	'enabled country changes use transactional reconnect'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'manual', '', 'uy123', healthyRuntime)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy restarted and synchronized the selected manual server.',
		serverSelectionChanged: true
	},
	'enabled mode changes use transactional reconnect'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'manual', 'manual', 'uy123', 'uy456', healthyRuntime)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy restarted and synchronized the selected manual server.',
		serverSelectionChanged: true
	},
	'enabled manual preferred server changes use transactional reconnect'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', healthyRuntime)),
	{
		actions: [],
		successMessage: '',
		serverSelectionChanged: false
	},
	'no runtime-relevant change produces no runtime actions'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', disabledRuntime)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'disabled runtime with unchanged config is reconciled'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', missingRuntime)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'missing runtime with unchanged config is reconciled'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', unknownRuntime)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'unknown runtime snapshot with unchanged config is reconciled'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', null)),
	{
		actions: [ 'reconnect' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'null runtime snapshot with unchanged config is reconciled'
);

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
		currentPublicCountryIp: '',
		cachedPublicIp: '',
		cachedPublicCountry: '',
		cachedPublicCountryIp: '',
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

async function testUpdateLocalStatusDoesNotClobberLivePublicLookupWithCache() {
	const replacements = {};
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
			replaceStatusText(id, value) {
				replacements[id] = value;
			},
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
		service: {
			parseExecJsonResponse(res, fallback) {
				if (!res || res.code !== 0)
					return fallback;

				return JSON.parse(res.stdout || '');
			},
			execService() {
				return Promise.resolve({
					code: 0,
					stdout: JSON.stringify({
						desired_enabled: true,
						operation_status: 'idle',
						runtime_disabled: false,
						interface_disabled: false,
						public_ip_cached: '198.51.100.10',
						public_country_cached: 'US'
					}),
					stderr: ''
				});
			}
		},
		_: function(message) {
			return {
				format: function() {
					let index = 0;
					const args = arguments;

					return String(message).replace(/%[sd]/g, function() {
						return String(args[index++]);
					});
				},
				toString: function() {
					return String(message);
				},
				valueOf: function() {
					return String(message);
				}
			};
		}
	}).managerActions;
	const state = buildUpdateLocalStatusState();

	state.currentPublicIp = '203.0.113.20';
	state.currentPublicCountry = 'IT';
	state.currentPublicCountryIp = '203.0.113.20';

	await actions.updateLocalStatus(state);

	assert.equal(state.currentPublicIp, '203.0.113.20', 'cached status does not replace fresher live public IP');
	assert.equal(state.currentPublicCountry, 'IT', 'cached status does not replace fresher live public country');
	assert.equal(state.currentPublicCountryIp, '203.0.113.20', 'cached status does not replace fresher live country IP binding');
	assert.equal(state.cachedPublicIp, '198.51.100.10', 'cached public IP is retained separately');
	assert.equal(state.cachedPublicCountry, 'US', 'cached public country is retained separately');
	assert.equal(replacements.public_ip, '203.0.113.20', 'public IP display prefers live value over cached status');
	assert.equal(replacements.public_country, 'IT', 'public country display prefers live value over cached status');
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
		currentPublicCountry: 'IT',
		currentPublicCountryIp: '203.0.113.20',
		cachedPublicIp: '',
		cachedPublicCountry: '',
		cachedPublicCountryIp: ''
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
	assert.equal(state.cachedPublicIp, '198.51.100.10', 'cached public IP is retained separately for later enabled states');
	assert.equal(state.cachedPublicCountry, 'US', 'cached public country is retained separately for later enabled states');
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
		currentPublicCountry: 'IT',
		currentPublicCountryIp: '203.0.113.20'
	};

	await actions.updatePublicIp(state, { force: true });
	await actions.updatePublicCountry(state, { force: true, expectedPublicIp: '203.0.113.20' });

	assert.deepEqual(networkCalls, [], 'disabled public lookups do not invoke service exec');
	assert.deepEqual(lockCalls, [], 'disabled public lookups return before acquiring operation locks');
	assert.equal(replacements.public_ip, 'Unavailable', 'disabled public IP lookup renders unavailable');
	assert.equal(replacements.public_country, 'Unavailable', 'disabled public country lookup renders unavailable');
	assert.equal(state.currentPublicIp, '', 'disabled public IP lookup clears live IP state');
	assert.equal(state.currentPublicCountry, '', 'disabled public country lookup clears live country state');
	assert.equal(state.currentPublicCountryIp, '', 'disabled public country lookup clears live country binding');
	assert.equal(countryMatchUpdates, 2, 'disabled public lookups refresh country-match status without network calls');
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
		currentPublicCountry: '',
		currentPublicCountryIp: '',
		cachedPublicIp: '',
		cachedPublicCountry: '',
		cachedPublicCountryIp: ''
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

Promise.resolve().then(async function() {
	await testUpdateLocalStatusMarksSnapshotsStaleOnFailedResponse();
	await testUpdateLocalStatusMarksSnapshotsStaleOnRejectedExec();
	await testUpdateLocalStatusDoesNotClobberLivePublicLookupWithCache();
	testRenderLocalStatusSnapshotClearsDisabledPlaceholders();
	await testPublicLookupsReturnEarlyWhenRuntimeDisabled();
	testRenderLocalStatusSnapshotHandlesBusyOperation();
	console.log('test-manager-actions.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
