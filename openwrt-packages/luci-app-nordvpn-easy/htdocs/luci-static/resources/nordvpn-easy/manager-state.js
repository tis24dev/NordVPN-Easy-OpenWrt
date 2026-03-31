'use strict';
'require baseclass';
'require fs';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require nordvpn-easy/manager-ui as managerUI';
'require nordvpn-easy/service as service';
'require ui';
'require uci';

function createState() {
	return {
		pendingOperationLabel: '',
		currentOperationStatus: 'idle',
		currentPublicCountry: '',
		appliedEnabled: false,
		appliedCountryCode: '',
		currentLocalStatus: managerData.parseLocalStatus('{}'),
		currentServerCatalog: managerData.emptyServerCatalog(),
		serverCatalogIndex: {},
		latestServerCatalogRequestId: 0
	};
}

function loadServerCatalog(state, country, forceRefresh) {
	const requestId = ++state.latestServerCatalogRequestId;
	const requestedCountry = managerData.normalizeCountryCode(country || '');
	const extraArgs = [ country || '' ];

	if (!country) {
		state.currentServerCatalog = managerData.emptyServerCatalog();
		state.serverCatalogIndex = {};
		managerUI.renderServerChoices(managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID), state.currentServerCatalog, '');
		managerUI.updateServerSelectionState(state);
		return Promise.resolve(state.currentServerCatalog);
	}

	if (forceRefresh)
		extraArgs.push('1');

	return service.execService('server_catalog', extraArgs).then(function(res) {
		let message;
		let parsedCatalog;

		if (requestId !== state.latestServerCatalogRequestId || requestedCountry !== managerUI.getSelectedCountry())
			return null;

		if (res.code !== 0) {
			message = (res.stderr || '').trim() || _('Server catalog refresh failed.');
			throw new Error(message);
		}

		parsedCatalog = managerData.parseServerCatalog(res.stdout || '');
		state.currentServerCatalog = parsedCatalog;
		state.serverCatalogIndex = managerData.buildServerCatalogIndex(parsedCatalog);
		managerUI.renderServerChoices(
			managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID),
			parsedCatalog,
			managerUI.getSelectedPreferredStation()
		);
		managerUI.updateServerSelectionState(state);
		return state.currentServerCatalog;
	});
}

function updatePublicIp() {
	return service.execService('public_ip').then(function(res) {
		const publicIp = res.stdout ? res.stdout.trim() : '';

		managerUI.replaceStatusText(
			managerUI.ids.PUBLIC_IP_STATUS_ID,
			(res.code === 0 && publicIp && publicIp !== 'null' && publicIp !== 'undefined') ? publicIp : _('Unavailable')
		);
	}).catch(function() {
		managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
	});
}

function updatePublicCountry(state) {
	return service.execService('public_country').then(function(res) {
		const publicCountry = managerData.normalizeCountryCode(res.stdout ? res.stdout.trim() : '');

		state.currentPublicCountry = (res.code === 0 && publicCountry) ? publicCountry : '';
		managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, state.currentPublicCountry || _('Unavailable'));
		managerUI.updateCountryMatchStatus(state);
	}).catch(function() {
		state.currentPublicCountry = '';
		managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
		managerUI.updateCountryMatchStatus(state);
	});
}

function updateLocalStatus(state) {
	return service.execService('status_json').then(function(res) {
		let busyAction;

		state.currentLocalStatus = service.parseExecJsonResponse(res, managerData.parseLocalStatus('{}'));
		state.currentOperationStatus = String(state.currentLocalStatus.operation_status || 'idle');
		state.appliedEnabled = !!state.currentLocalStatus.enabled;
		state.appliedCountryCode = managerData.normalizeCountryCode(state.currentLocalStatus.selected_country || state.appliedCountryCode);

		managerUI.replaceStatusText(managerUI.ids.CURRENT_SERVER_STATUS_ID, managerUI.currentServerSummaryFromStatus(state.currentLocalStatus, state));
		managerUI.replaceStatusText(managerUI.ids.PREFERRED_SERVER_STATUS_ID, managerUI.preferredServerSummaryFromStatus(state.currentLocalStatus));
		managerUI.replaceStatusText(managerUI.ids.ENDPOINT_STATUS_ID, state.currentLocalStatus.endpoint || _('Unavailable'));
		managerUI.replaceStatusText(managerUI.ids.HANDSHAKE_STATUS_ID, state.currentLocalStatus.latest_handshake || _('Never'));
		managerUI.replaceStatusText(
			managerUI.ids.TRANSFER_STATUS_ID,
			_('%s / %s').format(state.currentLocalStatus.transfer_rx || '0 B', state.currentLocalStatus.transfer_tx || '0 B')
		);

		if (state.currentOperationStatus.indexOf('busy:') === 0) {
			busyAction = state.currentOperationStatus.substring(5);
			managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying (%s)...').format(managerFormat.humanizeAction(busyAction)));
			managerUI.setManagerControlsDisabled(true);

			if (busyAction !== 'refresh_countries' && busyAction !== 'server_catalog') {
				managerUI.setVpnStatusIndicator(
					managerUI.isDisableRequested(state) ? 'inactive' : 'activating',
					managerUI.isDisableRequested(state) ? _('Disabled') : _('Activating')
				);
				managerUI.updateCountryMatchStatus(state);
				managerUI.updateServerSelectionState(state);
				return;
			}
		}
		else if (state.currentOperationStatus === 'busy') {
			managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying...'));
			managerUI.setVpnStatusIndicator(
				managerUI.isDisableRequested(state) ? 'inactive' : 'activating',
				managerUI.isDisableRequested(state) ? _('Disabled') : _('Activating')
			);
			managerUI.setManagerControlsDisabled(true);
			managerUI.updateCountryMatchStatus(state);
			managerUI.updateServerSelectionState(state);
			return;
		}

		if (state.pendingOperationLabel) {
			managerUI.replaceStatusText(
				managerUI.ids.OPERATION_STATUS_ID,
				_('Applying (%s)...').format(managerFormat.humanizeAction(state.pendingOperationLabel))
			);
			managerUI.setVpnStatusIndicator(
				managerUI.isDisableRequested(state) ? 'inactive' : 'activating',
				managerUI.isDisableRequested(state) ? _('Disabled') : _('Activating')
			);
			managerUI.setManagerControlsDisabled(true);
		}
		else if (state.currentOperationStatus !== 'busy' && state.currentOperationStatus.indexOf('busy:') !== 0) {
			managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Idle'));
			managerUI.setManagerControlsDisabled(false);
		}

		if (!state.currentLocalStatus.enabled || state.currentLocalStatus.interface_disabled || managerUI.isDisableRequested(state))
			managerUI.setVpnStatusIndicator('inactive', _('Disabled'));
		else if (state.currentLocalStatus.connected || state.currentLocalStatus.vpn_status === 'active')
			managerUI.setVpnStatusIndicator('active', _('Connected'));
		else
			managerUI.setVpnStatusIndicator('inactive', _('Disconnected'));

		managerUI.updateCountryMatchStatus(state);
		managerUI.updateServerSelectionState(state);
	}).catch(function() {
		state.currentOperationStatus = state.pendingOperationLabel ? ('busy:' + state.pendingOperationLabel) : 'unknown';
		managerUI.replaceStatusText(
			managerUI.ids.OPERATION_STATUS_ID,
			state.pendingOperationLabel ? _('Applying (%s)...').format(managerFormat.humanizeAction(state.pendingOperationLabel)) : _('Unknown')
		);
		managerUI.setVpnStatusIndicator(
			state.pendingOperationLabel ? 'activating' : 'inactive',
			state.pendingOperationLabel ? _('Activating') : _('Disconnected')
		);
		if (!state.pendingOperationLabel)
			managerUI.setManagerControlsDisabled(false);
		managerUI.updateCountryMatchStatus(state);
		managerUI.updateServerSelectionState(state);
	});
}

function onCountryChanged(state) {
	const country = managerUI.getSelectedCountry();
	const selectEl = managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID);

	if (selectEl)
		selectEl.value = '';

	if (!country) {
		state.latestServerCatalogRequestId++;
		state.currentServerCatalog = managerData.emptyServerCatalog();
		state.serverCatalogIndex = {};
		managerUI.renderServerChoices(selectEl, state.currentServerCatalog, '');
		managerUI.updateServerSelectionState(state);
		return Promise.resolve();
	}

	state.currentServerCatalog = managerData.emptyServerCatalog();
	state.serverCatalogIndex = {};
	managerUI.renderServerChoices(selectEl, state.currentServerCatalog, '');
	managerUI.updateServerSelectionState(state);

	return loadServerCatalog(state, country, false).catch(function(err) {
		service.notifyError(err);
	});
}

function onModeChanged(state) {
	if (managerUI.getSelectedMode() !== 'manual') {
		const selectEl = managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID);

		if (selectEl)
			selectEl.value = '';
	}

	managerUI.updateServerSelectionState(state);
}

function handleRefreshServerCatalog(state, ev) {
	const country = managerUI.getSelectedCountry();
	const button = ev ? ev.currentTarget : managerUI.getInputElement(managerUI.ids.SERVER_REFRESH_BUTTON_ID, 'button');

	if (!country) {
		ui.addNotification(null, E('p', _('Select a country before refreshing the server catalog.')), 'warning');
		return Promise.resolve();
	}

	if (button)
		button.disabled = true;

	ui.showModal(_('Refreshing Server List'), [
		E('p', { class: 'spinning' }, _('Downloading the NordVPN WireGuard server catalog...'))
	]);

	return loadServerCatalog(state, country, true).then(function(catalog) {
		if (catalog)
			service.notifyInfo(_('Server catalog refreshed.'));
	}).catch(function(err) {
		service.notifyError(err);
	}).finally(function() {
		ui.hideModal();
		if (button)
			button.disabled = false;
		managerUI.updateServerSelectionState(state);
	});
}

function formatDebugValue(value, fallback) {
	const normalized = String(value != null ? value : '').trim();

	return normalized || fallback || _('Automatic');
}

function buildSaveApplyDebugLines(previousEnabled, currentEnabled, previousCountry, currentCountry, previousMode, currentMode, previousPreferredStation, preferredStation, selectedServer) {
	const lines = [];
	const previousEnabledLabel = previousEnabled ? _('checked') : _('unchecked');
	const currentEnabledLabel = currentEnabled ? _('checked') : _('unchecked');
	const tokenField = managerUI.getInputElement(managerUI.ids.TOKEN_FIELD_ID, 'input');
	const existingToken = String(uci.get('nordvpn_easy', 'main', 'nordvpn_token') || '');
	const tokenFieldValue = String(tokenField && tokenField.value != null ? tokenField.value : '').trim();
	let tokenSourceLabel = _('missing');
	let preferredLabel = _('Automatic / Best recommended');

	if (selectedServer)
		preferredLabel = managerFormat.formatServerLabel(selectedServer);
	else if (preferredStation)
		preferredLabel = preferredStation;

	if (tokenFieldValue)
		tokenSourceLabel = _('provided in form');
	else if (existingToken)
		tokenSourceLabel = _('preserving saved token');

	if (previousEnabled !== currentEnabled)
		lines.push(_('Enabled: %s -> %s').format(previousEnabledLabel, currentEnabledLabel));
	else
		lines.push(_('Enabled unchanged: %s').format(currentEnabledLabel));

	if (previousCountry !== currentCountry)
		lines.push(_('Country: %s -> %s').format(formatDebugValue(previousCountry), formatDebugValue(currentCountry)));

	if (previousMode !== currentMode)
		lines.push(_('Server selection mode: %s -> %s').format(previousMode, currentMode));

	if (currentMode === 'manual' && previousPreferredStation !== preferredStation)
		lines.push(_('Preferred server: %s').format(preferredLabel));

	lines.push(_('Token handling: %s').format(tokenSourceLabel));

	return lines;
}

function notifyDebugBlock(title, lines) {
	if (!lines || !lines.length)
		return;

	ui.addNotification(null, E('div', [
		E('p', { style: 'font-weight:bold' }, [ title ])
	].concat(lines.map(function(line) {
		return E('p', line);
	}))), 'info');
}

function handleSaveApply(viewState, state, ev, mode) {
	const previousEnabled = !!viewState.initialEnabled;
	const previousCountry = viewState.initialCountry || '';
	const previousMode = viewState.initialMode || 'auto';
	const previousPreferredStation = viewState.initialPreferredStation || '';
	const currentEnabled = !!(managerUI.getEnabledCheckboxElement() && managerUI.getEnabledCheckboxElement().checked);
	const currentMode = managerUI.getSelectedMode();
	const currentCountry = managerUI.getSelectedCountry();
	const preferredStation = managerUI.getSelectedPreferredStation();
	const preferredStationChanged = (currentMode === 'manual' && preferredStation !== previousPreferredStation);
	const enteringManualMode = (currentMode === 'manual' && previousMode !== 'manual');
	const selectedServer = preferredStation ? state.serverCatalogIndex[preferredStation] : null;
	const debugLines = buildSaveApplyDebugLines(
		previousEnabled,
		currentEnabled,
		previousCountry,
		currentCountry,
		previousMode,
		currentMode,
		previousPreferredStation,
		preferredStation,
		selectedServer
	);
	const preservingExistingManualPreference = (
		currentMode === 'manual' &&
		previousMode === 'manual' &&
		!preferredStationChanged &&
		preferredStation === previousPreferredStation &&
		!!preferredStation
	);
	let confirmationPromise = Promise.resolve(true);

	if (currentMode === 'manual') {
		if (!currentCountry) {
			service.notifyError(new Error(_('Manual mode requires a selected country.')));
			return Promise.resolve();
		}

		if ((!preferredStation || !selectedServer) && !preservingExistingManualPreference) {
			service.notifyError(new Error(_('Manual mode requires a valid preferred server from the current catalog.')));
			return Promise.resolve();
		}

		if (preferredStationChanged || enteringManualMode) {
			uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', selectedServer.hostname);
			uci.set('nordvpn_easy', 'main', 'preferred_server_station', preferredStation);
		}
	}
	else {
		uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', '');
		uci.set('nordvpn_easy', 'main', 'preferred_server_station', '');
	}

	if (previousEnabled && managerUI.getEnabledCheckboxElement() && !managerUI.getEnabledCheckboxElement().checked) {
		confirmationPromise = managerUI.showConfirmationModal(
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
		confirmationPromise = managerUI.showConfirmationModal(
			_('Confirm Server Change'),
			[
				_('Applying these changes will briefly interrupt the VPN connection while NordVPN Easy reconfigures the tunnel.'),
				currentMode === 'manual'
					? (selectedServer
						? _('Preferred server: %s').format(managerFormat.formatServerLabel(selectedServer))
						: (preferredStation
							? _('Preferred server unchanged: %s').format(preferredStation)
							: _('Manual mode will keep the existing preferred server settings.')))
					: _('Automatic mode will use NordVPN recommended servers.')
			]
		);
	}

	return confirmationPromise.then(function(confirmed) {
		if (!confirmed)
			return;

		notifyDebugBlock(_('Save & Apply requested'), debugLines.concat([
			_('UCI changes are being committed before runtime actions start.')
		]));

		return viewState.handleSave(ev).then(function() {
			return new Promise(function(resolve, reject) {
				let settled = false;

				const cleanup = function() {
					if (viewState._uciAppliedHandler) {
						document.removeEventListener('uci-applied', viewState._uciAppliedHandler);
						viewState._uciAppliedHandler = null;
					}
				};

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

				viewState._uciAppliedHandler = function() {
					Promise.resolve().then(function() {
						uci.unload('nordvpn_easy');
						return uci.load('nordvpn_easy');
					}).then(function() {
						const enabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
						const country = managerData.normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
						const modeValue = String(uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto');
						const preferred = String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '');
						let actions = [];
						let successMessage = '';

						viewState.initialEnabled = enabled;
						viewState.initialCountry = country;
						viewState.initialMode = modeValue;
						viewState.initialPreferredStation = preferred;
						state.appliedEnabled = enabled;
						state.appliedCountryCode = country;

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
							notifyDebugBlock(_('Configuration applied'), [
								_('UCI changes were saved successfully.'),
								_('No runtime action was required.')
							]);
							state.pendingOperationLabel = '';
							updateLocalStatus(state);
							finishResolve();
							return;
						}

						state.pendingOperationLabel = managerFormat.formatActionsLabel(actions);
						state.currentOperationStatus = 'busy:' + state.pendingOperationLabel;
						notifyDebugBlock(_('Runtime actions queued'), [
							_('Executing: %s').format(state.pendingOperationLabel),
							_('Enabled state after save: %s').format(enabled ? _('checked') : _('unchecked'))
						]);
						updateLocalStatus(state);

						service.runActions(actions).then(function() {
							service.notifyInfo(successMessage);
							finishResolve();
						}).catch(function(err) {
							service.notifyError(err);
							finishReject(err);
						}).finally(function() {
							state.pendingOperationLabel = '';
							updateLocalStatus(state);
							updatePublicIp();
							updatePublicCountry(state);
						});
					}).catch(function(err) {
						const message = (err && err.message) ? err.message : String(err);

						service.notifyError(new Error(_('Automatic runtime sync failed: ') + message));
						finishReject(err);
					});
				};

				document.addEventListener('uci-applied', viewState._uciAppliedHandler);
				state.pendingOperationLabel = _('configuration');
				state.currentOperationStatus = 'busy:configuration';
				updateLocalStatus(state);
				Promise.resolve(ui.changes.apply(mode === '0')).catch(function(err) {
					finishReject(err);
				});
			});
		});
	});
}

return baseclass.extend({
	createState: createState,
	loadServerCatalog: loadServerCatalog,
	updatePublicIp: updatePublicIp,
	updatePublicCountry: updatePublicCountry,
	updateLocalStatus: updateLocalStatus,
	onCountryChanged: onCountryChanged,
	onModeChanged: onModeChanged,
	handleRefreshServerCatalog: handleRefreshServerCatalog,
	handleSaveApply: handleSaveApply
});
