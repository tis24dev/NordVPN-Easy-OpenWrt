'use strict';
/* global baseclass, managerActions, managerStore, poll, document */
'require baseclass';
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-store as managerStore';
'require poll';

const LOCAL_STATUS_POLL_SECONDS = 3;
const PUBLIC_IP_POLL_SECONDS = 5;

function documentIsHidden() {
	return (typeof document !== 'undefined') && !!document.hidden;
}

function shouldSkipBackgroundPoll(state) {
	return state.pollingSuspended ||
		state.phase === managerStore.PHASES.SAVING ||
		managerActions.runtimeOperationIsBusy(state, state.currentLocalStatus) ||
		documentIsHidden();
}

function shouldSkipPublicIpPoll(state) {
	return state.pollingSuspended || documentIsHidden();
}

function start(state) {
	if (state.pollersStarted)
		return;

	state.pollersStarted = true;

	poll.add(function() {
		if (documentIsHidden())
			return Promise.resolve();

		return managerActions.updateLocalStatus(state, {
			suppressAutoReconcile: !!state.saveApplyInProgress
		});
	}, LOCAL_STATUS_POLL_SECONDS);

	poll.add(function() {
		if (shouldSkipPublicIpPoll(state) || !state.appliedEnabled)
			return Promise.resolve();

		return managerActions.updatePublicIp(state, { quiet: true });
	}, PUBLIC_IP_POLL_SECONDS);

	poll.add(function() {
		if (shouldSkipBackgroundPoll(state) || !state.appliedEnabled)
			return Promise.resolve();

		return managerActions.updateDiagnosticsSummary(state);
	}, 120);
}

return baseclass.extend({
	LOCAL_STATUS_POLL_SECONDS: LOCAL_STATUS_POLL_SECONDS,
	PUBLIC_IP_POLL_SECONDS: PUBLIC_IP_POLL_SECONDS,
	start: start
});
