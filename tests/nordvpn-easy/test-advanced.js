#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const advancedPath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'view',
	'nordvpn-easy',
	'advanced.js'
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
const source = fs.readFileSync(advancedPath, 'utf8');

function loadManagerDataModule() {
	const managerDataSource = fs.readFileSync(managerDataPath, 'utf8');

	return vm.runInNewContext(`(function(){\n${managerDataSource}\n})();`, {
		baseclass: {
			extend(api) {
				return api;
			}
		}
	}, {
		filename: managerDataPath
	});
}

const managerDataModule = loadManagerDataModule();

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

assert.doesNotMatch(source, /hk318/, 'advanced fallback UI must not suggest a known-problematic HK318 station');

function normalizeValue(value) {
	return JSON.parse(JSON.stringify(value));
}

function translate(message) {
	const text = String(message);

	return {
		format: function() {
			let index = 0;
			const args = arguments;

			return text.replace(/%[sd]/g, function() {
				return String(args[index++]);
			});
		},
		toString: function() {
			return text;
		},
		valueOf: function() {
			return text;
		}
	};
}

function extendOptionClass(Parent, methods, kind) {
	function Option(option, title) {
		Parent.call(this, option, title);
		this.kind = kind;
	}

	Option.prototype = Object.create(Parent.prototype);
	Option.prototype.constructor = Option;
	Object.keys(methods || {}).forEach(function(key) {
		Option.prototype[key] = methods[key];
	});
	Option.extend = function(nextMethods) {
		return extendOptionClass(Option, nextMethods, kind + '.extended');
	};

	return Option;
}

function createOptionClass(kind) {
	function Option(option, title) {
		this.kind = kind;
		this.option = option;
		this.title = String(title || '');
		this.values = [];
		this.dependencies = [];
	}

	Option.prototype.value = function(value, label) {
		this.values.push({
			value: String(value),
			label: String(label)
		});
		return this;
	};
	Option.prototype.depends = function(option, value) {
		this.dependencies.push({
			option: option,
			value: value
		});
		return this;
	};
	Option.extend = function(methods) {
		return extendOptionClass(Option, methods, kind + '.extended');
	};

	return Option;
}

function createFormHarness() {
	const harness = {
		maps: []
	};
	const BaseOption = createOptionClass('Option');
	const form = {
		Flag: extendOptionClass(BaseOption, {}, 'Flag'),
		Value: extendOptionClass(BaseOption, {}, 'Value'),
		ListValue: extendOptionClass(BaseOption, {}, 'ListValue'),
		DummyValue: extendOptionClass(BaseOption, {}, 'DummyValue'),
		Button: extendOptionClass(BaseOption, {}, 'Button'),
		NamedSection: function NamedSection() {},
		Map: function Map(config, title, description) {
			this.config = config;
			this.title = String(title || '');
			this.description = String(description || '');
			this.sections = [];
			this.options = [];
			harness.maps.push(this);
		}
	};

	form.Map.prototype.section = function(_SectionClass, sectionId, sectionType, title) {
		const map = this;
		const section = {
			section_id: sectionId,
			section_type: sectionType,
			title: String(title || ''),
			options: [],
			option(OptionClass, option, optionTitle) {
				const item = new OptionClass(option, optionTitle);

				item.map = map;
				item.section = this;
				this.options.push(item);
				map.options.push(item);
				return item;
			}
		};

		this.sections.push(section);
		return section;
	};
	form.Map.prototype.render = function() {
		return Promise.resolve({
			tag: 'map',
			map: this
		});
	};

	harness.form = form;
	harness.findOption = function(name) {
		const map = harness.maps[harness.maps.length - 1];

		return map ? map.options.find(function(option) {
			return option.option === name;
		}) : null;
	};

	return harness;
}

function normalizeCountryCode(value) {
	return String(value || '').trim().toUpperCase();
}

function emptyServerCatalog() {
	return {
		country_code: '',
		country_name: '',
		servers: []
	};
}

function parseServerCatalog(raw) {
	let catalog;

	try {
		catalog = JSON.parse(raw || '{}');
	} catch (err) {
		return emptyServerCatalog();
	}

	if (!catalog || typeof catalog !== 'object' || Array.isArray(catalog))
		return emptyServerCatalog();

	return {
		country_code: normalizeCountryCode(catalog.country_code || ''),
		country_name: String(catalog.country_name || ''),
		servers: Array.isArray(catalog.servers) ? catalog.servers.filter(function(server) {
			return server && server.station && server.hostname && server.public_key;
		}).map(function(server) {
			return {
				station: String(server.station),
				hostname: String(server.hostname),
				city: String(server.city || ''),
				country_code: normalizeCountryCode(server.country_code || ''),
				country_name: String(server.country_name || ''),
				load: String(server.load != null ? server.load : ''),
				public_key: String(server.public_key || '')
			};
		}) : []
	};
}

function buildServerCatalogIndex(catalog) {
	const index = {};

	catalog.servers.forEach(function(server) {
		index[server.station] = server;
	});

	return index;
}

function parseExecJsonResponse(res, fallback) {
	if (!res || res.code !== 0)
		return fallback;

	try {
		return JSON.parse(res.stdout || '{}');
	} catch (err) {
		return fallback;
	}
}

function loadAdvancedView(options) {
	const opts = options || {};
	const formHarness = createFormHarness();
	const calls = {
		stat: [],
		read: [],
		execService: [],
		runAction: [],
		uciLoad: []
	};
	const notifications = [];
	const uciValues = Object.assign({
		vpn_country: 'UY',
		preferred_server_station: 'uy123',
		fallback_server_station: 'uy456'
	}, opts.uciValues || {});
	const statusPayload = opts.statusPayload || {
		operation_status: 'idle',
		operation_lock_state: 'none'
	};
	const catalogPayload = opts.catalogPayload || {
		country_code: 'UY',
		country_name: 'Uruguay',
		servers: [
			{
				hostname: 'uy456.nordvpn.com',
				station: 'uy456',
				city: 'Montevideo',
				country_code: 'UY',
				country_name: 'Uruguay',
				load: '8',
				public_key: 'pub'
			}
		]
	};
	const context = {
		form: formHarness.form,
		fs: {
			stat(file) {
				calls.stat.push(file);
				return opts.missingStats ? Promise.reject(new Error('missing')) : Promise.resolve({ path: file });
			},
			read(file) {
				calls.read.push(file);
				return Promise.resolve(JSON.stringify(catalogPayload));
			}
		},
		managerData: {
			normalizeCountryCode: normalizeCountryCode,
			emptyServerCatalog: emptyServerCatalog,
			parseServerCatalog: parseServerCatalog,
			buildServerCatalogIndex: buildServerCatalogIndex,
			runtimeStatusIsBusy: managerDataModule.runtimeStatusIsBusy
		},
		managerFormat: {
			formatServerLabel(server) {
				return [ server.country_code, server.city, server.hostname, server.load + '%' ].filter(Boolean).join(' - ');
			}
		},
		service: {
			execService(action) {
				calls.execService.push(action);
				return Promise.resolve({
					code: 0,
					stdout: JSON.stringify(statusPayload),
					stderr: ''
				});
			},
			parseExecJsonResponse: parseExecJsonResponse,
			runAction(action) {
				calls.runAction.push(action);
				return Promise.resolve(opts.actionResult || {
					success: true,
					message: action + ' complete'
				});
			},
			resultToError(result) {
				return new Error(result && result.stderr ? result.stderr : 'action failed');
			},
			notifyInfo(message) {
				notifications.push({ type: 'info', message: String(message) });
			},
			notifyError(err) {
				notifications.push({ type: 'error', message: (err && err.message) ? err.message : String(err) });
			}
		},
		uci: {
			load(config) {
				calls.uciLoad.push(config);
				return Promise.resolve();
			},
			get(_config, _section, option) {
				return uciValues[option];
			}
		},
		view: {
			extend(api) {
				return api;
			}
		},
		L: {
			resolveDefault(value, fallback) {
				return Promise.resolve(value).catch(function() {
					return fallback;
				});
			}
		},
		_: translate,
		Promise: Promise
	};

	return {
		view: vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
			filename: advancedPath
		}),
		formHarness: formHarness,
		calls: calls,
		notifications: notifications,
		stats: [
			{},
			{
				code: 0,
				stdout: JSON.stringify(statusPayload),
				stderr: ''
			},
			null,
			JSON.stringify(catalogPayload)
		]
	};
}

async function testFallbackValidationUsesCurrentCountryCatalog() {
	const harness = loadAdvancedView();

	await harness.view.render(harness.stats);

	const fallbackOption = harness.formHarness.findOption('fallback_server_station');
	const statusOption = harness.formHarness.findOption('_fallback_server_status');

	assert.equal(fallbackOption.validate('main', ''), true, 'empty fallback station remains optional');
	assert.match(String(fallbackOption.validate('main', 'uy123')), /different from the preferred server/, 'fallback validation rejects the preferred server');
	assert.match(String(fallbackOption.validate('main', 'uy999')), /not found in the current country catalog/, 'fallback validation rejects unknown stations from a loaded catalog');
	assert.equal(fallbackOption.validate('main', 'uy456'), true, 'fallback validation accepts stations from the current country catalog');
	assert.match(String(statusOption.cfgvalue('main')), /Valid: UY - Montevideo - uy456\.nordvpn\.com - 8%/, 'fallback status renders the matched catalog server');
}

async function testWireGuardTransportControlsValidateOperationalRanges() {
	const harness = loadAdvancedView();

	await harness.view.render(harness.stats);

	const keepaliveOption = harness.formHarness.findOption('wireguard_persistent_keepalive');
	const mtuOption = harness.formHarness.findOption('wireguard_mtu');
	const mtuFixOption = harness.formHarness.findOption('firewall_mtu_fix');

	assert.equal(keepaliveOption.default, '15', 'WireGuard keepalive defaults to 15 seconds in Advanced');
	assert.equal(keepaliveOption.validate('main', '0'), true, 'keepalive 0 is allowed to disable keepalive deliberately');
	assert.equal(keepaliveOption.validate('main', '15'), true, 'keepalive 15 is valid');
	assert.match(String(keepaliveOption.validate('main', '121')), /120 seconds or less/, 'keepalive above 120 is rejected');
	assert.match(String(keepaliveOption.validate('main', 'abc')), /between 0 and 120/, 'non-numeric keepalive is rejected');

	assert.equal(mtuOption.validate('main', ''), true, 'empty MTU keeps automatic mode');
	assert.equal(mtuOption.validate('main', '1420'), true, 'MTU 1420 is valid');
	assert.match(String(mtuOption.validate('main', '1279')), /between 1280 and 1500/, 'low MTU is rejected');
	assert.match(String(mtuOption.validate('main', '1501')), /between 1280 and 1500/, 'high MTU is rejected');
	assert.equal(mtuFixOption.default, '1', 'MSS clamping defaults on');

	const dnsModeOption = harness.formHarness.findOption('dns_mode');
	assert.equal(dnsModeOption.default, 'custom', 'dns_mode defaults to custom so an upgrade keeps the saved DNS');
	assert.deepEqual(
		dnsModeOption.values.map(function(v) { return v.value; }),
		['standard', 'threat_protection', 'threat_protection_family', 'custom'],
		'dns_mode offers standard, both threat-protection tiers and custom'
	);
	const dns1Option = harness.formHarness.findOption('vpn_dns1');
	assert.ok(
		dns1Option.dependencies.some(function(d) { return d.option === 'dns_mode' && d.value === 'custom'; }),
		'DNS 1 is only shown in custom dns_mode'
	);
	const dns2Option = harness.formHarness.findOption('vpn_dns2');
	assert.ok(
		dns2Option.dependencies.some(function(d) { return d.option === 'dns_mode' && d.value === 'custom'; }),
		'DNS 2 is only shown in custom dns_mode'
	);

	const cronOption = harness.formHarness.findOption('check_cron_schedule');
	assert.equal(cronOption.validate('main', ''), true, 'empty cron schedule disables cron');
	assert.equal(cronOption.validate('main', '*/10 * * * *'), true, 'stepped cron schedule is valid');
	assert.equal(cronOption.validate('main', '0-30/5 1,2 * * 1-5'), true, 'range/step/list cron schedule is valid');
	assert.match(String(cronOption.validate('main', '*/10 * * *')), /exactly 5 fields/, 'cron schedule with too few fields is rejected');
	assert.match(String(cronOption.validate('main', 'bad * * * *')), /not a valid cron expression/, 'cron field with invalid characters is rejected');
	assert.equal(cronOption.validate('main', '59 23 31 12 7'), true, 'cron schedule at the per-field maxima is valid');
	assert.match(String(cronOption.validate('main', '60 * * * *')), /not a valid cron expression/, 'minute above 59 is rejected (matches the init bounds)');
	assert.match(String(cronOption.validate('main', '* 24 * * *')), /not a valid cron expression/, 'hour above 23 is rejected');
	assert.match(String(cronOption.validate('main', '* * 0 * *')), /not a valid cron expression/, 'day-of-month below 1 is rejected');
	assert.match(String(cronOption.validate('main', '* * * 13 *')), /not a valid cron expression/, 'month above 12 is rejected');
	assert.match(String(cronOption.validate('main', '* * * * 8')), /not a valid cron expression/, 'weekday above 7 is rejected');
	assert.match(String(cronOption.validate('main', '30-10 * * * *')), /not a valid cron expression/, 'inverted minute range is rejected');
	assert.match(String(cronOption.validate('main', '*/99 * * * *')), /not a valid cron expression/, 'minute step above 59 is rejected');

	const wanOption = harness.formHarness.findOption('wan_if');
	const addrOption = harness.formHarness.findOption('vpn_addr');
	const portOption = harness.formHarness.findOption('vpn_port');
	const dnsOption = harness.formHarness.findOption('vpn_dns1');
	assert.equal(wanOption.datatype, 'uciname', 'WAN interface uses the uciname datatype');
	assert.equal(addrOption.datatype, 'cidr4', 'VPN address uses the cidr4 datatype');
	assert.equal(portOption.datatype, 'port', 'VPN port uses the port datatype');
	assert.equal(dnsOption.datatype, 'ipaddr', 'VPN DNS uses the ipaddr datatype');
}

async function testBusyRuntimeDisablesMutableActionsButKeepsHookRemovalAvailable() {
	const harness = loadAdvancedView({
		statusPayload: {
			operation_status: 'busy:check',
			operation_lock_state: 'held'
		}
	});

	await harness.view.render(harness.stats);

	const operationStatusOption = harness.formHarness.findOption('_operation_status');
	const setupOption = harness.formHarness.findOption('_run_setup');
	const checkOption = harness.formHarness.findOption('_check');
	const rotateOption = harness.formHarness.findOption('_rotate');
	const installHooksOption = harness.formHarness.findOption('_install_hooks');
	const removeHooksOption = harness.formHarness.findOption('_remove_hooks');

	assert.equal(String(operationStatusOption.cfgvalue()), 'Busy (busy:check)', 'busy runtime renders the specific operation status');
	assert.equal(setupOption.readonly, true, 'busy runtime disables setup action');
	assert.equal(checkOption.readonly, true, 'busy runtime disables check action');
	assert.equal(rotateOption.readonly, true, 'busy runtime disables rotate action');
	assert.equal(installHooksOption.readonly, true, 'busy runtime disables install-hooks action');
	assert.equal(removeHooksOption.readonly, undefined, 'busy runtime keeps remove-hooks action available');

	await setupOption.onclick();
	assert.deepEqual(harness.calls.runAction, [], 'busy setup click does not call the backend action');
	assert.match(harness.notifications[0].message, /another runtime operation/, 'busy setup click reports the skipped action');

	await removeHooksOption.onclick();
	assert.deepEqual(normalizeValue(harness.calls.runAction), [ 'remove_hooks' ], 'remove-hooks still invokes the backend action while runtime is busy');
}

async function testMismatchedCatalogIsClearedBeforeFallbackStateIsDerived() {
	const harness = loadAdvancedView({
		uciValues: {
			vpn_country: 'UY',
			preferred_server_station: 'uy123',
			fallback_server_station: 'us999'
		},
		catalogPayload: {
			country_code: 'US',
			country_name: 'United States',
			servers: [
				{
					hostname: 'us999.nordvpn.com',
					station: 'us999',
					city: 'New York',
					country_code: 'US',
					country_name: 'United States',
					load: '4',
					public_key: 'pub'
				}
			]
		}
	});

	await harness.view.render(harness.stats);

	const fallbackOption = harness.formHarness.findOption('fallback_server_station');
	const statusOption = harness.formHarness.findOption('_fallback_server_status');

	assert.equal(fallbackOption.validate('main', 'us999'), true, 'stale catalog data does not hard-fail fallback validation');
	assert.equal(String(statusOption.cfgvalue('main')), 'Not verified: server catalog unavailable', 'stale catalog data is cleared before fallback status rendering');
}

Promise.resolve().then(async function() {
	await testFallbackValidationUsesCurrentCountryCatalog();
	await testWireGuardTransportControlsValidateOperationalRanges();
	await testBusyRuntimeDisablesMutableActionsButKeepsHookRemovalAvailable();
	await testMismatchedCatalogIsClearedBeforeFallbackStateIsDerived();
	console.log('test-advanced.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
