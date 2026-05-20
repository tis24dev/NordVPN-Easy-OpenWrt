'use strict';
/* global baseclass, managerActions, managerStore */
'require baseclass';
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-store as managerStore';

return baseclass.extend({
	createState: managerStore.createState,
	loadServerCatalog: managerActions.loadServerCatalog,
	updatePublicIp: managerActions.updatePublicIp,
	updateLocalStatus: managerActions.updateLocalStatus,
	maybeAutoReconcileSelectionDrift: managerActions.maybeAutoReconcileSelectionDrift,
	onCountryChanged: managerActions.onCountryChanged,
	onModeChanged: managerActions.onModeChanged,
	handleRefreshServerCatalog: managerActions.handleRefreshServerCatalog,
	handleSaveApply: managerActions.handleSaveApply,
	runApplyCycle: managerActions.runApplyCycle
});
