'use strict';
/* global baseclass, managerData, managerFormat, managerStore, managerUI, service, ui, uci, Date, setTimeout, clearTimeout, E, _ */
'require baseclass';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require nordvpn-easy/manager-store as managerStore';
'require nordvpn-easy/manager-ui as managerUI';
'require nordvpn-easy/service as service';
'require ui';
'require uci';

const AUTO_RECONCILE_RETRY_DELAY_MS = 5 * 60 * 1000;

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
	const tokenFieldMasked = !!(tokenField && tokenField.getAttribute('data-token-masked') === '1');
	let tokenSourceLabel = _('missing');
	let preferredLabel = _('Automatic / Best recommended');

	if (selectedServer)
		preferredLabel = managerFormat.formatServerLabel(selectedServer);
	else if (preferredStation)
		preferredLabel = preferredStation;

	if (tokenFieldValue && !tokenFieldMasked && tokenFieldValue !== existingToken)
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

function normalizeSelectionMode(mode) {
	return String(mode || 'auto');
}

function hasServerSelectionChanged(previousCountry, currentCountry, previousMode, currentMode, previousPreferredStation, preferredStation) {
	if (managerData.normalizeCountryCode(previousCountry || '') !== managerData.normalizeCountryCode(currentCountry || ''))
		return true;

	if (normalizeSelectionMode(previousMode) !== normalizeSelectionMode(currentMode))
		return true;

	if (normalizeSelectionMode(currentMode) === 'manual' && String(previousPreferredStation || '') !== String(preferredStation || ''))
		return true;

	return false;
}

function hasRuntimeInterfaceSnapshot(runtimeStatus) {
	return !!(runtimeStatus && typeof runtimeStatus.interface === 'string' && runtimeStatus.interface);
}

function runtimeNeedsReconciliation(runtimeStatus) {
	if (!hasRuntimeInterfaceSnapshot(runtimeStatus))
		return true;

	return !!(runtimeStatus.runtime_disabled || runtimeStatus.interface_disabled || runtimeStatus.runtime_configured === false);
}

function deriveServerSelectionDrift(state, status) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};
	const mode = normalizeSelectionMode(runtimeStatus.server_selection_mode || 'auto');
	const rawSelectedCountry = Object.prototype.hasOwnProperty.call(runtimeStatus, 'selected_country')
		? runtimeStatus.selected_country
		: ((state && state.appliedCountryCode) || '');
	const selectedCountry = managerData.normalizeCountryCode(rawSelectedCountry || '');
	const currentServerCountry = managerData.normalizeCountryCode(runtimeStatus.current_server_country || '');
	const preferredStation = String(runtimeStatus.preferred_server_station || '');
	const currentStation = String(runtimeStatus.current_server_station || '');

	if (mode === 'manual') {
		if (!preferredStation || !currentStation || preferredStation === currentStation)
			return null;

		return {
			key: [ 'manual', preferredStation, currentStation ].join(':'),
			reason: _('manual server drift'),
			mode: mode,
			selectedCountry: selectedCountry,
			currentServerCountry: currentServerCountry,
			preferredStation: preferredStation,
			currentStation: currentStation
		};
	}

	if (!selectedCountry || !currentServerCountry || selectedCountry === currentServerCountry)
		return null;

	return {
		key: [ 'auto', selectedCountry, currentServerCountry ].join(':'),
		reason: _('country drift'),
		mode: mode,
		selectedCountry: selectedCountry,
		currentServerCountry: currentServerCountry,
		preferredStation: preferredStation,
		currentStation: currentStation
	};
}

function autoReconcileIsAllowed(state, status, drift) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};

	return !!drift &&
		!!state &&
		!!state.appliedEnabled &&
		!!runtimeStatus.desired_enabled &&
		!!runtimeStatus.runtime_configured &&
		!runtimeStatus.runtime_disabled &&
		!runtimeStatus.interface_disabled &&
		!runtimeOperationIsBusy(state, runtimeStatus) &&
		!managerUI.isDisableRequested(state);
}

function autoReconcileFailureIsThrottled(state, drift) {
	const failedAt = Number((state && state.lastAutoReconcileFailureAt) || 0);

	return !!(state && drift &&
		state.lastAutoReconcileFailureKey === drift.key &&
		failedAt > 0 &&
		(Date.now() - failedAt) < AUTO_RECONCILE_RETRY_DELAY_MS);
}

function autoReconcileDebugLines(drift) {
	return [
		_('Reason: %s').format(drift.reason),
		_('Mode: %s').format(drift.mode),
		_('Selected country: %s').format(formatDebugValue(drift.selectedCountry)),
		_('Current server country: %s').format(formatDebugValue(drift.currentServerCountry, _('Unknown'))),
		_('Preferred station: %s').format(formatDebugValue(drift.preferredStation)),
		_('Current station: %s').format(formatDebugValue(drift.currentStation, _('Unknown')))
	];
}

function maybeAutoReconcileSelectionDrift(state, status) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};
	const drift = deriveServerSelectionDrift(state, runtimeStatus);

	if (!autoReconcileIsAllowed(state, runtimeStatus, drift) || autoReconcileFailureIsThrottled(state, drift))
		return Promise.resolve(false);

	return managerStore.runExclusive(state, 'autoReconcile', function() {
		const latestStatus = state.currentLocalStatus || runtimeStatus;
		const latestDrift = deriveServerSelectionDrift(state, latestStatus);

		if (!autoReconcileIsAllowed(state, latestStatus, latestDrift) || autoReconcileFailureIsThrottled(state, latestDrift))
			return Promise.resolve(false);

		state.pendingOperationLabel = 'reconcile';
		state.currentOperationStatus = 'busy:reconcile';
		managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
		renderLocalStatusSnapshot(state, latestStatus);
		notifyDebugBlock(_('Automatic runtime sync queued'), autoReconcileDebugLines(latestDrift));

		return service.runActions([ 'reconcile' ]).then(function() {
			return refreshAfterSaveApply(state, true, { suppressAutoReconcile: true }).then(function() {
				const remainingDrift = deriveServerSelectionDrift(state, state.currentLocalStatus);
				let unchangedError;

				if (remainingDrift && remainingDrift.key === latestDrift.key) {
					unchangedError = new Error(_('Automatic runtime sync completed but server selection is still out of sync.'));
					state.lastAutoReconcileFailureKey = latestDrift.key;
					state.lastAutoReconcileFailureAt = Date.now();
					managerStore.setError(state, unchangedError);
					service.notifyError(unchangedError);
					return false;
				}

				state.lastAutoReconcileFailureKey = '';
				state.lastAutoReconcileFailureAt = 0;
				return true;
			});
		}).catch(function(err) {
			const message = (err && err.message) ? err.message : String(err);

			state.lastAutoReconcileFailureKey = latestDrift.key;
			state.lastAutoReconcileFailureAt = Date.now();
			managerStore.setError(state, err);
			return refreshAfterSaveApply(state, true, { suppressAutoReconcile: true }).then(function() {
				service.notifyError(new Error(_('Automatic runtime sync failed: ') + message));
				return false;
			});
		});
	});
}

function isLocalStatusPayload(value) {
	return !!value && typeof value === 'object' && !Array.isArray(value);
}

function buildLocalStatusSnapshot(res) {
	const rawStatus = service.parseExecJsonResponse(res, null);
	const fresh = !!(res && res.code === 0 && isLocalStatusPayload(rawStatus));

	return {
		status: fresh ? managerData.parseLocalStatus(JSON.stringify(rawStatus)) : managerData.parseLocalStatus('{}'),
		fresh: fresh
	};
}

function deriveRuntimeActionPlan(previousEnabled, enabled, previousCountry, country, previousMode, mode, previousPreferredStation, preferredStation, runtimeStatus) {
	const currentEnabled = !!enabled;
	const wasEnabled = !!previousEnabled;
	const currentMode = normalizeSelectionMode(mode);
	const serverSelectionChanged = hasServerSelectionChanged(
		previousCountry,
		country,
		previousMode,
		currentMode,
		previousPreferredStation,
		preferredStation
	);
	const runtimeReconciliationRequired = currentEnabled && runtimeNeedsReconciliation(runtimeStatus);
	const plan = {
		actions: [],
		successMessage: '',
		serverSelectionChanged: serverSelectionChanged
	};

	if (!wasEnabled && currentEnabled) {
		plan.actions = [ 'connect' ];
		plan.successMessage = _('NordVPN Easy enabled: setup completed and hooks installed.');
		return plan;
	}

	if (wasEnabled && !currentEnabled) {
		plan.actions = [ 'disconnect' ];
		plan.successMessage = _('NordVPN Easy disabled: VPN interface stopped and hooks removed.');
		return plan;
	}

	if (currentEnabled && serverSelectionChanged) {
		plan.actions = [ 'reconnect' ];
		plan.successMessage = currentMode === 'manual'
			? _('NordVPN Easy restarted and synchronized the selected manual server.')
			: _('NordVPN Easy restarted and synchronized the automatic server selection.');
		return plan;
	}

	if (runtimeReconciliationRequired) {
		plan.actions = [ 'reconcile' ];
		plan.successMessage = _('NordVPN Easy runtime synchronized with the saved configuration.');
	}

	return plan;
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

function loadServerCatalog(state, country, forceRefresh) {
	const requestId = ++state.latestServerCatalogRequestId;
	const requestedCountry = managerData.normalizeCountryCode(country || '');
	const extraArgs = [ country || '' ];

	if (!requestedCountry) {
		state.currentServerCatalog = managerData.emptyServerCatalog();
		state.serverCatalogIndex = {};
		managerUI.renderServerChoices(managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID), state.currentServerCatalog, '');
		managerUI.updateServerSelectionState(state);
		return Promise.resolve(state.currentServerCatalog);
	}

	if (runtimeOperationIsBusy(state, state.currentLocalStatus)) {
		if (state.currentServerCatalog &&
			state.currentServerCatalog.servers &&
			state.currentServerCatalog.servers.length &&
			managerData.normalizeCountryCode(state.currentServerCatalog.country_code) === requestedCountry) {
			managerUI.renderServerChoices(managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID), state.currentServerCatalog, '');
			managerUI.updateServerSelectionState(state);
			return Promise.resolve(state.currentServerCatalog);
		}

		managerUI.updateServerSelectionState(state);
		return Promise.resolve(managerData.emptyServerCatalog());
	}

	if (forceRefresh)
		extraArgs.push('1');

	return managerStore.runExclusive(state, 'catalog', function() {
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
	});
}

function normalizePublicIpValue(value) {
	const publicIp = String(value != null ? value : '').trim();

	if (!publicIp || publicIp === 'null' || publicIp === 'undefined')
		return '';

	return publicIp;
}

function runtimeOperationIsBusy(state, status) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};
	const operationStatus = String(runtimeStatus.operation_status || (state && state.currentOperationStatus) || 'idle');

	return !!(state && state.pendingOperationLabel) ||
		operationStatus === 'busy' ||
		operationStatus.indexOf('busy:') === 0 ||
		String(runtimeStatus.operation_lock_state || 'none') === 'held';
}

function publicLookupsAllowed(state, status) {
	const runtimeStatus = status || state.currentLocalStatus || {};

	return !!state.appliedEnabled &&
			!!runtimeStatus.desired_enabled &&
			!runtimeStatus.runtime_disabled &&
			!runtimeStatus.interface_disabled &&
			!runtimeOperationIsBusy(state, runtimeStatus) &&
			!managerUI.isDisableRequested(state);
}

function clearPublicLookupDisplay(state) {
	state.currentPublicIp = '';
	state.currentPublicCountry = '';
	state.currentPublicCountryIp = '';
	managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
}

function updateCachedPublicLookupState(state, status) {
	const cachedPublicIp = normalizePublicIpValue(status.public_ip_cached);
	const cachedPublicCountry = managerData.normalizeCountryCode(status.public_country_cached || '');

	if (cachedPublicIp)
		state.cachedPublicIp = cachedPublicIp;

	if (cachedPublicCountry) {
		state.cachedPublicCountry = cachedPublicCountry;
		state.cachedPublicCountryIp = cachedPublicIp || state.cachedPublicCountryIp || '';
	}
}

function renderPublicLookupStatus(state, status) {
	if (!publicLookupsAllowed(state, status)) {
		clearPublicLookupDisplay(state);
		return;
	}

	managerUI.replaceStatusText(
		managerUI.ids.PUBLIC_IP_STATUS_ID,
		state.currentPublicIp || state.cachedPublicIp || _('Unavailable')
	);
	managerUI.replaceStatusText(
		managerUI.ids.PUBLIC_COUNTRY_STATUS_ID,
		state.currentPublicCountry || state.cachedPublicCountry || _('Unavailable')
	);
}

function renderLocalStatusDetails(state, status) {
	const runtimeStatus = status || managerData.parseLocalStatus('{}');

	updateCachedPublicLookupState(state, runtimeStatus);
	managerUI.replaceStatusText(managerUI.ids.CURRENT_SERVER_STATUS_ID, managerUI.currentServerSummaryFromStatus(runtimeStatus, state));
	managerUI.replaceStatusText(managerUI.ids.PREFERRED_SERVER_STATUS_ID, managerUI.preferredServerSummaryFromStatus(runtimeStatus));
	managerUI.replaceStatusText(managerUI.ids.ENDPOINT_STATUS_ID, runtimeStatus.endpoint || _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.HANDSHAKE_STATUS_ID, runtimeStatus.latest_handshake || _('Never'));
	managerUI.replaceStatusText(
		managerUI.ids.TRANSFER_STATUS_ID,
		_('%s / %s').format(runtimeStatus.transfer_rx || '0 B', runtimeStatus.transfer_tx || '0 B')
	);
	managerUI.replaceStatusText(managerUI.ids.LAST_ERROR_STATUS_ID, runtimeStatus.last_error || _('None'));
	renderPublicLookupStatus(state, runtimeStatus);
}

function renderLocalStatusSnapshot(state, status) {
	let busyAction;
	const runtimeStatus = status || managerData.parseLocalStatus('{}');
	const desiredEnabled = !!runtimeStatus.desired_enabled;
	const operationStatus = String(state.currentOperationStatus || 'idle');

	state.currentLocalStatus = runtimeStatus;
	renderLocalStatusDetails(state, runtimeStatus);

	if (operationStatus.indexOf('busy:') === 0) {
		busyAction = operationStatus.substring(5);
		managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying (%s)...').format(managerFormat.humanizeAction(busyAction)));
		managerUI.setManagerControlsDisabled(true);

		if (busyAction !== 'refresh_countries' && busyAction !== 'server_catalog') {
			managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
			managerUI.setVpnStatusIndicator(
				managerUI.isDisableRequested(state) ? 'stopping' : 'starting',
				managerUI.isDisableRequested(state) ? _('Disabling') : _('Activating')
			);
			managerUI.updateCountryMatchStatus(state);
			managerUI.updateServerSelectionState(state);
			return runtimeStatus;
		}
	}
	else if (operationStatus === 'busy') {
		managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying...'));
		managerUI.setVpnStatusIndicator(
			managerUI.isDisableRequested(state) ? 'stopping' : 'starting',
			managerUI.isDisableRequested(state) ? _('Disabling') : _('Activating')
		);
		managerUI.setManagerControlsDisabled(true);
		managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
		managerUI.updateCountryMatchStatus(state);
		managerUI.updateServerSelectionState(state);
		return runtimeStatus;
	}

	if (state.pendingOperationLabel) {
		managerUI.replaceStatusText(
			managerUI.ids.OPERATION_STATUS_ID,
			_('Applying (%s)...').format(managerFormat.humanizeAction(state.pendingOperationLabel))
		);
		managerUI.setVpnStatusIndicator(
			managerUI.isDisableRequested(state) ? 'stopping' : 'starting',
			managerUI.isDisableRequested(state) ? _('Disabling') : _('Activating')
		);
		managerUI.setManagerControlsDisabled(true);
		managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
	}
	else {
		managerUI.replaceStatusText(
			managerUI.ids.OPERATION_STATUS_ID,
			operationStatus === 'unknown' ? _('Unknown') : _('Idle')
		);
		managerUI.setManagerControlsDisabled(false);
		managerStore.syncPhase(state);
	}

	if (!desiredEnabled || runtimeStatus.runtime_disabled || runtimeStatus.interface_disabled || managerUI.isDisableRequested(state))
		managerUI.setVpnStatusIndicator('inactive', _('Disabled'));
	else if (runtimeStatus.vpn_status === 'active' || runtimeStatus.connected)
		managerUI.setVpnStatusIndicator('active', _('Connected'));
	else if (runtimeStatus.vpn_status === 'starting')
		managerUI.setVpnStatusIndicator('starting', _('Starting'));
	else if (runtimeStatus.vpn_status === 'stopping')
		managerUI.setVpnStatusIndicator('stopping', _('Stopping'));
	else if (runtimeStatus.vpn_status === 'error')
		managerUI.setVpnStatusIndicator('error', _('Error'));
	else
		managerUI.setVpnStatusIndicator('inactive', _('Disconnected'));

	managerUI.updateCountryMatchStatus(state);
	managerUI.updateServerSelectionState(state);
	return runtimeStatus;
}

function updatePublicIp(state, options) {
	const opts = options || {};
	const extraArgs = opts.quiet ? [ 'quiet' ] : [];

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve();

	if (!publicLookupsAllowed(state, state.currentLocalStatus)) {
		clearPublicLookupDisplay(state);
		managerUI.updateCountryMatchStatus(state);
		return Promise.resolve();
	}

	return managerStore.runExclusive(state, 'publicIp', function() {
		if (!publicLookupsAllowed(state, state.currentLocalStatus)) {
			clearPublicLookupDisplay(state);
			managerUI.updateCountryMatchStatus(state);
			return Promise.resolve();
		}

		return service.execService('public_ip', extraArgs).then(function(res) {
			const publicIp = (res.code === 0) ? normalizePublicIpValue(res.stdout) : '';
			const previousPublicIp = state.currentPublicIp;
			const shouldRefreshCountry = !!publicIp && (
				opts.force ||
				publicIp !== previousPublicIp ||
				!state.currentPublicCountry ||
				state.currentPublicCountryIp !== publicIp
			);

			state.currentPublicIp = publicIp;
			managerUI.replaceStatusText(
				managerUI.ids.PUBLIC_IP_STATUS_ID,
				publicIp || _('Unavailable')
			);

			if (!publicIp) {
				state.currentPublicCountry = '';
				state.currentPublicCountryIp = '';
				managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
				managerUI.updateCountryMatchStatus(state);
				return Promise.resolve();
			}

			if (!shouldRefreshCountry)
				return Promise.resolve();

			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Checking...'));
			return updatePublicCountry(state, {
				quiet: opts.quiet,
				force: !!opts.force,
				expectedPublicIp: publicIp
			});
		}).catch(function() {
			state.currentPublicIp = '';
			state.currentPublicCountry = '';
			state.currentPublicCountryIp = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		});
	});
}

function updatePublicCountry(state, options) {
	const opts = options || {};
	const extraArgs = opts.quiet ? [ 'quiet' ] : [];
	const expectedPublicIp = normalizePublicIpValue(opts.expectedPublicIp || state.currentPublicIp);

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve();

	if (!publicLookupsAllowed(state, state.currentLocalStatus)) {
		clearPublicLookupDisplay(state);
		managerUI.updateCountryMatchStatus(state);
		return Promise.resolve();
	}

	return managerStore.runExclusive(state, 'publicCountry', function() {
		if (!publicLookupsAllowed(state, state.currentLocalStatus)) {
			clearPublicLookupDisplay(state);
			managerUI.updateCountryMatchStatus(state);
			return Promise.resolve();
		}

		if (!expectedPublicIp) {
			state.currentPublicCountry = '';
			state.currentPublicCountryIp = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
			return Promise.resolve();
		}

		return service.execService('public_country', extraArgs).then(function(res) {
			const publicCountry = managerData.normalizeCountryCode(res.stdout ? res.stdout.trim() : '');

			state.currentPublicCountry = (res.code === 0 && publicCountry) ? publicCountry : '';
			state.currentPublicCountryIp = state.currentPublicCountry ? expectedPublicIp : '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, state.currentPublicCountry || _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		}).catch(function() {
			state.currentPublicCountry = '';
			state.currentPublicCountryIp = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		});
	});
}

function updateLocalStatus(state, options) {
	const opts = options || {};

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve(state.currentLocalStatus);

	return managerStore.runExclusive(state, 'status', function() {
		return service.execService('status_json').then(function(res) {
			const localStatusSnapshot = buildLocalStatusSnapshot(res);
			const status = localStatusSnapshot.status;
			const desiredEnabled = !!status.desired_enabled;

			managerStore.clearError(state);
			state.currentLocalStatus = status;
			state.currentLocalStatusFresh = localStatusSnapshot.fresh;
			state.currentLocalStatusLastUpdated = localStatusSnapshot.fresh ? Date.now() : 0;
			state.currentOperationStatus = String(status.operation_status || 'idle');
			state.appliedEnabled = desiredEnabled;
			state.appliedCountryCode = managerData.normalizeCountryCode(status.selected_country || state.appliedCountryCode);
			renderLocalStatusSnapshot(state, status);
			if (localStatusSnapshot.fresh && !opts.suppressAutoReconcile)
				void maybeAutoReconcileSelectionDrift(state, status);
			return status;
		}).catch(function(err) {
			state.currentLocalStatusFresh = false;
			state.currentLocalStatusLastUpdated = 0;
			state.currentOperationStatus = state.pendingOperationLabel ? ('busy:' + state.pendingOperationLabel) : 'unknown';

			if (!state.pendingOperationLabel)
				managerStore.setError(state, err);
			return renderLocalStatusSnapshot(state, state.currentLocalStatus || managerData.parseLocalStatus('{}'));
		});
	});
}

function onCountryChanged(state) {
	const country = managerUI.getSelectedCountry();
	const selectEl = managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID);

	if (selectEl)
		selectEl.value = '';

	state.latestServerCatalogRequestId++;
	state.currentServerCatalog = managerData.emptyServerCatalog();
	state.serverCatalogIndex = {};
	managerUI.renderServerChoices(selectEl, state.currentServerCatalog, '');
	managerUI.updateServerSelectionState(state);

	if (!country || !managerStore.shouldLoadCatalog(managerUI.getSelectedMode(), country))
		return Promise.resolve();

	return loadServerCatalog(state, country, false).catch(function(err) {
		service.notifyError(err);
	});
}

function onModeChanged(state) {
	const mode = managerUI.getSelectedMode();
	const country = managerUI.getSelectedCountry();
	const selectEl = managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID);

	if (mode !== 'manual') {
		if (selectEl)
			selectEl.value = '';
		managerUI.updateServerSelectionState(state);
		return Promise.resolve();
	}

	managerUI.updateServerSelectionState(state);

	if (!country || state.currentServerCatalog.servers.length)
		return Promise.resolve();

	return loadServerCatalog(state, country, false).catch(function(err) {
		service.notifyError(err);
	});
}

function handleRefreshServerCatalog(state, ev) {
	const country = managerUI.getSelectedCountry();
	const button = ev ? ev.currentTarget : managerUI.getInputElement(managerUI.ids.SERVER_REFRESH_BUTTON_ID, 'button');

	if (!country) {
		ui.addNotification(null, E('p', _('Select a country before refreshing the server catalog.')), 'warning');
		return Promise.resolve();
	}

	if (runtimeOperationIsBusy(state, state.currentLocalStatus)) {
		ui.addNotification(null, E('p', _('NordVPN Easy is applying another runtime operation. Server catalog refresh was skipped.')), 'info');
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

function loadSavedRuntimeConfig() {
	return Promise.resolve().then(function() {
		uci.unload('nordvpn_easy');
		return uci.load('nordvpn_easy');
	}).then(function() {
		return {
			enabled: managerData.parseEnabledFlag(uci.get('nordvpn_easy', 'main', 'enabled')),
			country: managerData.normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || ''),
			mode: String(uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto'),
			preferredStation: String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '')
		};
	});
}

function rememberSavedRuntimeConfig(viewState, state, savedConfig) {
	viewState.initialEnabled = savedConfig.enabled;
	viewState.initialCountry = savedConfig.country;
	viewState.initialMode = savedConfig.mode;
	viewState.initialPreferredStation = savedConfig.preferredStation;
	state.appliedEnabled = savedConfig.enabled;
	state.appliedCountryCode = savedConfig.country;
}

function refreshAfterSaveApply(state, refreshPublicIp, options) {
	const opts = options || {};

	state.pendingOperationLabel = '';
	managerStore.resumePolling(state);

	return updateLocalStatus(state, {
		force: true,
		suppressAutoReconcile: !!opts.suppressAutoReconcile
	}).then(function() {
		if (refreshPublicIp)
			return updatePublicIp(state, { force: true });

		return null;
	});
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
	const serverSelectionChanged = hasServerSelectionChanged(
		previousCountry,
		currentCountry,
		previousMode,
		currentMode,
		previousPreferredStation,
		preferredStation
	);
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
		serverSelectionChanged
	)) {
		confirmationPromise = managerUI.showConfirmationModal(
			_('Confirm Server Change'),
			[
				_('Applying these changes will reconfigure the current VPN tunnel, cycle the VPN interface, and then reconnect with the selected server settings.'),
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
			return Promise.resolve();

		notifyDebugBlock(_('Save & Apply requested'), debugLines.concat([
			_('UCI changes are being committed before runtime actions start.')
		]));

		managerStore.clearError(state);
		managerStore.suspendPolling(state);
		managerStore.setPhase(state, managerStore.PHASES.SAVING);

		return new Promise(function(resolve, reject) {
			let settled = false;
				let timeoutId = null;

				const cleanup = function() {
					if (timeoutId !== null) {
						clearTimeout(timeoutId);
						timeoutId = null;
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

			const handleRejectedSaveFlow = function(err) {
				managerStore.setError(state, err);
				state.pendingOperationLabel = '';
				managerStore.resumePolling(state);
				updateLocalStatus(state, { force: true });
				finishReject(err);
			};

			cleanup();

			Promise.resolve(viewState.handleSave(ev)).then(function() {
				const continueAfterUciApply = function() {
					return loadSavedRuntimeConfig().then(function(savedConfig) {
						rememberSavedRuntimeConfig(viewState, state, savedConfig);
						return updateLocalStatus(state, { force: true }).then(function(status) {
							const localStatus = state.currentLocalStatusFresh ? status : null;
							const runtimePlan = deriveRuntimeActionPlan(
								previousEnabled,
								savedConfig.enabled,
								previousCountry,
								savedConfig.country,
								previousMode,
								savedConfig.mode,
								previousPreferredStation,
								savedConfig.preferredStation,
								localStatus
							);
							const actions = runtimePlan.actions;
							const successMessage = runtimePlan.successMessage;

							if (!actions.length) {
								notifyDebugBlock(_('Configuration applied'), [
									_('UCI changes were saved successfully.'),
									_('No runtime action was required.')
								]);
								return refreshAfterSaveApply(state, false).then(function() {
									finishResolve();
								});
							}

							state.pendingOperationLabel = managerFormat.formatActionsLabel(actions);
							state.currentOperationStatus = 'busy:' + state.pendingOperationLabel;
							managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
							managerStore.resumePolling(state);
							notifyDebugBlock(_('Runtime actions queued'), [
								_('Executing: %s').format(state.pendingOperationLabel),
								_('Enabled state after save: %s').format(savedConfig.enabled ? _('checked') : _('unchecked'))
							]);

							return updateLocalStatus(state, { force: true }).then(function() {
								return service.runActions(actions);
							}).then(function() {
								service.notifyInfo(successMessage);
								return refreshAfterSaveApply(state, true);
							}).then(function() {
								finishResolve();
							}).catch(function(err) {
								managerStore.setError(state, err);
								service.notifyError(err);
								return refreshAfterSaveApply(state, true).then(function() {
									finishReject(err);
								});
							});
						});
					}).catch(function(err) {
						const message = (err && err.message) ? err.message : String(err);

						managerStore.setError(state, err);
						return refreshAfterSaveApply(state, true).then(function() {
							service.notifyError(new Error(_('Automatic runtime sync failed: ') + message));
							finishReject(err);
						});
					});
				};

				timeoutId = setTimeout(function() {
					const timeoutError = new Error(_('Configuration apply timed out.'));

					managerStore.setError(state, timeoutError);
					state.pendingOperationLabel = '';
					managerStore.resumePolling(state);
					updateLocalStatus(state, { force: true });
					finishReject(timeoutError);
				}, 60000);

				state.pendingOperationLabel = _('configuration');
				state.currentOperationStatus = 'busy:configuration';
				managerStore.setPhase(state, managerStore.PHASES.SAVING);
				updateLocalStatus(state, { force: true });
				Promise.resolve(ui.changes.apply(mode === '0')).then(continueAfterUciApply).catch(function(err) {
					managerStore.setError(state, err);
					state.pendingOperationLabel = '';
					managerStore.resumePolling(state);
					updateLocalStatus(state, { force: true });
					finishReject(err);
				});
			}).catch(function(err) {
				handleRejectedSaveFlow(err);
			});
		});
	});
}

	return baseclass.extend({
		hasServerSelectionChanged: hasServerSelectionChanged,
		deriveServerSelectionDrift: deriveServerSelectionDrift,
		maybeAutoReconcileSelectionDrift: maybeAutoReconcileSelectionDrift,
		deriveRuntimeActionPlan: deriveRuntimeActionPlan,
		runtimeOperationIsBusy: runtimeOperationIsBusy,
		loadServerCatalog: loadServerCatalog,
	renderLocalStatusSnapshot: renderLocalStatusSnapshot,
	updatePublicIp: updatePublicIp,
	updatePublicCountry: updatePublicCountry,
	updateLocalStatus: updateLocalStatus,
	onCountryChanged: onCountryChanged,
	onModeChanged: onModeChanged,
	handleRefreshServerCatalog: handleRefreshServerCatalog,
	handleSaveApply: handleSaveApply
});
