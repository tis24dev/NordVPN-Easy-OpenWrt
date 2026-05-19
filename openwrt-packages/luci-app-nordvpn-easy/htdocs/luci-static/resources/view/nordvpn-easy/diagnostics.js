'use strict';
/* global service, ui, view, E, _ */
'require nordvpn-easy/service as service';
'require ui';
'require view';

function lastMatchingLine(lines, pattern) {
	for (let i = lines.length - 1; i >= 0; i--) {
		if (pattern.test(lines[i]))
			return lines[i];
	}

	return '';
}

function parseKeyValueSection(rawLog, sectionTitle) {
	const lines = String(rawLog || '').split(/\r?\n/);
	const values = {};
	let inSection = false;

	for (let i = 0; i < lines.length; i++) {
		const line = lines[i].trim();

		if (line === '## ' + sectionTitle) {
			inSection = true;
			continue;
		}

		if (inSection && line.indexOf('## ') === 0)
			break;

		if (!inSection || !line || line.indexOf('=') < 0)
			continue;

		const splitAt = line.indexOf('=');
		values[line.slice(0, splitAt)] = line.slice(splitAt + 1);
	}

	return values;
}

function summarizeDiagnostics(rawLog) {
	const lines = String(rawLog || '').split(/\r?\n/).map(function(line) {
		return line.trim();
	}).filter(function(line) {
		return line;
	});

	return [
		{ label: _('Last Apply'), value: lastMatchingLine(lines, /(setup requested; enabled flag is|disable_runtime requested; enabled flag is|install_hooks requested with|Save & Apply requested)/) },
		{ label: _('Last Setup'), value: lastMatchingLine(lines, /(running core action: setup|SETUP PREREQUISITES|NordVPN configuration is ready|Bootstrapping VPN state)/) },
		{ label: _('Last Check'), value: lastMatchingLine(lines, /(running core action: check|Starting VPN health-check|VPN health-check passed)/) },
		{ label: _('Last Rotate'), value: lastMatchingLine(lines, /(running core action: rotate|Rotate action started|Changing VPN server)/) },
		{ label: _('Last Blocker'), value: lastMatchingLine(lines, /BLOCKER:/) },
		{ label: _('Last Lock Event'), value: lastMatchingLine(lines, /(execution lock acquired|execution lock released|lock is already held|Recovering stale execution lock)/i) },
		{ label: _('Last Runtime Result'), value: lastMatchingLine(lines, /(completed successfully|failed \(duration=|VPN connection restored|did not restore VPN connectivity)/) },
		{ label: _('Last Error'), value: lastMatchingLine(lines, /ERROR:/) }
	];
}

function formatStatusValue(value) {
	if (value === true || value === 'true')
		return _('Yes');

	if (value === false || value === 'false')
		return _('No');

	return value || _('Unknown');
}

function connectionStatusRows(status) {
	if (!status || typeof status !== 'object')
		return [];

	return [
		{ label: _('State'), value: status.state || _('Unknown') },
		{ label: _('Connected'), value: formatStatusValue(status.connected) },
		{ label: _('VPN Status'), value: status.vpn_status || _('Unknown') },
		{ label: _('Handshake'), value: status.latest_handshake || _('Never') },
		{ label: _('Endpoint'), value: status.endpoint || _('N/A') },
		{ label: _('Last Error'), value: status.last_error || _('None') }
	];
}

function assessmentRows(healthSummary, connectivity) {
	const rows = [
		{
			label: _('Primary Issue'),
			value: healthSummary.probable_issue || _('No issue detected'),
			alert: healthSummary.probable_issue_code && healthSummary.probable_issue_code !== 'none'
		},
		{
			label: _('Recommended Action'),
			value: healthSummary.recommended_action || _('No action required')
		},
		{
			label: _('Issue Codes'),
			value: healthSummary.probable_issues || _('none')
		},
		{
			label: _('Routing Blackhole Risk'),
			value: connectivity.routing_blackhole_risk || healthSummary.routing_blackhole_risk || _('Unknown')
		},
		{
			label: _('WireGuard Connected'),
			value: connectivity.wireguard_connected || healthSummary.wireguard_connected || _('Unknown')
		},
		{
			label: _('Default Route Device'),
			value: connectivity.default_route_device || healthSummary.default_route_device || _('Unknown')
		},
		{
			label: _('WAN Ping'),
			value: connectivity.wan_ping || healthSummary.wan_ping || _('Unknown')
		},
		{
			label: _('API DNS (api.nordvpn.com)'),
			value: connectivity.dns_api_nordvpn_com || healthSummary.dns_api_nordvpn_com || _('Unknown')
		}
	];

	return rows;
}

function renderSummaryTable(title, rows) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', title),
		E('div', { 'class': 'table-wrapper' }, [
			E('table', { 'class': 'table' }, rows.map(function(entry) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', style: 'width: 20%; font-weight: bold;' }, [ entry.label ]),
					E('td', {
						'class': 'td left',
						style: entry.alert ? 'color: #c44;' : ''
					}, [ entry.value || _('No matching log entry found yet.') ])
				]);
			}))
		])
	]);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			service.execService('diagnostics_log').catch(function() {
				return null;
			}),
			service.execService('status_json').catch(function() {
				return null;
			})
		]);
	},

	render: function(results) {
		const logResult = results && results[0];
		const statusResult = results && results[1];
		const logContent = (logResult && logResult.code === 0) ? (logResult.stdout || '') : '';
		const summary = summarizeDiagnostics(logContent);
		const healthSummary = parseKeyValueSection(logContent, 'Health summary');
		const connectivity = parseKeyValueSection(logContent, 'Connectivity assessment');
		let status = null;

		status = service.parseExecJsonResponse(statusResult, null);

		return E([
			E('h2', _('NordVPN Easy Diagnostics')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Review connection assessment, runtime status, and download the full NordVPN Easy log collected from system logread.')
			]),
			renderSummaryTable(_('Connection Status'), connectionStatusRows(status)),
			renderSummaryTable(_('Assessment'), assessmentRows(healthSummary, connectivity)),
			renderSummaryTable(_('Latest Log Highlights'), summary),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ _('Log File') ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('button', {
							'class': 'cbi-button cbi-button-apply',
							'type': 'button',
							'click': ui.createHandlerFn(this, function(ev) {
								const button = ev.currentTarget;
								const now = new Date();
								const fileName = 'nordvpn-easy-diagnostics-%04d-%02d-%02d_%02d-%02d-%02d.log'.format(
									now.getFullYear(),
									now.getMonth() + 1,
									now.getDate(),
									now.getHours(),
									now.getMinutes(),
									now.getSeconds()
								);

								button.disabled = true;

								return service.execService('diagnostics_log').then(function(res) {
									const content = res.stdout || '';
									const message = res.stderr ? res.stderr.trim() : '';

									if (res.code !== 0) {
										service.notifyError(new Error(_(
											'Log export failed with exit code %d: %s'
										).format(res.code, message || _('Unknown error.'))));
										return;
									}

									if (!content.trim()) {
										service.notifyInfo(_('No NordVPN Easy logs are currently available.'));
										return;
									}

									service.downloadTextFile(fileName, content);
								}).catch(function(err) {
									const message = (err && err.message) ||
										(typeof err === 'string' ? err : JSON.stringify(err)) ||
										_('Unknown error');

									service.notifyError(new Error(_('Log export failed: ') + message));
								}).finally(function() {
									button.disabled = false;
								});
							})
						}, [ _('Download Log') ])
					])
				])
			])
		]);
	}
});
