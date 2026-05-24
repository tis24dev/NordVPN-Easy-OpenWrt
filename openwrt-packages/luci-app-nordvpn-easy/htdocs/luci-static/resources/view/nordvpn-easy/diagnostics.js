'use strict';
/* global service, ui, view, E, _ */
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-store as managerStore';
'require nordvpn-easy/service as service';
'require ui';
'require view';

const RUNTIME_IDLE_POLL_MS = 2000;
const RUNTIME_IDLE_MAX_WAIT_MS = 90000;

function waitForRuntimeIdle() {
	const deadline = Date.now() + RUNTIME_IDLE_MAX_WAIT_MS;

	return function poll() {
		return service.execService('status_json').then(function(res) {
			const status = service.parseExecJsonResponse(res, null);

			if (!managerData.runtimeStatusIsBusy(status))
				return true;

			if (Date.now() >= deadline) {
				return Promise.reject(new Error(
					_('NordVPN Easy is busy with another operation. Wait for the current stop/connect cycle to finish, then retry.')
				));
			}

			return new Promise(function(resolve) {
				window.setTimeout(resolve, RUNTIME_IDLE_POLL_MS);
			}).then(poll);
		});
	}();
}

function parseDiagnosticsLoadResult(summaryResult) {
	let payload;

	if (!summaryResult)
		return managerData.emptyDiagnosticsSummary();

	if (managerData.isDiagnosticsSummaryPayload(summaryResult))
		return managerData.parseDiagnosticsSummary(summaryResult);

	if (summaryResult.code != null || summaryResult.stdout != null || summaryResult.message != null) {
		if (summaryResult.stdout)
			payload = managerData.parseJson(summaryResult.stdout, null);

		if (!payload)
			payload = service.parseExecJsonResponse(summaryResult, null);

		if (payload && managerData.isDiagnosticsSummaryPayload(payload))
			return managerData.parseDiagnosticsSummary(payload);

		if (summaryResult.loadFailed || summaryResult.code !== 0) {
			return managerData.parseDiagnosticsSummary({
				generated_at: 0,
				primary_finding: {
					code: 'operational.summary_failed',
					message: summaryResult.message ||
						_('Diagnostics summary is unavailable.'),
					action: _('Use Refresh assessment or review NordVPN Easy logs.'),
					severity: 'critical'
				},
				findings: [],
				health: {},
				connectivity: {}
			});
		}
	}

	return managerData.parseDiagnosticsSummary(summaryResult);
}

function formatStatusValue(value) {
	if (value === true || value === 'true')
		return _('Yes');

	if (value === false || value === 'false')
		return _('No');

	return value || _('Unknown');
}

function formatProbeValue(value) {
	if (value === 'skipped')
		return _('Skipped (background refresh)');

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
			value: formatProbeValue(connectivity.wan_ping)
		},
		{
			label: _('API DNS (api.nordvpn.com)'),
			value: formatProbeValue(connectivity.dns_api_nordvpn_com)
		},
		{
			label: _('Kill Switch'),
			value: formatStatusValue(summary && summary.health ?
				summary.health.kill_switch_enabled :
				undefined),
			alert: !!(summary && summary.health &&
				summary.health.kill_switch_enabled === true &&
				summary.health.wireguard_connected !== true)
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
		if (typeof service.ensureLuCiRpcTimeout === 'function')
			service.ensureLuCiRpcTimeout();
		return waitForRuntimeIdle().then(function() {
			return service.execService('diagnostics_summary');
		}).catch(function(err) {
			return {
				code: -1,
				stdout: '',
				message: (err && err.message) ? err.message : String(err),
				loadFailed: true
			};
		});
	},

	poll: function() {
		return this.load();
	},

	render: function(summaryResult) {
		const summary = parseDiagnosticsLoadResult(summaryResult);
		const findings = findingsRows(summary);
		const view = this;
		const actionButtons = [
			E('button', {
				'class': 'cbi-button',
				'type': 'button',
				'click': ui.createHandlerFn(view, function(ev) {
					const button = ev && ev.target;

					if (!button || button.disabled || button._nordvpnRefreshing)
						return;

					button._nordvpnRefreshing = true;
					button.disabled = true;

					return view.poll().then(function(result) {
						const container = document.querySelector('[data-nordvpn-easy-diagnostics]');

						if (!container || !container.parentNode)
							return;

						const refreshed = view.render(result);
						container.parentNode.replaceChild(refreshed, container);
					}).catch(function() {
						return null;
					}).finally(function() {
						button._nordvpnRefreshing = false;
						button.disabled = false;
					});
				})
			}, [ _('Refresh assessment') ])
		];

		if (summary.primary_finding && summary.primary_finding.code === 'selection.drift') {
			actionButtons.push(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'type': 'button',
				'click': ui.createHandlerFn(view, function(ev) {
					const button = ev && ev.target;

					if (!button || button.disabled || button._nordvpnApplying)
						return;

					button._nordvpnApplying = true;
					button.disabled = true;

					const syncState = managerStore.createState();

					return waitForRuntimeIdle().then(function() {
						return managerActions.runApplyCycle(null, syncState, null, {
							skipFormSave: true,
							skipDriftRestart: true
						});
					}).then(function() {
						service.notifyInfo(_('Server selection synchronized.'));
						return view.poll().then(function(result) {
							const container = document.querySelector('[data-nordvpn-easy-diagnostics]');

							if (!container || !container.parentNode)
								return;

							container.parentNode.replaceChild(view.render(result), container);
						});
					}).catch(function(err) {
						service.notifyError(err);
					}).finally(function() {
						button._nordvpnApplying = false;
						button.disabled = false;
					});
				})
			}, [ _('Apply server selection') ]));
		}

		return E('div', { 'data-nordvpn-easy-diagnostics': '1' }, [
			E('h2', _('NordVPN Easy Diagnostics')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Review structured connectivity assessment from the NordVPN Easy backend or download the full log export. Active WAN/DNS probes are skipped during background refresh.')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value-field' }, actionButtons)
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

								return waitForRuntimeIdle().then(function() {
									return service.execService('diagnostics_log');
								}).then(function(res) {
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
