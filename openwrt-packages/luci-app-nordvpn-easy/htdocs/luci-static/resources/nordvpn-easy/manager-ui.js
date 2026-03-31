'use strict';
'require baseclass';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require ui';

const ids = {
	ENABLED_FIELD_ID: 'cbid.nordvpn_easy.main.enabled',
	TOKEN_FIELD_ID: 'cbid.nordvpn_easy.main.nordvpn_token',
	COUNTRY_FIELD_ID: 'cbid.nordvpn_easy.main.vpn_country',
	COUNTRY_REFRESH_BUTTON_ID: 'cbid.nordvpn_easy.main.vpn_country.refresh',
	MODE_FIELD_ID: 'cbid.nordvpn_easy.main.server_selection_mode',
	SERVER_FIELD_ID: 'cbid.nordvpn_easy.main.preferred_server_station',
	SERVER_REFRESH_BUTTON_ID: 'cbid.nordvpn_easy.main._refresh_servers',
	VPN_STATUS_ID: 'nordvpn-easy-vpn-status',
	CURRENT_SERVER_STATUS_ID: 'nordvpn-easy-current-server-status',
	PREFERRED_SERVER_STATUS_ID: 'nordvpn-easy-preferred-server-status',
	ENDPOINT_STATUS_ID: 'nordvpn-easy-endpoint-status',
	HANDSHAKE_STATUS_ID: 'nordvpn-easy-handshake-status',
	TRANSFER_STATUS_ID: 'nordvpn-easy-transfer-status',
	OPERATION_STATUS_ID: 'nordvpn-easy-operation-status',
	PUBLIC_IP_STATUS_ID: 'nordvpn-easy-public-ip-status',
	PUBLIC_COUNTRY_STATUS_ID: 'nordvpn-easy-public-country-status',
	COUNTRY_MATCH_STATUS_ID: 'nordvpn-easy-country-match-status',
	SERVER_CATALOG_STATUS_ID: 'nordvpn-easy-server-catalog-status',
	SERVER_SELECTION_HINT_ID: 'nordvpn-easy-server-selection-hint'
};

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
	return getInputElement(ids.ENABLED_FIELD_ID, 'input[type="checkbox"]');
}

function getSelectedCountry() {
	const selectEl = getSelectElement(ids.COUNTRY_FIELD_ID);

	return managerData.normalizeCountryCode(selectEl ? selectEl.value : '');
}

function getSelectedMode() {
	const selectEl = getSelectElement(ids.MODE_FIELD_ID);

	return String(selectEl ? selectEl.value : 'auto');
}

function getSelectedPreferredStation() {
	const selectEl = getSelectElement(ids.SERVER_FIELD_ID);

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
			managerFormat.formatServerLabel(server)
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

	setStatusIndicator(ids.VPN_STATUS_ID, color, label);
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

	setStatusIndicator(ids.COUNTRY_MATCH_STATUS_ID, color, label);
}

function replaceStatusText(elementId, value) {
	const element = document.getElementById(elementId);

	if (element)
		element.textContent = value;
}

function isDisableRequested(state) {
	const enabledCheckbox = getEnabledCheckboxElement();

	return !!(state && state.pendingOperationLabel && enabledCheckbox && !enabledCheckbox.checked);
}

function currentServerSummaryFromStatus(status, state) {
	if (!status)
		return _('Not configured');

	if (!status.enabled || status.interface_disabled || isDisableRequested(state))
		return _('Disabled');

	if (!status.current_server_station)
		return _('Not configured');

	return managerFormat.formatServerSummary({
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

	return managerFormat.formatServerSummary({
		hostname: status.preferred_server_hostname,
		station: status.preferred_server_station,
		country_code: status.selected_country
	});
}

function updateCountryMatchStatus(state) {
	let busyAction;
	const expectedCountry = managerData.normalizeCountryCode(state.appliedCountryCode);
	const actualCountry = managerData.normalizeCountryCode(state.currentPublicCountry);

	if (!state.appliedEnabled || state.currentLocalStatus.interface_disabled || isDisableRequested(state))
		return setCountryMatchIndicator('inactive', _('Inactive'));

	if (state.currentOperationStatus.indexOf('busy:') === 0) {
		busyAction = state.currentOperationStatus.substring(5);

		if (busyAction !== 'refresh_countries' && busyAction !== 'server_catalog')
			return setCountryMatchIndicator('checking', _('Checking'));
	}
	else if (state.currentOperationStatus === 'busy') {
		return setCountryMatchIndicator('checking', _('Checking'));
	}

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
		ids.ENABLED_FIELD_ID,
		ids.TOKEN_FIELD_ID,
		ids.COUNTRY_FIELD_ID,
		ids.COUNTRY_REFRESH_BUTTON_ID,
		ids.MODE_FIELD_ID,
		ids.SERVER_FIELD_ID,
		ids.SERVER_REFRESH_BUTTON_ID
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

	document.querySelectorAll('.cbi-page-actions button, .cbi-page-actions input[type="button"], .cbi-page-actions input[type="submit"]').forEach(function(el) {
		el.disabled = disabled;
	});
}

function updateServerCatalogStatus(state) {
	let text;
	let freshness = '';
	const mode = getSelectedMode();
	const country = getSelectedCountry();
	const selectionHintEl = document.getElementById(ids.SERVER_SELECTION_HINT_ID);
	const statusEl = document.getElementById(ids.SERVER_CATALOG_STATUS_ID);

	if (!country) {
		text = _('Select a country to load the manual server catalog.');
	}
	else if (!state.currentServerCatalog.servers.length) {
		text = _('No server catalog loaded for %s yet.').format(country);
	}
	else {
		text = _('%d servers cached for %s').format(
			state.currentServerCatalog.servers.length,
			state.currentServerCatalog.country_name || state.currentServerCatalog.country_code || country
		);

		if (state.currentServerCatalog.cached_at)
			freshness = managerFormat.formatRelativeTimestamp(state.currentServerCatalog.cached_at);

		if (freshness)
			text += _(' (refreshed %s)').format(freshness);
	}

	if (statusEl)
		statusEl.textContent = text;

	if (selectionHintEl) {
		if (mode !== 'manual')
			selectionHintEl.textContent = _('Automatic mode uses NordVPN recommended servers for the selected country.');
		else if (!country)
			selectionHintEl.textContent = _('Manual mode requires a country and a preferred server.');
		else if (!state.currentServerCatalog.servers.length)
			selectionHintEl.textContent = _('Use "Refresh Server List" to fetch the NordVPN catalog for the selected country.');
		else
			selectionHintEl.textContent = _('Manual mode is rigid during health checks. Rotate updates the saved preferred server.');
	}
}

function updateServerSelectionState(state) {
	const mode = getSelectedMode();
	const country = getSelectedCountry();
	const busy = state.currentOperationStatus.indexOf('busy') === 0;
	const selectEl = getSelectElement(ids.SERVER_FIELD_ID);
	const refreshButton = getInputElement(ids.SERVER_REFRESH_BUTTON_ID, 'button');

	updateServerCatalogStatus(state);

	if (selectEl)
		selectEl.disabled = busy || mode !== 'manual' || !country || !state.currentServerCatalog.servers.length;

	if (refreshButton)
		refreshButton.disabled = busy || !country;
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
		]));

		ui.showModal(title, body);
	});
}

function renderStatusSection() {
	return E('div', { class: 'table-wrapper' }, [
		E('table', { class: 'table' }, [
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'width: 30%; font-weight: bold' }, [ _('Connection') ]),
				E('td', { class: 'td left' }, [ E('span', { id: ids.VPN_STATUS_ID }, [ _('Collecting data...') ]) ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Current Server') ]),
				E('td', { class: 'td left', id: ids.CURRENT_SERVER_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Preferred Server') ]),
				E('td', { class: 'td left', id: ids.PREFERRED_SERVER_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Endpoint') ]),
				E('td', { class: 'td left', id: ids.ENDPOINT_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Last WireGuard Handshake') ]),
				E('td', { class: 'td left', id: ids.HANDSHAKE_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Tunnel Activity (RX / TX)') ]),
				E('td', { class: 'td left', id: ids.TRANSFER_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Operation Status') ]),
				E('td', { class: 'td left', id: ids.OPERATION_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Public IP') ]),
				E('td', { class: 'td left', id: ids.PUBLIC_IP_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Public Country') ]),
				E('td', { class: 'td left', id: ids.PUBLIC_COUNTRY_STATUS_ID }, [ _('Collecting data...') ])
			]),
			E('tr', { class: 'tr' }, [
				E('td', { class: 'td left', style: 'font-weight: bold' }, [ _('Country Match') ]),
				E('td', { class: 'td left' }, [ E('span', { id: ids.COUNTRY_MATCH_STATUS_ID }, [ _('Checking') ]) ])
			])
		])
	]);
}

return baseclass.extend({
	ids: ids,
	getSelectElement: getSelectElement,
	getInputElement: getInputElement,
	getEnabledCheckboxElement: getEnabledCheckboxElement,
	getSelectedCountry: getSelectedCountry,
	getSelectedMode: getSelectedMode,
	getSelectedPreferredStation: getSelectedPreferredStation,
	renderCountryChoices: renderCountryChoices,
	renderServerChoices: renderServerChoices,
	setVpnStatusIndicator: setVpnStatusIndicator,
	setCountryMatchIndicator: setCountryMatchIndicator,
	replaceStatusText: replaceStatusText,
	isDisableRequested: isDisableRequested,
	currentServerSummaryFromStatus: currentServerSummaryFromStatus,
	preferredServerSummaryFromStatus: preferredServerSummaryFromStatus,
	updateCountryMatchStatus: updateCountryMatchStatus,
	setManagerControlsDisabled: setManagerControlsDisabled,
	updateServerCatalogStatus: updateServerCatalogStatus,
	updateServerSelectionState: updateServerSelectionState,
	showConfirmationModal: showConfirmationModal,
	renderStatusSection: renderStatusSection
});
