/**
 * Copyright (C) 2026 tis24dev
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

'use strict';
/* global baseclass, managerData, rpc, ui, document, window, Blob, E, _, L */
'require baseclass';
'require nordvpn-easy/manager-data as managerData';
'require rpc';
'require ui';

// stop_vpn/connect often exceed LuCI default (20s) and stock rpcd (30s).
const RUNTIME_RPC_TIMEOUT = 120;
const START_CONNECT_RPC_TIMEOUT = 15;
const DIAGNOSTICS_RPC_TIMEOUT = 180;
// OpenWrt 24 LuCI rpc.js ignores rpc.declare({ timeout }) and uses
// L.env.rpctimeout only, so execService applies that value per RPC call.
// Keep 180s for diagnostics/rpcd/uhttpd compatibility, not as a page-global.
const LUCI_RPC_TIMEOUT_SEC = 180;

function ensureLuCiRpcTimeout(minSeconds) {
	const min = Number(minSeconds) || LUCI_RPC_TIMEOUT_SEC;

	if (typeof L === 'undefined' || !L.env)
		return min;

	const current = Number(L.env.rpctimeout) || 20;

	if (current < min)
		L.env.rpctimeout = min;

	return Number(L.env.rpctimeout) || min;
}

function setLuCiRpcTimeout(seconds) {
	const timeout = Number(seconds) || LUCI_RPC_TIMEOUT_SEC;

	if (typeof L === 'undefined' || !L.env)
		return timeout;

	L.env.rpctimeout = timeout;
	return Number(L.env.rpctimeout) || timeout;
}

function callWithLuCiRpcTimeout(seconds, fn) {
	setLuCiRpcTimeout(seconds);
	return fn();
}

const callStatus = rpc.declare({
	object: 'nordvpn.easy',
	method: 'status',
	timeout: 45
});

const callConnect = rpc.declare({
	object: 'nordvpn.easy',
	method: 'connect',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callStartConnect = rpc.declare({
	object: 'nordvpn.easy',
	method: 'start_connect',
	timeout: START_CONNECT_RPC_TIMEOUT
});

const callStopVpn = rpc.declare({
	object: 'nordvpn.easy',
	method: 'stop_vpn',
	timeout: RUNTIME_RPC_TIMEOUT
});

// The async supervised apply. The backend setsid-forks the supervise worker
// and this RPC returns in <1s (the JS then polls status_json for convergence), so a
// short START_CONNECT_RPC_TIMEOUT is enough. This is the sole apply path.
const callApply = rpc.declare({
	object: 'nordvpn.easy',
	method: 'apply',
	timeout: START_CONNECT_RPC_TIMEOUT
});

const callRotate = rpc.declare({
	object: 'nordvpn.easy',
	method: 'rotate',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callSetup = rpc.declare({
	object: 'nordvpn.easy',
	method: 'setup',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callCheck = rpc.declare({
	object: 'nordvpn.easy',
	method: 'check',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callReconcile = rpc.declare({
	object: 'nordvpn.easy',
	method: 'reconcile',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callInstallHooks = rpc.declare({
	object: 'nordvpn.easy',
	method: 'install_hooks',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callRemoveHooks = rpc.declare({
	object: 'nordvpn.easy',
	method: 'remove_hooks',
	timeout: RUNTIME_RPC_TIMEOUT
});

const callPublicIp = rpc.declare({
	object: 'nordvpn.easy',
	method: 'public_ip',
	timeout: 45
});

const callDiagnostics = rpc.declare({
	object: 'nordvpn.easy',
	method: 'diagnostics',
	timeout: DIAGNOSTICS_RPC_TIMEOUT
});

const callDiagnosticsSummary = rpc.declare({
	object: 'nordvpn.easy',
	method: 'diagnostics_summary',
	timeout: DIAGNOSTICS_RPC_TIMEOUT
});

const callRefreshCountries = rpc.declare({
	object: 'nordvpn.easy',
	method: 'refresh_countries',
	params: [ 'force' ],
	timeout: 90
});

const callServerCatalog = rpc.declare({
	object: 'nordvpn.easy',
	method: 'server_catalog',
	params: [ 'country', 'force' ],
	timeout: 90
});

function rpcErrorMessage(err) {
	return (err && err.message) ? String(err.message) : String(err);
}

function normalizeRpcError(err) {
	const message = rpcErrorMessage(err);

	if (message.indexOf('Object not found') !== -1) {
		return new Error(
			_('NordVPN Easy backend RPC object is not registered. Reinstall or upgrade luci-app-nordvpn-easy, reload rpcd, then refresh LuCI.')
		);
	}

	return err;
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
	if (result && result.busy) {
		return new Error(
			_('NordVPN Easy is already running %s. Try again when the current operation finishes.').format(
				result.holder_action || _('another operation')
			)
		);
	}

	return new Error(
		_('%s failed with exit code %d: %s').format(
			result.action || _('command'),
			(result.code != null) ? result.code : -1,
			result.message || fallback || _('Unknown error.')
		)
	);
}

function normalizeExecResult(action, payload) {
	let stdout = '';
	let stderr = '';
	let code = 0;
	let message = '';
	let holderAgeSeconds = 0;

	if (payload == null)
		payload = {};

	if (payload.code != null)
		code = Number(payload.code) || 0;
	else if (payload.success === false)
		code = 1;

	if (payload.stdout != null)
		stdout = String(payload.stdout);
	else if (payload.log != null)
		stdout = String(payload.log);
	else if (action === 'diagnostics_log' && payload.message != null && !payload.stderr)
		stdout = String(payload.message);
	else if (payload.stdout == null && payload.log == null &&
		(payload.code == null && payload.success == null || payload.success === false ||
			Object.prototype.hasOwnProperty.call(payload, 'generated_at')))
		stdout = JSON.stringify(payload);

	if (payload.stderr != null)
		stderr = String(payload.stderr);

	if (payload.message != null)
		message = String(payload.message);
	else
		message = responseMessage({ stdout: stdout, stderr: stderr });

	if (payload.holder_age_seconds != null)
		holderAgeSeconds = Number(payload.holder_age_seconds) || 0;

	return {
		action: action,
		code: code,
		busy: !!payload.busy,
		skipped: !!payload.skipped,
		reason: String(payload.reason || ''),
		holder_pid: String(payload.holder_pid || ''),
		holder_action: String(payload.holder_action || ''),
		holder_age_seconds: holderAgeSeconds,
		stdout: stdout,
		stderr: stderr,
		message: message
	};
}

function callSimpleAction(action) {
	switch (action) {
	case 'connect':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callConnect);
	case 'start_connect':
		return callWithLuCiRpcTimeout(START_CONNECT_RPC_TIMEOUT, callStartConnect);
	case 'stop_vpn':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callStopVpn);
	case 'apply':
		return callWithLuCiRpcTimeout(START_CONNECT_RPC_TIMEOUT, callApply);
	case 'rotate':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callRotate);
	case 'setup':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callSetup);
	case 'check':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callCheck);
	case 'reconcile':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callReconcile);
	case 'install_hooks':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callInstallHooks);
	case 'remove_hooks':
		return callWithLuCiRpcTimeout(RUNTIME_RPC_TIMEOUT, callRemoveHooks);
	case 'public_ip':
		return callWithLuCiRpcTimeout(45, callPublicIp);
	default:
		return null;
	}
}

function execService(action, extraArgs) {
	const args = extraArgs || [];
	let request;

	switch (action) {
	case 'status_json':
		request = callWithLuCiRpcTimeout(45, callStatus);
		break;
	case 'refresh_countries':
		request = callWithLuCiRpcTimeout(90, function() { return callRefreshCountries(false); });
		break;
	case 'refresh_countries_force':
		request = callWithLuCiRpcTimeout(90, function() { return callRefreshCountries(true); });
		break;
	case 'server_catalog':
		request = callWithLuCiRpcTimeout(90, function() {
			return callServerCatalog(args[0] || '', args[1] === '1' || args[1] === true);
		});
		break;
	case 'diagnostics_log':
		request = callWithLuCiRpcTimeout(DIAGNOSTICS_RPC_TIMEOUT, callDiagnostics);
		break;
	case 'diagnostics_summary':
		request = callWithLuCiRpcTimeout(DIAGNOSTICS_RPC_TIMEOUT, callDiagnosticsSummary);
		break;
	default:
		request = callSimpleAction(action);
		if (!request)
			return Promise.reject(new Error(_('Unsupported NordVPN Easy action: %s').format(action)));
		break;
	}

	return request.then(function(payload) {
		return normalizeExecResult(action, payload);
	}).catch(function(err) {
		throw normalizeRpcError(err);
	});
}

function runAction(action, extraArgs) {
	return execService(action, extraArgs).then(function(res) {
			return {
				action: action,
				code: res.code,
				success: (res.code === 0),
				busy: !!res.busy,
				skipped: !!res.skipped,
				reason: res.reason || '',
				holder_pid: res.holder_pid || '',
				holder_action: res.holder_action || '',
				holder_age_seconds: res.holder_age_seconds || 0,
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

function parseExecJsonResponse(res, fallback) {
	if (!res || res.code !== 0)
		return fallback;

	return managerData.parseJson(res.stdout || '', fallback);
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

return baseclass.extend({
	LUCI_RPC_TIMEOUT_SEC: LUCI_RPC_TIMEOUT_SEC,
	ensureLuCiRpcTimeout: ensureLuCiRpcTimeout,
	parseExecJsonResponse: parseExecJsonResponse,
	responseMessage: responseMessage,
	resultToError: resultToError,
	execService: execService,
	runAction: runAction,
	notifyInfo: notifyInfo,
	notifyError: notifyError,
	downloadTextFile: downloadTextFile
});
