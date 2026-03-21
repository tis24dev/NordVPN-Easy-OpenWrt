'use strict';
'require form';
'require fs';
'require ui';
'require view';

function runAction(action) {
	return fs.exec('/etc/init.d/nordvpn-easy', [ action ]).then(function(res) {
		var lines = [];

		if (res.stdout)
			lines.push(res.stdout.trim());

		if (res.stderr)
			lines.push(res.stderr.trim());

		if (!lines.length)
			lines.push(_('Command completed.'));

		if (res.code !== 0) {
			ui.addNotification(null, E('p', _(
				'Command failed with exit code %d: %s'
			).format(res.code, res.stderr ? res.stderr.trim() : lines.join('\n'))), 'error');
			return;
		}

		ui.addNotification(null, E('p', lines.join('\n')), 'info');
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Command failed: ') + err.message), 'error');
	});
}

function requireOneToken(section_id, value, otherValue) {
	var token = (value || '').trim();
	var otherToken = (otherValue || '').trim();

	if (token || otherToken)
		return true;

	return _('At least one of NordVPN Token or NordVPN Basic Token must be set.');
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.stat('/etc/cron.d/nordvpn-easy'), null),
			L.resolveDefault(fs.stat('/etc/hotplug.d/iface/95-nordvpn-easy'), null)
		]);
	},

	render: function(stats) {
		var cronInstalled = !!stats[0];
		var hotplugInstalled = !!stats[1];
		var m, s, o;

		m = new form.Map('nordvpn_easy', _('NordVPN Easy'),
			_('Configure NordVPN Easy for OpenWrt. The backend uses scheduled one-shot health checks instead of a permanently running watchdog shell process.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Settings'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'nordvpn_token', _('NordVPN Token'));
		o.password = true;
		o.rmempty = true;
		o.description = _('At least one token is required; leave this empty if using the other token.');
		o.validate = function(section_id, value) {
			return requireOneToken(section_id, value, this.section.formvalue(section_id, 'nordvpn_basic_token'));
		};

		o = s.option(form.Value, 'nordvpn_basic_token', _('NordVPN Basic Token'));
		o.password = true;
		o.rmempty = true;
		o.description = _('At least one token is required; leave this empty if using the other token.');
		o.validate = function(section_id, value) {
			return requireOneToken(section_id, value, this.section.formvalue(section_id, 'nordvpn_token'));
		};

		o = s.option(form.Value, 'wan_if', _('WAN Interface'));
		o.placeholder = 'wan';
		o.rmempty = false;

		o = s.option(form.Value, 'vpn_if', _('VPN Interface'));
		o.placeholder = 'wg0';
		o.rmempty = false;

		o = s.option(form.Value, 'vpn_country', _('Country Filter'));
		o.placeholder = 'IT / Italy / 106';
		o.rmempty = true;
		o.description = _('Optional. Use a country code, a full country name or a NordVPN country id.');

		o = s.option(form.Value, 'vpn_addr', _('VPN Address'));
		o.placeholder = '10.5.0.2/32';
		o.rmempty = true;
		o.description = _('Optional. Local VPN interface address.');

		o = s.option(form.Value, 'vpn_port', _('VPN Port'));
		o.placeholder = '51820';
		o.rmempty = true;
		o.description = _('Optional. Backend VPN server port.');

		o = s.option(form.Value, 'vpn_dns1', _('DNS 1'));
		o.placeholder = '103.86.99.99';
		o.rmempty = true;

		o = s.option(form.Value, 'vpn_dns2', _('DNS 2'));
		o.placeholder = '103.86.96.96';
		o.rmempty = true;

		o = s.option(form.Value, 'check_cron_schedule', _('Cron Schedule'));
		o.placeholder = '* * * * *';
		o.rmempty = true;
		o.description = _('Leave empty to disable cron-based checks.');

		o = s.option(form.Flag, 'enable_hotplug', _('Enable Hotplug Checks'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'failure_retry_delay', _('Failure Retry Delay'));
		o.placeholder = '6';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.option(form.Value, 'server_rotate_threshold', _('Rotate Threshold'));
		o.placeholder = '5';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.option(form.Value, 'interface_restart_threshold', _('Restart Threshold'));
		o.placeholder = '10';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.option(form.Value, 'max_interface_restarts', _('Max Interface Restarts'));
		o.placeholder = '3';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('Maximum interface restarts per check run. Use 0 to disable interface restarts.');

		o = s.option(form.Value, 'interface_restart_delay', _('Interface Restart Delay'));
		o.placeholder = '10';
		o.datatype = 'uinteger';
		o.rmempty = false;

		o = s.option(form.Value, 'post_restart_delay', _('Post Restart Delay'));
		o.placeholder = '60';
		o.datatype = 'uinteger';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Runtime'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_hooks', _('Installed Hooks'));
		o.cfgvalue = function() {
			var state = [];

			state.push(cronInstalled ? _('cron: installed') : _('cron: missing'));
			state.push(hotplugInstalled ? _('hotplug: installed') : _('hotplug: missing'));

			return state.join(', ');
		};

		o = s.option(form.Button, '_setup', _('Run Setup'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return runAction('setup');
		};

		o = s.option(form.Button, '_check', _('Run Check'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return runAction('check');
		};

		o = s.option(form.Button, '_rotate', _('Rotate Server'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return runAction('rotate');
		};

		o = s.option(form.Button, '_install_hooks', _('Install Hooks'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			return runAction('install_hooks');
		};

		o = s.option(form.Button, '_remove_hooks', _('Remove Hooks'));
		o.inputstyle = 'reset';
		o.onclick = function() {
			return runAction('remove_hooks');
		};

		return m.render();
	}
});
