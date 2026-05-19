'use strict';
/* global service, ui, view, E, _ */
'require nordvpn-easy/service as service';
'require ui';
'require view';

function formatStatusValue(value) {
	if (value === true || value === 'true')
		return _('Yes');

	if (value === false || value === 'false')
		return _('No');

	return value || _('Unknown');
}

function connectionStatusRows(summary) {
	const status = (summary && summary.status) || null;
	const health = (summary && summary.health) || {};

	if (status && typeof status === 'object') {
		return [
			{ label: _('State'), value: status.state || _('Unknown') },
			{ label: _('Connected'), value: formatStatusValue(status.connected) },
			{ label: _('VPN Status'), value: status.vpn_status || _('Unknown') },
			{ label: _('Handshake'), value: status.latest_handshake || _('Never') },
			{ label: _('Endpoint'), value: status.endpoint || _('N/A') },
			{ label: _('Last Error'), value: status.last_error || _('None') }
		];
	}

	return [
		{ label: _('State'), value: health.enterprise_state || _('Unknown') },
		{ label: _('Connected'), value: formatStatusValue(health.wireguard_connected) },
		{ label: _('VPN Status'), value: health.vpn_status || _('Unknown') },
		{ label: _('Handshake'), value: health.wireguard_handshake || _('Never') },
		{ label: _('Last Error'), value: (summary && summary.caches && summary.caches.last_error) || _('None') }
	];
}

function assessmentRows(summary) {
	const primary = (summary && summary.primary_finding) || {};
	const connectivity = (summary && summary.connectivity) || {};
	const health = (summary && summary.health) || {};
	const hasIssue = !!(primary.code && primary.code !== 'none');

	return [
		{
			label: _('Primary Issue'),
			value: primary.message || _('No issue detected'),
			alert: hasIssue
		},
		{
			label: _('Recommended Action'),
			value: primary.action || _('No action required')
		},
		{
			label: _('Issue Codes'),
			value: ((summary && summary.findings) || []).map(function(finding) {
				return finding.code;
			}).join(', ') || _('none')
		},
		{
			label: _('Routing Blackhole Risk'),
			value: connectivity.routing_blackhole_risk || health.routing_blackhole_risk || _('Unknown'),
			alert: connectivity.routing_blackhole_risk === 'yes'
		},
		{
			label: _('WireGuard Connected'),
			value: formatStatusValue(connectivity.wireguard_connected != null ?
				connectivity.wireguard_connected :
				health.wireguard_connected)
		},
		{
			label: _('Default Route Device'),
			value: connectivity.default_route_device || health.default_route_device || _('Unknown')
		},
		{
			label: _('WAN Ping'),
			value: connectivity.wan_ping || _('Unknown')
		},
		{
			label: _('API DNS (api.nordvpn.com)'),
			value: connectivity.dns_api_nordvpn_com || _('Unknown')
		},
		{
			label: _('Kill Switch'),
			value: formatStatusValue((summary && summary.health && summary.health.kill_switch_enabled) || false),
			alert: !!(summary && summary.health && summary.health.kill_switch_enabled) &&
				!(summary && summary.health && summary.health.wireguard_connected)
		},
		{
			label: _('Probe Duration'),
			value: connectivity.diagnostics_probe_duration_ms != null ?
				String(connectivity.diagnostics_probe_duration_ms) + ' ms' :
				_('Unknown')
		}
	];
}

function findingsRows(summary) {
	return ((summary && summary.findings) || []).map(function(finding) {
		return {
			label: finding.code || _('Unknown'),
			value: [ finding.message, finding.action ].filter(function(part) {
				return part;
			}).join(' — '),
			alert: finding.severity === 'critical'
		};
	});
}

function renderSummaryTable(title, rows, emptyMessage) {
	const body = (rows && rows.length) ? rows : [{
		label: _('Status'),
		value: emptyMessage || _('No data available.')
	}];

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', title),
		E('div', { 'class': 'table-wrapper' }, [
			E('table', { 'class': 'table' }, body.map(function(entry) {
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
		return service.execService('diagnostics_summary').catch(function() {
			return null;
		});
	},

	poll: function() {
		return this.load();
	},

	render: function(summaryResult) {
		const summary = service.parseExecJsonResponse(summaryResult, null);
		const findings = findingsRows(summary);
		const view = this;

		return E('div', { 'data-nordvpn-easy-diagnostics': '1' }, [
			E('h2', _('NordVPN Easy Diagnostics')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Review structured connectivity assessment from the NordVPN Easy backend or download the full log export. Active WAN/DNS probes are skipped during background refresh.')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'cbi-button',
						'type': 'button',
						'click': ui.createHandlerFn(view, function() {
							return view.poll().then(function(result) {
								const container = document.querySelector('[data-nordvpn-easy-diagnostics]');

								if (!container || !container.parentNode)
									return;

								const refreshed = view.render(result);
								container.parentNode.replaceChild(refreshed, container);
							});
						})
					}, [ _('Refresh assessment') ])
				])
			]),
			renderSummaryTable(_('Connection Status'), connectionStatusRows(summary)),
			renderSummaryTable(_('Assessment'), assessmentRows(summary)),
			renderSummaryTable(
				_('Findings'),
				findings,
				_('No issues detected.')
			),
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
