#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const managerPollingPath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'nordvpn-easy',
	'manager-polling.js'
);

function loadManagerPollingModule(overrides) {
	const source = fs.readFileSync(managerPollingPath, 'utf8');
	const pollers = [];
	const calls = [];
	const context = {
		baseclass: {
			extend(api) {
				return api;
			}
		},
		managerActions: {
			runtimeOperationIsBusy() {
				return false;
			},
			updateLocalStatus(_state, options) {
				calls.push(options && options.force ? 'status:force' : 'status');
				return Promise.resolve();
			},
			updatePublicIp() {
				calls.push('public_ip');
				return Promise.resolve();
			},
			updateDiagnosticsSummary() {
				calls.push('diagnostics');
				return Promise.resolve();
			}
		},
		managerStore: {
			PHASES: {
				SAVING: 'saving'
			}
		},
		poll: {
			add(fn, interval) {
				pollers.push({ fn: fn, interval: interval });
			}
		},
		document: {
			hidden: false
		},
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
		managerPolling: vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
			filename: managerPollingPath
		}),
		pollers: pollers,
		calls: calls
	};
}

Promise.resolve().then(async function() {
	const harness = loadManagerPollingModule();
	const state = {
		pollersStarted: false,
		pollingSuspended: false,
		phase: 'idle',
		appliedEnabled: true,
		currentLocalStatus: {}
	};

	harness.managerPolling.start(state);

	assert.equal(harness.managerPolling.LOCAL_STATUS_POLL_SECONDS, 3,
		'local status poll interval is exported as 3 seconds');
	assert.equal(harness.managerPolling.PUBLIC_IP_POLL_SECONDS, 5,
		'public IP poll interval is exported as 5 seconds');
	assert.deepEqual(harness.pollers.map(function(entry) {
		return entry.interval;
	}), [ 3, 5, 120 ], 'manager pollers use status/public-ip/diagnostics intervals');

	await harness.pollers[0].fn();
	assert.deepEqual(harness.calls, [ 'status' ], 'first poller refreshes local status');

	state.pollingSuspended = true;
	state.saveApplyInProgress = true;
	await harness.pollers[0].fn();
	assert.deepEqual(harness.calls, [ 'status', 'status' ],
		'local status keeps refreshing during Save & Apply even when other polls are suspended');
	state.saveApplyInProgress = false;
	state.pollingSuspended = false;

	harness.managerPolling.start(state);
	assert.equal(harness.pollers.length, 3, 'start is idempotent');

	console.log('test-manager-polling.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
