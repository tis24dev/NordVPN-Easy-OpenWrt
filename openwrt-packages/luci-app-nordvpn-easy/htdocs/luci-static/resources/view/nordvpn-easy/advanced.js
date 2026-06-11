'use strict';
/* global form, fs, managerData, managerFormat, service, uci, view, L, _ */
'require form';
'require fs';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require nordvpn-easy/service as service';
'require uci';
'require view';

const SERVER_CATALOG_CACHE_PATH = '/tmp/nordvpn-easy-servers.json';

function runAction(action, runtimeBusy) {
	const isMutating = [ 'setup', 'check', 'rotate', 'install_hooks' ].indexOf(action) !== -1;

	// Re-query the live runtime status at click time rather than trusting the
	// render-time snapshot, so an action dispatched from a long-open page is
	// gated on current state (the backend remains the final guard). Fall back to
	// the render-time snapshot if the live query yields nothing.
	const busyCheck = isMutating
		? L.resolveDefault(service.execService('status_json'), null).then(function(res) {
			const payload = service.parseExecJsonResponse(res, null);
			return (payload == null) ? !!runtimeBusy : managerData.runtimeStatusIsBusy(payload);
		})
		: Promise.resolve(false);

	return busyCheck.then(function(busy) {
		if (busy) {
			service.notifyInfo(_('NordVPN Easy is applying another runtime operation. This action was skipped.'));
			return;
		}

		return service.runAction(action).then(function(result) {
			if (!result.success) {
				service.notifyError(service.resultToError(result));
				return;
			}

			service.notifyInfo(result.message);
		});
	});
}

function fallbackBasicStatus(station, preferred, country) {
	if (!station)
		return _('Not configured');

	if (preferred && station === preferred)
		return _('Invalid: fallback matches the preferred server');

	if (!country)
		return _('Not verified: choose a server country first');

	return '';
}

function fallbackCatalogStatus(station, country, catalog, catalogIndex, runtimeBusy) {
	const match = catalogIndex[station];

	if (!catalog || !catalog.servers || !catalog.servers.length)
		return runtimeBusy
			? _('Not verified while another runtime operation is running')
			: _('Not verified: server catalog unavailable');

	if (!match)
		return _('Not found in %s catalog').format(catalog.country_name || country);

	return _('Valid: %s').format(managerFormat.formatServerLabel(match));
}

function fallbackStatusLabel(fallbackStation, preferredStation, configuredCountry, catalog, catalogIndex, runtimeBusy) {
	const station = String(fallbackStation || '').trim();
	const preferred = String(preferredStation || '').trim();
	const country = managerData.normalizeCountryCode(configuredCountry || '');
	const basicStatus = fallbackBasicStatus(station, preferred, country);

	return basicStatus || fallbackCatalogStatus(station, country, catalog, catalogIndex, runtimeBusy);
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.stat('/etc/cron.d/nordvpn-easy'), null),
			L.resolveDefault(fs.stat('/etc/hotplug.d/iface/95-nordvpn-easy'), null),
			L.resolveDefault(service.execService('status_json'), null),
			uci.load('nordvpn_easy'),
			L.resolveDefault(fs.read(SERVER_CATALOG_CACHE_PATH), '')
		]);
	},

	render: function(stats) {
		const cronInstalled = !!stats[0];
		const hotplugInstalled = !!stats[1];
		const statusPayload = service.parseExecJsonResponse(stats[2], null);
		const runtimeBusy = managerData.runtimeStatusIsBusy(statusPayload);
		const operationStatus = String((statusPayload && statusPayload.operation_status) || 'idle');
		const configuredCountry = managerData.normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
		const preferredStation = String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '');
		let fallbackCatalog = managerData.parseServerCatalog(stats[4] || '{}');

		if (configuredCountry && fallbackCatalog.country_code !== configuredCountry)
			fallbackCatalog = managerData.emptyServerCatalog();

		const fallbackCatalogIndex = managerData.buildServerCatalogIndex(fallbackCatalog);
		let m, s, o;

		m = new form.Map('nordvpn_easy', _('NordVPN Easy Advanced'),
			_('Adjust advanced network, health-check and recovery settings.'));

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Network & Runtime'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'wan_if', _('WAN Interface'));
		o.placeholder = 'wan';
		o.rmempty = false;
		o.datatype = 'uciname';

		o = s.option(form.Value, 'vpn_if', _('VPN Interface'));
		o.placeholder = 'wg0';
		o.rmempty = false;
		o.datatype = 'uciname';

		o = s.option(form.Value, 'vpn_addr', _('VPN Address'));
		o.placeholder = '10.5.0.2/32';
		o.rmempty = true;
		o.datatype = 'cidr4';
		o.description = _('Optional. Local VPN interface address in CIDR form.');

		o = s.option(form.Value, 'vpn_port', _('VPN Port'));
		o.placeholder = '51820';
		o.rmempty = true;
		o.datatype = 'port';
		o.description = _('Optional. Backend VPN server port.');

		o = s.option(form.Value, 'wireguard_persistent_keepalive', _('WireGuard Keepalive'));
		o.default = '15';
		o.placeholder = '15';
		o.rmempty = false;
		o.description = _('Seconds between WireGuard keepalive packets. Lower values help clients behind aggressive NAT; use 0 only to disable keepalive deliberately.');
		o.validate = function(_section_id, value) {
			const keepalive = String(value || '').trim();

			if (!/^[0-9]+$/.test(keepalive))
				return _('Keepalive must be a number between 0 and 120 seconds.');

			if (Number(keepalive) > 120)
				return _('Keepalive must be 120 seconds or less.');

			return true;
		};

		o = s.option(form.Value, 'wireguard_mtu', _('WireGuard MTU'));
		o.placeholder = _('Automatic');
		o.rmempty = true;
		o.description = _('Optional. Leave automatic unless streams or sites stall over WireGuard; typical diagnostic values are 1420, 1380 or 1280.');
		o.validate = function(_section_id, value) {
			const mtu = String(value || '').trim();

			if (!mtu)
				return true;

			if (!/^[0-9]+$/.test(mtu))
				return _('MTU must be empty or a number between 1280 and 1500.');

			if (Number(mtu) < 1280 || Number(mtu) > 1500)
				return _('MTU must be between 1280 and 1500.');

			return true;
		};

		o = s.option(form.Flag, 'firewall_mtu_fix', _('MSS Clamping'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Enable TCP MSS clamping on the firewall zone that carries the WireGuard tunnel. This reduces MTU blackhole problems on long-lived streams.');

		o = s.option(form.Value, 'vpn_dns1', _('DNS 1'));
		o.placeholder = '103.86.99.99';
		o.rmempty = true;
		o.datatype = 'ipaddr';

		o = s.option(form.Value, 'vpn_dns2', _('DNS 2'));
		o.placeholder = '103.86.96.96';
		o.rmempty = true;
		o.datatype = 'ipaddr';

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Fallback Recovery'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'fallback_server_station', _('Fallback Server Station'));
		o.placeholder = _('Optional station id');
		o.rmempty = true;
		o.description = _('Optional. If the selected server cannot be applied or repeated health checks cannot recover connectivity, this station is promoted as the new preferred server. The fallback station must belong to the currently selected country.');
		o.validate = function(section_id, value) {
			const station = String(value || '').trim();

			if (!station)
				return true;

			if (preferredStation && station === preferredStation)
				return _('Fallback server must be different from the preferred server.');

			if (!configuredCountry || !fallbackCatalog.servers.length)
				return true;

			if (!fallbackCatalogIndex[station])
				return _('Fallback server was not found in the current country catalog.');

			return true;
		};

		o = s.option(form.DummyValue, '_fallback_server_status', _('Fallback Status'));
		o.cfgvalue = function(section_id) {
			return fallbackStatusLabel(
				uci.get('nordvpn_easy', section_id, 'fallback_server_station'),
				preferredStation,
				configuredCountry,
				fallbackCatalog,
				fallbackCatalogIndex,
				runtimeBusy
			);
		};

		s = m.section(form.NamedSection, 'main', 'nordvpn_easy', _('Health Checks & Recovery'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'check_cron_schedule', _('Cron Schedule'));
		o.placeholder = '*/10 * * * *';
		o.rmempty = true;
		o.description = _('Leave empty to disable cron-based checks. Recommended values are 5 minutes or slower.');
		o.validate = function(_section_id, value) {
			const schedule = String(value || '').trim();

			if (!schedule)
				return true;

			const fields = schedule.split(/\s+/);
			if (fields.length !== 5)
				return _('Cron schedule must have exactly 5 fields (minute hour day-of-month month day-of-week).');

			// Mirror the init service's accepted tokens: *, */n, a, a-b, a-b/n and comma lists.
			const item = '(\\*|\\*\\/[0-9]+|[0-9]+(-[0-9]+)?(\\/[0-9]+)?)';
			const token = new RegExp('^' + item + '(,' + item + ')*$');
			for (let i = 0; i < fields.length; i++) {
				if (!token.test(fields[i]))
					return _('Cron field "%s" is not a valid cron expression.').format(fields[i]);
			}

			return true;
		};

		o = s.option(form.Flag, 'enable_hotplug', _('Enable Hotplug Checks'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'hotplug_debounce_seconds', _('Hotplug Debounce'));
		o.placeholder = '30';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('Minimum seconds between hotplug-triggered health checks.');

		o = s.option(form.Flag, 'kill_switch_enabled', _('Kill Switch'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('On (default): while the VPN is enabled, LAN traffic is forced through the tunnel and is blocked if the tunnel drops, so nothing leaks to the bare WAN (IPv6 is always blocked, since NordLynx is IPv4-only). Turn off to allow the LAN to fall back to the unprotected WAN when the tunnel is down.');

		o = s.option(form.Value, 'failure_retry_delay', _('Failure Retry Delay'));
		o.placeholder = '6';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('Seconds to wait before reprovisioning the VPN during a health check when ping fails but WAN is up.');

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

		o = s.option(form.DummyValue, '_operation_status', _('Operation Status'));
		o.cfgvalue = function() {
			return runtimeBusy ? _('Busy (%s)').format(operationStatus) : _('Idle');
		};

		o = s.option(form.Button, '_run_setup', _('Run Setup'));
		o.inputstyle = 'apply';
		o.readonly = runtimeBusy;
		o.onclick = function() {
			return runAction('setup', runtimeBusy);
		};

		o = s.option(form.Button, '_check', _('Run Check'));
		o.inputstyle = 'apply';
		o.readonly = runtimeBusy;
		o.onclick = function() {
			return runAction('check', runtimeBusy);
		};

		o = s.option(form.Button, '_rotate', _('Rotate Server'));
		o.inputstyle = 'apply';
		o.readonly = runtimeBusy;
		o.onclick = function() {
			return runAction('rotate', runtimeBusy);
		};

		o = s.option(form.Button, '_install_hooks', _('Install Hooks'));
		o.inputstyle = 'apply';
		o.readonly = runtimeBusy;
		o.onclick = function() {
			return runAction('install_hooks', runtimeBusy);
		};

		o = s.option(form.Button, '_remove_hooks', _('Remove Hooks'));
		o.inputstyle = 'reset';
		o.onclick = function() {
			return runAction('remove_hooks');
		};

		return m.render();
	}
});
