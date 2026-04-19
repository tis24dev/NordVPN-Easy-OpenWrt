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

function loadManagerActionsModule() {
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

	return vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
		filename: managerActionsPath
	});
}

const managerActions = loadManagerActionsModule();

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

console.log('test-manager-actions.js: ok');
