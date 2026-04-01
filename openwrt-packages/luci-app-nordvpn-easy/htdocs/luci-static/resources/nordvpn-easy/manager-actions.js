'use strict';
'require baseclass';
'require nordvpn-easy/manager-data as managerData';
'require nordvpn-easy/manager-format as managerFormat';
'require nordvpn-easy/manager-store as managerStore';
'require nordvpn-easy/manager-ui as managerUI';
'require nordvpn-easy/service as service';
'require ui';
'require uci';

function formatDebugValue(value, fallback) {
	const normalized = String(value != null ? value : '').trim();

	return normalized || fallback || _('Automatic');
}

function buildSaveApplyDebugLines(previousEnabled, currentEnabled, previousCountry, currentCountry, previousMode, currentMode, previousPreferredStation, preferredStation, selectedServer) {
	const lines = [];
	const previousEnabledLabel = previousEnabled ? _('checked') : _('unchecked');
	const currentEnabledLabel = currentEnabled ? _('checked') : _('unchecked');
	const tokenField = managerUI.getInputElement(managerUI.ids.TOKEN_FIELD_ID, 'input');
	const existingToken = String(uci.get('nordvpn_easy', 'main', 'nordvpn_token') || '');
	const tokenFieldValue = String(tokenField && tokenField.value != null ? tokenField.value : '').trim();
	const tokenFieldMasked = !!(tokenField && tokenField.getAttribute('data-token-masked') === '1');
	let tokenSourceLabel = _('missing');
	let preferredLabel = _('Automatic / Best recommended');

	if (selectedServer)
		preferredLabel = managerFormat.formatServerLabel(selectedServer);
	else if (preferredStation)
		preferredLabel = preferredStation;

	if (tokenFieldValue && !tokenFieldMasked && tokenFieldValue !== existingToken)
		tokenSourceLabel = _('provided in form');
	else if (existingToken)
		tokenSourceLabel = _('preserving saved token');

	if (previousEnabled !== currentEnabled)
		lines.push(_('Enabled: %s -> %s').format(previousEnabledLabel, currentEnabledLabel));
	else
		lines.push(_('Enabled unchanged: %s').format(currentEnabledLabel));

	if (previousCountry !== currentCountry)
		lines.push(_('Country: %s -> %s').format(formatDebugValue(previousCountry), formatDebugValue(currentCountry)));

	if (previousMode !== currentMode)
		lines.push(_('Server selection mode: %s -> %s').format(previousMode, currentMode));

	if (currentMode === 'manual' && previousPreferredStation !== preferredStation)
		lines.push(_('Preferred server: %s').format(preferredLabel));

	lines.push(_('Token handling: %s').format(tokenSourceLabel));

	return lines;
}

function normalizeSelectionMode(mode) {
	return String(mode || 'auto');
}

function hasServerSelectionChanged(previousCountry, currentCountry, previousMode, currentMode, previousPreferredStation, preferredStation) {
	if (managerData.normalizeCountryCode(previousCountry || '') !== managerData.normalizeCountryCode(currentCountry || ''))
		return true;

	if (normalizeSelectionMode(previousMode) !== normalizeSelectionMode(currentMode))
		return true;

	if (normalizeSelectionMode(currentMode) === 'manual' && String(previousPreferredStation || '') !== String(preferredStation || ''))
		return true;

	return false;
}

function hasRuntimeInterfaceSnapshot(runtimeStatus) {
	return !!(runtimeStatus && typeof runtimeStatus.interface === 'string' && runtimeStatus.interface);
}

function runtimeNeedsReconciliation(runtimeStatus) {
	if (!hasRuntimeInterfaceSnapshot(runtimeStatus))
		return false;

	return !!(runtimeStatus.runtime_disabled || runtimeStatus.interface_disabled || runtimeStatus.runtime_configured === false);
}

function deriveRuntimeActionPlan(previousEnabled, enabled, previousCountry, country, previousMode, mode, previousPreferredStation, preferredStation, runtimeStatus) {
	const currentEnabled = !!enabled;
	const wasEnabled = !!previousEnabled;
	const currentMode = normalizeSelectionMode(mode);
	const serverSelectionChanged = hasServerSelectionChanged(
		previousCountry,
		country,
		previousMode,
		currentMode,
		previousPreferredStation,
		preferredStation
	);
	const runtimeReconciliationRequired = currentEnabled && runtimeNeedsReconciliation(runtimeStatus);
	const plan = {
		actions: [],
		successMessage: '',
		serverSelectionChanged: serverSelectionChanged
	};

	if (!wasEnabled && currentEnabled) {
		plan.actions = [ 'setup', 'install_hooks' ];
		plan.successMessage = _('NordVPN Easy enabled: setup completed and hooks installed.');
		return plan;
	}

	if (wasEnabled && !currentEnabled) {
		plan.actions = [ 'disable_runtime' ];
		plan.successMessage = _('NordVPN Easy disabled: VPN interface stopped and hooks removed.');
		return plan;
	}

	if (currentEnabled && serverSelectionChanged) {
		plan.actions = [ 'setup', 'install_hooks' ];
		plan.successMessage = currentMode === 'manual'
			? _('NordVPN Easy restarted and synchronized the selected manual server.')
			: _('NordVPN Easy restarted and synchronized the automatic server selection.');
		return plan;
	}

	if (runtimeReconciliationRequired) {
		plan.actions = [ 'setup', 'install_hooks' ];
		plan.successMessage = _('NordVPN Easy runtime synchronized with the saved configuration.');
	}

	return plan;
}

function notifyDebugBlock(title, lines) {
	if (!lines || !lines.length)
		return;

	ui.addNotification(null, E('div', [
		E('p', { style: 'font-weight:bold' }, [ title ])
	].concat(lines.map(function(line) {
		return E('p', line);
	}))), 'info');
}

function loadServerCatalog(state, country, forceRefresh) {
	const requestId = ++state.latestServerCatalogRequestId;
	const requestedCountry = managerData.normalizeCountryCode(country || '');
	const extraArgs = [ country || '' ];

	if (!requestedCountry) {
		state.currentServerCatalog = managerData.emptyServerCatalog();
		state.serverCatalogIndex = {};
		managerUI.renderServerChoices(managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID), state.currentServerCatalog, '');
		managerUI.updateServerSelectionState(state);
		return Promise.resolve(state.currentServerCatalog);
	}

	if (forceRefresh)
		extraArgs.push('1');

	return managerStore.runExclusive(state, 'catalog', function() {
		return service.execService('server_catalog', extraArgs).then(function(res) {
			let message;
			let parsedCatalog;

			if (requestId !== state.latestServerCatalogRequestId || requestedCountry !== managerUI.getSelectedCountry())
				return null;

			if (res.code !== 0) {
				message = (res.stderr || '').trim() || _('Server catalog refresh failed.');
				throw new Error(message);
			}

			parsedCatalog = managerData.parseServerCatalog(res.stdout || '');
			state.currentServerCatalog = parsedCatalog;
			state.serverCatalogIndex = managerData.buildServerCatalogIndex(parsedCatalog);
			managerUI.renderServerChoices(
				managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID),
				parsedCatalog,
				managerUI.getSelectedPreferredStation()
			);
			managerUI.updateServerSelectionState(state);
			return state.currentServerCatalog;
		});
	});
}

function normalizePublicIpValue(value) {
	const publicIp = String(value != null ? value : '').trim();

	if (!publicIp || publicIp === 'null' || publicIp === 'undefined')
		return '';

	return publicIp;
}

function updatePublicIp(state, options) {
	const opts = options || {};
	const extraArgs = opts.quiet ? [ 'quiet' ] : [];

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve();

	return managerStore.runExclusive(state, 'publicIp', function() {
		return service.execService('public_ip', extraArgs).then(function(res) {
			const publicIp = (res.code === 0) ? normalizePublicIpValue(res.stdout) : '';
			const previousPublicIp = state.currentPublicIp;
			const shouldRefreshCountry = !!publicIp && (
				opts.force ||
				publicIp !== previousPublicIp ||
				!state.currentPublicCountry ||
				state.currentPublicCountryIp !== publicIp
			);

			state.currentPublicIp = publicIp;
			managerUI.replaceStatusText(
				managerUI.ids.PUBLIC_IP_STATUS_ID,
				publicIp || _('Unavailable')
			);

			if (!publicIp) {
				state.currentPublicCountry = '';
				state.currentPublicCountryIp = '';
				managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
				managerUI.updateCountryMatchStatus(state);
				return;
			}

			if (!shouldRefreshCountry)
				return;

			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Checking...'));
			return updatePublicCountry(state, {
				quiet: opts.quiet,
				force: !!opts.force,
				expectedPublicIp: publicIp
			});
		}).catch(function() {
			state.currentPublicIp = '';
			state.currentPublicCountry = '';
			state.currentPublicCountryIp = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_IP_STATUS_ID, _('Unavailable'));
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		});
	});
}

function updatePublicCountry(state, options) {
	const opts = options || {};
	const extraArgs = opts.quiet ? [ 'quiet' ] : [];
	const expectedPublicIp = normalizePublicIpValue(opts.expectedPublicIp || state.currentPublicIp);

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve();

	return managerStore.runExclusive(state, 'publicCountry', function() {
		if (!expectedPublicIp) {
			state.currentPublicCountry = '';
			state.currentPublicCountryIp = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
			return;
		}

		return service.execService('public_country', extraArgs).then(function(res) {
			const publicCountry = managerData.normalizeCountryCode(res.stdout ? res.stdout.trim() : '');

			state.currentPublicCountry = (res.code === 0 && publicCountry) ? publicCountry : '';
			state.currentPublicCountryIp = state.currentPublicCountry ? expectedPublicIp : '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, state.currentPublicCountry || _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		}).catch(function() {
			state.currentPublicCountry = '';
			state.currentPublicCountryIp = '';
			managerUI.replaceStatusText(managerUI.ids.PUBLIC_COUNTRY_STATUS_ID, _('Unavailable'));
			managerUI.updateCountryMatchStatus(state);
		});
	});
}

function updateLocalStatus(state, options) {
	const opts = options || {};

	if (state.pollingSuspended && !opts.force)
		return Promise.resolve(state.currentLocalStatus);

	return managerStore.runExclusive(state, 'status', function() {
		return service.execService('status_json').then(function(res) {
			let busyAction;
			const status = service.parseExecJsonResponse(res, managerData.parseLocalStatus('{}'));
			const desiredEnabled = !!status.desired_enabled;

			managerStore.clearError(state);
			state.currentLocalStatus = status;
			state.currentOperationStatus = String(status.operation_status || 'idle');
			state.appliedEnabled = desiredEnabled;
			state.appliedCountryCode = managerData.normalizeCountryCode(status.selected_country || state.appliedCountryCode);

			managerUI.replaceStatusText(managerUI.ids.CURRENT_SERVER_STATUS_ID, managerUI.currentServerSummaryFromStatus(status, state));
			managerUI.replaceStatusText(managerUI.ids.PREFERRED_SERVER_STATUS_ID, managerUI.preferredServerSummaryFromStatus(status));
			managerUI.replaceStatusText(managerUI.ids.ENDPOINT_STATUS_ID, status.endpoint || _('Unavailable'));
			managerUI.replaceStatusText(managerUI.ids.HANDSHAKE_STATUS_ID, status.latest_handshake || _('Never'));
			managerUI.replaceStatusText(
				managerUI.ids.TRANSFER_STATUS_ID,
				_('%s / %s').format(status.transfer_rx || '0 B', status.transfer_tx || '0 B')
			);

			if (state.currentOperationStatus.indexOf('busy:') === 0) {
				busyAction = state.currentOperationStatus.substring(5);
				managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying (%s)...').format(managerFormat.humanizeAction(busyAction)));
				managerUI.setManagerControlsDisabled(true);

				if (busyAction !== 'refresh_countries' && busyAction !== 'server_catalog') {
					managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
					managerUI.setVpnStatusIndicator(
						managerUI.isDisableRequested(state) ? 'stopping' : 'starting',
						managerUI.isDisableRequested(state) ? _('Disabling') : _('Activating')
					);
					managerUI.updateCountryMatchStatus(state);
					managerUI.updateServerSelectionState(state);
					return status;
				}
			}
			else if (state.currentOperationStatus === 'busy') {
				managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Applying...'));
				managerUI.setVpnStatusIndicator(
					managerUI.isDisableRequested(state) ? 'stopping' : 'starting',
					managerUI.isDisableRequested(state) ? _('Disabling') : _('Activating')
				);
				managerUI.setManagerControlsDisabled(true);
				managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
				managerUI.updateCountryMatchStatus(state);
				managerUI.updateServerSelectionState(state);
				return status;
			}

			if (state.pendingOperationLabel) {
				managerUI.replaceStatusText(
					managerUI.ids.OPERATION_STATUS_ID,
					_('Applying (%s)...').format(managerFormat.humanizeAction(state.pendingOperationLabel))
				);
				managerUI.setVpnStatusIndicator(
					managerUI.isDisableRequested(state) ? 'stopping' : 'starting',
					managerUI.isDisableRequested(state) ? _('Disabling') : _('Activating')
				);
				managerUI.setManagerControlsDisabled(true);
				managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
			}
			else {
				managerUI.replaceStatusText(managerUI.ids.OPERATION_STATUS_ID, _('Idle'));
				managerUI.setManagerControlsDisabled(false);
				managerStore.syncPhase(state);
			}

			if (!desiredEnabled || status.runtime_disabled || status.interface_disabled || managerUI.isDisableRequested(state))
				managerUI.setVpnStatusIndicator('inactive', _('Disabled'));
			else if (status.vpn_status === 'active' || status.connected)
				managerUI.setVpnStatusIndicator('active', _('Connected'));
			else if (status.vpn_status === 'starting')
				managerUI.setVpnStatusIndicator('starting', _('Starting'));
			else if (status.vpn_status === 'stopping')
				managerUI.setVpnStatusIndicator('stopping', _('Stopping'));
			else if (status.vpn_status === 'error')
				managerUI.setVpnStatusIndicator('error', _('Error'));
			else
				managerUI.setVpnStatusIndicator('inactive', _('Disconnected'));

			managerUI.updateCountryMatchStatus(state);
			managerUI.updateServerSelectionState(state);
			return status;
		}).catch(function(err) {
			state.currentOperationStatus = state.pendingOperationLabel ? ('busy:' + state.pendingOperationLabel) : 'unknown';

			if (!state.pendingOperationLabel)
				managerStore.setError(state, err);

			managerUI.replaceStatusText(
				managerUI.ids.OPERATION_STATUS_ID,
				state.pendingOperationLabel ? _('Applying (%s)...').format(managerFormat.humanizeAction(state.pendingOperationLabel)) : _('Unknown')
			);
			managerUI.setVpnStatusIndicator(
				state.pendingOperationLabel ? 'starting' : 'inactive',
				state.pendingOperationLabel ? _('Activating') : _('Disconnected')
			);
			if (!state.pendingOperationLabel)
				managerUI.setManagerControlsDisabled(false);
			managerUI.updateCountryMatchStatus(state);
			managerUI.updateServerSelectionState(state);
			return state.currentLocalStatus;
		});
	});
}

function onCountryChanged(state) {
	const country = managerUI.getSelectedCountry();
	const selectEl = managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID);

	if (selectEl)
		selectEl.value = '';

	state.latestServerCatalogRequestId++;
	state.currentServerCatalog = managerData.emptyServerCatalog();
	state.serverCatalogIndex = {};
	managerUI.renderServerChoices(selectEl, state.currentServerCatalog, '');
	managerUI.updateServerSelectionState(state);

	if (!country || !managerStore.shouldLoadCatalog(managerUI.getSelectedMode(), country))
		return Promise.resolve();

	return loadServerCatalog(state, country, false).catch(function(err) {
		service.notifyError(err);
	});
}

function onModeChanged(state) {
	const mode = managerUI.getSelectedMode();
	const country = managerUI.getSelectedCountry();
	const selectEl = managerUI.getSelectElement(managerUI.ids.SERVER_FIELD_ID);

	if (mode !== 'manual') {
		if (selectEl)
			selectEl.value = '';
		managerUI.updateServerSelectionState(state);
		return Promise.resolve();
	}

	managerUI.updateServerSelectionState(state);

	if (!country || state.currentServerCatalog.servers.length)
		return Promise.resolve();

	return loadServerCatalog(state, country, false).catch(function(err) {
		service.notifyError(err);
	});
}

function handleRefreshServerCatalog(state, ev) {
	const country = managerUI.getSelectedCountry();
	const button = ev ? ev.currentTarget : managerUI.getInputElement(managerUI.ids.SERVER_REFRESH_BUTTON_ID, 'button');

	if (!country) {
		ui.addNotification(null, E('p', _('Select a country before refreshing the server catalog.')), 'warning');
		return Promise.resolve();
	}

	if (button)
		button.disabled = true;

	ui.showModal(_('Refreshing Server List'), [
		E('p', { class: 'spinning' }, _('Downloading the NordVPN WireGuard server catalog...'))
	]);

	return loadServerCatalog(state, country, true).then(function(catalog) {
		if (catalog)
			service.notifyInfo(_('Server catalog refreshed.'));
	}).catch(function(err) {
		service.notifyError(err);
	}).finally(function() {
		ui.hideModal();
		if (button)
			button.disabled = false;
		managerUI.updateServerSelectionState(state);
	});
}

function handleSaveApply(viewState, state, ev, mode) {
	const previousEnabled = !!viewState.initialEnabled;
	const previousCountry = viewState.initialCountry || '';
	const previousMode = viewState.initialMode || 'auto';
	const previousPreferredStation = viewState.initialPreferredStation || '';
	const currentEnabled = !!(managerUI.getEnabledCheckboxElement() && managerUI.getEnabledCheckboxElement().checked);
	const currentMode = managerUI.getSelectedMode();
	const currentCountry = managerUI.getSelectedCountry();
	const preferredStation = managerUI.getSelectedPreferredStation();
	const preferredStationChanged = (currentMode === 'manual' && preferredStation !== previousPreferredStation);
	const enteringManualMode = (currentMode === 'manual' && previousMode !== 'manual');
	const serverSelectionChanged = hasServerSelectionChanged(
		previousCountry,
		currentCountry,
		previousMode,
		currentMode,
		previousPreferredStation,
		preferredStation
	);
	const selectedServer = preferredStation ? state.serverCatalogIndex[preferredStation] : null;
	const debugLines = buildSaveApplyDebugLines(
		previousEnabled,
		currentEnabled,
		previousCountry,
		currentCountry,
		previousMode,
		currentMode,
		previousPreferredStation,
		preferredStation,
		selectedServer
	);
	const preservingExistingManualPreference = (
		currentMode === 'manual' &&
		previousMode === 'manual' &&
		preferredStation === previousPreferredStation &&
		!!preferredStation
	);
	let confirmationPromise = Promise.resolve(true);

	if (currentMode === 'manual') {
		if (!currentCountry) {
			service.notifyError(new Error(_('Manual mode requires a selected country.')));
			return Promise.resolve();
		}

		if ((!preferredStation || !selectedServer) && !preservingExistingManualPreference) {
			service.notifyError(new Error(_('Manual mode requires a valid preferred server from the current catalog.')));
			return Promise.resolve();
		}

		if (preferredStationChanged || enteringManualMode) {
			uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', selectedServer.hostname);
			uci.set('nordvpn_easy', 'main', 'preferred_server_station', preferredStation);
		}
	}
	else {
		uci.set('nordvpn_easy', 'main', 'preferred_server_hostname', '');
		uci.set('nordvpn_easy', 'main', 'preferred_server_station', '');
	}

	if (previousEnabled && managerUI.getEnabledCheckboxElement() && !managerUI.getEnabledCheckboxElement().checked) {
		confirmationPromise = managerUI.showConfirmationModal(
			_('Disable NordVPN Easy'),
			[
				_('Disabling NordVPN Easy will stop the VPN interface and remove cron/hotplug hooks.'),
				_('Your current VPN connection will be interrupted.')
			]
		);
	}
	else if (previousEnabled && (
		serverSelectionChanged
	)) {
		confirmationPromise = managerUI.showConfirmationModal(
			_('Confirm Server Change'),
			[
				_('Applying these changes will reconfigure the current VPN tunnel, cycle the VPN interface, and then reconnect with the selected server settings.'),
				currentMode === 'manual'
					? (selectedServer
						? _('Preferred server: %s').format(managerFormat.formatServerLabel(selectedServer))
						: (preferredStation
							? _('Preferred server unchanged: %s').format(preferredStation)
							: _('Manual mode will keep the existing preferred server settings.')))
					: _('Automatic mode will use NordVPN recommended servers.')
			]
		);
	}

	return confirmationPromise.then(function(confirmed) {
		if (!confirmed)
			return;

		notifyDebugBlock(_('Save & Apply requested'), debugLines.concat([
			_('UCI changes are being committed before runtime actions start.')
		]));

		managerStore.clearError(state);
		managerStore.suspendPolling(state);
		managerStore.setPhase(state, managerStore.PHASES.SAVING);

		return new Promise(function(resolve, reject) {
			let settled = false;
			let timeoutId = null;

			const cleanup = function() {
				if (timeoutId !== null) {
					clearTimeout(timeoutId);
					timeoutId = null;
				}
				if (viewState._uciAppliedHandler) {
					document.removeEventListener('uci-applied', viewState._uciAppliedHandler);
					viewState._uciAppliedHandler = null;
				}
			};

			const finishResolve = function(value) {
				if (settled)
					return;

				settled = true;
				cleanup();
				resolve(value);
			};

			const finishReject = function(err) {
				if (settled)
					return;

				settled = true;
				cleanup();
				reject(err);
			};

			const handleRejectedSaveFlow = function(err) {
				managerStore.setError(state, err);
				state.pendingOperationLabel = '';
				managerStore.resumePolling(state);
				updateLocalStatus(state, { force: true });
				finishReject(err);
			};

			cleanup();

			Promise.resolve(viewState.handleSave(ev)).then(function() {
				viewState._uciAppliedHandler = function() {
					Promise.resolve().then(function() {
						uci.unload('nordvpn_easy');
						return uci.load('nordvpn_easy');
					}).then(function() {
						const enabled = (uci.get('nordvpn_easy', 'main', 'enabled') !== '0');
						const country = managerData.normalizeCountryCode(uci.get('nordvpn_easy', 'main', 'vpn_country') || '');
						const modeValue = String(uci.get('nordvpn_easy', 'main', 'server_selection_mode') || 'auto');
						const preferred = String(uci.get('nordvpn_easy', 'main', 'preferred_server_station') || '');
						const runtimePlan = deriveRuntimeActionPlan(
							previousEnabled,
							enabled,
							previousCountry,
							country,
							previousMode,
							modeValue,
							previousPreferredStation,
							preferred,
							state.currentLocalStatus
						);
						const actions = runtimePlan.actions;
						const successMessage = runtimePlan.successMessage;

						viewState.initialEnabled = enabled;
						viewState.initialCountry = country;
						viewState.initialMode = modeValue;
						viewState.initialPreferredStation = preferred;
						state.appliedEnabled = enabled;
						state.appliedCountryCode = country;

						if (!actions.length) {
							notifyDebugBlock(_('Configuration applied'), [
								_('UCI changes were saved successfully.'),
								_('No runtime action was required.')
							]);
							state.pendingOperationLabel = '';
							managerStore.resumePolling(state);
							updateLocalStatus(state, { force: true });
							finishResolve();
							return;
						}

						state.pendingOperationLabel = managerFormat.formatActionsLabel(actions);
						state.currentOperationStatus = 'busy:' + state.pendingOperationLabel;
						managerStore.setPhase(state, managerStore.PHASES.RUNTIME_BUSY);
						managerStore.resumePolling(state);
						notifyDebugBlock(_('Runtime actions queued'), [
							_('Executing: %s').format(state.pendingOperationLabel),
							_('Enabled state after save: %s').format(enabled ? _('checked') : _('unchecked'))
						]);
						updateLocalStatus(state, { force: true });

						service.runActions(actions).then(function() {
							service.notifyInfo(successMessage);
							finishResolve();
						}).catch(function(err) {
							managerStore.setError(state, err);
							service.notifyError(err);
							finishReject(err);
						}).finally(function() {
							state.pendingOperationLabel = '';
							managerStore.resumePolling(state);
							updateLocalStatus(state, { force: true });
							updatePublicIp(state, { force: true });
						});
					}).catch(function(err) {
						const message = (err && err.message) ? err.message : String(err);

						managerStore.setError(state, err);
						managerStore.resumePolling(state);
						service.notifyError(new Error(_('Automatic runtime sync failed: ') + message));
						finishReject(err);
					});
				};

				timeoutId = setTimeout(function() {
					const timeoutError = new Error(_('Configuration apply timed out.'));

					managerStore.setError(state, timeoutError);
					state.pendingOperationLabel = '';
					managerStore.resumePolling(state);
					updateLocalStatus(state, { force: true });
					finishReject(timeoutError);
				}, 60000);

				document.addEventListener('uci-applied', viewState._uciAppliedHandler);
				state.pendingOperationLabel = _('configuration');
				state.currentOperationStatus = 'busy:configuration';
				managerStore.setPhase(state, managerStore.PHASES.SAVING);
				updateLocalStatus(state, { force: true });
				Promise.resolve(ui.changes.apply(mode === '0')).catch(function(err) {
					managerStore.setError(state, err);
					state.pendingOperationLabel = '';
					managerStore.resumePolling(state);
					updateLocalStatus(state, { force: true });
					finishReject(err);
				});
			}).catch(function(err) {
				handleRejectedSaveFlow(err);
			});
		});
	});
}

return baseclass.extend({
	hasServerSelectionChanged: hasServerSelectionChanged,
	deriveRuntimeActionPlan: deriveRuntimeActionPlan,
	loadServerCatalog: loadServerCatalog,
	updatePublicIp: updatePublicIp,
	updatePublicCountry: updatePublicCountry,
	updateLocalStatus: updateLocalStatus,
	onCountryChanged: onCountryChanged,
	onModeChanged: onModeChanged,
	handleRefreshServerCatalog: handleRefreshServerCatalog,
	handleSaveApply: handleSaveApply
});
