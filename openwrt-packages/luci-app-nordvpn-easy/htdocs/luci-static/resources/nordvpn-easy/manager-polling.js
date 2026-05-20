'use strict';
/* global baseclass, managerActions, managerStore, poll, document */
'require baseclass';
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-store as managerStore';
'require poll';

const LOCAL_STATUS_POLL_SECONDS = 3;

function documentIsHidden() {
	return (typeof document !== 'undefined') && !!document.hidden;
}

function shouldSkipBackgroundPoll(state) {
	return state.pollingSuspended ||
		state.phase === managerStore.PHASES.SAVING ||
		managerActions.runtimeOperationIsBusy(state, state.currentLocalStatus) ||
		documentIsHidden();
}

function start(state) {
	if (state.pollersStarted)
		return;

	state.pollersStarted = true;

	poll.add(function() {
		if (shouldSkipBackgroundPoll(state) || documentIsHidden())
			return Promise.resolve();

		return managerActions.updateLocalStatus(state);
	}, LOCAL_STATUS_POLL_SECONDS);

	poll.add(function() {
		if (shouldSkipBackgroundPoll(state) || !state.appliedEnabled)
			return Promise.resolve();

		return managerActions.updatePublicIp(state, { quiet: true });
	}, 60);

	poll.add(function() {
		if (shouldSkipBackgroundPoll(state) || !state.appliedEnabled)
			return Promise.resolve();

		return managerActions.updateDiagnosticsSummary(state);
	}, 120);
}

return baseclass.extend({
	LOCAL_STATUS_POLL_SECONDS: LOCAL_STATUS_POLL_SECONDS,
	start: start
});
