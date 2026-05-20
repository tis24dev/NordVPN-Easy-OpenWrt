'use strict';
/* global baseclass, managerData, managerFormat, managerStore, managerUI, service, ui, uci, rpc, request, L, document, Date, setTimeout, clearTimeout, E, _ */
'require baseclass';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require nordvpn-easy/manager-store as managerStore';
'require nordvpn-easy/manager-ui as managerUI';
'require nordvpn-easy/service as service';
'require rpc';
'require request';
'require ui';
'require uci';


const AUTO_RECONCILE_RETRY_DELAY_MS = 5 * 60 * 1000;
const MAX_DRIFT_RESTART_DEPTH = 1;
const SAVE_APPLY_TIMEOUT_MS = 150000;
const RUNTIME_ACTION_RECOVERY_POLL_MS = 3000;
const RUNTIME_ACTION_COOLDOWN_MS = SAVE_APPLY_TIMEOUT_MS + 30000;
let callUciCommit = null;

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

const APPLY_CYCLE_SUCCESS_CONNECTED = _('NordVPN Easy applied your configuration and connected.');
const APPLY_CYCLE_SUCCESS_DISABLED = _('NordVPN Easy applied your configuration. VPN remains disabled.');

function normalizeSubmittedConfig(raw) {
	const submitted = raw || {};
	const mode = normalizeSelectionMode(submitted.mode);
	const country = managerData.normalizeCountryCode(submitted.country || '');
	let preferredStation = String(submitted.preferredStation || '');
	let effectiveMode = mode;

	if (effectiveMode === 'manual' && (!country || !preferredStation))
		effectiveMode = 'auto';

	if (effectiveMode !== 'manual')
		preferredStation = '';

	return {
		country: country,
		mode: effectiveMode,
		enabled: !!submitted.enabled,
		preferredStation: preferredStation
	};
}

function nordvpnTokenIsPresent() {
	const tokenField = managerUI.getInputElement(managerUI.ids.TOKEN_FIELD_ID, 'input');
	const existingToken = String(uci.get('nordvpn_easy', 'main', 'nordvpn_token') || '');
	const tokenFieldValue = String(tokenField && tokenField.value != null ? tokenField.value : '').trim();
	const tokenFieldMasked = !!(tokenField && tokenField.getAttribute('data-token-masked') === '1');

	if (tokenFieldValue && !tokenFieldMasked)
		return true;

	return !!existingToken;
}

function syncPreferredServerFieldsToUci(submitted, serverCatalogIndex) {
	const catalog = serverCatalogIndex || {};

	if (submitted.mode === 'manual' && submitted.preferredStation) {
		const server = catalog[submitted.preferredStation];

		uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', server ? String(server.hostname || '') : '');
		uci.set('nordvpn_easy', 'main', 'preferred_server_station', submitted.preferredStation);
		return;
	}

	uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', '');
	uci.set('nordvpn_easy', 'main', 'preferred_server_station', '');
}

function readSubmittedConfigFromForm(state) {
	return normalizeSubmittedConfig({
		country: managerUI.getSelectedCountry(),
		mode: managerUI.getSelectedMode(),
		enabled: !!(managerUI.getEnabledCheckboxElement() && managerUI.getEnabledCheckboxElement().checked),
		preferredStation: managerUI.getSelectedPreferredStation()
	});
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

function runtimeActionCooldownActive(state) {
	return Date.now() < Number((state && state.runtimeActionCooldownUntil) || 0);
}

function markRuntimeActionCooldown(state) {
	if (!state)
		return;

	state.runtimeActionCooldownUntil = Date.now() + RUNTIME_ACTION_COOLDOWN_MS;
}

function autoReconcileIsAllowed(state, status, drift) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};

	return !!drift &&
		!!state &&
		driftEvaluationAllowed(state) &&
		!runtimeActionCooldownActive(state) &&
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

function maybeRestartApplyCycleOnDrift(viewState, state, ev, restartOptions) {
	const opts = restartOptions || {};
	const depth = Number(opts.driftDepth) || 0;
	const runtimeStatus = state.currentLocalStatus || {};
	const drift = deriveServerSelectionDrift(state, runtimeStatus);

	if (depth >= MAX_DRIFT_RESTART_DEPTH)
		return Promise.resolve(false);

	if (!drift || !driftEvaluationAllowed(state) || !state.appliedEnabled)
		return Promise.resolve(false);

	if (opts.driftContext && autoReconcileFailureIsThrottled(state, drift))
		return Promise.resolve(false);

	return runApplyCycle(viewState, state, ev, {
		skipFormSave: true,
		skipDriftRestart: false,
		driftDepth: depth + 1,
		driftContext: drift,
		notifyDriftQueued: !!opts.notifyDriftQueued
	});
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

		markRuntimeActionCooldown(state);
		renderLocalStatusSnapshot(state, latestStatus);
		notifyDebugBlock(_('Automatic runtime sync queued'), autoReconcileDebugLines(latestDrift));

		return runApplyCycle(null, state, null, {
			skipFormSave: true,
			skipDriftRestart: true,
			driftDepth: 0,
			driftContext: latestDrift
		}).then(function() {
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

function buildDiagnosticsSnapshot(res) {
	const rawSummary = service.parseExecJsonResponse(res, null);
	const fresh = !!(res && res.code === 0 && managerData.isDiagnosticsSummaryPayload(rawSummary));

	return {
		summary: managerData.parseDiagnosticsSummary(rawSummary),
		fresh: fresh
	};
}

function runApplyCycleConnectPhase(state, savedConfig) {
	const successMessage = APPLY_CYCLE_SUCCESS_CONNECTED;

	state.pendingOperationLabel = 'connect';
	state.currentOperationStatus = 'busy:connect';
	managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);

	return service.runAction('connect').then(function(result) {
		if (!result.success) {
			const error = service.resultToError(result);

			error.result = result;
			throw error;
		}

		service.notifyInfo(successMessage);
		return refreshAfterSaveApply(state, true, { suppressAutoReconcile: true });
	}).catch(function(err) {
		if (runtimeActionErrorLooksAborted(err)) {
			return recoverAbortedRuntimeAction(state, savedConfig, err, successMessage);
		}

		throw err;
	});
}

function runApplyCycle(viewState, state, ev, options) {
	const opts = options || {};
	const submitted = opts.submitted || null;
	const skipFormSave = !!opts.skipFormSave;

	if (opts.notifyDriftQueued && opts.driftContext)
		notifyDebugBlock(_('Runtime sync queued'), autoReconcileDebugLines(opts.driftContext));

	state.pendingOperationLabel = 'stop_vpn';
	state.currentOperationStatus = 'busy:stop_vpn';
	managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);

	return service.runAction('stop_vpn').then(function(stopResult) {
		if (!stopResult.success)
			throw service.resultToError(stopResult);

		if (!skipFormSave && submitted) {
			syncPreferredServerFieldsToUci(submitted, state.serverCatalogIndex || {});
			syncSubmittedRuntimeConfigToUci(submitted);
			return Promise.resolve(viewState && viewState.handleSave ? viewState.handleSave(ev) : null);
		}

		return null;
	}).then(function() {
		if (skipFormSave)
			return null;

		return flushLuCiPendingChanges();
	}).then(function() {
		return loadSavedRuntimeConfig();
	}).then(function(savedConfig) {
		if (submitted && !skipFormSave)
			savedConfig = mergeSavedConfigWithSubmittedValues(savedConfig, submitted);

		if (viewState)
			rememberSavedRuntimeConfig(viewState, state, savedConfig);

		if (savedConfig.enabled && !nordvpnTokenIsPresent()) {
			const tokenError = new Error(_('NordVPN token is required before enabling NordVPN Easy.'));

			service.notifyError(tokenError);
			return refreshAfterSaveApply(state, false, { suppressAutoReconcile: true }).then(function() {
				throw tokenError;
			});
		}

		if (!savedConfig.enabled) {
			service.notifyInfo(APPLY_CYCLE_SUCCESS_DISABLED);
			return refreshAfterSaveApply(state, false, { suppressAutoReconcile: true });
		}

		return runApplyCycleConnectPhase(state, savedConfig);
	}).then(function(refreshResult) {
		if (opts.skipDriftRestart)
			return refreshResult;

		return maybeRestartApplyCycleOnDrift(viewState, state, ev, {
			driftDepth: Number(opts.driftDepth) || 0,
			driftContext: opts.driftContext || null,
			notifyDriftQueued: true
		}).then(function() {
			return refreshResult;
		});
	});
}

function clearLuCiUnsavedChangesIndicator() {
	if (typeof ui !== 'undefined' && ui.changes)
		ui.changes.changes = {};

	if (typeof ui !== 'undefined' && ui.changes && typeof ui.changes.setIndicator === 'function')
		ui.changes.setIndicator(0);
}

function countLuCiChanges(changes) {
	let count = 0;

	if (!changes || typeof changes !== 'object')
		return 0;

	Object.keys(changes).forEach(function(config) {
		const records = changes[config];

		if (Array.isArray(records))
			count += records.length;
	});

	return count;
}

function renderLuCiChangeTracker(changes) {
	const pendingChanges = changes || {};

	if (typeof ui !== 'undefined' && ui.changes) {
		ui.changes.changes = pendingChanges;

		if (typeof ui.changes.renderChangeIndicator === 'function')
			ui.changes.renderChangeIndicator(pendingChanges);
		else if (typeof ui.changes.setIndicator === 'function')
			ui.changes.setIndicator(countLuCiChanges(pendingChanges));
	}

	if (!countLuCiChanges(pendingChanges))
		clearLuCiUnsavedChangesIndicator();

	return pendingChanges;
}

function refreshLuCiChangeTracker() {
	if (typeof uci !== 'undefined' && typeof uci.changes === 'function') {
		return uci.changes().then(function(changes) {
			const pendingChanges = renderLuCiChangeTracker(changes);

			return pendingChanges;
		});
	}

	if (typeof ui !== 'undefined' && ui.changes && typeof ui.changes.init === 'function') {
		return ui.changes.init().then(function() {
			return ui.changes.changes || {};
		});
	}

	return Promise.resolve();
}

function applyLuCiPendingChangesWithSession() {
	if (typeof request === 'undefined' ||
		typeof L === 'undefined' ||
		!L.env ||
		typeof L.url !== 'function' ||
		typeof request.request !== 'function') {
		return Promise.reject(new Error(_('LuCI apply endpoint is unavailable.')));
	}

	return request.request(L.url('admin/uci', 'apply_unchecked'), {
		method: 'post',
		query: {
			sid: L.env.sessionid,
			token: L.env.token
		}
	}).then(function(res) {
		const status = Number((res && res.status) || 0);

		if (status === 200 || status === 204)
			return refreshLuCiChangeTracker();

		return Promise.reject(new Error(_('LuCI apply request failed with status %s.').format(status || _('unknown'))));
	});
}

function commitLuCiPendingChangesFallback() {
	if (!callUciCommit && typeof rpc !== 'undefined') {
		callUciCommit = rpc.declare({
			object: 'uci',
			method: 'commit',
			params: [ 'config' ],
			reject: true
		});
	}

	if (!callUciCommit)
		return Promise.reject(new Error(_('Could not commit UCI changes: LuCI RPC is unavailable.')));

	return callUciCommit('nordvpn_easy').then(function() {
		return refreshLuCiChangeTracker();
	}).catch(function(err) {
		const message = (err && err.message) ? err.message : String(err);

		return Promise.reject(new Error(_('Could not commit UCI changes: ') + message));
	});
}

function flushLuCiPendingChanges() {
	return applyLuCiPendingChangesWithSession().catch(function(err) {
		return commitLuCiPendingChangesFallback();
	});
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

function driftEvaluationAllowed(state) {
	if (!state)
		return false;

	if (state.saveApplyInProgress || state.pendingOperationLabel)
		return false;

	if (state.phase === 'saving' || state.phase === 'runtime_busy')
		return false;

	return true;
}

function configurationTransitionActive(state) {
	return !driftEvaluationAllowed(state);
}

function runtimeOperationIsBusy(state, status) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};

	return configurationTransitionActive(state) ||
		runtimeStatusIndicatesBusy(runtimeStatus, state && state.currentOperationStatus);
}

function runtimeStatusIndicatesBusy(status, fallbackOperationStatus) {
	const runtimeStatus = status || {};

	return managerData.runtimeStatusIsBusy({
		operation_status: runtimeStatus.operation_status || fallbackOperationStatus || 'idle',
		operation_lock_state: runtimeStatus.operation_lock_state || 'none'
	});
}

function runtimeActionErrorLooksAborted(err) {
	const message = String((err && err.message) || err || '').toLowerCase();

	return message.indexOf('xhr request aborted') !== -1 ||
		message.indexOf('xhr request timed out') !== -1 ||
		message.indexOf('request timed out') !== -1 ||
		message.indexOf('request aborted') !== -1 ||
		message.indexOf('aborted by browser') !== -1;
}

function savedRuntimeCountryMatches(status, savedConfig) {
	const savedCountry = managerData.normalizeCountryCode((savedConfig && savedConfig.country) || '');
	const runtimeCountry = managerData.normalizeCountryCode(
		(status && (status.current_server_country || status.selected_country)) || ''
	);

	return !savedCountry || runtimeCountry === savedCountry;
}

function savedRuntimeManualServerMatches(status, savedConfig) {
	const savedMode = normalizeSelectionMode((savedConfig && savedConfig.mode) || 'auto');
	const savedStation = String((savedConfig && savedConfig.preferredStation) || '');
	const runtimeStation = String((status && status.current_server_station) || '');

	return savedMode !== 'manual' || !savedStation || runtimeStation === savedStation;
}

function runtimeActionRecoverySucceeded(savedConfig, status) {
	const runtimeStatus = status || {};
	const savedEnabled = !!(savedConfig && savedConfig.enabled);

	if (runtimeStatusIndicatesBusy(runtimeStatus))
		return false;

	if (!savedEnabled) {
		return runtimeStatus.desired_enabled === false ||
			!!runtimeStatus.runtime_disabled ||
			!!runtimeStatus.interface_disabled ||
			String(runtimeStatus.vpn_status || '') === 'inactive' ||
			runtimeStatus.connected === false;
	}

	if (runtimeStatus.runtime_configured === false ||
		!!runtimeStatus.runtime_disabled ||
		!!runtimeStatus.interface_disabled) {
		return false;
	}

	if (!(runtimeStatus.connected || String(runtimeStatus.vpn_status || '') === 'active'))
		return false;

	return savedRuntimeCountryMatches(runtimeStatus, savedConfig) &&
		savedRuntimeManualServerMatches(runtimeStatus, savedConfig);
}

function abortedRuntimeActionRecoveryError(err) {
	const message = (err && err.message) ? err.message : String(err);

	return new Error(
		_('Runtime action request was interrupted before LuCI received the response. Original error: ') + message
	);
}

function recoverAbortedRuntimeAction(state, savedConfig, originalError, successMessage) {
	const deadline = Date.now() + SAVE_APPLY_TIMEOUT_MS;
	const recoveryError = abortedRuntimeActionRecoveryError(originalError);

	notifyDebugBlock(_('Runtime action response interrupted'), [
		_('LuCI lost the backend response while the runtime action may still be running.'),
		_('Polling local status until the runtime finishes.')
	]);

	const poll = function() {
		return updateLocalStatus(state, {
			force: true,
			suppressAutoReconcile: true
		}).then(function(status) {
			const freshStatus = state.currentLocalStatusFresh ? status : null;

			if (runtimeActionRecoverySucceeded(savedConfig, freshStatus)) {
				service.notifyInfo(successMessage);
				return refreshAfterSaveApply(state, true, { suppressAutoReconcile: true });
			}

			if (Date.now() >= deadline)
				return Promise.reject(recoveryError);

			return new Promise(function(resolve, reject) {
				setTimeout(function() {
					poll().then(resolve, reject);
				}, RUNTIME_ACTION_RECOVERY_POLL_MS);
			});
		});
	};

	return poll();
}

function suppressDriftUi(state) {
	managerUI.updateDiagnosticsBanner(managerData.emptyDiagnosticsSummary());
}

function publicLookupsAllowed(state, status) {
	const runtimeStatus = status || state.currentLocalStatus || {};

	return !!state.appliedEnabled &&
			!!runtimeStatus.desired_enabled &&
			!runtimeStatus.runtime_disabled &&
			!runtimeStatus.interface_disabled &&
			!managerUI.isDisableRequested(state);
}

function clearPublicLookupDisplay(state) {
	state.currentPublicIp = '';
	state.currentPublicCountry = '';
	managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
}

function syncPublicLookupStateFromStatus(state, status) {
	state.currentPublicIp = normalizePublicIpValue(status.public_ip_cached) || state.currentPublicIp || '';
	state.currentPublicCountry = managerData.normalizeCountryCode(status.public_country_cached || '') || state.currentPublicCountry || '';
}

function renderPublicLookupStatus(state, status) {
	if (!publicLookupsAllowed(state, status)) {
		clearPublicLookupDisplay(state);
		return;
	}

	managerUI.replaceStatusText(
		managerUI.ids.PUBLIC_IP_STATUS_ID,
		state.currentPublicIp || _('Unavailable')
	);
	managerUI.replaceStatusText(
		managerUI.ids.PUBLIC_COUNTRY_STATUS_ID,
		state.currentPublicCountry || _('Unavailable')
	);
}

function renderLocalStatusDetails(state, status) {
	const runtimeStatus = status || managerData.parseLocalStatus('{}');

	syncPublicLookupStateFromStatus(state, runtimeStatus);
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

function renderApplyingTransitionUi(state) {
	const label = state.pendingOperationLabel || _('configuration');

	managerUI.replaceStatusText(
		managerUI.ids.OPERATION_STATUS_ID,
		_('Applying (%s)...').format(managerFormat.humanizeAction(label))
	);
	managerUI.replaceStatusText(managerUI.ids.CURRENT_SERVER_STATUS_ID, _('Applying server change...'));
	managerUI.replaceStatusText(managerUI.ids.ENDPOINT_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.HANDSHAKE_STATUS_ID, _('Unavailable'));
	managerUI.setManagerControlsDisabled(true);
	managerStore.setPhase(
		state,
		state.saveApplyInProgress ? managerStore.PHASES.SAVING : managerStore.PHASES.RUNTIME_BUSY
	);
	managerUI.setVpnStatusIndicator('stopping', _('Applying changes'));
	managerUI.updateCountryMatchStatus(state);
	managerUI.updateServerSelectionState(state);
}

function renderLocalStatusSnapshot(state, status) {
	let busyAction;
	const runtimeStatus = status || managerData.parseLocalStatus('{}');
	const desiredEnabled = !!runtimeStatus.desired_enabled;
	const operationStatus = String(state.currentOperationStatus || 'idle');

	state.currentLocalStatus = runtimeStatus;
	renderLocalStatusDetails(state, runtimeStatus);

	if (configurationTransitionActive(state)) {
		renderApplyingTransitionUi(state);
		return runtimeStatus;
	}

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

function parsePublicIpSnapshot(res) {
	const raw = service.parseExecJsonResponse(res, null);
	const fallbackIp = (res && res.code === 0) ? normalizePublicIpValue(res.stdout) : '';
	const snapshot = {
		ip: fallbackIp,
		changed: false,
		country: ''
	};

	if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
		snapshot.ip = normalizePublicIpValue(raw.ip || '');
		snapshot.changed = !!raw.changed;
		snapshot.country = managerData.normalizeCountryCode(raw.country || '');
	}

	return snapshot;
}

function updatePublicIp(state, options) {
	const opts = options || {};

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

		return service.execService('public_ip').then(function(res) {
			const snapshot = parsePublicIpSnapshot(res);
			const publicIp = (res.code === 0) ? snapshot.ip : '';
			state.currentPublicIp = publicIp;
			state.currentPublicCountry = snapshot.changed
				? snapshot.country
				: (snapshot.country || state.currentPublicCountry || '');
			managerUI.replaceStatusText(
				managerUI.ids.PUBLIC_IP_STATUS_ID,
				publicIp || _('Unavailable')
			);

			if (!publicIp) {
				state.currentPublicCountry = '';
				managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
				managerUI.updateCountryMatchStatus(state);
				return Promise.resolve();
			}

			managerUI.replaceStatusText(
				managerUI.ids.PUBLIC_COUNTRY_STATUS_ID,
				state.currentPublicCountry || _('Unavailable')
			);
			managerUI.updateCountryMatchStatus(state);
		}).catch(function() {
			state.currentPublicIp = '';
			state.currentPublicCountry = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		});
	});
}

function renderDiagnosticsSnapshot(state, summary, fresh) {
	state.currentDiagnosticsSummary = summary;
	state.currentDiagnosticsSummaryFresh = !!fresh;

	if (!driftEvaluationAllowed(state)) {
		suppressDriftUi(state);
		return;
	}

	managerUI.updateDiagnosticsBanner(summary);
}

function updateDiagnosticsSummary(state, options) {
	const opts = options || {};

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve(state.currentDiagnosticsSummary);

	if (!driftEvaluationAllowed(state)) {
		suppressDriftUi(state);
		return Promise.resolve(state.currentDiagnosticsSummary);
	}

	if (!state.appliedEnabled) {
		renderDiagnosticsSnapshot(state, managerData.emptyDiagnosticsSummary(), false);
		return Promise.resolve(state.currentDiagnosticsSummary);
	}

	return managerStore.runExclusive(state, 'diagnostics', function() {
		return service.execService('diagnostics_summary').then(function(res) {
			const diagnosticsSnapshot = buildDiagnosticsSnapshot(res);

			renderDiagnosticsSnapshot(state, diagnosticsSnapshot.summary, diagnosticsSnapshot.fresh);
			return diagnosticsSnapshot.summary;
		}).catch(function() {
			renderDiagnosticsSnapshot(state, managerData.emptyDiagnosticsSummary(), false);
			return state.currentDiagnosticsSummary;
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
			if (configurationTransitionActive(state) && state.pendingOperationLabel)
				state.currentOperationStatus = 'busy:' + state.pendingOperationLabel;
			else if (configurationTransitionActive(state))
				state.currentOperationStatus = state.currentOperationStatus || 'busy:configuration';
			else
				state.currentOperationStatus = String(status.operation_status || 'idle');
			state.appliedEnabled = desiredEnabled;
			state.appliedCountryCode = managerData.normalizeCountryCode(status.selected_country || state.appliedCountryCode);
			renderLocalStatusSnapshot(state, status);
			// Drift is evaluated only after Save & Apply / runtime actions finish.
			if (desiredEnabled && driftEvaluationAllowed(state))
				void updateDiagnosticsSummary(state, { force: opts.force });
			else if (!driftEvaluationAllowed(state))
				suppressDriftUi(state);
			else
				renderDiagnosticsSnapshot(state, managerData.emptyDiagnosticsSummary(), false);

			if (!opts.suppressAutoReconcile && desiredEnabled && driftEvaluationAllowed(state))
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

function syncSubmittedRuntimeConfigToUci(submitted) {
	const country = managerData.normalizeCountryCode((submitted && submitted.country) || '');
	const mode = normalizeSelectionMode((submitted && submitted.mode) || 'auto');

	uci.set('nordvpn_easy', 'main', 'vpn_country', country);
	uci.set('nordvpn_easy', 'main', 'server_selection_mode', mode);
	uci.set('nordvpn_easy', 'main', 'enabled', (submitted && submitted.enabled) ? '1' : '0');
}

function mergeSavedConfigWithSubmittedValues(savedConfig, submitted) {
	const merged = Object.assign({}, savedConfig || {});
	const formCountry = managerData.normalizeCountryCode((submitted && submitted.country) || '');

	if (submitted && Object.prototype.hasOwnProperty.call(submitted, 'country'))
		merged.country = formCountry;

	if (submitted && submitted.mode)
		merged.mode = normalizeSelectionMode(submitted.mode);

	if (submitted && Object.prototype.hasOwnProperty.call(submitted, 'enabled'))
		merged.enabled = !!submitted.enabled;

	if (submitted && Object.prototype.hasOwnProperty.call(submitted, 'preferredStation'))
		merged.preferredStation = String(submitted.preferredStation || '');

	return merged;
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
	state.saveApplyInProgress = false;
	managerStore.setPhase(state, managerStore.PHASES.IDLE);

	return updateLocalStatus(state, {
		force: true,
		suppressAutoReconcile: !!opts.suppressAutoReconcile
	}).then(function() {
		if (refreshPublicIp)
			return updatePublicIp(state, { force: true });

		return null;
	}).then(function() {
		return refreshLuCiChangeTracker();
	}).then(function(result) {
		managerStore.resumePolling(state);
		return result;
	}).catch(function(err) {
		managerStore.resumePolling(state);
		return Promise.reject(err);
	});
}

function handleSaveApply(viewState, state, ev) {
	const previousEnabled = !!viewState.initialEnabled;
	const previousCountry = viewState.initialCountry || '';
	const previousMode = viewState.initialMode || 'auto';
	const previousPreferredStation = viewState.initialPreferredStation || '';
	const submittedRuntimeConfig = readSubmittedConfigFromForm(state);
	const selectedServer = submittedRuntimeConfig.preferredStation
		? state.serverCatalogIndex[submittedRuntimeConfig.preferredStation]
		: null;
	const debugLines = buildSaveApplyDebugLines(
		previousEnabled,
		submittedRuntimeConfig.enabled,
		previousCountry,
		submittedRuntimeConfig.country,
		previousMode,
		submittedRuntimeConfig.mode,
		previousPreferredStation,
		submittedRuntimeConfig.preferredStation,
		selectedServer
	);

	notifyDebugBlock(_('Save & Apply requested'), debugLines.concat([
		_('Runtime flow: stop VPN, save configuration, connect when enabled.')
	]));

	managerStore.clearError(state);
	state.saveApplyInProgress = true;
	markRuntimeActionCooldown(state);
	managerStore.suspendPolling(state);
	managerStore.setPhase(state, managerStore.PHASES.SAVING);
	suppressDriftUi(state);

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

		timeoutId = setTimeout(function() {
			const timeoutError = new Error(_('Configuration apply timed out.'));

			managerStore.setError(state, timeoutError);
			state.pendingOperationLabel = '';
			state.saveApplyInProgress = false;
			managerStore.resumePolling(state);
			updateLocalStatus(state, { force: true });
			finishReject(timeoutError);
		}, SAVE_APPLY_TIMEOUT_MS);

		state.pendingOperationLabel = _('configuration');
		state.currentOperationStatus = 'busy:configuration';
		updateLocalStatus(state, { force: true });

		runApplyCycle(viewState, state, ev, {
			submitted: submittedRuntimeConfig,
			skipDriftRestart: false,
			driftDepth: 0
		}).then(function() {
			state.saveApplyInProgress = false;
			finishResolve();
		}).catch(function(err) {
			const message = (err && err.message) ? err.message : String(err);

			state.saveApplyInProgress = false;
			managerStore.setError(state, err);
			return refreshAfterSaveApply(state, true, { suppressAutoReconcile: true }).then(function() {
				service.notifyError(new Error(_('Save & Apply failed: ') + message));
				finishReject(err);
			});
		});
	});
}

return baseclass.extend({
	runApplyCycle: runApplyCycle,
	maybeAutoReconcileSelectionDrift: maybeAutoReconcileSelectionDrift,
	runtimeOperationIsBusy: runtimeOperationIsBusy,
	loadServerCatalog: loadServerCatalog,
	renderLocalStatusSnapshot: renderLocalStatusSnapshot,
	renderDiagnosticsSnapshot: renderDiagnosticsSnapshot,
	updatePublicIp: updatePublicIp,
	updateLocalStatus: updateLocalStatus,
	updateDiagnosticsSummary: updateDiagnosticsSummary,
	onCountryChanged: onCountryChanged,
	onModeChanged: onModeChanged,
	handleRefreshServerCatalog: handleRefreshServerCatalog,
	handleSaveApply: handleSaveApply
});
