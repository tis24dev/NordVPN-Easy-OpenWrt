'use strict';
'require form';
'require fs';
'require poll';
'require ui';
'require uci';
'require view';

var COUNTRIES_CACHE_PATH = '/tmp/nordvpn-easy-countries.json';
var PUBLIC_IP_STATUS_ID = 'nordvpn-easy-public-ip-status';

function parseCountries(countriesRaw) {
	var countries = [];

	try {
		countries = JSON.parse(countriesRaw || '[]');
	} catch (e) {
		countries = [];
	}

	return countries.filter(function(country) {
		return country && country.name && country.code;
	}).sort(function(a, b) {
		return String(a.name).localeCompare(String(b.name));
	});
}

function getCountrySelectElement(optionId) {
	var frameEl = document.getElementById(optionId);

	if (!frameEl)
		return null;

	return frameEl.querySelector('select');
}

function renderCountryChoices(selectEl, countries, currentCountry) {
	var seenCurrent = false;

	if (!selectEl)
		return;

	while (selectEl.firstChild)
		selectEl.removeChild(selectEl.firstChild);

	selectEl.appendChild(E('option', { value: '' }, [ _('Automatic') ]));

	countries.forEach(function(country) {
		var value = String(country.code);
		selectEl.appendChild(E('option', { value: value }, [
			_('%s (%s)').format(country.name, value)
		]));

		if (value === currentCountry)
			seenCurrent = true;
	});

	if (currentCountry && !seenCurrent) {
		selectEl.appendChild(E('option', { value: currentCountry }, [
			_('Current value: %s').format(currentCountry)
		]));
	}

	selectEl.value = currentCountry || '';
}

const CountrySelectValue = form.ListValue.extend({
	refreshCountries(buttonEl, section_id) {
		buttonEl.disabled = true;

		return fs.exec('/etc/init.d/nordvpn-easy', [ 'refresh_countries_force' ]).then(function(res) {
			var message;

			if (res.code !== 0) {
				message = res.stderr ? res.stderr.trim() : _('Country refresh failed.');
				throw new Error(_('Country refresh failed with exit code %d: %s').format(res.code, message));
			}

			return fs.read(COUNTRIES_CACHE_PATH);
		}).then(function(countriesRaw) {
			var selectEl = getCountrySelectElement(this.cbid(section_id));
			var currentCountry = selectEl ? selectEl.value : '';
			var countries = parseCountries(countriesRaw);

			renderCountryChoices(selectEl, countries, currentCountry);
			ui.addNotification(null, E('p', _('Country list refreshed.')), 'info');
		}.bind(this)).catch(function(err) {
			ui.addNotification(null, E('p', err.message), 'error');
		}).finally(function() {
			buttonEl.disabled = false;
		});
	},

	renderWidget(section_id, option_index, cfgvalue) {
		var choices = this.transformChoices();
		var widget = new ui.Select((cfgvalue != null) ? cfgvalue : this.default, choices, {
			id: this.cbid(section_id),
			size: this.size,
			sort: this.keylist,
			widget: this.widget,
			optional: this.optional,
			orientation: this.orientation,
			placeholder: this.placeholder,
			validate: this.getValidator(section_id),
			disabled: (this.readonly != null) ? this.readonly : this.map.readonly
		});

		return E('div', {
			'style': 'display:inline-flex;gap:0.5rem;align-items:center;flex-wrap:wrap;max-width:100%;'
		}, [
			E('div', { 'style': 'display:inline-block;width:18rem;max-width:100%;' }, [ widget.render() ]),
			E('button', {
				'class': 'cbi-button cbi-button-apply',
				'type': 'button',
				'click': ui.createHandlerFn(this, function(section_id, ev) {
					ev.preventDefault();
					return this.refreshCountries(ev.currentTarget, section_id);
				}, section_id),
				'disabled': (this.readonly != null) ? this.readonly : this.map.readonly
			}, [ _('Refresh') ])
		]);
	}
});

const PublicIPValue = form.DummyValue.extend({
	textvalue() {
		return E('span', { 'id': PUBLIC_IP_STATUS_ID }, [ _('Collecting data...') ]);
	}
});

function updatePublicIp() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'public_ip' ]).then(function(res) {
		var statusEl = document.getElementById(PUBLIC_IP_STATUS_ID);
		var publicIp = res.stdout ? res.stdout.trim() : '';

		if (!statusEl)
			return;

		statusEl.textContent = (res.code === 0 && publicIp) ? publicIp : _('Unavailable');
	}).catch(function() {
		var statusEl = document.getElementById(PUBLIC_IP_STATUS_ID);

		if (statusEl)
			statusEl.textContent = _('Unavailable');
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.exec('/etc/init.d/nordvpn-easy', [ 'refresh_countries' ]), null).then(function() {
			return Promise.all([
				L.resolveDefault(fs.read(COUNTRIES_CACHE_PATH), '[]'),
				uci.load('nordvpn_easy')
			]);
		});
	},

	render: function(data) {
		var countriesRaw = data[0];
		var currentCountry = uci.get('nordvpn_easy', 'main', 'vpn_country') || '';
		var countries = parseCountries(countriesRaw);
		var m, s, o;

		m = new form.Map('nordvpn_easy', _('NordVPN Easy'),
			_('Configure the minimum settings required to connect NordVPN Easy.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Setup'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(PublicIPValue, '_public_ip', _('Public IP'));

		o = s.option(form.Value, 'nordvpn_token', _('NordVPN Token'));
		o.password = true;
		o.rmempty = false;
		o.description = _('Required. NordVPN access token.');

		o = s.option(CountrySelectValue, 'vpn_country', _('Server Country'));
		o.value('', _('Automatic'));
		o.rmempty = true;
		o.description = _('Optional. Country list is refreshed automatically every 24 hours.');

		countries.forEach(function(country) {
			var value = String(country.code);
			o.value(value, _('%s (%s)').format(country.name, value));
		});

		if (currentCountry && !countries.some(function(country) { return String(country.code) === currentCountry; }))
			o.value(currentCountry, _('Current value: %s').format(currentCountry));

		o = s.option(form.Button, '_advanced', _('Advanced'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			window.location.href = L.url('admin', 'services', 'nordvpn-easy', 'advanced');
		};

		return m.render().then(function(node) {
			poll.add(function() {
				return updatePublicIp();
			}, 5);

			updatePublicIp();
			return node;
		});
	}
});
