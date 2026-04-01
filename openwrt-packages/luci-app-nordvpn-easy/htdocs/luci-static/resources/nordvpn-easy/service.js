'use strict';
'require baseclass';
'require fs';
'require ui';

function parseJson(raw, fallback) {
	try {
		return JSON.parse(raw || '');
	} catch (e) {
		return fallback;
	}
}

function responseMessage(res, fallback) {
	const lines = [];

	if (res && res.stdout)
		lines.push(res.stdout.trim());

	if (res && res.stderr)
		lines.push(res.stderr.trim());

	return lines.filter(function(line) {
		return line;
	}).join('\n') || fallback || _('Command completed.');
}

function resultToError(result, fallback) {
	return new Error(
		_('%s failed with exit code %d: %s').format(
			result.action || _('command'),
			(result.code != null) ? result.code : -1,
			result.message || fallback || _('Unknown error.')
		)
	);
}

function execService(action, extraArgs) {
	return fs.exec('/etc/init.d/nordvpn-easy', [ action ].concat(extraArgs || []));
}

function runAction(action, extraArgs) {
	return execService(action, extraArgs).then(function(res) {
		return {
			action: action,
			code: res.code,
			success: (res.code === 0),
			stdout: res.stdout || '',
			stderr: res.stderr || '',
			message: responseMessage(res)
		};
	}).catch(function(err) {
		return {
			action: action,
			code: -1,
			success: false,
			stdout: '',
			stderr: '',
			message: (err && err.message) ? err.message : String(err)
		};
	});
}

function runActions(actions) {
	const results = [];

	return actions.reduce(function(chain, action) {
		return chain.then(function() {
			return runAction(action).then(function(result) {
				results.push(result);

				if (!result.success) {
					const error = resultToError(result);

					error.result = result;
					error.results = results.slice();
					throw error;
				}

				return result;
			});
		});
	}, Promise.resolve()).then(function() {
		return results;
	});
}

function parseExecJsonResponse(res, fallback) {
	if (!res || res.code !== 0)
		return fallback;

	return parseJson(res.stdout || '', fallback);
}

function notifyInfo(message) {
	ui.addNotification(null, E('p', message), 'info');
}

function notifyError(err, prefix) {
	const message = (err && err.message) ? err.message : String(err);

	ui.addNotification(null, E('p', prefix ? (prefix + message) : message), 'error');
}

function downloadTextFile(name, content) {
	const blob = new Blob([ content ], { type: 'text/plain;charset=utf-8' });
	const url = window.URL.createObjectURL(blob);
	const link = E('a', {
		style: 'display:none',
		href: url,
		download: name
	});

	document.body.appendChild(link);
	link.click();
	document.body.removeChild(link);
	window.URL.revokeObjectURL(url);
}

function logEvent(message) {
	const normalized = String(message != null ? message : '').trim();

	if (!normalized)
		return Promise.resolve(null);

	return fs.exec('/bin/busybox', [ 'logger', '-t', 'nordvpn-easy', normalized ]).catch(function() {
		return null;
	});
}

return baseclass.extend({
	parseJson: parseJson,
	parseExecJsonResponse: parseExecJsonResponse,
	responseMessage: responseMessage,
	resultToError: resultToError,
	execService: execService,
	runAction: runAction,
	runActions: runActions,
	notifyInfo: notifyInfo,
	notifyError: notifyError,
	downloadTextFile: downloadTextFile,
	logEvent: logEvent
});
