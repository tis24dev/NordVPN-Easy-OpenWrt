'use strict';
'require form';
'require fs';
'require poll';
'require ui';
'require uci';
'require view';

var COUNTRIES_CACHE_PATH = '/tmp/nordvpn-easy-countries.json';
var OPERATION_STATUS_ID = 'nordvpn-easy-operation-status';
var PUBLIC_IP_STATUS_ID = 'nordvpn-easy-public-ip-status';
var VPN_STATUS_ID = 'nordvpn-easy-vpn-status';
var ENABLED_FIELD_ID = 'cbid.nordvpn_easy.main.enabled';
var TOKEN_FIELD_ID = 'cbid.nordvpn_easy.main.nordvpn_token';
var COUNTRY_FIELD_ID = 'cbid.nordvpn_easy.main.vpn_country';
var COUNTRY_REFRESH_BUTTON_ID = 'cbid.nordvpn_easy.main.vpn_country.refresh';
var pendingOperationLabel = '';
var currentOperationStatus = 'idle';

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

function humanizeAction(action) {
	return String(action || _('operation')).replace(/_/g, ' ');
}

function formatActionsLabel(actions) {
	return actions.map(humanizeAction).join(' + ');
}

function setSetupControlsDisabled(disabled) {
	[
		ENABLED_FIELD_ID,
		TOKEN_FIELD_ID,
		COUNTRY_FIELD_ID,
		COUNTRY_REFRESH_BUTTON_ID
	].forEach(function(id) {
		var el = document.getElementById(id);

		if (el)
			el.disabled = disabled;
	});
}

function setOperationStatusText(text, busy) {
	var statusEl = document.getElementById(OPERATION_STATUS_ID);

	if (statusEl)
		statusEl.textContent = text;

	setSetupControlsDisabled(busy);
}

function setVpnStatusIndicator(state, label) {
	var statusEl = document.getElementById(VPN_STATUS_ID);
	var color;

	if (!statusEl)
		return;

	switch (state) {
	case 'active':
		color = '#2ea043';
		break;
	case 'activating':
		color = '#d29922';
		break;
	default:
		color = '#cf222e';
		break;
	}

	statusEl.innerHTML = '<span style="display:inline-block;width:0.75rem;height:0.75rem;border-radius:50%;background:%s;vertical-align:middle;margin-right:0.45rem;"></span>%s'
		.format(color, label);
}

function updateOperationStatus() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'operation_status' ]).then(function(res) {
		var raw = res.stdout ? res.stdout.trim() : '';
		var action;

		if (res.code !== 0) {
			currentOperationStatus = 'unknown';
			setOperationStatusText(_('Unknown'), false);
			return;
		}

		currentOperationStatus = raw || 'idle';

		if (raw.indexOf('busy:') === 0) {
			action = raw.substring(5);
			setOperationStatusText(_('Applying (%s)...').format(humanizeAction(action)), true);
			return;
		}

		if (raw === 'busy') {
			setOperationStatusText(_('Applying...'), true);
			return;
		}

		if (pendingOperationLabel) {
			setOperationStatusText(_('Applying (%s)...').format(humanizeAction(pendingOperationLabel)), true);
			return;
		}

		setOperationStatusText(_('Idle'), false);
	}).catch(function() {
		currentOperationStatus = pendingOperationLabel ? ('busy:' + pendingOperationLabel) : 'unknown';

		if (pendingOperationLabel) {
			setOperationStatusText(_('Applying (%s)...').format(humanizeAction(pendingOperationLabel)), true);
			return;
		}

		setOperationStatusText(_('Unknown'), false);
	});
}

function updateVpnStatus() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'vpn_status' ]).then(function(res) {
		var state = res.stdout ? res.stdout.trim() : 'inactive';
		var busyAction;

		if (currentOperationStatus.indexOf('busy:') === 0) {
			busyAction = currentOperationStatus.substring(5);

			if (busyAction !== 'refresh_countries')
				return setVpnStatusIndicator('activating', _('Activating'));
		}
		else if (currentOperationStatus === 'busy') {
			return setVpnStatusIndicator('activating', _('Activating'));
		}

		if (res.code !== 0) {
			setVpnStatusIndicator('inactive', _('Not Active'));
			return;
		}

		if (state === 'active')
			setVpnStatusIndicator('active', _('Active'));
		else
			setVpnStatusIndicator('inactive', _('Not Active'));
	}).catch(function() {
		if (currentOperationStatus.indexOf('busy') === 0)
			setVpnStatusIndicator('activating', _('Activating'));
		else
			setVpnStatusIndicator('inactive', _('Not Active'));
	});
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
				'id': COUNTRY_REFRESH_BUTTON_ID,
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

function updatePublicIp() {
	return fs.exec('/etc/init.d/nordvpn-easy', [ 'public_ip' ]).then(function(res) {
		var statusEl = document.getElementById(PUBLIC_IP_STATUS_ID);
		var publicIp = res.stdout ? res.stdout.trim() : '';

		if (!statusEl)
			return;

		statusEl.textContent = (res.code === 0 && publicIp && publicIp !== 'null' && publicIp !== 'undefined')
			? publicIp
			: _('Unavailable');
	}).catch(function() {
		var statusEl = document.getElementById(PUBLIC_IP_STATUS_ID);

		if (statusEl)
			statusEl.textContent = _('Unavailable');
	});
}

function runServiceAction(action) {
	return fs.exec('/etc/init.d/nordvpn-easy', [ action ]).then(function(res) {
		var lines = [];

		if (res.stdout)
			lines.push(res.stdout.trim());

		if (res.stderr)
			lines.push(res.stderr.trim());

		return {
			action: action,
			code: res.code,
			message: lines.filter(function(line) {
				return line;
			}).join('\n') || _('Command completed.')
		};
	}).catch(function(err) {
		return {
			action: action,
			code: -1,
			message: (err && err.message) ? err.message : String(err)
		};
	});
}

function runServiceActions(actions) {
	var results = [];

	return actions.reduce(function(chain, action) {
		return chain.then(function() {
			return runServiceAction(action).then(function(result) {
				results.push(result);
			});
		});
	}, Promise.resolve()).then(function() {
		return results;
	});
}

function summarizeActionFailures(results) {
	return results.filter(function(result) {
		return result.code !== 0;
	}).map(function(result) {
		return _('%s failed with exit code %d: %s').format(result.action, result.code, result.message);
	}).join('\n');
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

		this.initialEnabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
		this.initialCountry = currentCountry;

		m = new form.Map('nordvpn_easy', _('NordVPN Easy'),
			_('Configure the minimum settings required to connect NordVPN Easy.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Setup'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DummyValue, '_vpn_status', _('VPN Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(VPN_STATUS_ID, _('Unknown'));
		};

		o = s.option(form.DummyValue, '_operation_status', _('Operation Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(OPERATION_STATUS_ID, _('Idle'));
		};

		o = s.option(form.DummyValue, '_public_ip', _('Public IP'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<span id="%s">%s</span>'.format(PUBLIC_IP_STATUS_ID, _('Collecting data...'));
		};

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

		return m.render().then(function(node) {
			poll.add(function() {
				return updatePublicIp();
			}, 5);

			poll.add(function() {
				return updateOperationStatus();
			}, 2);

			poll.add(function() {
				return updateVpnStatus();
			}, 2);

			updateOperationStatus();
			updateVpnStatus();
			updatePublicIp();
			return node;
		});
	},

	handleSaveApply: function(ev, mode) {
		var previousEnabled = !!this.initialEnabled;
		var previousCountry = this.initialCountry || '';

		return this.handleSave(ev).then(L.bind(function() {
			return new Promise(L.bind(function(resolve, reject) {
				var settled = false;
				var cleanup = L.bind(function() {
					if (this._uciAppliedHandler) {
						document.removeEventListener('uci-applied', this._uciAppliedHandler);
						this._uciAppliedHandler = null;
					}
				}, this);
				var finishResolve = function(value) {
					if (settled)
						return;

					settled = true;
					cleanup();
					resolve(value);
				};
				var finishReject = function(err) {
					if (settled)
						return;

					settled = true;
					cleanup();
					reject(err);
				};

				cleanup();

				this._uciAppliedHandler = L.bind(function() {
					Promise.resolve().then(function() {
						uci.unload('nordvpn_easy');
						return uci.load('nordvpn_easy');
					}).then(L.bind(function() {
						var currentEnabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
						var currentCountry = uci.get('nordvpn_easy', 'main', 'vpn_country') || '';
						var actions = [];
						var successMessage = '';

						this.initialEnabled = currentEnabled;
						this.initialCountry = currentCountry;

						if (!previousEnabled && currentEnabled) {
							actions = [ 'setup', 'install_hooks' ];
							successMessage = _('NordVPN Easy enabled: setup completed and hooks installed.');
						}
						else if (previousEnabled && !currentEnabled) {
							actions = [ 'disable_runtime' ];
							successMessage = _('NordVPN Easy disabled: VPN interface stopped and hooks removed.');
						}
						else if (currentEnabled && previousCountry !== currentCountry) {
							actions = [ 'setup' ];
							successMessage = _('Server country updated: VPN server synchronized.');
						}

						if (!actions.length) {
							pendingOperationLabel = '';
							return updateOperationStatus();
						}

						pendingOperationLabel = formatActionsLabel(actions);
						currentOperationStatus = 'busy:' + pendingOperationLabel;
						setVpnStatusIndicator('activating', _('Activating'));
						setOperationStatusText(_('Applying (%s)...').format(pendingOperationLabel), true);

						return runServiceActions(actions).then(function(results) {
							var failures = summarizeActionFailures(results);

							if (failures) {
								ui.addNotification(null, E('p', failures), 'error');
								return;
							}

							ui.addNotification(null, E('p', successMessage), 'info');
						});
					}, this)).then(function(value) {
						finishResolve(value);
					}).catch(function(err) {
						var message = (err && err.message) ? err.message : String(err);

						ui.addNotification(null, E('p', _('Automatic runtime sync failed: ') + message), 'error');
						finishReject(err);
					}).finally(function() {
						pendingOperationLabel = '';
						updateOperationStatus();
					});
				}, this);

				document.addEventListener('uci-applied', this._uciAppliedHandler);
				pendingOperationLabel = _('configuration');
				currentOperationStatus = 'busy:configuration';
				setVpnStatusIndicator('activating', _('Activating'));
				setOperationStatusText(_('Applying configuration...'), true);
				Promise.resolve(ui.changes.apply(mode == '0')).catch(function(err) {
					finishReject(err);
				});
			}, this));
		}, this));
	}
});
