'use strict';
'require form';
'require fs';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require nordvpn-easy/manager-state as managerState';
'require nordvpn-easy/manager-ui as managerUI';
'require nordvpn-easy/service as service';
'require poll';
'require ui';
'require uci';
'require view';

const COUNTRIES_CACHE_PATH = '/tmp/nordvpn-easy-countries.json';
const state = managerState.createState();

const CountrySelectValue = form.ListValue.extend({
	refreshCountries: function(buttonEl, section_id) {
		buttonEl.disabled = true;

		return service.execService('refresh_countries_force').then(function(res) {
			let message;

			if (res.code !== 0) {
				message = res.stderr ? res.stderr.trim() : _('Country refresh failed.');
				throw new Error(_('Country refresh failed with exit code %d: %s').format(res.code, message));
			}

			return fs.read(COUNTRIES_CACHE_PATH);
		}.bind(this)).then(function(countriesRaw) {
			const selectEl = managerUI.getSelectElement(this.cbid(section_id));
			const currentCountry = selectEl ? managerData.normalizeCountryCode(selectEl.value) : '';
			const countries = managerData.parseCountries(countriesRaw);

			managerUI.renderCountryChoices(selectEl, countries, currentCountry);
			service.notifyInfo(_('Country list refreshed.'));
		}.bind(this)).catch(function(err) {
			service.notifyError(err);
		}).finally(function() {
			buttonEl.disabled = false;
		});
	},

	renderWidget: function(section_id, option_index, cfgvalue) {
		const choices = this.transformChoices();
		const widget = new ui.Select((cfgvalue != null) ? cfgvalue : this.default, choices, {
			id: this.cbid(section_id),
			size: this.size,
			sort: this.keylist,
			widget: this.widget,
			optional: this.optional,
			orientation: this.orientation,
			placeholder: this.placeholder,
			validate: (typeof this.getValidator === 'function') ? this.getValidator(section_id) : null,
			disabled: (this.readonly != null) ? this.readonly : this.map.readonly
		});

		return E('div', {
			style: 'display:inline-flex;gap:0.5rem;align-items:center;flex-wrap:wrap;max-width:100%;'
		}, [
			E('div', { style: 'display:inline-block;width:18rem;max-width:100%;' }, [ widget.render() ]),
			E('button', {
				id: managerUI.ids.COUNTRY_REFRESH_BUTTON_ID,
				class: 'cbi-button cbi-button-action',
				type: 'button',
				click: ui.createHandlerFn(this, function(section_id, ev) {
					ev.preventDefault();
					return this.refreshCountries(ev.currentTarget, section_id);
				}, section_id),
				disabled: (this.readonly != null) ? this.readonly : this.map.readonly
			}, [ _('Refresh Countries') ])
		]);
	}
});

return view.extend({
	load: function() {
		const uciLoad = uci.load('nordvpn_easy');

		return L.resolveDefault(service.execService('refresh_countries'), null).then(function() {
			return L.resolveDefault(fs.read(COUNTRIES_CACHE_PATH), '[]');
		}).then(function(countriesRaw) {
			return Promise.all([
				Promise.resolve(countriesRaw),
				uciLoad
			]);
		}).then(function(results) {
			const configuredCountry = managerData.normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
			const statusPromise = L.resolveDefault(service.execService('status_json'), null);
			const catalogPromise = configuredCountry
				? L.resolveDefault(service.execService('server_catalog', [ configuredCountry ]), null)
				: Promise.resolve(null);

			return Promise.all([ Promise.resolve(results[0]), statusPromise, catalogPromise ]);
		});
	},

	handleRefreshServerCatalog: function(ev) {
		return managerState.handleRefreshServerCatalog(state, ev);
	},

	render: function(data) {
		const countries = managerData.parseCountries(data[0]);
		const initialStatus = managerData.parseLocalStatus(data[1] && data[1].code === 0 ? data[1].stdout || '{}' : '{}');
		const initialCatalog = managerData.parseServerCatalog(data[2] && data[2].code === 0 ? data[2].stdout || '{}' : '{}');
		const currentCountry = managerData.normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
		const currentMode = String(uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto');
		const currentPreferredStation = String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '');
		let m, s, o;

		this.initialEnabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
		this.initialCountry = currentCountry;
		this.initialMode = currentMode;
		this.initialPreferredStation = currentPreferredStation;

		state.appliedEnabled = this.initialEnabled;
		state.appliedCountryCode = currentCountry;
		state.currentLocalStatus = initialStatus;
		state.currentOperationStatus = String(initialStatus.operation_status || 'idle');
		state.currentServerCatalog = initialCatalog;
		state.serverCatalogIndex = managerData.buildServerCatalogIndex(state.currentServerCatalog);

		m = new form.Map('nordvpn_easy', _('NordVPN Easy'),
			_('Manage NordVPN Easy connection, manual server selection and runtime status.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Connection Status'));
		s.anonymous = true;
		s.addremove = false;
		s.render = function() {
			return E('div', { class: 'cbi-section' }, [
				E('div', { class: 'cbi-section-node' }, [ managerUI.renderStatusSection() ])
			]);
		};

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Setup'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'nordvpn_token', _('NordVPN Token'));
		o.password = true;
		o.rmempty = false;
		o.description = _('Required. NordVPN access token.');

		o = s.option(CountrySelectValue, 'vpn_country', _('Server Country'));
		o.value('', _('Automatic'));
		o.rmempty = true;
		o.description = _('Choose a country or leave automatic mode for best recommended servers.');
		countries.forEach(function(country) {
			const value = String(country.code);
			o.value(value, _('%s (%s)').format(country.name, value));
		});

		o = s.option(form.ListValue, 'server_selection_mode', _('Server Selection Mode'));
		o.value('auto', _('Automatic / Best recommended'));
		o.value('manual', _('Manual preferred server'));
		o.default = 'auto';
		o.rmempty = false;
		o.description = _('Manual mode is rigid during health checks and requires a country and preferred server.');

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Server Selection'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.DummyValue, '_server_catalog_status', _('Catalog Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(managerUI.ids.SERVER_CATALOG_STATUS_ID, _('Collecting data...'));
		};

		o = s.option(form.ListValue, 'preferred_server_station', _('Preferred Server'));
		o.value('', _('-- Select Server --'));
		o.default = currentPreferredStation;
		o.rmempty = true;
		o.depends('server_selection_mode', 'manual');
		o.description = _('Label format: Country - City - Hostname - Load%.');
		state.currentServerCatalog.servers.forEach(function(server) {
			o.value(String(server.station), managerFormat.formatServerLabel(server));
		});

		o = s.option(form.DummyValue, '_server_selection_hint', _('Selection Behaviour'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(managerUI.ids.SERVER_SELECTION_HINT_ID, _('Collecting data...'));
		};

		o = s.option(form.Button, '_refresh_servers', _('Refresh Server List'));
		o.inputstyle = 'apply';
		o.onclick = ui.createHandlerFn(this, function(ev) {
			return this.handleRefreshServerCatalog(ev);
		});
		o.inputtitle = _('Refresh Server List');

		return m.render().then(function(node) {
			const countrySelect = managerUI.getSelectElement(managerUI.ids.COUNTRY_FIELD_ID);
			const modeSelect = managerUI.getSelectElement(managerUI.ids.MODE_FIELD_ID);

			managerUI.renderServerChoices(managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID), state.currentServerCatalog, currentPreferredStation);
			managerState.updateLocalStatus(state);
			managerState.updatePublicIp();
			managerState.updatePublicCountry(state);
			managerUI.updateServerSelectionState(state);

			if (countrySelect) {
				countrySelect.addEventListener('change', function() {
					managerState.onCountryChanged(state);
				});
			}

			if (modeSelect) {
				modeSelect.addEventListener('change', function() {
					managerState.onModeChanged(state);
				});
			}

			poll.add(function() {
				return managerState.updateLocalStatus(state);
			}, 2);

			poll.add(function() {
				return managerState.updatePublicIp();
			}, 10);

			poll.add(function() {
				return managerState.updatePublicCountry(state);
			}, 30);

			return node;
		}.bind(this));
	},

	handleSaveApply: function(ev, mode) {
		return managerState.handleSaveApply(this, state, ev, mode);
	}
});
