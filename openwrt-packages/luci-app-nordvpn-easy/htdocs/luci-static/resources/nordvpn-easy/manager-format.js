'use strict';

function humanizeAction(action) {
	return String(action || _('operation')).replace(/_/g, ' ');
}

function formatActionsLabel(actions) {
	return actions.map(humanizeAction).join(' + ');
}

function formatServerLabel(server) {
	const parts = [];
	const numericLoad = Number(server.load);
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

	if (server.load != null && server.load !== '' && Number.isFinite(numericLoad))
		label += (label ? ' - ' : '') + _('Load %s%%').format(numericLoad);

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
	let remaining = Number(seconds || 0);
	const parts = [];
	let value;

	if (!Number.isFinite(remaining))
		remaining = 0;
	else
		remaining = Math.max(0, remaining);

	if (remaining < 5)
		return _('just now');

	value = Math.floor(remaining / 86400);
	if (value > 0) {
		parts.push(pluralize(value, _('day'), _('days')));
		remaining -= value * 86400;
	}

	value = Math.floor(remaining / 3600);
	if (value > 0) {
		parts.push(pluralize(value, _('hour'), _('hours')));
		remaining -= value * 3600;
	}

	value = Math.floor(remaining / 60);
	if (value > 0) {
		parts.push(pluralize(value, _('minute'), _('minutes')));
		remaining -= value * 60;
	}

	value = Math.floor(remaining);
	if (value > 0 || !parts.length)
		parts.push(pluralize(value, _('second'), _('seconds')));

	return _('%s ago').format(parts.slice(0, 2).join(', '));
}

function formatRelativeTimestamp(epochSeconds) {
	const ts = Number(epochSeconds || 0);

	if (!ts)
		return '';

	return formatRelativeAge((Date.now() / 1000) - ts);
}

return {
	humanizeAction: humanizeAction,
	formatActionsLabel: formatActionsLabel,
	formatServerLabel: formatServerLabel,
	formatServerSummary: formatServerSummary,
	formatRelativeAge: formatRelativeAge,
	formatRelativeTimestamp: formatRelativeTimestamp
};
