'use strict';
/* global baseclass, managerData */
'require baseclass';
'require nordvpn-easy/manager-data as managerData';

const PHASES = {
	BOOTING: 'booting',
	IDLE: 'idle',
	SAVING: 'saving',
	RUNTIME_BUSY: 'runtime_busy',
	DISABLED: 'disabled',
	ERROR: 'error'
};

function createState() {
	return {
		phase: PHASES.BOOTING,
		pendingOperationLabel: '',
		currentOperationStatus: 'idle',
		currentPublicIp: '',
		currentPublicCountry: '',
		appliedEnabled: false,
		appliedCountryCode: '',
		currentLocalStatus: managerData.parseLocalStatus('{}'),
		currentLocalStatusFresh: false,
		currentLocalStatusLastUpdated: 0,
		currentServerCatalog: managerData.emptyServerCatalog(),
		currentDiagnosticsSummary: managerData.emptyDiagnosticsSummary(),
		currentDiagnosticsSummaryFresh: false,
		serverCatalogIndex: {},
		latestServerCatalogRequestId: 0,
		lastAutoReconcileFailureKey: '',
		lastAutoReconcileFailureAt: 0,
		saveApplyInProgress: false,
		runtimeActionCooldownUntil: 0,
		pollingSuspended: false,
		pollersStarted: false,
		lastError: '',
		inFlight: {
			status: null,
			diagnostics: null,
			publicIp: null,
			catalog: null,
			autoReconcile: null
		}
	};
}

function shouldLoadCatalog(mode, country) {
	return String(mode || 'auto') === 'manual' && !!managerData.normalizeCountryCode(country || '');
}

function setPhase(state, phase) {
	state.phase = phase;
	return phase;
}

function setError(state, err) {
	state.lastError = (err && err.message) ? err.message : String(err || '');
	state.phase = PHASES.ERROR;
}

function clearError(state) {
	state.lastError = '';
}

function derivePhase(state) {
	const operation = String(state.currentOperationStatus || 'idle');

	if (state.saveApplyInProgress || operation === 'busy' || operation.indexOf('busy:') === 0)
		return PHASES.RUNTIME_BUSY;

	if (state.lastError)
		return PHASES.ERROR;

	if (!state.appliedEnabled || state.currentLocalStatus.runtime_disabled || state.currentLocalStatus.interface_disabled)
		return PHASES.DISABLED;

	return PHASES.IDLE;
}

function syncPhase(state) {
	return setPhase(state, derivePhase(state));
}

function suspendPolling(state) {
	state.pollingSuspended = true;
}

function resumePolling(state) {
	state.pollingSuspended = false;
}

function clearInFlight(state, key) {
	if (!state || !state.inFlight)
		return;

	state.inFlight[key] = null;
}

function runExclusive(state, key, factory, options) {
	const opts = options || {};

	if (opts.fresh)
		clearInFlight(state, key);

	const current = state.inFlight[key];

	if (current)
		return current;

	state.inFlight[key] = Promise.resolve().then(factory).finally(function() {
		state.inFlight[key] = null;
	});

	return state.inFlight[key];
}

return baseclass.extend({
	PHASES: PHASES,
	createState: createState,
	shouldLoadCatalog: shouldLoadCatalog,
	setPhase: setPhase,
	setError: setError,
	clearError: clearError,
	syncPhase: syncPhase,
	suspendPolling: suspendPolling,
	resumePolling: resumePolling,
	clearInFlight: clearInFlight,
	runExclusive: runExclusive
});
