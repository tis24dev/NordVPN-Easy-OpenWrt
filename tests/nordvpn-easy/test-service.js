#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const servicePath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'nordvpn-easy',
	'service.js'
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

function buildServiceModule(initialRpctimeout) {
	const source = fs.readFileSync(servicePath, 'utf8');
	const calls = [];
	const responses = [];
	const context = {
		baseclass: {
			extend(api) {
				return api;
			}
		},
		managerData: managerData,
		rpc: {
			declare(spec) {
				return function() {
					const args = Array.prototype.slice.call(arguments);
					const response = responses.length ? responses.shift() : {
						code: 0,
						success: true,
						stdout: JSON.stringify({ method: spec.method, args: args }),
						stderr: ''
					};

					calls.push({ spec: spec, args: args });
					if (response instanceof Error)
						return Promise.reject(response);

					return Promise.resolve(response);
				};
			}
		},
		ui: {
			addNotification() {}
		},
		_: function(message) {
			return new String(message);
		},
		E: function() {
			return null;
		},
		window: {
			URL: {
				createObjectURL() {
					return 'blob:test';
				},
				revokeObjectURL() {}
			}
		},
		document: {
			body: {
				appendChild() {},
				removeChild() {}
			}
		},
		Blob: function() {},
		Promise: Promise,
		L: {
			env: {
				rpctimeout: initialRpctimeout
			}
		}
	};

	const service = vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
		filename: servicePath
	});

	return {
		service: service,
		calls: calls,
		responses: responses,
		getRpctimeout() {
			return context.L.env.rpctimeout;
		},
		setRpctimeout(value) {
			context.L.env.rpctimeout = value;
		}
	};
}

function loadServiceModule(initialRpctimeout) {
	const built = buildServiceModule(initialRpctimeout == null ? 20 : initialRpctimeout);

	return {
		service: built.service,
		calls: built.calls,
		responses: built.responses,
		getRpctimeout: built.getRpctimeout,
		setRpctimeout: built.setRpctimeout
	};
}

Promise.resolve().then(async function() {
	const lowTimeout = loadServiceModule(20);
	lowTimeout.service.ensureLuCiRpcTimeout();
	assert.equal(lowTimeout.getRpctimeout(), 180, 'ensureLuCiRpcTimeout raises LuCI global RPC timeout');

	const highTimeout = loadServiceModule(240);
	highTimeout.service.ensureLuCiRpcTimeout();
	assert.equal(highTimeout.getRpctimeout(), 240, 'ensureLuCiRpcTimeout keeps larger existing timeouts');

	const loaded = loadServiceModule();
	const catalogResult = await loaded.service.execService('server_catalog', [ 'UY', '1' ]);
	const catalogCall = loaded.calls[loaded.calls.length - 1];
	const catalogPayload = JSON.parse(catalogResult.stdout);

	assert.equal(catalogResult.code, 0, 'server_catalog returns normalized success result');
	assert.equal(catalogCall.spec.object, 'nordvpn.easy', 'server_catalog uses nordvpn.easy ubus object');
	assert.equal(catalogCall.spec.method, 'server_catalog', 'server_catalog uses the dedicated ubus method');
	assert.deepEqual(catalogCall.args, [ 'UY', true ], 'server_catalog forwards country and force args');
	assert.deepEqual(catalogPayload.args, [ 'UY', true ], 'server_catalog preserves rpc payload in stdout');

	await assert.rejects(
		loaded.service.execService('refresh_servers'),
		/Unsupported NordVPN Easy action: refresh_servers/,
		'legacy refresh_servers alias is not exposed from the LuCI service client'
	);

	await assert.rejects(
		loaded.service.execService('disable_runtime'),
		/Unsupported NordVPN Easy action: disable_runtime/,
		'disable_runtime is not exposed from the LuCI service client'
	);

	const connectResult = await loaded.service.execService('connect');
	const connectCall = loaded.calls[loaded.calls.length - 1];
	assert.equal(connectResult.code, 0, 'connect returns normalized success result');
	assert.equal(connectCall.spec.method, 'connect', 'connect uses the dedicated ubus method');

	await assert.rejects(
		loaded.service.execService('reconcile'),
		/Unsupported NordVPN Easy action: reconcile/,
		'legacy reconcile is not exposed from the LuCI service client'
	);

	const diagnosticsResult = await loaded.service.execService('diagnostics_summary');
	const diagnosticsCall = loaded.calls[loaded.calls.length - 1];
	const diagnosticsPayload = JSON.parse(diagnosticsResult.stdout);

	assert.equal(diagnosticsResult.code, 0, 'diagnostics_summary returns normalized success result');
	assert.equal(diagnosticsCall.spec.object, 'nordvpn.easy', 'diagnostics_summary uses nordvpn.easy ubus object');
	assert.equal(diagnosticsCall.spec.method, 'diagnostics_summary', 'diagnostics_summary uses the dedicated ubus method');
	assert.deepEqual(diagnosticsCall.args, [], 'diagnostics_summary forwards no args');
	assert.deepEqual(diagnosticsPayload.args, [], 'diagnostics_summary preserves rpc payload in stdout');

	loaded.responses.push({
		code: 75,
		success: false,
		busy: true,
		skipped: true,
		reason: 'operation_busy',
		holder_action: 'setup',
		holder_pid: '1234',
		holder_age_seconds: 9,
		stdout: '',
		stderr: 'operation busy'
	});
	const busyResult = await loaded.service.runAction('check');
	const busyError = loaded.service.resultToError(busyResult);

	assert.equal(busyResult.success, false, 'busy result is not a successful action');
	assert.equal(busyResult.busy, true, 'busy result preserves busy flag');
	assert.equal(busyResult.skipped, true, 'busy result preserves skipped flag');
	assert.equal(busyResult.holder_action, 'setup', 'busy result preserves lock holder action');
	assert.match(busyError.message, /already running setup/, 'busy result renders an operation-in-progress error');

	const missingRpc = loadServiceModule();
	missingRpc.responses.push(
		new Error('RPC call to nordvpn.easy/refresh_countries failed with error -32000: Object not found')
	);
	await assert.rejects(
		missingRpc.service.execService('refresh_countries_force'),
		/backend RPC object is not registered/,
		'missing rpcd object renders an actionable backend registration error'
	);

	await assert.rejects(
		loaded.service.execService('unsupported_action'),
		/Unsupported NordVPN Easy action/,
		'unsupported service actions still reject explicitly'
	);

	console.log('test-service.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
