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
	const declares = [];
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
				declares.push(spec);
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
		declares: declares,
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
		declares: built.declares,
		responses: built.responses,
		getRpctimeout: built.getRpctimeout,
		setRpctimeout: built.setRpctimeout
	};
}

function testAclGrantsEveryDeclaredMethod() {
	const built = loadServiceModule();
	const declaredMethods = built.declares
		.filter(function(spec) { return spec && spec.object === 'nordvpn.easy'; })
		.map(function(spec) { return spec.method; });

	assert.ok(declaredMethods.length > 0, 'service.js declares at least one nordvpn.easy method');

	const aclPath = path.join(__dirname, '..', '..', 'openwrt-packages', 'luci-app-nordvpn-easy', 'root', 'usr', 'share', 'rpcd', 'acl.d', 'luci-app-nordvpn-easy.json');
	const acl = JSON.parse(fs.readFileSync(aclPath, 'utf8'));
	const grant = acl['luci-app-nordvpn-easy'] || {};
	const grantedUbus = function(scope) {
		return (grant[scope] && grant[scope].ubus && grant[scope].ubus['nordvpn.easy']) || [];
	};
	const granted = grantedUbus('read').concat(grantedUbus('write'));

	const missing = declaredMethods.filter(function(method) { return granted.indexOf(method) === -1; });
	assert.deepEqual(missing, [], 'every nordvpn.easy method the frontend declares must be granted by the rpcd ACL (missing: ' + JSON.stringify(missing) + ')');
}

Promise.resolve().then(async function() {
	testAclGrantsEveryDeclaredMethod();
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

	const startConnectResult = await loaded.service.execService('start_connect');
	const startConnectCall = loaded.calls[loaded.calls.length - 1];
	assert.equal(startConnectResult.code, 0, 'start_connect returns normalized success result');
	assert.equal(startConnectCall.spec.method, 'start_connect', 'start_connect uses the dedicated ubus method');
	assert.equal(startConnectCall.spec.timeout, 15, 'start_connect uses a short rpc timeout');

	const beginApplyResult = await loaded.service.execService('begin_connect_apply');
	const beginApplyCall = loaded.calls[loaded.calls.length - 1];
	assert.equal(beginApplyResult.code, 0, 'begin_connect_apply returns normalized success result');
	assert.equal(beginApplyCall.spec.method, 'begin_connect_apply', 'begin_connect_apply uses the dedicated ubus method');
	assert.equal(beginApplyCall.spec.timeout, 15, 'begin_connect_apply uses a short rpc timeout');

	const abortApplyResult = await loaded.service.execService('abort_connect_apply');
	const abortApplyCall = loaded.calls[loaded.calls.length - 1];
	assert.equal(abortApplyResult.code, 0, 'abort_connect_apply returns normalized success result');
	assert.equal(abortApplyCall.spec.method, 'abort_connect_apply', 'abort_connect_apply uses the dedicated ubus method');
	assert.equal(abortApplyCall.spec.timeout, 15, 'abort_connect_apply uses a short rpc timeout');

	const reconcileResult = await loaded.service.execService('reconcile');
	const reconcileCall = loaded.calls[loaded.calls.length - 1];
	assert.equal(reconcileResult.code, 0, 'reconcile returns normalized success result');
	assert.equal(reconcileCall.spec.method, 'reconcile', 'reconcile uses the dedicated ubus method');
	assert.equal(reconcileCall.spec.timeout, 120, 'reconcile uses the runtime rpc timeout');

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
