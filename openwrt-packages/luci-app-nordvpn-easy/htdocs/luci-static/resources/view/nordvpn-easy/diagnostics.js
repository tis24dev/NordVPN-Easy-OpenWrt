'use strict';
'require fs';
'require ui';
'require view';

function downloadLogFile(content) {
	const now = new Date();
	const name = 'nordvpn-easy-diagnostics-%04d-%02d-%02d_%02d-%02d-%02d.log'.format(
		now.getFullYear(),
		now.getMonth() + 1,
		now.getDate(),
		now.getHours(),
		now.getMinutes(),
		now.getSeconds()
	);
	const blob = new Blob([ content ], { type: 'text/plain;charset=utf-8' });
	const url = window.URL.createObjectURL(blob);
	const link = E('a', {
		'style': 'display:none',
		'href': url,
		'download': name
	});

	document.body.appendChild(link);
	link.click();
	document.body.removeChild(link);
	window.URL.revokeObjectURL(url);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	render: function() {
		return E([
			E('h2', _('NordVPN Easy Diagnostics')),
			E('div', { 'class': 'cbi-section-descr' }, [
				_('Download the current NordVPN Easy log collected from system logread.')
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

								button.disabled = true;

								return fs.exec('/etc/init.d/nordvpn-easy', [ 'diagnostics_log' ]).then(function(res) {
									const content = res.stdout || '';
									const message = res.stderr ? res.stderr.trim() : '';

									if (res.code !== 0) {
										ui.addNotification(null, E('p', _(
											'Log export failed with exit code %d: %s'
										).format(res.code, message || _('Unknown error.'))), 'error');
										return;
									}

									if (!content.trim()) {
										ui.addNotification(null, E('p', _('No NordVPN Easy logs are currently available.')), 'info');
										return;
									}

									downloadLogFile(content);
								}).catch(function(err) {
									const message = (err && err.message) ||
										(typeof err === 'string' ? err : JSON.stringify(err)) ||
										_('Unknown error');

									ui.addNotification(null, E('p', _('Log export failed: ') + message), 'error');
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
