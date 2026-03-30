'use strict';

function humanizeAction(action) {
	return String(action || _('operation')).replace(/_/g, ' ');
}

function formatActionsLabel(actions) {
	return actions.map(humanizeAction).join(' + ');
}

function formatServerLabel(server) {
	const parts = [];
	let label;

	if (server.country_name)
		parts.push(server.country_name);
	else if (server.country_code)
		parts.push(server.country_code);

	if (server.city)
		parts.push(server.city);

	if (server.hostname)
		parts.push(server.hostname);

	label = parts.join(' - ');

	if (server.load !== '')
		label += (label ? ' - ' : '') + _('Load %s%%').format(server.load);

	return label || server.station;
}

function formatServerSummary(server) {
	if (!server)
		return _('Automatic / Best recommended');

	return formatServerLabel(server);
}

function pluralize(value, singular, plural) {
	return _('%d %s').format(value, value === 1 ? singular : plural);
}

function formatRelativeAge(seconds) {
	let remaining = Math.max(0, Number(seconds || 0));
	const days = Math.floor(remaining / 86400);
	const hours = Math.floor((remaining % 86400) / 3600);
	const minutes = Math.floor((remaining % 3600) / 60);

	if (remaining < 5)
		return _('just now');

	if (days > 0)
		return pluralize(days, _('day'), _('days'));

	if (hours > 0)
		return pluralize(hours, _('hour'), _('hours'));

	if (minutes > 0)
		return pluralize(minutes, _('minute'), _('minutes'));

	return pluralize(Math.floor(remaining), _('second'), _('seconds'));
}

function formatRelativeTimestamp(epochSeconds) {
	const ts = Number(epochSeconds || 0);

	if (!ts)
		return '';

	return _('%s ago').format(formatRelativeAge((Date.now() / 1000) - ts));
}

return {
	humanizeAction: humanizeAction,
	formatActionsLabel: formatActionsLabel,
	formatServerLabel: formatServerLabel,
	formatServerSummary: formatServerSummary,
	formatRelativeAge: formatRelativeAge,
	formatRelativeTimestamp: formatRelativeTimestamp
};
