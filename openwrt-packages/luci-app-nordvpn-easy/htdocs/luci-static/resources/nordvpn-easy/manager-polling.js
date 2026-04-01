'use strict';
'require baseclass';
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-store as managerStore';
'require poll';

function shouldSkipBackgroundPoll(state) {
	return state.pollingSuspended ||
		state.phase === managerStore.PHASES.SAVING ||
		state.phase === managerStore.PHASES.RUNTIME_BUSY;
}

function start(state) {
	if (state.pollersStarted)
		return;

	state.pollersStarted = true;

	poll.add(function() {
		if (state.pollingSuspended)
			return Promise.resolve();

		return managerActions.updateLocalStatus(state);
	}, 2);

	poll.add(function() {
		if (shouldSkipBackgroundPoll(state))
			return Promise.resolve();

		return managerActions.updatePublicIp(state, { quiet: true });
	}, 5);
}

return baseclass.extend({
	start: start
});
