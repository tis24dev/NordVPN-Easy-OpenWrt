'use strict';
'require form';
'require view';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('nordvpn_easy', _('NordVPN Easy'),
			_('Configure the minimum settings required to connect NordVPN Easy.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Setup'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'nordvpn_token', _('NordVPN Token'));
		o.password = true;
		o.rmempty = false;
		o.description = _('Required. NordVPN access token.');

		o = s.option(form.Value, 'vpn_country', _('Country Filter'));
		o.placeholder = 'IT / Italy / 106';
		o.rmempty = true;
		o.description = _('Optional. Use a country code, a full country name or a NordVPN country id.');

		o = s.option(form.Button, '_advanced', _('Advanced'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			window.location.href = L.url('admin', 'services', 'nordvpn-easy', 'advanced');
		};

		return m.render();
	}
});
