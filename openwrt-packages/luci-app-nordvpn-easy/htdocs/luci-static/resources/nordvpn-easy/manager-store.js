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
		countryMatchLogKey: '',
		onCountryMatchChange: null,
		applyTransitionActive: false,
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
		},
		inFlightEpochs: {
			status: 0,
			diagnostics: 0,
			publicIp: 0,
			catalog: 0,
			autoReconcile: 0
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

function ensureInFlightState(state, key) {
	if (!state.inFlight)
		state.inFlight = {};

	if (!state.inFlightEpochs)
		state.inFlightEpochs = {};

	if (state.inFlightEpochs[key] == null)
		state.inFlightEpochs[key] = 0;
}

function inFlightPromise(entry) {
	if (!entry)
		return null;

	if (typeof entry.then === 'function')
		return entry;

	return entry.promise || null;
}

function clearInFlight(state, key) {
	if (!state)
		return;

	ensureInFlightState(state, key);
	state.inFlightEpochs[key]++;
	state.inFlight[key] = null;
}

function runExclusive(state, key, factory, options) {
	const opts = options || {};
	let current;
	let entry;
	let promise;
	let epoch;

	ensureInFlightState(state, key);

	if (opts.fresh)
		clearInFlight(state, key);

	current = inFlightPromise(state.inFlight[key]);

	if (current)
		return current;

	epoch = state.inFlightEpochs[key];
	entry = {
		epoch: epoch,
		promise: null
	};
	promise = Promise.resolve().then(factory).finally(function() {
		if (state.inFlight[key] === entry && state.inFlightEpochs[key] === epoch)
			state.inFlight[key] = null;
	});
	entry.promise = promise;
	state.inFlight[key] = entry;

	return promise;
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
