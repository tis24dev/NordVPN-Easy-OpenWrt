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
		managerActions: vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
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

assert.equal(typeof managerActions.hasServerSelectionChanged, 'function', 'hasServerSelectionChanged is exported');
assert.equal(typeof managerActions.deriveRuntimeActionPlan, 'function', 'deriveRuntimeActionPlan is exported');

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
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy enabled: setup completed and hooks installed.',
		serverSelectionChanged: true
	},
	'disabled to enabled keeps the existing setup flow'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, false, 'AT', 'AT', 'auto', 'auto', '', '', healthyRuntime)),
	{
		actions: [ 'disable_runtime' ],
		successMessage: 'NordVPN Easy disabled: VPN interface stopped and hooks removed.',
		serverSelectionChanged: false
	},
	'enabled to disabled keeps the disable flow'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'AT', 'UY', 'auto', 'auto', '', '', healthyRuntime)),
	{
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy restarted and synchronized the automatic server selection.',
		serverSelectionChanged: true
	},
	'enabled country changes use the clean restart flow'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'manual', '', 'uy123', healthyRuntime)),
	{
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy restarted and synchronized the selected manual server.',
		serverSelectionChanged: true
	},
	'enabled mode changes use the clean restart flow'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'manual', 'manual', 'uy123', 'uy456', healthyRuntime)),
	{
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy restarted and synchronized the selected manual server.',
		serverSelectionChanged: true
	},
	'enabled manual preferred server changes use the clean restart flow'
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
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'disabled runtime with unchanged config is reconciled'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', missingRuntime)),
	{
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'missing runtime with unchanged config is reconciled'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', unknownRuntime)),
	{
		actions: [ 'setup', 'install_hooks' ],
		successMessage: 'NordVPN Easy runtime synchronized with the saved configuration.',
		serverSelectionChanged: false
	},
	'unknown runtime snapshot with unchanged config is reconciled'
);

assert.deepEqual(
	normalizeValue(managerActions.deriveRuntimeActionPlan(true, true, 'UY', 'UY', 'auto', 'auto', '', '', null)),
	{
		actions: [ 'setup', 'install_hooks' ],
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
				OPERATION_STATUS_ID: 'operation'
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

Promise.resolve().then(async function() {
	await testUpdateLocalStatusMarksSnapshotsStaleOnFailedResponse();
	await testUpdateLocalStatusMarksSnapshotsStaleOnRejectedExec();
	console.log('test-manager-actions.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
