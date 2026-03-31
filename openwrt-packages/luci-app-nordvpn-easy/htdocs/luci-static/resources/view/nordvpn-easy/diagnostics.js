'use strict';
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

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return service.execService('diagnostics_log').catch(function() {
			return null;
		});
	},

	render: function(logResult) {
		const logContent = (logResult && logResult.code === 0) ? (logResult.stdout || '') : '';
		const summary = summarizeDiagnostics(logContent);

		return E([
			E('h2', _('NordVPN Easy Diagnostics')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Review the latest high-signal diagnostics summary or download the full NordVPN Easy log collected from system logread.')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Latest Summary')),
				E('div', { 'class': 'table-wrapper' }, [
					E('table', { 'class': 'table' }, summary.map(function(entry) {
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left', style: 'width: 20%; font-weight: bold;' }, [ entry.label ]),
							E('td', { 'class': 'td left' }, [ entry.value || _('No matching log entry found yet.') ])
						]);
					}))
				])
			]),
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
