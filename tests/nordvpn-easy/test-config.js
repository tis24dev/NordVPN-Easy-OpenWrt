#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const configPath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'view',
	'nordvpn-easy',
	'config.js'
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

function normalizeValue(value) {
	return JSON.parse(JSON.stringify(value));
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
		this.default = null;
		this.rmempty = true;
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
	Option.prototype.super = function() {
		return '';
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

function parseExecJsonResponse(res, fallback) {
	if (!res || res.code !== 0)
		return fallback;

	try {
		return JSON.parse(res.stdout || '{}');
	} catch (err) {
		return fallback;
	}
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

function createSelectElement(id, value) {
	return {
		id: id,
		value: value || '',
		handlers: [],
		addEventListener(type, handler) {
			this.handlers.push({
				type: type,
				handler: handler
			});
		}
	};
}

function loadConfigView(options) {
	const opts = options || {};
	const source = fs.readFileSync(configPath, 'utf8');
	const managerData = loadManagerDataModule();
	const formHarness = createFormHarness();
	const state = {
		phase: 'booting',
		pendingOperationLabel: '',
		currentOperationStatus: 'idle',
		currentPublicIp: '',
		currentPublicCountry: '',
		currentPublicCountryIp: '',
		cachedPublicIp: '',
		cachedPublicCountry: '',
		cachedPublicCountryIp: '',
		appliedEnabled: false,
		appliedCountryCode: '',
		currentLocalStatus: managerData.parseLocalStatus('{}'),
		currentLocalStatusFresh: false,
		currentLocalStatusLastUpdated: 0,
		currentServerCatalog: managerData.emptyServerCatalog(),
		serverCatalogIndex: {},
		latestServerCatalogRequestId: 0,
		pollingSuspended: false,
		pollersStarted: false,
		lastError: '',
		inFlight: {}
	};
	const calls = {
		service: [],
		fsRead: [],
		uciLoad: [],
		renderServerChoices: [],
		renderCountryChoices: [],
		renderLocalStatusSnapshot: [],
		updateLocalStatus: [],
		updatePublicIp: [],
		loadServerCatalog: [],
		updateServerSelectionState: [],
		onCountryChanged: 0,
		onModeChanged: 0,
		pollingStart: []
	};
	const uciValues = Object.assign({
		enabled: '1',
		vpn_country: 'UY',
		server_selection_mode: 'manual',
		preferred_server_station: 'uy123',
		nordvpn_token: 'token'
	}, opts.uciValues || {});
	const fsReadResponses = (opts.fsReadResponses || [ '[]' ]).slice();
	const selectElements = {
		'cbid.nordvpn_easy.main.vpn_country': createSelectElement('cbid.nordvpn_easy.main.vpn_country', uciValues.vpn_country),
		'cbid.nordvpn_easy.main.server_selection_mode': createSelectElement('cbid.nordvpn_easy.main.server_selection_mode', uciValues.server_selection_mode),
		'cbid.nordvpn_easy.main.preferred_server_station': createSelectElement('cbid.nordvpn_easy.main.preferred_server_station', uciValues.preferred_server_station)
	};
	const statusPayload = opts.statusPayload || {
		desired_enabled: uciValues.enabled === '1',
		runtime_disabled: false,
		interface_disabled: false,
		runtime_configured: true,
		selected_country: uciValues.vpn_country,
		server_selection_mode: uciValues.server_selection_mode,
		preferred_server_station: uciValues.preferred_server_station,
		operation_status: 'idle'
	};
	const catalogPayload = opts.catalogPayload || {
		country_code: 'UY',
		country_name: 'Uruguay',
		servers: [
			{
				hostname: 'uy123.nordvpn.com',
				station: 'uy123',
				city: 'Montevideo',
				country_code: 'UY',
				country_name: 'Uruguay',
				load: '12',
				public_key: 'pub'
			}
		]
	};
	const context = {
		form: formHarness.form,
		fs: {
			read(file) {
				calls.fsRead.push(file);
				return Promise.resolve(fsReadResponses.length ? fsReadResponses.shift() : '[]');
			}
		},
		managerActions: {
			handleRefreshServerCatalog() {
				return Promise.resolve();
			},
			renderLocalStatusSnapshot(renderState, status) {
				calls.renderLocalStatusSnapshot.push({
					state: renderState,
					status: normalizeValue(status)
				});
			},
			updateLocalStatus(renderState, updateOptions) {
				calls.updateLocalStatus.push({
					state: renderState,
					options: normalizeValue(updateOptions)
				});
				return Promise.resolve();
			},
				updatePublicIp(renderState, updateOptions) {
					calls.updatePublicIp.push({
						state: renderState,
						options: normalizeValue(updateOptions)
					});
					return Promise.resolve();
				},
				loadServerCatalog(renderState, country, forceRefresh) {
					calls.loadServerCatalog.push({
						state: renderState,
						country: country,
						forceRefresh: forceRefresh
					});
					return Promise.resolve();
				},
				onCountryChanged() {
				calls.onCountryChanged++;
			},
			onModeChanged() {
				calls.onModeChanged++;
			}
		},
		managerData: managerData,
		managerFormat: {
			formatServerLabel(server) {
				return [ server.country_code, server.city, server.hostname, server.load + '%' ].filter(Boolean).join(' - ');
			}
		},
		managerPolling: {
			start(startState) {
				calls.pollingStart.push(startState);
			}
		},
		managerStore: {
			createState() {
				return state;
			},
			shouldLoadCatalog(mode, country) {
				return String(mode || 'auto') === 'manual' && !!managerData.normalizeCountryCode(country || '');
			}
		},
		managerUI: {
			ids: {
				COUNTRY_FIELD_ID: 'cbid.nordvpn_easy.main.vpn_country',
				MODE_FIELD_ID: 'cbid.nordvpn_easy.main.server_selection_mode',
				SERVER_FIELD_ID: 'cbid.nordvpn_easy.main.preferred_server_station',
				SERVER_CATALOG_STATUS_ID: 'catalog-status',
				SERVER_SELECTION_HINT_ID: 'selection-hint',
				PUBLIC_IP_STATUS_ID: 'public-ip',
				PUBLIC_COUNTRY_STATUS_ID: 'public-country'
			},
			getSelectElement(id) {
				return selectElements[id] || null;
			},
			getInputElement() {
				return null;
			},
			renderCountryChoices(selectEl, countries, currentCountry) {
				calls.renderCountryChoices.push({
					id: selectEl ? selectEl.id : '',
					countries: normalizeValue(countries),
					currentCountry: currentCountry
				});
			},
			renderServerChoices(selectEl, catalog, currentStation) {
				calls.renderServerChoices.push({
					id: selectEl ? selectEl.id : '',
					catalog: normalizeValue(catalog),
					currentStation: currentStation
				});
			},
			replaceStatusText() {},
			updateServerSelectionState(updateState) {
				calls.updateServerSelectionState.push(updateState);
			}
		},
		service: {
			execService(action, args) {
				calls.service.push({
					action: action,
					args: args || []
				});

				if (opts.execService)
					return opts.execService(action, args || []);

				if (action === 'status_json') {
					return Promise.resolve({
						code: 0,
						stdout: JSON.stringify(statusPayload),
						stderr: ''
					});
				}

				if (action === 'server_catalog') {
					return Promise.resolve({
						code: 0,
						stdout: JSON.stringify(catalogPayload),
						stderr: ''
					});
				}

				return Promise.resolve({
					code: 0,
					stdout: '',
					stderr: ''
				});
			},
			parseExecJsonResponse: parseExecJsonResponse,
			notifyInfo() {},
			notifyError() {}
		},
		ui: {
			Select: function Select() {},
			createHandlerFn(ctx, fn) {
				const boundArgs = Array.prototype.slice.call(arguments, 2);

				return function() {
					return fn.apply(ctx, boundArgs.concat(Array.prototype.slice.call(arguments)));
				};
			}
		},
		uci: {
			load(config) {
				calls.uciLoad.push(config);
				return Promise.resolve();
			},
			get(_config, _section, option) {
				return uciValues[option];
			},
			set(_config, _section, option, value) {
				uciValues[option] = value;
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
		E: function(tag, attrs, children) {
			return {
				tag: tag,
				attrs: attrs,
				children: children
			};
		},
		_: translate,
		Promise: Promise
	};

	return {
		view: vm.runInNewContext(`(function(){\n${source}\n})();`, context, {
			filename: configPath
		}),
		state: state,
		calls: calls,
		formHarness: formHarness,
		selectElements: selectElements,
		uciValues: uciValues
	};
}

async function testLoadUsesCachedCountriesWithoutBlockingOnManualCatalog() {
	const harness = loadConfigView({
		fsReadResponses: [
			'[]'
		],
		uciValues: {
			vpn_country: 'UY',
			server_selection_mode: 'manual'
		},
		statusPayload: {
			desired_enabled: true,
			operation_status: 'idle',
			operation_lock_state: 'none'
		}
	});
	const data = await harness.view.load();

	assert.equal(data[0], '[]', 'empty country cache does not block initial render');
	assert.deepEqual(
		normalizeValue(harness.calls.service.map(function(call) {
			return [ call.action, call.args ];
		})),
			[
				[ 'status_json', [] ]
			],
			'idle manual configuration loads status without blocking on server catalog refresh'
		);
		assert.equal(data[2], null, 'manual server catalog is loaded after render');
}

async function testLoadSkipsRefreshesWhenRuntimeBusy() {
	const harness = loadConfigView({
		fsReadResponses: [ '[]' ],
		uciValues: {
			vpn_country: 'UY',
			server_selection_mode: 'manual'
		},
		statusPayload: {
			desired_enabled: true,
			operation_status: 'busy:setup',
			operation_lock_state: 'held'
		}
	});
	const data = await harness.view.load();

	assert.deepEqual(
		normalizeValue(harness.calls.service.map(function(call) {
			return [ call.action, call.args ];
		})),
		[ [ 'status_json', [] ] ],
		'busy runtime skips country refresh and server catalog loading'
	);
	assert.equal(data[2], null, 'busy runtime returns no server catalog response');
}

async function testRenderWiresInitialStateAndLiveHandlers() {
	const countryRaw = JSON.stringify([ { name: 'Uruguay', code: 'UY' } ]);
	const statusResult = {
		code: 0,
		stdout: JSON.stringify({
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			selected_country: 'UY',
			server_selection_mode: 'manual',
			preferred_server_station: 'uy123',
			operation_status: 'idle'
		}),
		stderr: ''
	};
	const catalogResult = {
		code: 0,
		stdout: JSON.stringify({
			country_code: 'UY',
			country_name: 'Uruguay',
			servers: [
				{
					hostname: 'uy123.nordvpn.com',
					station: 'uy123',
					city: 'Montevideo',
					country_code: 'UY',
					country_name: 'Uruguay',
					load: '12',
					public_key: 'pub'
				}
			]
		}),
		stderr: ''
	};
	const harness = loadConfigView({
		uciValues: {
			enabled: '1',
			vpn_country: 'uy',
			server_selection_mode: 'manual',
			preferred_server_station: 'uy123'
		}
	});
	const node = await harness.view.render([ countryRaw, statusResult, catalogResult ]);
	const countryOption = harness.formHarness.findOption('vpn_country');
	const preferredServerOption = harness.formHarness.findOption('preferred_server_station');

	assert.equal(node.tag, 'map', 'config render resolves the LuCI map node');
	assert.equal(harness.state.appliedEnabled, true, 'render stores the applied enabled flag');
	assert.equal(harness.state.appliedCountryCode, 'UY', 'render normalizes the applied country');
	assert.equal(harness.state.currentLocalStatusFresh, true, 'fresh status_json response is marked fresh');
	assert.equal(harness.state.currentOperationStatus, 'idle', 'render stores the current operation status');
	assert.equal(harness.state.currentServerCatalog.servers.length, 1, 'render stores the initial server catalog');
	assert.equal(harness.state.serverCatalogIndex.uy123.hostname, 'uy123.nordvpn.com', 'render builds a station index for server-selection UI');
	assert.deepEqual(
		countryOption.values.map(function(item) {
			return item.value;
		}),
		[ '', 'UY' ],
		'country selector includes automatic mode and parsed country choices'
	);
	assert.deepEqual(
		preferredServerOption.values.map(function(item) {
			return item.value;
		}),
		[ '', 'uy123' ],
		'preferred-server selector includes the current catalog server'
	);
	assert.equal(harness.calls.renderLocalStatusSnapshot.length, 1, 'render publishes the initial runtime status snapshot');
	assert.equal(harness.calls.updateLocalStatus.length, 0, 'fresh initial status does not trigger an immediate status refresh');
	assert.deepEqual(harness.calls.updatePublicIp.map(function(call) {
		return call.options;
	}), [ { force: true } ], 'enabled configuration starts a forced public-IP refresh');
	assert.equal(harness.calls.renderServerChoices.length, 1, 'render refreshes server choices after the map node exists');
	assert.equal(harness.calls.loadServerCatalog.length, 0, 'render does not refresh server catalog when initial catalog is already present');
	assert.equal(harness.calls.updateServerSelectionState.length, 1, 'render updates server-selection state after wiring controls');
	assert.deepEqual(harness.calls.pollingStart, [ harness.state ], 'render starts manager polling with the shared state');

	harness.selectElements['cbid.nordvpn_easy.main.vpn_country'].handlers[0].handler();
	harness.selectElements['cbid.nordvpn_easy.main.server_selection_mode'].handlers[0].handler();
	assert.equal(harness.calls.onCountryChanged, 1, 'country select change delegates to manager-actions');
	assert.equal(harness.calls.onModeChanged, 1, 'mode select change delegates to manager-actions');
}

async function testRenderLoadsManualCatalogInBackgroundAfterInitialPaint() {
	const statusResult = {
		code: 0,
		stdout: JSON.stringify({
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: true,
			selected_country: 'UY',
			server_selection_mode: 'manual',
			operation_status: 'idle'
		}),
		stderr: ''
	};
	const harness = loadConfigView({
		uciValues: {
			enabled: '1',
			vpn_country: 'UY',
			server_selection_mode: 'manual',
			preferred_server_station: ''
		}
	});

	await harness.view.render([ JSON.stringify([ { name: 'Uruguay', code: 'UY' } ]), statusResult, null ]);
	await Promise.resolve();

	assert.equal(harness.state.currentServerCatalog.servers.length, 0, 'initial render is not blocked by server catalog data');
	assert.deepEqual(
		harness.calls.loadServerCatalog.map(function(call) {
			return {
				country: call.country,
				forceRefresh: call.forceRefresh
			};
		}),
		[ { country: 'UY', forceRefresh: false } ],
		'manual server catalog refresh starts in the background after render'
	);
}

async function testRenderRefreshesEmptyCountryCacheInBackground() {
	const statusResult = {
		code: 0,
		stdout: JSON.stringify({
			desired_enabled: true,
			runtime_disabled: false,
			interface_disabled: false,
			runtime_configured: false,
			selected_country: '',
			server_selection_mode: 'auto',
			operation_status: 'idle'
		}),
		stderr: ''
	};
	const harness = loadConfigView({
		fsReadResponses: [
			JSON.stringify([ { name: 'Belize', code: 'BZ' } ])
		],
		uciValues: {
			enabled: '1',
			vpn_country: '',
			server_selection_mode: 'auto',
			preferred_server_station: ''
		}
	});

	await harness.view.render([ '[]', statusResult, null ]);
	await Promise.resolve();
	await Promise.resolve();
	await Promise.resolve();

	assert.deepEqual(
		normalizeValue(harness.calls.service.map(function(call) {
			return [ call.action, call.args ];
		})),
		[ [ 'refresh_countries', [] ] ],
		'empty country cache refreshes in the background after render'
	);
	assert.deepEqual(
		harness.calls.renderCountryChoices,
		[
			{
				id: 'cbid.nordvpn_easy.main.vpn_country',
				countries: [ { name: 'Belize', code: 'BZ' } ],
				currentCountry: ''
			}
		],
		'background country refresh repopulates the rendered country selector'
	);
}

Promise.resolve().then(async function() {
	await testLoadUsesCachedCountriesWithoutBlockingOnManualCatalog();
	await testLoadSkipsRefreshesWhenRuntimeBusy();
	await testRenderWiresInitialStateAndLiveHandlers();
	await testRenderLoadsManualCatalogInBackgroundAfterInitialPaint();
	await testRenderRefreshesEmptyCountryCacheInBackground();
	console.log('test-config.js: ok');
}).catch(function(err) {
	console.error(err);
	process.exit(1);
});
