'use strict';
'require baseclass';
'require nordvpn-easy/manager-actions as managerActions';
'require nordvpn-easy/manager-store as managerStore';

return baseclass.extend({
	createState: managerStore.createState,
	loadServerCatalog: managerActions.loadServerCatalog,
	updatePublicIp: managerActions.updatePublicIp,
	updatePublicCountry: managerActions.updatePublicCountry,
	updateLocalStatus: managerActions.updateLocalStatus,
	onCountryChanged: managerActions.onCountryChanged,
	onModeChanged: managerActions.onModeChanged,
	handleRefreshServerCatalog: managerActions.handleRefreshServerCatalog,
	handleSaveApply: managerActions.handleSaveApply
});
