'use strict';
'require form';
'require fs';
'require poll';
'require ui';
'require uci';
'require view';

const COUNTRIES_CACHE_PATH = '/tmp/nordvpn-easy-countries.json';
const ENABLED_FIELD_ID = 'cbid.nordvpn_easy.main.enabled';
const TOKEN_FIELD_ID = 'cbid.nordvpn_easy.main.nordvpn_token';
const COUNTRY_FIELD_ID = 'cbid.nordvpn_easy.main.vpn_country';
const COUNTRY_REFRESH_BUTTON_ID = 'cbid.nordvpn_easy.main.vpn_country.refresh';
const MODE_FIELD_ID = 'cbid.nordvpn_easy.main.server_selection_mode';
const SERVER_FIELD_ID = 'cbid.nordvpn_easy.main.preferred_server_station';
const SERVER_CACHE_ENABLED_FIELD_ID = 'cbid.nordvpn_easy.main.server_cache_enabled';
const SERVER_CACHE_TTL_FIELD_ID = 'cbid.nordvpn_easy.main.server_cache_ttl';
const ACTION_BAR_ID = 'nordvpn-easy-manager-actions';
const SERVER_REFRESH_BUTTON_ID = 'cbid.nordvpn_easy.main._refresh_servers';
const SERVER_REFRESH_BUTTON_ID_TOP = 'nordvpn-easy-refresh-servers-top';
const VPN_STATUS_ID = 'nordvpn-easy-vpn-status';
const CURRENT_SERVER_STATUS_ID = 'nordvpn-easy-current-server-status';
const PREFERRED_SERVER_STATUS_ID = 'nordvpn-easy-preferred-server-status';
const ENDPOINT_STATUS_ID = 'nordvpn-easy-endpoint-status';
const HANDSHAKE_STATUS_ID = 'nordvpn-easy-handshake-status';
const TRANSFER_STATUS_ID = 'nordvpn-easy-transfer-status';
const OPERATION_STATUS_ID = 'nordvpn-easy-operation-status';
const PUBLIC_IP_STATUS_ID = 'nordvpn-easy-public-ip-status';
const PUBLIC_COUNTRY_STATUS_ID = 'nordvpn-easy-public-country-status';
const COUNTRY_MATCH_STATUS_ID = 'nordvpn-easy-country-match-status';
const SERVER_CATALOG_STATUS_ID = 'nordvpn-easy-server-catalog-status';
const SERVER_SELECTION_HINT_ID = 'nordvpn-easy-server-selection-hint';

let pendingOperationLabel = '';
let currentOperationStatus = 'idle';
let currentPublicCountry = '';
let appliedEnabled = false;
let appliedCountryCode = '';
let currentLocalStatus = {};
let currentServerCatalog = emptyServerCatalog();
let serverCatalogIndex = {};

function emptyServerCatalog() {
	return {
		country_code: '',
		country_name: '',
		servers: []
	};
}

function parseJson(raw, fallback) {
	try {
		return JSON.parse(raw || '');
	} catch (e) {
		return fallback;
	}
}

function parseCountries(countriesRaw) {
	const countries = parseJson(countriesRaw, []);

	return countries.filter(function(country) {
		return country && country.name && country.code;
	}).sort(function(a, b) {
		return String(a.name).localeCompare(String(b.name));
	});
}

function parseLocalStatus(raw) {
	const status = parseJson(raw, {});

	return {
		enabled: !!status.enabled,
		server_selection_mode: String(status.server_selection_mode || 'auto'),
		selected_country: normalizeCountryCode(status.selected_country || ''),
		interface: String(status.interface || ''),
		vpn_status: String(status.vpn_status || 'inactive'),
		operation_status: String(status.operation_status || 'idle'),
		connected: !!status.connected,
		endpoint: String(status.endpoint || 'N/A'),
		latest_handshake: String(status.latest_handshake || 'Never'),
		transfer_rx: String(status.transfer_rx || '0 B'),
		transfer_tx: String(status.transfer_tx || '0 B'),
		current_server_hostname: String(status.current_server_hostname || ''),
		current_server_station: String(status.current_server_station || ''),
		current_server_city: String(status.current_server_city || ''),
		current_server_country: normalizeCountryCode(status.current_server_country || ''),
		current_server_load: String(status.current_server_load || ''),
		preferred_server_hostname: String(status.preferred_server_hostname || ''),
		preferred_server_station: String(status.preferred_server_station || '')
	};
}

function parseServerCatalog(raw) {
	const catalog = parseJson(raw, emptyServerCatalog());

	if (!catalog || typeof catalog !== 'object')
		return emptyServerCatalog();

	return {
		country_id: String(catalog.country_id || ''),
		country_code: normalizeCountryCode(catalog.country_code || ''),
		country_name: String(catalog.country_name || ''),
		servers: Array.isArray(catalog.servers) ? catalog.servers.filter(function(server) {
			return server && server.hostname && server.station && server.public_key;
		}).map(function(server) {
			return {
				hostname: String(server.hostname),
				station: String(server.station),
				load: String(server.load != null ? server.load : ''),
				city: String(server.city || ''),
				country_code: normalizeCountryCode(server.country_code || ''),
				country_name: String(server.country_name || ''),
				public_key: String(server.public_key || '')
			};
		}) : []
	};
}

function buildServerCatalogIndex(catalog) {
	const index = {};

	catalog.servers.forEach(function(server) {
		index[String(server.station)] = server;
	});

	return index;
}

function humanizeAction(action) {
	return String(action || _('operation')).replace(/_/g, ' ');
}

function formatActionsLabel(actions) {
	return actions.map(humanizeAction).join(' + ');
}

function normalizeCountryCode(value) {
	return String(value || '').trim().toUpperCase();
}

function getSelectElement(optionId) {
	const frameEl = document.getElementById(optionId);

	if (!frameEl)
		return null;

	if (frameEl.matches && frameEl.matches('select'))
		return frameEl;

	return frameEl.querySelector ? frameEl.querySelector('select') : null;
}

function getInputElement(optionId, selector) {
	const fieldEl = document.getElementById(optionId);

	if (!fieldEl)
		return null;

	if (!selector)
		return fieldEl;

	if (fieldEl.matches && fieldEl.matches(selector))
		return fieldEl;

	return fieldEl.querySelector ? fieldEl.querySelector(selector) : null;
}

function getEnabledCheckboxElement() {
	return getInputElement(ENABLED_FIELD_ID, 'input[type="checkbox"]');
}

function getSelectedCountry() {
	const selectEl = getSelectElement(COUNTRY_FIELD_ID);

	return normalizeCountryCode(selectEl ? selectEl.value : '');
}

function getSelectedMode() {
	const selectEl = getSelectElement(MODE_FIELD_ID);

	return String(selectEl ? selectEl.value : 'auto');
}

function getSelectedPreferredStation() {
	const selectEl = getSelectElement(SERVER_FIELD_ID);

	return String(selectEl ? selectEl.value : '');
}

function renderCountryChoices(selectEl, countries, currentCountry) {
	let seenCurrent = false;

	if (!selectEl)
		return;

	while (selectEl.firstChild)
		selectEl.removeChild(selectEl.firstChild);

	selectEl.appendChild(E('option', { value: '' }, [ _('Automatic') ]));

	countries.forEach(function(country) {
		const value = String(country.code);

		selectEl.appendChild(E('option', { value: value }, [
			_('%s (%s)').format(country.name, value)
		]));

		if (value === currentCountry)
			seenCurrent = true;
	});

	if (currentCountry && !seenCurrent) {
		selectEl.appendChild(E('option', { value: currentCountry }, [
			_('Current value: %s').format(currentCountry)
		]));
	}

	selectEl.value = currentCountry || '';
}

function formatServerLabel(server) {
	const parts = [];
	let label;

	if (server.country_name)
		parts.push(server.country_name);
	else if (server.country_code)
		parts.push(server.country_code);

	if (server.city)
		parts.push(server.city);

	if (server.hostname)
		parts.push(server.hostname);

	label = parts.join(' - ');

	if (server.load !== '')
		label += (label ? ' - ' : '') + _('Load %s%%').format(server.load);

	return label || server.station;
}

function formatServerSummary(server) {
	if (!server)
		return _('Automatic / Best recommended');

	return formatServerLabel(server);
}

function renderServerChoices(selectEl, catalog, currentStation) {
	let seenCurrent = false;

	if (!selectEl)
		return;

	while (selectEl.firstChild)
		selectEl.removeChild(selectEl.firstChild);

	selectEl.appendChild(E('option', { value: '' }, [
		catalog.servers.length ? _('-- Select Server --') : _('No server catalog loaded')
	]));

	catalog.servers.forEach(function(server) {
		const value = String(server.station);

		selectEl.appendChild(E('option', { value: value }, [
			formatServerLabel(server)
		]));

		if (value === currentStation)
			seenCurrent = true;
	});

	if (currentStation && !seenCurrent) {
		selectEl.appendChild(E('option', { value: currentStation }, [
			_('Current value: %s').format(currentStation)
		]));
	}

	selectEl.value = currentStation || '';
}

function setStatusIndicator(elementId, color, label) {
	const statusEl = document.getElementById(elementId);

	if (!statusEl)
		return;

	statusEl.replaceChildren(
		E('span', {
			style: 'display:inline-block;width:0.75rem;height:0.75rem;border-radius:50%;background:' + color + ';vertical-align:middle;margin-right:0.45rem;'
		}),
		document.createTextNode(label)
	);
}

function setVpnStatusIndicator(state, label) {
	let color = '#cf222e';

	if (state === 'active')
		color = '#2ea043';
	else if (state === 'activating')
		color = '#d29922';

	setStatusIndicator(VPN_STATUS_ID, color, label);
}

function setCountryMatchIndicator(state, label) {
	let color = '#cf222e';

	switch (state) {
	case 'match':
		color = '#2ea043';
		break;
	case 'checking':
	case 'automatic':
		color = '#d29922';
		break;
	case 'inactive':
	case 'unavailable':
		color = '#8c959f';
		break;
	}

	setStatusIndicator(COUNTRY_MATCH_STATUS_ID, color, label);
}

function replaceStatusText(elementId, value) {
	const element = document.getElementById(elementId);

	if (element)
		element.textContent = value;
}

function currentServerSummaryFromStatus(status) {
	if (!status || !status.current_server_station)
		return _('Not configured');

	return formatServerSummary({
		hostname: status.current_server_hostname,
		station: status.current_server_station,
		city: status.current_server_city,
		country_code: status.current_server_country,
		load: status.current_server_load
	});
}

function preferredServerSummaryFromStatus(status) {
	if (!status)
		return _('Automatic / Best recommended');

	if (status.server_selection_mode !== 'manual')
		return _('Automatic / Best recommended');

	if (!status.preferred_server_station)
		return _('Manual selection pending');

	return formatServerSummary({
		hostname: status.preferred_server_hostname,
		station: status.preferred_server_station,
		country_code: status.selected_country
	});
}

function updateCountryMatchStatus() {
	let busyAction;
	const expectedCountry = normalizeCountryCode(appliedCountryCode);
	const actualCountry = normalizeCountryCode(currentPublicCountry);

	if (currentOperationStatus.indexOf('busy:') === 0) {
		busyAction = currentOperationStatus.substring(5);

		if (busyAction !== 'refresh_countries' && busyAction !== 'server_catalog')
			return setCountryMatchIndicator('checking', _('Checking'));
	}
	else if (currentOperationStatus === 'busy') {
		return setCountryMatchIndicator('checking', _('Checking'));
	}

	if (!appliedEnabled)
		return setCountryMatchIndicator('inactive', _('Inactive'));

	if (!expectedCountry)
		return setCountryMatchIndicator('automatic', _('Automatic'));

	if (!actualCountry)
		return setCountryMatchIndicator('unavailable', _('Unavailable'));

	if (actualCountry === expectedCountry)
		return setCountryMatchIndicator('match', _('Match (%s)').format(actualCountry));

	setCountryMatchIndicator('mismatch', _('Mismatch (%s)').format(actualCountry));
}

function setManagerControlsDisabled(disabled) {
	[
		ENABLED_FIELD_ID,
		TOKEN_FIELD_ID,
		COUNTRY_FIELD_ID,
		COUNTRY_REFRESH_BUTTON_ID,
		MODE_FIELD_ID,
		SERVER_FIELD_ID,
		SERVER_CACHE_ENABLED_FIELD_ID,
		SERVER_CACHE_TTL_FIELD_ID,
		SERVER_REFRESH_BUTTON_ID,
		SERVER_REFRESH_BUTTON_ID_TOP
	].forEach(function(id) {
		const fieldEl = document.getElementById(id);
		const selectEl = getSelectElement(id);
		const inputEl = getInputElement(id, 'input,button');

		if (fieldEl && fieldEl.matches && fieldEl.matches('button'))
			fieldEl.disabled = disabled;

		if (selectEl)
			selectEl.disabled = disabled;

		if (inputEl)
			inputEl.disabled = disabled;
	});
}

function updateServerCatalogStatus() {
	let text;
	const mode = getSelectedMode();
	const country = getSelectedCountry();
	const selectionHintEl = document.getElementById(SERVER_SELECTION_HINT_ID);
	const statusEl = document.getElementById(SERVER_CATALOG_STATUS_ID);

	if (!country) {
		text = _('Select a country to load the manual server catalog.');
	}
	else if (!currentServerCatalog.servers.length) {
		text = _('No server catalog loaded for %s yet.').format(country);
	}
	else {
		text = _('%d servers cached for %s').format(
			currentServerCatalog.servers.length,
			currentServerCatalog.country_name || currentServerCatalog.country_code || country
		);
	}

	if (statusEl)
		statusEl.textContent = text;

	if (selectionHintEl) {
		if (mode !== 'manual')
			selectionHintEl.textContent = _('Automatic mode uses NordVPN recommended servers for the selected country.');
		else if (!country)
			selectionHintEl.textContent = _('Manual mode requires a country and a preferred server.');
		else if (!currentServerCatalog.servers.length)
			selectionHintEl.textContent = _('Use "Refresh Server List" to fetch the NordVPN catalog for the selected country.');
		else
			selectionHintEl.textContent = _('Manual mode is rigid during health checks. Rotate updates the saved preferred server.');
	}
}

function updateServerSelectionState() {
	const mode = getSelectedMode();
	const country = getSelectedCountry();
	const busy = currentOperationStatus.indexOf('busy') === 0;
	const selectEl = getSelectElement(SERVER_FIELD_ID);
	const refreshButtons = [
		getInputElement(SERVER_REFRESH_BUTTON_ID, 'button'),
		document.getElementById(SERVER_REFRESH_BUTTON_ID_TOP)
	];

	updateServerCatalogStatus();

	if (selectEl)
		selectEl.disabled = busy || mode !== 'manual' || !country || !currentServerCatalog.servers.length;

	refreshButtons.forEach(function(button) {
		if (button)
			button.disabled = busy || !country;
	});
}

function showConfirmationModal(title, lines) {
	return new Promise(function(resolve) {
		const body = [
			E('p', {}, lines[0])
		];

		if (lines[1])
			body.push(E('p', {}, lines[1]));

		body.push(E('div', { class: 'right' }, [
				E('button', {
					class: 'btn',
					click: function() {
						ui.hideModal();
						resolve(false);
					}
				}, [ _('Cancel') ]),
				' ',
				E('button', {
					class: 'btn cbi-button-apply',
					click: function() {
						ui.hideModal();
						resolve(true);
					}
				}, [ _('Apply') ])
			])
			);

		ui.showModal(title, body);
	});
}

function parseExecJsonResponse(res, fallback) {
	if (!res || res.code !== 0)
		return fallback;

	return parseJson(res.stdout || '', fallback);
}

function loadServerCatalog(country, forceRefresh) {
	const args = [ 'server_catalog', country || '' ];

	if (!country) {
		currentServerCatalog = emptyServerCatalog();
		serverCatalogIndex = {};
		renderServerChoices(getSelectElement(SERVER_FIELD_ID), currentServerCatalog, '');
		updateServerSelectionState();
		return Promise.resolve(currentServerCatalog);
	}

	if (forceRefresh)
		args.push('1');

	return fs.exec('/etc/init.d/nordvpn-easy', args).then(function(res) {
		let message;

		if (res.code !== 0) {
			message = (res.stderr || '').trim() || _('Server catalog refresh failed.');
			throw new Error(message);
		}

		currentServerCatalog = parseServerCatalog(res.stdout || '');
		serverCatalogIndex = buildServerCatalogIndex(currentServerCatalog);
		renderServerChoices(getSelectElement(SERVER_FIELD_ID), currentServerCatalog, getSelectedPreferredStation());
		updateServerSelectionState();
		return currentServerCatalog;
	});
}

const CountrySelectValue = form.ListValue.extend({
	refreshCountries: function(buttonEl, section_id) {
		buttonEl.disabled = true;

		return fs.exec('/etc/init.d/nordvpn-easy', [ 'refresh_countries_force' ]).then(function(res) {
			let message;

			if (res.code !== 0) {
				message = res.stderr ? res.stderr.trim() : _('Country refresh failed.');
				throw new Error(_('Country refresh failed with exit code %d: %s').format(res.code, message));
			}

			return fs.read(COUNTRIES_CACHE_PATH);
		}.bind(this)).then(function(countriesRaw) {
			const selectEl = getSelectElement(this.cbid(section_id));
			const currentCountry = selectEl ? normalizeCountryCode(selectEl.value) : '';
			const countries = parseCountries(countriesRaw);

			renderCountryChoices(selectEl, countries, currentCountry);
			ui.addNotification(null, E('p', _('Country list refreshed.')), 'info');
		}.bind(this)).catch(function(err) {
			ui.addNotification(null, E('p', err.message), 'error');
		}).finally(function() {
			buttonEl.disabled = false;
		});
	},

	renderWidget: function(section_id, option_index, cfgvalue) {
		const choices = this.transformChoices();
		const widget = new ui.Select((cfgvalue != null) ? cfgvalue : this.default, choices, {
			id: this.cbid(section_id),
			size: this.size,
			sort: this.keylist,
			widget: this.widget,
			optional: this.optional,
			orientation: this.orientation,
			placeholder: this.placeholder,
			validate: (typeof this.getValidator === 'function') ? this.getValidator(section_id) : null,
			disabled: (this.readonly != null) ? this.readonly : this.map.readonly
		});

		return E('div', {
			style: 'display:inline-flex;gap:0.5rem;align-items:center;flex-wrap:wrap;max-width:100%;'
		}, [
			E('div', { style: 'display:inline-block;width:18rem;max-width:100%;' }, [ widget.render() ]),
			E('button', {
				id: COUNTRY_REFRESH_BUTTON_ID,
				class: 'cbi-button cbi-button-action',
				type: 'button',
				click: ui.createHandlerFn(this, function(section_id, ev) {
					ev.preventDefault();
					return this.refreshCountries(ev.currentTarget, section_id);
				}, section_id),
				disabled: (this.readonly != null) ? this.readonly : this.map.readonly
			}, [ _('Refresh Countries') ])
		]);
	}
});

function runServiceAction(action) {
	return fs.exec('/etc/init.d/nordvpn-easy', [ action ]).then(function(res) {
		const lines = [];

		if (res.stdout)
			lines.push(res.stdout.trim());

		if (res.stderr)
			lines.push(res.stderr.trim());

		return {
			action: action,
			code: res.code,
			message: lines.filter(function(line) {
				return line;
			}).join('\n') || _('Command completed.')
		};
	}).catch(function(err) {
		return {
			action: action,
			code: -1,
			message: (err && err.message) ? err.message : String(err)
		};
	});
}

function runServiceActions(actions) {
	const results = [];

	return actions.reduce(function(chain, action) {
		return chain.then(function() {
			return runServiceAction(action).then(function(result) {
				results.push(result);
			});
		});
	}, Promise.resolve()).then(function() {
		return results;
	});
}

function summarizeActionFailures(results) {
	return results.filter(function(result) {
		return result.code !== 0;
	}).map(function(result) {
		return _('%s failed with exit code %d: %s').format(result.action, result.code, result.message);
	}).join('\n');
}

function updatePublicIp() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'public_ip' ]).then(function(res) {
		const publicIp = res.stdout ? res.stdout.trim() : '';

		replaceStatusText(PUBLIC_IP_STATUS_ID,
			(res.code === 0 && publicIp && publicIp !== 'null' && publicIp !== 'undefined') ? publicIp : _('Unavailable'));
	}).catch(function() {
		replaceStatusText(PUBLIC_IP_STATUS_ID, _('Unavailable'));
	});
}

function updatePublicCountry() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'public_country' ]).then(function(res) {
		const publicCountry = normalizeCountryCode(res.stdout ? res.stdout.trim() : '');

		currentPublicCountry = (res.code === 0 && publicCountry) ? publicCountry : '';
		replaceStatusText(PUBLIC_COUNTRY_STATUS_ID, currentPublicCountry || _('Unavailable'));
		updateCountryMatchStatus();
	}).catch(function() {
		currentPublicCountry = '';
		replaceStatusText(PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
		updateCountryMatchStatus();
	});
}

function updateLocalStatus() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'status_json' ]).then(function(res) {
		let busyAction;

		currentLocalStatus = parseExecJsonResponse(res, parseLocalStatus('{}'));
		currentOperationStatus = String(currentLocalStatus.operation_status || 'idle');
		appliedEnabled = !!currentLocalStatus.enabled;
		appliedCountryCode = normalizeCountryCode(currentLocalStatus.selected_country || appliedCountryCode);

		replaceStatusText(CURRENT_SERVER_STATUS_ID, currentServerSummaryFromStatus(currentLocalStatus));
		replaceStatusText(PREFERRED_SERVER_STATUS_ID, preferredServerSummaryFromStatus(currentLocalStatus));
		replaceStatusText(ENDPOINT_STATUS_ID, currentLocalStatus.endpoint || _('Unavailable'));
		replaceStatusText(HANDSHAKE_STATUS_ID, currentLocalStatus.latest_handshake || _('Never'));
		replaceStatusText(TRANSFER_STATUS_ID,
			_('%s / %s').format(currentLocalStatus.transfer_rx || '0 B', currentLocalStatus.transfer_tx || '0 B'));

		if (currentOperationStatus.indexOf('busy:') === 0) {
			busyAction = currentOperationStatus.substring(5);
			replaceStatusText(OPERATION_STATUS_ID, _('Applying (%s)...').format(humanizeAction(busyAction)));
			setManagerControlsDisabled(true);

			if (busyAction !== 'refresh_countries' && busyAction !== 'server_catalog') {
				setVpnStatusIndicator('activating', _('Activating'));
				updateCountryMatchStatus();
				updateServerSelectionState();
				return;
			}
		}
		else if (currentOperationStatus === 'busy') {
			replaceStatusText(OPERATION_STATUS_ID, _('Applying...'));
			setVpnStatusIndicator('activating', _('Activating'));
			setManagerControlsDisabled(true);
			updateCountryMatchStatus();
			updateServerSelectionState();
			return;
		}

		if (pendingOperationLabel) {
			replaceStatusText(OPERATION_STATUS_ID, _('Applying (%s)...').format(humanizeAction(pendingOperationLabel)));
			setVpnStatusIndicator('activating', _('Activating'));
			setManagerControlsDisabled(true);
		}
		else if (currentOperationStatus !== 'busy' && currentOperationStatus.indexOf('busy:') !== 0) {
			replaceStatusText(OPERATION_STATUS_ID, _('Idle'));
			setManagerControlsDisabled(false);
		}

		if (currentLocalStatus.connected || currentLocalStatus.vpn_status === 'active')
			setVpnStatusIndicator('active', _('Connected'));
		else
			setVpnStatusIndicator('inactive', _('Disconnected'));

		updateCountryMatchStatus();
		updateServerSelectionState();
	}).catch(function() {
		currentOperationStatus = pendingOperationLabel ? ('busy:' + pendingOperationLabel) : 'unknown';
		replaceStatusText(OPERATION_STATUS_ID, pendingOperationLabel ? _('Applying (%s)...').format(humanizeAction(pendingOperationLabel)) : _('Unknown'));
		setVpnStatusIndicator(pendingOperationLabel ? 'activating' : 'inactive',
			pendingOperationLabel ? _('Activating') : _('Disconnected'));
		if (!pendingOperationLabel)
			setManagerControlsDisabled(false);
		updateCountryMatchStatus();
		updateServerSelectionState();
	});
}

function onCountryChanged() {
	const country = getSelectedCountry();
	const selectEl = getSelectElement(SERVER_FIELD_ID);

	if (selectEl)
		selectEl.value = '';

	if (!country) {
		currentServerCatalog = emptyServerCatalog();
		serverCatalogIndex = {};
		renderServerChoices(selectEl, currentServerCatalog, '');
		updateServerSelectionState();
		return Promise.resolve();
	}

	currentServerCatalog = emptyServerCatalog();
	serverCatalogIndex = {};
	renderServerChoices(selectEl, currentServerCatalog, '');
	updateServerSelectionState();

	return loadServerCatalog(country, false).catch(function(err) {
		ui.addNotification(null, E('p', err.message), 'error');
	});
}

function onModeChanged() {
	if (getSelectedMode() !== 'manual') {
		const selectEl = getSelectElement(SERVER_FIELD_ID);

		if (selectEl)
			selectEl.value = '';
	}

	updateServerSelectionState();
}

function renderStatusSection() {
	return E('div', { class: 'table-wrapper' }, [
		E('table', { class: 'table' }, [
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'width: 30%; font-weight: bold' }, [ _('Connection') ]),
				E('td', { class: 'td left' }, [ E('span', { id: VPN_STATUS_ID }, [ _('Collecting data...') ]) ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Current Server') ]),
				E('td', { class: 'td left', id: CURRENT_SERVER_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Preferred Server') ]),
				E('td', { class: 'td left', id: PREFERRED_SERVER_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Endpoint') ]),
				E('td', { class: 'td left', id: ENDPOINT_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Latest Handshake') ]),
				E('td', { class: 'td left', id: HANDSHAKE_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Transfer (RX / TX)') ]),
				E('td', { class: 'td left', id: TRANSFER_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Operation Status') ]),
				E('td', { class: 'td left', id: OPERATION_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Public IP') ]),
				E('td', { class: 'td left', id: PUBLIC_IP_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Public Country') ]),
				E('td', { class: 'td left', id: PUBLIC_COUNTRY_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Country Match') ]),
				E('td', { class: 'td left' }, [ E('span', { id: COUNTRY_MATCH_STATUS_ID }, [ _('Checking') ]) ])
			])
		])
	]);
}

function renderActionBar(viewInstance) {
	return E('div', { id: ACTION_BAR_ID, class: 'cbi-page-actions' }, [
		E('button', {
			id: SERVER_REFRESH_BUTTON_ID_TOP,
			class: 'btn cbi-button cbi-button-action',
			type: 'button',
			click: ui.createHandlerFn(viewInstance, 'handleRefreshServerCatalog')
		}, [ _('Refresh Server List') ]),
		' ',
		E('button', {
			class: 'btn cbi-button cbi-button-apply',
			type: 'button',
			click: ui.createHandlerFn(viewInstance, function(ev) {
				return this.handleSaveApply(ev, '0');
			})
		}, [ _('Save & Apply') ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec('/etc/init.d/nordvpn-easy', [ 'refresh_countries' ]), null),
			L.resolveDefault(fs.read(COUNTRIES_CACHE_PATH), '[]'),
			uci.load('nordvpn_easy')
		]).then(function(results) {
			const configuredCountry = normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
			const statusPromise = L.resolveDefault(fs.exec('/etc/init.d/nordvpn-easy', [ 'status_json' ]), null);
			const catalogPromise = configuredCountry
				? L.resolveDefault(fs.exec('/etc/init.d/nordvpn-easy', [ 'server_catalog', configuredCountry ]), null)
				: Promise.resolve(null);

			return Promise.all([ Promise.resolve(results[1]), statusPromise, catalogPromise ]);
		});
	},

	handleRefreshServerCatalog: function(ev) {
		const country = getSelectedCountry();
		const button = ev ? ev.currentTarget : document.getElementById(SERVER_REFRESH_BUTTON_ID_TOP);

		if (!country) {
			ui.addNotification(null, E('p', _('Select a country before refreshing the server catalog.')), 'warning');
			return Promise.resolve();
		}

		if (button)
			button.disabled = true;

		ui.showModal(_('Refreshing Server List'), [
			E('p', { class: 'spinning' }, _('Downloading the NordVPN WireGuard server catalog...'))
		]);

		return loadServerCatalog(country, true).then(function() {
			ui.addNotification(null, E('p', _('Server catalog refreshed.')), 'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p', err.message), 'error');
		}).finally(function() {
			ui.hideModal();
			if (button)
				button.disabled = false;
			updateServerSelectionState();
		});
	},

	render: function(data) {
		const countries = parseCountries(data[0]);
		const initialStatus = parseExecJsonResponse(data[1], parseLocalStatus('{}'));
		const initialCatalog = data[2] ? parseExecJsonResponse(data[2], emptyServerCatalog()) : emptyServerCatalog();
		const currentCountry = normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
		const currentMode = String(uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto');
		const currentPreferredStation = String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '');
		let m, s, o;

		this.initialEnabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
		this.initialCountry = currentCountry;
		this.initialMode = currentMode;
		this.initialPreferredStation = currentPreferredStation;

		appliedEnabled = this.initialEnabled;
		appliedCountryCode = currentCountry;
		currentLocalStatus = initialStatus;
		currentOperationStatus = String(initialStatus.operation_status || 'idle');
		currentServerCatalog = parseServerCatalog(JSON.stringify(initialCatalog));
		serverCatalogIndex = buildServerCatalogIndex(currentServerCatalog);

		m = new form.Map('nordvpn_easy', _('NordVPN Easy'),
			_('Manage NordVPN Easy connection, manual server selection and runtime status.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Connection Status'));
		s.anonymous = true;
		s.addremove = false;
		s.render = function() {
			return E('div', { class: 'cbi-section' }, [
				E('div', { class: 'cbi-section-node' }, [ renderStatusSection() ])
			]);
		};

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Setup'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'nordvpn_token', _('NordVPN Token'));
		o.password = true;
		o.rmempty = false;
		o.description = _('Required. NordVPN access token.');

		o = s.option(CountrySelectValue, 'vpn_country', _('Server Country'));
		o.value('', _('Automatic'));
		o.rmempty = true;
		o.description = _('Choose a country or leave automatic mode for best recommended servers.');
		countries.forEach(function(country) {
			const value = String(country.code);
			o.value(value, _('%s (%s)').format(country.name, value));
		});

		o = s.option(form.ListValue, 'server_selection_mode', _('Server Selection Mode'));
		o.value('auto', _('Automatic / Best recommended'));
		o.value('manual', _('Manual preferred server'));
		o.default = 'auto';
		o.rmempty = false;
		o.description = _('Manual mode is rigid during health checks and requires a country and preferred server.');

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Server Selection'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_server_catalog_status', _('Catalog Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(SERVER_CATALOG_STATUS_ID, _('Collecting data...'));
		};

		o = s.option(form.ListValue, 'preferred_server_station', _('Preferred Server'));
		o.value('', _('-- Select Server --'));
		o.default = currentPreferredStation;
		o.rmempty = true;
		o.depends('server_selection_mode', 'manual');
		o.description = _('Label format: Country - City - Hostname - Load%.');
		currentServerCatalog.servers.forEach(function(server) {
			o.value(String(server.station), formatServerLabel(server));
		});

		o = s.option(form.DummyValue, '_server_selection_hint', _('Selection Behaviour'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(SERVER_SELECTION_HINT_ID, _('Collecting data...'));
		};

		o = s.option(form.Button, '_refresh_servers', _('Refresh Server List'));
		o.inputstyle = 'apply';
		o.onclick = ui.createHandlerFn(this, function(ev) {
			return this.handleRefreshServerCatalog(ev);
		});
		o.inputtitle = _('Refresh Server List');

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Cache'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'server_cache_enabled', _('Enable Server Catalog Cache'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Cache the NordVPN manual server catalog for the selected country.');

		o = s.option(form.Value, 'server_cache_ttl', _('Server Catalog Cache TTL'));
		o.datatype = 'uinteger';
		o.placeholder = '86400';
		o.rmempty = false;
		o.depends('server_cache_enabled', '1');
		o.description = _('How long to keep the manual server catalog before refreshing it again.');

		return m.render().then(function(node) {
			const countrySelect = getSelectElement(COUNTRY_FIELD_ID);
			const modeSelect = getSelectElement(MODE_FIELD_ID);

			node.appendChild(renderActionBar(this));

			renderServerChoices(getSelectElement(SERVER_FIELD_ID), currentServerCatalog, currentPreferredStation);
			updateLocalStatus();
			updatePublicIp();
			updatePublicCountry();
			updateServerSelectionState();

			if (countrySelect) {
				countrySelect.addEventListener('change', function() {
					onCountryChanged();
				});
			}

			if (modeSelect) {
				modeSelect.addEventListener('change', function() {
					onModeChanged();
				});
			}

			poll.add(function() {
				return updateLocalStatus();
			}, 2);

			poll.add(function() {
				return updatePublicIp();
			}, 10);

			poll.add(function() {
				return updatePublicCountry();
			}, 30);

			return node;
		}.bind(this));
	},

	handleSaveApply: function(ev, mode) {
		const previousEnabled = !!this.initialEnabled;
		const previousCountry = this.initialCountry || '';
		const previousMode = this.initialMode || 'auto';
		const previousPreferredStation = this.initialPreferredStation || '';
		const currentMode = getSelectedMode();
		const currentCountry = getSelectedCountry();
		const preferredStation = getSelectedPreferredStation();
		const selectedServer = serverCatalogIndex[preferredStation];
		let confirmationPromise = Promise.resolve(true);

		if (currentMode === 'manual') {
			if (!currentCountry) {
				ui.addNotification(null, E('p', _('Manual mode requires a selected country.')), 'error');
				return Promise.resolve();
			}

			if (!preferredStation || !selectedServer) {
				ui.addNotification(null, E('p', _('Manual mode requires a valid preferred server from the current catalog.')), 'error');
				return Promise.resolve();
			}

			uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', selectedServer.hostname);
			uci.set('nordvpn_easy', 'main', 'preferred_server_station', preferredStation);
		}
		else {
			uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', '');
			uci.set('nordvpn_easy', 'main', 'preferred_server_station', '');
		}

		if (previousEnabled && getEnabledCheckboxElement() && !getEnabledCheckboxElement().checked) {
			confirmationPromise = showConfirmationModal(
				_('Disable NordVPN Easy'),
				[
					_('Disabling NordVPN Easy will stop the VPN interface and remove cron/hotplug hooks.'),
					_('Your current VPN connection will be interrupted.')
				]
			);
		}
		else if (previousEnabled && (
			previousCountry !== currentCountry ||
			previousMode !== currentMode ||
			(currentMode === 'manual' && previousPreferredStation !== preferredStation)
		)) {
			confirmationPromise = showConfirmationModal(
				_('Confirm Server Change'),
				[
					_('Applying these changes will briefly interrupt the VPN connection while NordVPN Easy reconfigures the tunnel.'),
					currentMode === 'manual' && selectedServer
						? _('Preferred server: %s').format(formatServerLabel(selectedServer))
						: _('Automatic mode will use NordVPN recommended servers.')
				]
			);
		}

		return confirmationPromise.then(function(confirmed) {
			if (!confirmed)
				return;

			return this.handleSave(ev).then(function() {
				return new Promise(function(resolve, reject) {
					let settled = false;

					const cleanup = function() {
						if (this._uciAppliedHandler) {
							document.removeEventListener('uci-applied', this._uciAppliedHandler);
							this._uciAppliedHandler = null;
						}
					}.bind(this);

					const finishResolve = function(value) {
						if (settled)
							return;

						settled = true;
						cleanup();
						resolve(value);
					};

					const finishReject = function(err) {
						if (settled)
							return;

						settled = true;
						cleanup();
						reject(err);
					};

					cleanup();

					this._uciAppliedHandler = function() {
						Promise.resolve().then(function() {
							uci.unload('nordvpn_easy');
							return uci.load('nordvpn_easy');
						}).then(function() {
							const enabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
							const country = normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
							const modeValue = String(uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto');
							const preferred = String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '');
							let actions = [];
							let successMessage = '';

							this.initialEnabled = enabled;
							this.initialCountry = country;
							this.initialMode = modeValue;
							this.initialPreferredStation = preferred;
							appliedEnabled = enabled;
							appliedCountryCode = country;

							if (!previousEnabled && enabled) {
								actions = [ 'setup', 'install_hooks' ];
								successMessage = _('NordVPN Easy enabled: setup completed and hooks installed.');
							}
							else if (previousEnabled && !enabled) {
								actions = [ 'disable_runtime' ];
								successMessage = _('NordVPN Easy disabled: VPN interface stopped and hooks removed.');
							}
							else if (enabled && (
								previousCountry !== country ||
								previousMode !== modeValue ||
								(modeValue === 'manual' && previousPreferredStation !== preferred)
							)) {
								actions = [ 'setup' ];
								successMessage = modeValue === 'manual'
									? _('Manual preferred server updated and synchronized.')
									: _('NordVPN Easy synchronized the automatic server selection.');
							}

							if (!actions.length) {
								pendingOperationLabel = '';
								updateLocalStatus();
								finishResolve();
								return;
							}

							pendingOperationLabel = formatActionsLabel(actions);
							currentOperationStatus = 'busy:' + pendingOperationLabel;
							updateLocalStatus();

							runServiceActions(actions).then(function(results) {
								const failures = summarizeActionFailures(results);

								if (failures) {
									ui.addNotification(null, E('p', failures), 'error');
									finishReject(new Error(failures));
									return;
								}

								ui.addNotification(null, E('p', successMessage), 'info');
								finishResolve();
							}).catch(function(err) {
								finishReject(err);
							}).finally(function() {
								pendingOperationLabel = '';
								updateLocalStatus();
								updatePublicIp();
								updatePublicCountry();
							});
						}.bind(this)).catch(function(err) {
							const message = (err && err.message) ? err.message : String(err);

							ui.addNotification(null, E('p', _('Automatic runtime sync failed: ') + message), 'error');
							finishReject(err);
						});
					}.bind(this);

					document.addEventListener('uci-applied', this._uciAppliedHandler);
					pendingOperationLabel = _('configuration');
					currentOperationStatus = 'busy:configuration';
					updateLocalStatus();
					Promise.resolve(ui.changes.apply(mode === '0')).catch(function(err) {
						finishReject(err);
					});
				}.bind(this));
			}.bind(this));
		}.bind(this));
	}
});
