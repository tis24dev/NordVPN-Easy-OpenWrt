'use strict';
'require form';
'require fs';
'require nordvpn-easy/service as service';
'require view';

function runAction(action) {
	return service.runAction(action).then(function(result) {
		if (!result.success) {
			service.notifyError(service.resultToError(result));
			return;
		}

		service.notifyInfo(result.message);
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.stat('/etc/cron.d/nordvpn-easy'), null),
			L.resolveDefault(fs.stat('/etc/hotplug.d/iface/95-nordvpn-easy'), null)
		]);
	},

	render: function(stats) {
		const cronInstalled = !!stats[0];
		const hotplugInstalled = !!stats[1];
		let m, s, o;

		m = new form.Map('nordvpn_easy', _('NordVPN Easy Advanced'),
			_('Adjust advanced network, health-check and recovery settings.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Network & Runtime'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'wan_if', _('WAN Interface'));
		o.placeholder = 'wan';
		o.rmempty = false;

		o = s.option(form.Value, 'vpn_if', _('VPN Interface'));
		o.placeholder = 'wg0';
		o.rmempty = false;

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

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Health Checks & Recovery'));
		s.anonymous = true;
		s.addremove = false;

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

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Cache & Catalog'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'server_cache_enabled', _('Enable Server Catalog Cache'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Cache the NordVPN manual server catalog for the selected country.');

		o = s.option(form.Value, 'server_cache_ttl', _('Server Catalog Cache TTL'));
		o.datatype = 'uinteger';
		o.default = '86400';
		o.placeholder = '86400';
		o.rmempty = false;
		o.depends('server_cache_enabled', '1');
		o.description = _('How long to keep the manual server catalog before refreshing it again.');

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Runtime Actions'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_hooks', _('Installed Hooks'));
		o.cfgvalue = function() {
			const state = [];

			state.push(cronInstalled ? _('cron: installed') : _('cron: missing'));
			state.push(hotplugInstalled ? _('hotplug: installed') : _('hotplug: missing'));

			return state.join(', ');
		};

		o = s.option(form.Button, '_run_setup', _('Run Setup'));
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
