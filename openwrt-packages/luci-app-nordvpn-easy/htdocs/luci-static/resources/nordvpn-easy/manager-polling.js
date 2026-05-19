'use strict';
/* global baseclass, managerActions, managerStore, poll, document */
'require baseclass';
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-store as managerStore';
'require poll';

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
		if (state.pollingSuspended || documentIsHidden())
			return Promise.resolve();

		return managerActions.updateLocalStatus(state);
	}, 10);

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
	start: start
});
