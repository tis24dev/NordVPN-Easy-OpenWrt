'use strict';
/* global baseclass, managerData, managerFormat, managerStore, managerUI, service, ui, uci, rpc, request, L, document, Date, localStorage, setTimeout, clearTimeout, E, _ */
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
const SAVE_APPLY_TIMEOUT_MS = 240000;
const RUNTIME_ACTION_RECOVERY_POLL_MS = 3000;
const APPLY_CONVERGENCE_POLL_MS = 1000;
const CONNECT_APPLY_DISPATCH_CLOCK_SLACK_MS = 120000;
const RUNTIME_ACTION_COOLDOWN_MS = SAVE_APPLY_TIMEOUT_MS + 30000;
const ENABLED_RUNTIME_RECOVERY_COOLDOWN_MS = 15000;
const POST_APPLY_RECOVERY_GRACE_MS = 120000;
let callUciCommit = null;

// Opt-in, same-origin-only Save & Apply timing log (development / lab). It is
// disabled unless localStorage['nordvpnEasyTimingLog'] === '1'. When enabled it
// posts one record per milestone to the timing CGI on the same origin; it never
// contacts any external endpoint. See docs/DIAGNOSTICS.md section 3.
const TIMING_LOG_ENDPOINT = '/cgi-bin/nordvpn-easy-timing-log';
const TIMING_LOG_FLAG = 'nordvpnEasyTimingLog';

function timingLogEnabled() {
	try {
		return typeof localStorage !== 'undefined' && localStorage.getItem(TIMING_LOG_FLAG) === '1';
	} catch (e) {
		return false;
	}
}

function timingLog(location, event, data) {
	if (!timingLogEnabled())
		return;

	if (typeof request === 'undefined' || typeof request.post !== 'function')
		return;

	request.post(TIMING_LOG_ENDPOINT, {
		location: location,
		event: event,
		data: data || {},
		timestamp: Date.now()
	}, {
		timeout: 5000,
		credentials: true
	}).catch(function() {});
}

// Always-on, same-origin record of when the on-screen Country Match indicator
// transitions, so the change lands in the automatic diagnostics log (the timing
// CGI mirrors country_match events to the system log, which diagnostics_log
// exports). Unlike the opt-in timing log this is not gated, but it only fires on
// a real indicator transition (manager-ui dedups), so the volume stays low.
function postCountryMatchLog(info) {
	if (typeof request === 'undefined' || typeof request.post !== 'function')
		return;

	const indicator = (info && info.indicator) || 'unknown';
	const selected = (info && info.expected) || 'automatic';
	const exit = (info && info.actual) || 'unknown';
	const message = 'country match indicator -> ' + indicator +
		' (selected=' + selected + ', exit=' + exit + ')';

	request.post(TIMING_LOG_ENDPOINT, {
		location: 'countryMatch',
		event: 'country_match',
		message: message,
		data: { indicator: indicator, selected: selected, exit: exit },
		timestamp: Date.now()
	}, {
		timeout: 5000,
		credentials: true
	}).catch(function() {});
}

function newApplyAttemptId(state) {
	// Keep the counter on state so each manager instance has its own apply-id
	// sequence, instead of a module-global shared across views.
	state.nextApplyAttempt = (state.nextApplyAttempt || 0) + 1;
	return 'apply-' + state.nextApplyAttempt;
}

function applyAttemptIsCurrent(state, applyAttemptId) {
	return !applyAttemptId || (state && state.currentApplyAttempt === applyAttemptId);
}

function staleApplyAttemptError() {
	const err = new Error('Apply attempt was superseded.');

	err.staleApplyAttempt = true;
	return err;
}

function rejectStaleApplyAttempt() {
	return Promise.reject(staleApplyAttemptError());
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
		notifyDriftQueued: !!opts.notifyDriftQueued,
		applyAttemptId: opts.applyAttemptId || null
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
			return finishApplyCycle(state, { suppressAutoReconcile: true }).then(function() {
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

function runtimeActionFailureFromStatus(status) {
	const runtimeStatus = status || {};

	if (String(runtimeStatus.state || '') === 'failed')
		return true;

	if (String(runtimeStatus.vpn_status || '') === 'error')
		return true;

	return !!(runtimeStatus.last_error && String(runtimeStatus.last_error).trim());
}

function applyConvergencePollIntervalMs(state) {
	return (state && state.saveApplyInProgress) ?
		APPLY_CONVERGENCE_POLL_MS :
		RUNTIME_ACTION_RECOVERY_POLL_MS;
}

function noteConnectApplyServerMarker(state, status) {
	const runtimeStatus = status || {};
	const startedAt = Number(runtimeStatus.connect_apply_started_at || 0);

	if (!state || !state.connectApplyDispatchedAt || startedAt <= 0)
		return;

	state.connectApplyServerStartedAt = Math.max(
		Number(state.connectApplyServerStartedAt || 0),
		startedAt
	);
}

function savedConfigForApplyState(state) {
	return {
		enabled: state.appliedEnabled !== false,
		country: managerData.normalizeCountryCode(state.appliedCountryCode || ''),
		mode: 'auto',
		preferredStation: ''
	};
}

function applyRuntimeCountryMatchesSaved(savedConfig, status) {
	const runtimeStatus = status || {};
	const savedCountry = managerData.normalizeCountryCode((savedConfig && savedConfig.country) || '');

	if (!savedCountry)
		return true;

	const serverCountry = managerData.normalizeCountryCode(runtimeStatus.current_server_country || '');

	return serverCountry === savedCountry;
}

function applyRuntimeLiveReady(savedConfig, status) {
	const runtimeStatus = status || {};

	if (!savedConfig || !savedConfig.enabled)
		return false;

	if (!applyRuntimeCountryMatchesSaved(savedConfig, runtimeStatus))
		return false;

	const vpnUp = runtimeStatus.connected === true ||
		String(runtimeStatus.vpn_status || '') === 'active' ||
		String(runtimeStatus.state || '') === 'connected';

	if (!vpnUp)
		return false;

	const handshakeAge = Number(runtimeStatus.handshake_age_seconds);
	const handshakeFresh = Number.isFinite(handshakeAge) &&
		handshakeAge >= 0 &&
		handshakeAge < 180;

	return handshakeFresh;
}

function applyRuntimeConvergenceSucceeded(savedConfig, status, state) {
	if (savedConfig && savedConfig.enabled)
		return applyRuntimeLiveReady(savedConfig, status);

	return runtimeActionRecoverySucceeded(savedConfig, status, state);
}

function awaitRuntimeConvergenceAfterDispatch(state, savedConfig, applyAttemptId, successMessage) {
	const deadline = Date.now() + SAVE_APPLY_TIMEOUT_MS;

	const pollForConvergence = function() {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (Date.now() >= deadline) {
			return Promise.reject(new Error(
				_('Configuration apply timed out waiting for VPN runtime to finish.')
			));
		}

		return updateLocalStatus(state, {
			force: true,
			suppressAutoReconcile: true
		}).then(function(status) {
			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return rejectStaleApplyAttempt();

			const runtimeStatus = status || null;

			if (runtimeStatus)
				noteConnectApplyServerMarker(state, runtimeStatus);

			if (connectApplyJobFailed(state, runtimeStatus)) {
				throw new Error(_('VPN connect failed.'));
			}

			if (runtimeActionFailureFromStatus(runtimeStatus)) {
				const failureMessage = String((runtimeStatus && runtimeStatus.last_error) || '').trim() ||
					_('VPN connect failed.');

				throw new Error(failureMessage);
			}

			if (applyRuntimeConvergenceSucceeded(savedConfig, runtimeStatus, state)) {
				service.notifyInfo(successMessage);
				return finishApplyCycle(state, {
					suppressAutoReconcile: true,
					applyAttemptId: applyAttemptId
				});
			}

			return new Promise(function(resolve, reject) {
				setTimeout(function() {
					pollForConvergence().then(resolve, reject);
				}, applyConvergencePollIntervalMs(state));
			});
		});
	};

	return service.runAction('start_connect').then(function(dispatchResult) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (!dispatchResult.success) {
			const error = service.resultToError(dispatchResult);

			error.result = dispatchResult;
			throw error;
		}

		state.connectApplyDispatchedAt = Date.now();
		return pollForConvergence();
	});
}


function recoverEnabledRuntimeAfterApplyFailure() {
	return service.runAction('abort_connect_apply').catch(function() {
		return { success: true };
	}).then(function() {
		return service.runAction('start_connect');
	});
}

function runtimeRecoveryRequested(submitted, state) {
	const submittedEnabled = !!(submitted && submitted.enabled);
	const status = (state && state.currentLocalStatus) || {};

	return submittedEnabled || !!status.desired_enabled;
}


function shouldRecoverAfterApplyFailure(state, submitted) {
	if (!runtimeRecoveryRequested(submitted, state))
		return false;

	if (state && state.connectApplyDispatchedAt)
		return false;

	return String((state && state.applyPhase) || '') === 'stop_vpn';
}

function runApplyCycleConfigurationPhase(viewState, state, ev, submitted, skipFormSave, applyAttemptId) {
	if (!applyAttemptIsCurrent(state, applyAttemptId))
		return rejectStaleApplyAttempt();

	if (skipFormSave || !submitted)
		return loadSavedRuntimeConfig();

	state.applyPhase = 'configuration';
	timingLog('runApplyCycleConfigurationPhase', 'configuration', {
		country: (submitted && submitted.country) || ''
	});

	return Promise.resolve(viewState && viewState.handleSave ? viewState.handleSave(ev) : null).then(function() {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		syncPreferredServerFieldsToUci(submitted, state.serverCatalogIndex || {});
		syncSubmittedRuntimeConfigToUci(submitted);

		return flushLuCiPendingChanges();
	}).then(function() {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		return loadSavedRuntimeConfig().then(function(savedConfig) {
			const expectedCountry = managerData.normalizeCountryCode((submitted && submitted.country) || '');
			const persistedCountry = managerData.normalizeCountryCode((savedConfig && savedConfig.country) || '');

			if (expectedCountry && persistedCountry !== expectedCountry) {
				return Promise.reject(new Error(
					_('Server country %s was not persisted to UCI before VPN reconnect (found %s).')
						.format(expectedCountry, persistedCountry || _('empty'))
				));
			}

			return savedConfig;
		});
	});
}

function runApplyCycleStopWithConnectApplyGuard(state, applyAttemptId) {
	return service.runAction('begin_connect_apply').then(function(beginResult) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (!beginResult.success)
			throw service.resultToError(beginResult);

		state.applyPhase = 'stop_vpn';

		return service.runAction('stop_vpn').then(function(stopResult) {
			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return rejectStaleApplyAttempt();

			if (!stopResult.success)
				throw service.resultToError(stopResult);
		});
	});
}

function runApplyCycleDisabledStop(state, applyAttemptId) {
	if (!applyAttemptIsCurrent(state, applyAttemptId))
		return rejectStaleApplyAttempt();

	state.applyPhase = 'stop_vpn';

	return service.runAction('stop_vpn').then(function(stopResult) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (!stopResult.success)
			throw service.resultToError(stopResult);
	});
}

function recentConnectApplySucceeded(status, maxAgeMs) {
	const runtimeStatus = status || {};
	const finishedAt = Number(runtimeStatus.connect_apply_finished_at || 0) * 1000;
	const graceMs = Number(maxAgeMs) || POST_APPLY_RECOVERY_GRACE_MS;

	if (!runtimeStatus.connect_apply_finished || !runtimeStatus.connect_apply_success || !finishedAt)
		return false;

	return (Date.now() - finishedAt) < graceMs;
}

function postApplyRecoveryGraceActive(state) {
	const until = Number((state && state.postApplyRecoveryGraceUntil) || 0);

	return until > 0 && Date.now() < until;
}

function runtimeNeedsEnabledRecovery(status, state) {
	const runtimeStatus = status || {};

	if (!runtimeStatus.desired_enabled && !runtimeStatus.enabled)
		return false;

	if (state && (state.saveApplyInProgress || managerUI.isDisableRequested(state)))
		return false;

	if (postApplyRecoveryGraceActive(state))
		return false;

	if (recentConnectApplySucceeded(runtimeStatus, POST_APPLY_RECOVERY_GRACE_MS))
		return false;

	if (runtimeStatus.connect_apply_pending)
		return false;

	if (runtimeOperationIsBusy(state, runtimeStatus))
		return false;

	// runtime_configured is normalized to a boolean in parseLocalStatus, so a
	// single-type check suffices (no dual string/boolean check needed).
	if (runtimeStatus.runtime_configured === true)
		return false;

	if (runtimeStatus.vpn_status === 'active' || runtimeStatus.connected)
		return false;

	if (runtimeStatus.vpn_status === 'error')
		return false;

	return true;
}

function maybeEnsureEnabledRuntime(state, status) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};

	if (!state || !runtimeNeedsEnabledRecovery(runtimeStatus, state))
		return Promise.resolve(false);

	const now = Date.now();
	const lastAttempt = Number(state.lastEnabledRuntimeRecoveryAt || 0);

	if (state.enabledRuntimeRecoveryInFlight)
		return Promise.resolve(false);

	if (lastAttempt > 0 && (now - lastAttempt) < ENABLED_RUNTIME_RECOVERY_COOLDOWN_MS)
		return Promise.resolve(false);

	state.lastEnabledRuntimeRecoveryAt = now;
	state.enabledRuntimeRecoveryInFlight = true;

	return managerStore.runExclusive(state, 'enabledRecovery', function() {
		return service.runAction('reconcile').then(function(result) {
			if (!result.success && !result.busy)
				state.lastEnabledRuntimeRecoveryFailureAt = Date.now();

			return !!result.success;
		}).catch(function() {
			state.lastEnabledRuntimeRecoveryFailureAt = Date.now();
			return false;
		}).finally(function() {
			state.enabledRuntimeRecoveryInFlight = false;
		});
	});
}

function maybeRecoverOrphanedRuntime(state) {
	return maybeEnsureEnabledRuntime(state, state && state.currentLocalStatus);
}

function captureApplySelectionBaseline(state, viewState) {
	const baseline = (state && state.applySelectionBaseline) || {};

	if (baseline.captured)
		return baseline;

	baseline.captured = true;
	baseline.country = managerData.normalizeCountryCode(
		uci.get('nordvpn_easy', 'main', 'vpn_country') || ''
	);
	baseline.mode = normalizeSelectionMode(
		uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto'
	);
	baseline.preferredStation = String(
		uci.get('nordvpn_easy', 'main', 'preferred_server_station') || ''
	);

	if (state)
		state.applySelectionBaseline = baseline;

	return baseline;
}

function runtimeSelectionChanged(state, viewState, submitted) {
	const baseline = captureApplySelectionBaseline(state, viewState);
	const nextCountry = managerData.normalizeCountryCode((submitted && submitted.country) || '');
	const nextMode = normalizeSelectionMode((submitted && submitted.mode) || 'auto');
	const nextStation = String((submitted && submitted.preferredStation) || '');

	return baseline.country !== nextCountry ||
		baseline.mode !== nextMode ||
		baseline.preferredStation !== nextStation;
}

function runApplyCycleStopPhase(viewState, state, submitted, applyAttemptId) {
	if (!applyAttemptIsCurrent(state, applyAttemptId))
		return rejectStaleApplyAttempt();

	state.applyPhase = 'stop_vpn';

	const selectionChanged = runtimeSelectionChanged(state, viewState, submitted);
	timingLog('runApplyCycleStopPhase', 'stop_phase', { selectionChanged: selectionChanged });

	if (!selectionChanged)
		return runApplyCycleStopWithConnectApplyGuard(state, applyAttemptId);

	return service.runAction('stop_vpn').then(function(stopResult) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (!stopResult.success)
			throw service.resultToError(stopResult);

		return service.runAction('begin_connect_apply').then(function(beginResult) {
			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return rejectStaleApplyAttempt();

			if (!beginResult.success)
				throw service.resultToError(beginResult);
		});
	});
}

function shouldHideDiagnosticsAlerts(state) {
	if (!state)
		return false;

	return !!state.saveApplyInProgress ||
		!!managerData.normalizeCountryCode(state.applyTargetCountryCode || '');
}

function runApplyCycleConnectPhase(state, savedConfig, applyAttemptId) {
	const successMessage = APPLY_CYCLE_SUCCESS_CONNECTED;

	if (!applyAttemptIsCurrent(state, applyAttemptId))
		return rejectStaleApplyAttempt();

	state.applyPhase = 'connect';
	timingLog('runApplyCycleConnectPhase', 'connect', {});

	return awaitRuntimeConvergenceAfterDispatch(state, savedConfig, applyAttemptId, successMessage);
}

function runApplyCycle(viewState, state, ev, options) {
	const opts = options || {};
	const submitted = opts.submitted || null;
	const skipFormSave = !!opts.skipFormSave;
	const applyAttemptId = opts.applyAttemptId || null;

	if (!applyAttemptIsCurrent(state, applyAttemptId))
		return rejectStaleApplyAttempt();

	if (opts.notifyDriftQueued && opts.driftContext)
		notifyDebugBlock(_('Runtime sync queued'), autoReconcileDebugLines(opts.driftContext));

	return runApplyCycleConfigurationPhase(viewState, state, ev, submitted, skipFormSave, applyAttemptId).then(function(savedConfig) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (submitted && !skipFormSave)
			savedConfig = mergeSavedConfigWithSubmittedValues(savedConfig, submitted);

		if (viewState)
			rememberSavedRuntimeConfig(viewState, state, savedConfig);

		if (savedConfig.enabled && !nordvpnTokenIsPresent()) {
			const tokenError = new Error(_('NordVPN token is required before enabling NordVPN Easy.'));

			service.notifyError(tokenError);
			return finishApplyCycle(state, {
				suppressAutoReconcile: true,
				applyAttemptId: applyAttemptId
			}).then(function() {
				throw tokenError;
			});
		}

		if (!savedConfig.enabled) {
			return runApplyCycleDisabledStop(state, applyAttemptId).then(function() {
				service.notifyInfo(APPLY_CYCLE_SUCCESS_DISABLED);
				return finishApplyCycle(state, {
					suppressAutoReconcile: true,
					applyAttemptId: applyAttemptId
				});
			});
		}

		return runApplyCycleStopPhase(viewState, state, submitted, applyAttemptId).then(function() {
			return runApplyCycleConnectPhase(state, savedConfig, applyAttemptId);
		});
	}).then(function(refreshResult) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		if (opts.skipDriftRestart)
			return refreshResult;

		return maybeRestartApplyCycleOnDrift(viewState, state, ev, {
			driftDepth: Number(opts.driftDepth) || 0,
			driftContext: opts.driftContext || null,
			notifyDriftQueued: true,
			applyAttemptId: applyAttemptId
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
	if (typeof uci !== 'undefined' && typeof uci.save === 'function') {
		return uci.save().then(function() {
			return commitLuCiPendingChangesFallback();
		}).catch(function() {
			return commitLuCiPendingChangesFallback();
		});
	}

	return commitLuCiPendingChangesFallback();
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

	// Key the exclusive slot by country so a fast A->B country switch starts a
	// fresh fetch for B instead of reusing A's in-flight promise (whose result
	// the requestId guard would then discard, leaving the dropdown stale).
	return managerStore.runExclusive(state, 'catalog:' + requestedCountry, function() {
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

function effectiveOperationStatus(runtimeStatus, state) {
	const status = runtimeStatus || {};
	let operation = String(status.operation_status || 'idle');
	const lockState = String(status.operation_lock_state || 'none');
	const lockAction = String(status.operation_lock_action || '').trim();

	if (lockState === 'held' || lockState === 'stale_recovered') {
		if (lockAction)
			operation = 'busy:' + lockAction;
		else if (operation === 'idle')
			operation = 'busy';
	}
	else if (state && state.saveApplyInProgress && operation === 'idle') {
		const phase = String(state.applyPhase || 'configuration').trim();

		operation = phase ? ('busy:' + phase) : 'busy:configuration';
	}
	if (state && state.saveApplyInProgress &&
		operation === 'busy:stop_vpn' &&
		String(status.vpn_status || '') === 'inactive') {
		operation = 'busy:reconfiguring';
	}

	if (state && state.saveApplyInProgress) {
		const applySaved = savedConfigForApplyState(state);

		if (applyRuntimeConvergenceSucceeded(applySaved, status, state))
			return 'busy:finishing';
	}

	return operation;
}

function driftEvaluationAllowed(state) {
	if (!state)
		return false;

	if (state.saveApplyInProgress)
		return false;

	return true;
}

function runtimeOperationIsBusy(state, status) {
	const runtimeStatus = status || (state && state.currentLocalStatus) || {};

	return !!state.saveApplyInProgress ||
		runtimeStatusIndicatesBusy(runtimeStatus);
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

function connectApplyResultBelongsToDispatch(state, status) {
	const runtimeStatus = status || {};
	const dispatchedAt = Number((state && state.connectApplyDispatchedAt) || 0);
	const startedAt = Number(runtimeStatus.connect_apply_started_at || 0);
	const finishedAt = Number(runtimeStatus.connect_apply_finished_at || 0);
	const serverStartedAt = Number((state && state.connectApplyServerStartedAt) || 0);
	const markerSeconds = finishedAt || startedAt;

	if (!dispatchedAt)
		return false;

	if (serverStartedAt > 0 && finishedAt > 0)
		return finishedAt >= serverStartedAt;

	if (!markerSeconds)
		return !!runtimeStatus.connect_apply_finished;

	return (markerSeconds * 1000) >= (dispatchedAt - CONNECT_APPLY_DISPATCH_CLOCK_SLACK_MS);
}

function connectApplyJobFailed(state, status) {
	const runtimeStatus = status || {};

	if (!state || !state.connectApplyDispatchedAt)
		return false;

	if (runtimeStatus.connect_apply_pending)
		return false;

	if (!runtimeStatus.connect_apply_finished || runtimeStatus.connect_apply_success)
		return false;

	return connectApplyResultBelongsToDispatch(state, runtimeStatus);
}

function connectApplyJobSucceeded(state, savedConfig, status) {
	const runtimeStatus = status || {};
	const savedCountry = managerData.normalizeCountryCode((savedConfig && savedConfig.country) || '');
	const resultCountry = managerData.normalizeCountryCode(runtimeStatus.connect_apply_country || '');

	if (!state || !state.connectApplyDispatchedAt)
		return false;

	if (runtimeStatus.connect_apply_pending)
		return false;

	if (!runtimeStatus.connect_apply_finished || !runtimeStatus.connect_apply_success)
		return false;

	if (!state.connectApplyServerStartedAt)
		return false;

	if (!connectApplyResultBelongsToDispatch(state, runtimeStatus))
		return false;

	if (savedCountry && resultCountry && resultCountry === savedCountry)
		return savedRuntimeManualServerMatches(runtimeStatus, savedConfig);

	return savedRuntimeCountryMatches(runtimeStatus, savedConfig) &&
		savedRuntimeManualServerMatches(runtimeStatus, savedConfig);
}

function runtimeActionRecoverySucceeded(savedConfig, status, state) {
	const runtimeStatus = status || {};
	const savedEnabled = !!(savedConfig && savedConfig.enabled);

	if (state && state.saveApplyInProgress &&
		connectApplyJobSucceeded(state, savedConfig, runtimeStatus)) {
		return true;
	}

	if (state && state.saveApplyInProgress &&
		applyRuntimeLiveReady(savedConfig, runtimeStatus)) {
		return true;
	}

	if (runtimeStatus.connect_apply_pending)
		return false;

	if ((!state || !state.saveApplyInProgress) && runtimeStatusIndicatesBusy(runtimeStatus))
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

	if (runtimeStatus.connect_apply_finished && runtimeStatus.connect_apply_success)
		return savedRuntimeCountryMatches(runtimeStatus, savedConfig) &&
			savedRuntimeManualServerMatches(runtimeStatus, savedConfig);

	if (!runtimeStatus.connected &&
		String(runtimeStatus.vpn_status || '') !== 'active' &&
		String(runtimeStatus.state || '') !== 'connected') {
		return false;
	}

	return savedRuntimeCountryMatches(runtimeStatus, savedConfig) &&
		savedRuntimeManualServerMatches(runtimeStatus, savedConfig);
}

function abortedRuntimeActionRecoveryError(err) {
	const message = (err && err.message) ? err.message : String(err);

	return new Error(
		_('Runtime action request was interrupted before LuCI received the response. Original error: ') + message
	);
}

function recoverAbortedRuntimeAction(state, savedConfig, originalError, successMessage, applyAttemptId) {
	const deadline = Date.now() + SAVE_APPLY_TIMEOUT_MS;
	const recoveryError = abortedRuntimeActionRecoveryError(originalError);
	let interruptionNotified = false;

	const notifyInterruptionOnce = function() {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return;

		if (interruptionNotified)
			return;

		interruptionNotified = true;
		notifyDebugBlock(_('Runtime action response interrupted'), [
			_('LuCI lost the backend response while the runtime action may still be running.'),
			_('Polling local status until the runtime finishes.')
		]);
	};

	if (runtimeActionRecoverySucceeded(savedConfig, state.currentLocalStatusFresh ? state.currentLocalStatus : null, state)) {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		service.notifyInfo(successMessage);
		return finishApplyCycle(state, {
			suppressAutoReconcile: true,
			applyAttemptId: applyAttemptId
		});
	}

	const poll = function() {
		if (!applyAttemptIsCurrent(state, applyAttemptId))
			return rejectStaleApplyAttempt();

		return updateLocalStatus(state, {
			force: true,
			suppressAutoReconcile: true
		}).then(function(status) {
			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return rejectStaleApplyAttempt();

			const runtimeStatus = status || null;

			if (runtimeActionRecoverySucceeded(savedConfig, runtimeStatus, state)) {
				service.notifyInfo(successMessage);
				return finishApplyCycle(state, {
					suppressAutoReconcile: true,
					applyAttemptId: applyAttemptId
				});
			}

			notifyInterruptionOnce();

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
	if (shouldHideDiagnosticsAlerts(state))
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

function statusErrorMessage(err) {
	const message = (err && err.message) ? String(err.message) : String(err || '');

	return message || _('Backend status unavailable');
}

function statusResponseError(res) {
	const message = String((res && res.stderr) || '').trim();

	return new Error(message || _('Backend status unavailable'));
}

function renderLocalStatusUnavailable(state, err) {
	const message = statusErrorMessage(err);

	state.currentLocalStatus = Object.assign(managerData.parseLocalStatus('{}'), {
		desired_enabled: !!state.appliedEnabled,
		vpn_status: 'error',
		operation_status: 'unknown',
		last_error: message
	});
	state.currentLocalStatusFresh = false;
	state.currentOperationStatus = 'unknown';
	state.currentPublicIp = '';
	state.currentPublicCountry = '';

	managerUI.replaceStatusText(managerUI.ids.CURRENT_SERVER_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.PREFERRED_SERVER_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.ENDPOINT_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.HANDSHAKE_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.TRANSFER_STATUS_ID, _('0 B / 0 B'));
	managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Unknown'));
	managerUI.replaceStatusText(managerUI.ids.LAST_ERROR_STATUS_ID, message);
	managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
	managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
	managerUI.setManagerControlsDisabled(!!state.saveApplyInProgress);
	managerUI.setVpnStatusIndicator('error', _('Unavailable'));
	managerUI.updateCountryMatchStatus(state);
	managerUI.updateServerSelectionState(state);

	return state.currentLocalStatus;
}

function handleLocalStatusUnavailable(state, err) {
	let fallbackStatus = state.currentLocalStatusLastUpdated ? state.currentLocalStatus : null;

	state.currentLocalStatusFresh = false;
	state.currentLocalStatusLastUpdated = 0;
	managerStore.setError(state, err);

	if (fallbackStatus) {
		renderLocalStatusSnapshot(state, fallbackStatus);
		managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Unknown'));
		managerUI.replaceStatusText(managerUI.ids.LAST_ERROR_STATUS_ID, statusErrorMessage(err));
		state.currentOperationStatus = 'unknown';
		renderDiagnosticsSnapshot(state, managerData.emptyDiagnosticsSummary(), false);
		return fallbackStatus;
	}

	fallbackStatus = renderLocalStatusUnavailable(state, err);
	renderDiagnosticsSnapshot(state, managerData.emptyDiagnosticsSummary(), false);
	return fallbackStatus;
}

function renderLocalStatusSnapshot(state, status) {
	let busyAction;
	const runtimeStatus = status || managerData.parseLocalStatus('{}');
	const desiredEnabled = !!runtimeStatus.desired_enabled;
	const operationStatus = effectiveOperationStatus(runtimeStatus, state);
	const controlsLocked = !!state.saveApplyInProgress || runtimeStatusIndicatesBusy(runtimeStatus);

	state.currentLocalStatus = runtimeStatus;
	state.currentOperationStatus = operationStatus;
	// During an in-flight Save & Apply that has not yet converged, the tunnel is
	// being torn down / re-established, so the raw status snapshot (connected,
	// current_server_*) is optimistically stale (the backend still reports the
	// old session within the 180s handshake window). Mark the transition so the
	// connection indicator and the Current Server line render it honestly instead
	// of trusting the stale snapshot. 'busy:finishing' means convergence already
	// succeeded, so we let the real connected state show through from then on.
	const applyConverging = !!state.saveApplyInProgress && operationStatus !== 'busy:finishing';
	state.applyTransitionActive = applyConverging;
	renderLocalStatusDetails(state, runtimeStatus);

	if (operationStatus.indexOf('busy:') === 0) {
		busyAction = operationStatus.substring(5);
		if (busyAction === 'finishing') {
			managerUI.replaceStatusText(
				managerUI.ids.OPERATION_STATUS_ID,
				_('Finishing connection...')
			);
		}
		else {
			managerUI.replaceStatusText(
				managerUI.ids.OPERATION_STATUS_ID,
				_('Applying (%s)...').format(managerFormat.humanizeAction(busyAction))
			);
		}
	}
	else if (operationStatus === 'busy') {
		managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying...'));
	}
	else {
		managerUI.replaceStatusText(
			managerUI.ids.OPERATION_STATUS_ID,
			operationStatus === 'unknown' ? _('Unknown') : _('Idle')
		);
	}

	managerUI.setManagerControlsDisabled(controlsLocked);

	if (state.saveApplyInProgress)
		managerStore.setPhase(state, managerStore.PHASES.SAVING);
	else if (runtimeStatusIndicatesBusy(runtimeStatus))
		managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
	else
		managerStore.syncPhase(state);

	const enterpriseState = String(runtimeStatus.state || '');

	if (!desiredEnabled || runtimeStatus.runtime_disabled || runtimeStatus.interface_disabled || managerUI.isDisableRequested(state))
		managerUI.setVpnStatusIndicator('inactive', _('Disabled'));
	else if (applyConverging)
		managerUI.setVpnStatusIndicator('starting', _('Connecting'));
	else if (enterpriseState === 'connected' || runtimeStatus.vpn_status === 'active' || runtimeStatus.connected)
		managerUI.setVpnStatusIndicator('active', _('Connected'));
	else if (state.saveApplyInProgress ||
		enterpriseState === 'connecting' || enterpriseState === 'recovering' ||
		enterpriseState === 'degraded' || runtimeStatus.connect_apply_pending ||
		runtimeStatus.vpn_status === 'starting' || state.enabledRuntimeRecoveryInFlight)
		managerUI.setVpnStatusIndicator('starting', _('Connecting'));
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
	if (shouldHideDiagnosticsAlerts(state)) {
		summary = managerData.emptyDiagnosticsSummary();
		fresh = false;
	}

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

	return managerStore.runExclusive(state, 'status', function() {
		return service.execService('status_json').then(function(res) {
			const localStatusSnapshot = buildLocalStatusSnapshot(res);

			if (!localStatusSnapshot.fresh)
				return handleLocalStatusUnavailable(state, statusResponseError(res));

			const status = localStatusSnapshot.status;
			const desiredEnabled = !!status.desired_enabled;

			managerStore.clearError(state);
			state.currentLocalStatus = status;
			state.currentLocalStatusFresh = localStatusSnapshot.fresh;
			state.currentLocalStatusLastUpdated = localStatusSnapshot.fresh ? Date.now() : 0;
			state.currentOperationStatus = effectiveOperationStatus(status, state);

			state.appliedEnabled = desiredEnabled;
			const targetCountry = managerData.normalizeCountryCode(state.applyTargetCountryCode || '');
			const runtimeCountry = managerData.normalizeCountryCode(
				status.current_server_country || status.selected_country || ''
			);

			if (!targetCountry || targetCountry === runtimeCountry) {
				state.appliedCountryCode = managerData.normalizeCountryCode(
					status.selected_country || state.appliedCountryCode
				);
				if (targetCountry && targetCountry === runtimeCountry)
					state.applyTargetCountryCode = '';
			}

			renderLocalStatusSnapshot(state, status);

			if (state.saveApplyInProgress && state.currentApplyAttempt &&
				applyRuntimeConvergenceSucceeded(
					savedConfigForApplyState(state),
					status,
					state
				)) {
				void finishApplyCycle(state, {
					suppressAutoReconcile: true,
					applyAttemptId: state.currentApplyAttempt
				});
			}

			// Drift is evaluated only after Save & Apply / runtime actions finish.
			if (desiredEnabled && driftEvaluationAllowed(state))
				void updateDiagnosticsSummary(state, { force: opts.force });
			else if (!driftEvaluationAllowed(state))
				suppressDriftUi(state);
			else
				renderDiagnosticsSnapshot(state, managerData.emptyDiagnosticsSummary(), false);

			if (!opts.suppressAutoReconcile && desiredEnabled && driftEvaluationAllowed(state))
				void maybeAutoReconcileSelectionDrift(state, status);

			if (desiredEnabled && driftEvaluationAllowed(state))
				void maybeEnsureEnabledRuntime(state, status);

			return status;
		}).catch(function(err) {
			return handleLocalStatusUnavailable(state, err);
		});
	}, { fresh: !!(opts.force || state.saveApplyInProgress) });
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

function finishApplyCycle(state, options) {
	const opts = options || {};
	const applyAttemptId = opts.applyAttemptId || null;

	if (!applyAttemptIsCurrent(state, applyAttemptId))
		return Promise.resolve();

	// Idempotency: the convergence poll, the background status poll, and the
	// timeout watchdog can each reach this for the same attempt. Complete the
	// cycle (state reset + forced refresh) at most once per attempt so a
	// converging apply never triggers a second forced refresh.
	if (applyAttemptId && state.applyCycleFinishedFor === applyAttemptId)
		return Promise.resolve();
	if (applyAttemptId)
		state.applyCycleFinishedFor = applyAttemptId;

	state.pendingOperationLabel = '';
	state.applyPhase = '';
	state.saveApplyInProgress = false;
	// Re-enable the manager controls deterministically when the apply cycle
	// settles, rather than waiting for the forced status refresh below: if that
	// refresh fails or hangs, the controls would otherwise stay disabled.
	managerUI.setManagerControlsDisabled(false);
	state.postApplyRecoveryGraceUntil = Date.now() + POST_APPLY_RECOVERY_GRACE_MS;
	state.applySelectionBaseline = { captured: false };
	managerStore.clearInFlight(state, 'status');
	managerStore.resumePolling(state);
	managerStore.setPhase(state, managerStore.PHASES.IDLE);

	timingLog('finishApplyCycle', 'apply_finished', {
		suppressAutoReconcile: !!opts.suppressAutoReconcile
	});

	return updateLocalStatus(state, {
		force: true,
		suppressAutoReconcile: !!opts.suppressAutoReconcile
	}).then(function() {
		return refreshLuCiChangeTracker();
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
	const applyAttemptId = newApplyAttemptId(state);

	notifyDebugBlock(_('Save & Apply requested'), debugLines.concat([
		_('Runtime flow: save configuration, stop VPN when needed, connect when enabled.')
	]));

	state.currentApplyAttempt = applyAttemptId;
	managerStore.clearError(state);
	state.saveApplyInProgress = true;
	state.applySelectionBaseline = { captured: false };
	captureApplySelectionBaseline(state, viewState);
	state.applyTargetCountryCode = managerData.normalizeCountryCode(submittedRuntimeConfig.country || '');
	state.connectApplyDispatchedAt = 0;
	state.pendingOperationLabel = '';
	state.applyPhase = 'configuration';
	markRuntimeActionCooldown(state);
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
			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return;

			if (settled)
				return;

			settled = true;
			state.currentApplyAttempt = null;
			cleanup();
			resolve(value);
		};

		const finishReject = function(err) {
			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return;

			if (settled)
				return;

			settled = true;
			state.currentApplyAttempt = null;
			cleanup();
			reject(err);
		};

		timeoutId = setTimeout(function() {
			// Early-return if the apply already settled (or this attempt is no
			// longer current): a stale watchdog must not fire a recovery network
			// call or resurrect a settled attempt id.
			if (settled || !applyAttemptIsCurrent(state, applyAttemptId))
				return;

			const timeoutError = new Error(_('Configuration apply timed out.'));
			const timeoutApplyAttemptId = applyAttemptId + ':timeout';
			const recoveryPromise = shouldRecoverAfterApplyFailure(state, submittedRuntimeConfig)
				? recoverEnabledRuntimeAfterApplyFailure()
				: Promise.resolve();

			managerStore.setError(state, timeoutError);
			state.currentApplyAttempt = timeoutApplyAttemptId;
			recoveryPromise.finally(function() {
				finishApplyCycle(state, {
					suppressAutoReconcile: true,
					applyAttemptId: timeoutApplyAttemptId
				}).finally(function() {
					if (!applyAttemptIsCurrent(state, timeoutApplyAttemptId))
						return;

					state.currentApplyAttempt = applyAttemptId;
					finishReject(timeoutError);
				});
			});
		}, SAVE_APPLY_TIMEOUT_MS);

		runApplyCycle(viewState, state, ev, {
			submitted: submittedRuntimeConfig,
			skipDriftRestart: true,
			driftDepth: 0,
			applyAttemptId: applyAttemptId
		}).then(function() {
			finishResolve();
		}).catch(function(err) {
			const message = (err && err.message) ? err.message : String(err);
			const recoveryPromise = shouldRecoverAfterApplyFailure(state, submittedRuntimeConfig)
				? recoverEnabledRuntimeAfterApplyFailure()
				: Promise.resolve();

			if (!applyAttemptIsCurrent(state, applyAttemptId))
				return;

			managerStore.setError(state, err);
			return recoveryPromise.then(function() {
				return finishApplyCycle(state, {
					suppressAutoReconcile: true,
					applyAttemptId: applyAttemptId
				});
			}).then(function() {
				if (!applyAttemptIsCurrent(state, applyAttemptId))
					return;

				service.notifyError(new Error(_('Save & Apply failed: ') + message));
				finishReject(err);
			});
		});
	});
}

return baseclass.extend({
	runApplyCycle: runApplyCycle,
	maybeRecoverOrphanedRuntime: maybeRecoverOrphanedRuntime,
	maybeEnsureEnabledRuntime: maybeEnsureEnabledRuntime,
	maybeAutoReconcileSelectionDrift: maybeAutoReconcileSelectionDrift,
	runtimeOperationIsBusy: runtimeOperationIsBusy,
	loadServerCatalog: loadServerCatalog,
	renderLocalStatusSnapshot: renderLocalStatusSnapshot,
	renderLocalStatusUnavailable: renderLocalStatusUnavailable,
	renderDiagnosticsSnapshot: renderDiagnosticsSnapshot,
	updatePublicIp: updatePublicIp,
	updateLocalStatus: updateLocalStatus,
	updateDiagnosticsSummary: updateDiagnosticsSummary,
	onCountryChanged: onCountryChanged,
	onModeChanged: onModeChanged,
	postCountryMatchLog: postCountryMatchLog,
	handleRefreshServerCatalog: handleRefreshServerCatalog,
	handleSaveApply: handleSaveApply
});
