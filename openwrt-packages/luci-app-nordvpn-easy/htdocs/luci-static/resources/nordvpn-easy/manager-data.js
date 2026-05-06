'use strict';
/* global baseclass */
'require baseclass';

function normalizeCountryCode(value) {
	return String(value || '').trim().toUpperCase();
}

function parseEnabledFlag(value) {
	switch (String(value != null ? value : '0').trim().toLowerCase()) {
	case '1':
	case 'true':
	case 'yes':
	case 'on':
		return true;
	default:
		return false;
	}
}

function emptyServerCatalog() {
	return {
		country_id: '',
		country_code: '',
		country_name: '',
		cached_at: null,
		cache_ttl: null,
		servers: []
	};
}

function parseJson(raw, fallback) {
	try {
		return JSON.parse(raw || '');
	} catch (e) {
		return fallback;
	}
}

function parseCountries(countriesRaw) {
	const countries = parseJson(countriesRaw, []);

	return countries.filter(function(country) {
		return country && country.name && country.code;
	}).sort(function(a, b) {
		return String(a.name).localeCompare(String(b.name));
	});
}

function parseLocalStatus(raw) {
	const status = parseJson(raw, {});

	return {
		desired_enabled: ('desired_enabled' in status) ? !!status.desired_enabled : !!status.enabled,
		state: String(status.state || ''),
		updated_at: Number(status.updated_at || 0),
		enabled: !!status.enabled,
		runtime_disabled: ('runtime_disabled' in status) ? !!status.runtime_disabled : !!status.interface_disabled,
		interface_disabled: !!status.interface_disabled,
		runtime_configured: ('runtime_configured' in status) ? !!status.runtime_configured : !!status.current_server_station,
		server_selection_mode: String(status.server_selection_mode || 'auto'),
		kill_switch_enabled: !!status.kill_switch_enabled,
		selected_country: normalizeCountryCode(status.selected_country || ''),
			interface: String(status.interface || ''),
			vpn_status: String(status.vpn_status || 'inactive'),
			operation_status: String(status.operation_status || 'idle'),
			operation_lock_state: String(status.operation_lock_state || 'none'),
			operation_lock_pid: String(status.operation_lock_pid || ''),
			operation_lock_action: String(status.operation_lock_action || ''),
			operation_lock_age_seconds: Number(status.operation_lock_age_seconds || 0),
			connected: !!status.connected,
			endpoint: String(status.endpoint || 'N/A'),
			endpoint_port: String(status.endpoint_port || ''),
			wireguard_persistent_keepalive: Number(status.wireguard_persistent_keepalive || 0),
			wireguard_mtu: String(status.wireguard_mtu || ''),
			firewall_mtu_fix: !!status.firewall_mtu_fix,
			latest_handshake: String(status.latest_handshake || 'Never'),
			latest_handshake_epoch: Number(status.latest_handshake_epoch || 0),
			handshake_age_seconds: Number(status.handshake_age_seconds || 0),
		transfer_rx: String(status.transfer_rx || '0 B'),
		transfer_rx_bytes: Number(status.transfer_rx_bytes || 0),
		transfer_tx: String(status.transfer_tx || '0 B'),
		transfer_tx_bytes: Number(status.transfer_tx_bytes || 0),
		public_ip_cached: String(status.public_ip_cached || ''),
		public_country_cached: normalizeCountryCode(status.public_country_cached || ''),
		last_error: String(status.last_error || ''),
		current_server_hostname: String(status.current_server_hostname || ''),
		current_server_station: String(status.current_server_station || ''),
		current_server_city: String(status.current_server_city || ''),
		current_server_country: normalizeCountryCode(status.current_server_country || ''),
		current_server_load: String(status.current_server_load || ''),
		preferred_server_hostname: String(status.preferred_server_hostname || ''),
		preferred_server_station: String(status.preferred_server_station || '')
	};
}

function parseServerCatalog(raw) {
	const catalog = parseJson(raw, emptyServerCatalog());

	if (!catalog || typeof catalog !== 'object')
		return emptyServerCatalog();

	return {
		country_id: String(catalog.country_id || ''),
		country_code: normalizeCountryCode(catalog.country_code || ''),
		country_name: String(catalog.country_name || ''),
		cached_at: (catalog.cached_at != null && catalog.cached_at !== '') ? Number(catalog.cached_at) : null,
		cache_ttl: (catalog.cache_ttl != null && catalog.cache_ttl !== '') ? Number(catalog.cache_ttl) : null,
		servers: Array.isArray(catalog.servers) ? catalog.servers.filter(function(server) {
			return server && server.hostname && server.station && server.public_key;
		}).map(function(server) {
			return {
				hostname: String(server.hostname),
				station: String(server.station),
				load: String(server.load != null ? server.load : ''),
				city: String(server.city || ''),
				country_code: normalizeCountryCode(server.country_code || ''),
				country_name: String(server.country_name || ''),
				public_key: String(server.public_key || '')
			};
		}) : []
	};
}

function buildServerCatalogIndex(catalog) {
	const index = {};

	catalog.servers.forEach(function(server) {
		index[String(server.station)] = server;
	});

	return index;
}

return baseclass.extend({
	normalizeCountryCode: normalizeCountryCode,
	parseEnabledFlag: parseEnabledFlag,
	emptyServerCatalog: emptyServerCatalog,
	parseJson: parseJson,
	parseCountries: parseCountries,
	parseLocalStatus: parseLocalStatus,
	parseServerCatalog: parseServerCatalog,
	buildServerCatalogIndex: buildServerCatalogIndex
});
