#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const managerStorePath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'nordvpn-easy',
	'manager-store.js'
);

function deferred() {
	let resolve;
	let reject;
	const promise = new Promise(function(resolvePromise, rejectPromise) {
		resolve = resolvePromise;
		reject = rejectPromise;
	});

	return {
		promise: promise,
		resolve: resolve,
		reject: reject
	};
}

function loadManagerStoreModule() {
	const source = fs.readFileSync(managerStorePath, 'utf8');

	return vm.runInNewContext(`(function(){\n${source}\n})();`, {
		baseclass: {
			extend(api) {
				return api;
			}
		},
		managerData: {
			parseLocalStatus() {
				return {};
			},
			emptyServerCatalog() {
				return { servers: [] };
			},
			emptyDiagnosticsSummary() {
				return {};
			},
			normalizeCountryCode(value) {
				return String(value || '').trim().toUpperCase();
			}
		}
	}, {
		filename: managerStorePath
	});
}

Promise.resolve().then(async function() {
	const managerStore = loadManagerStoreModule();
	const state = managerStore.createState();
	const first = deferred();
	const second = deferred();
	let calls = 0;

	const firstPromise = managerStore.runExclusive(state, 'status', function() {
		calls++;
		return first.promise;
	});
	const duplicatePromise = managerStore.runExclusive(state, 'status', function() {
		calls++;
		return Promise.resolve('duplicate');
	});

	assert.equal(duplicatePromise, firstPromise, 'runExclusive reuses an in-flight request');
	assert.equal(calls, 0, 'runExclusive installs the placeholder before invoking the factory');

	await Promise.resolve();
	assert.equal(calls, 1, 'runExclusive invokes only the first factory for duplicate callers');

	const freshPromise = managerStore.runExclusive(state, 'status', function() {
		calls++;
		return second.promise;
	}, { fresh: true });

	await Promise.resolve();
	assert.equal(calls, 2, 'fresh run starts a replacement request');

	first.resolve('old');
	assert.equal(await firstPromise, 'old', 'older request can settle without breaking newer request');
	assert.equal(managerStore.runExclusive(state, 'status', function() {
		calls++;
		return Promise.resolve('third');
	}), freshPromise, 'older cleanup does not clear the newer in-flight request');
	assert.equal(calls, 2, 'older cleanup does not allow a duplicate replacement request');

	second.resolve('fresh');
	assert.equal(await freshPromise, 'fresh', 'fresh replacement request resolves normally');
	assert.equal(state.inFlight.status, null, 'current request clears its own in-flight slot');

	console.log('test-manager-store.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
