#!/usr/bin/env node

'use strict';

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

function loadServiceModule() {
	const source = fs.readFileSync(servicePath, 'utf8');
	const calls = [];
	const context = {
		baseclass: {
			extend(api) {
				return api;
			}
		},
		rpc: {
			declare(spec) {
				return function() {
					const args = Array.prototype.slice.call(arguments);
					calls.push({ spec: spec, args: args });
					return Promise.resolve({
						code: 0,
						success: true,
						stdout: JSON.stringify({ method: spec.method, args: args }),
						stderr: ''
					});
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
		Promise: Promise
	};

	return {
		service: vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
			filename: servicePath
		}),
		calls: calls
	};
}

Promise.resolve().then(async function() {
	const loaded = loadServiceModule();
	const result = await loaded.service.execService('refresh_servers', [ 'UY', '1' ]);
	const call = loaded.calls[loaded.calls.length - 1];
	const payload = JSON.parse(result.stdout);

	assert.equal(result.code, 0, 'refresh_servers returns normalized success result');
	assert.equal(call.spec.object, 'nordvpn.easy', 'refresh_servers uses nordvpn.easy ubus object');
	assert.equal(call.spec.method, 'refresh_servers', 'refresh_servers uses the dedicated ubus method');
	assert.deepEqual(call.args, [ 'UY', true ], 'refresh_servers forwards country and force args');
	assert.deepEqual(payload.args, [ 'UY', true ], 'refresh_servers preserves rpc payload in stdout');

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
