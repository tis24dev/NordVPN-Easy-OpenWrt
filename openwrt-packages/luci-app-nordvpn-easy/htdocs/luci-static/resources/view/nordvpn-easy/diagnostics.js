'use strict';
'require nordvpn-easy/service as service';
'require ui';
'require view';

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
