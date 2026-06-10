#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rootDir = path.resolve(__dirname, '..', '..');
const resDir = path.join(
	rootDir,
	'openwrt-packages', 'luci-app-nordvpn-easy', 'htdocs', 'luci-static', 'resources', 'nordvpn-easy'
);

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function() {
			let index = 0;
			const args = arguments;
			return String(this).replace(/%[sd]/g, function() {
				return String(args[index++]);
			});
		},
		configurable: true
	});
}

// The module runs in its own vm realm, so LuCI's String.prototype.format must be
// defined on that realm's String, not just this one.
const FORMAT_POLYFILL =
	"if (!String.prototype.format) { Object.defineProperty(String.prototype, 'format', " +
	"{ value: function(){ var i=0, a=arguments; return String(this).replace(/%[sd]/g, " +
	"function(){ return String(a[i++]); }); }, configurable: true }); }\n";

function loadModule(file, context) {
	const source = fs.readFileSync(path.join(resDir, file), 'utf8');
	return vm.runInNewContext(`(function(){\n${FORMAT_POLYFILL}${source}\n})();`, context, { filename: file });
}

const managerData = loadModule('manager-data.js', {
	baseclass: { extend(api) { return api; } }
});

// Minimal DOM: a country dropdown (the unsaved selection), and the Country Match
// status cell whose rendered colour + label we capture. document.getElementById
// reads `registry` at call time, so we wire elements up after the module loads
// and learns its own element ids.
const registry = {};
const indicator = { color: null, label: null };

function makeStatusCell() {
	return {
		replaceChildren(spanNode, textNode) {
			const style = (spanNode && spanNode.props && spanNode.props.style) || '';
			const m = style.match(/background:([^;]+)/);
			indicator.color = m ? m[1] : null;
			indicator.label = textNode ? textNode.nodeText : null;
		}
	};
}

function makeSelect(value) {
	return { value: value, matches(sel) { return sel === 'select'; }, querySelector() { return null; } };
}

const context = {
	baseclass: { extend(api) { return api; } },
	managerData: managerData,
	managerFormat: {},
	ui: {},
	L: {},
	_: function(s) { return s; },
	E: function(tag, props, children) { return { tag: tag, props: props, children: children }; },
	document: {
		getElementById(id) { return registry[id] || null; },
		createTextNode(text) { return { nodeText: text }; }
	}
};

const managerUI = loadModule('manager-ui.js', context);
const ids = managerUI.ids;

function run(state, dropdownCountry) {
	registry[ids.COUNTRY_FIELD_ID] = makeSelect(dropdownCountry);
	registry[ids.COUNTRY_MATCH_STATUS_ID] = makeStatusCell();
	indicator.color = null;
	indicator.label = null;
	managerUI.updateCountryMatchStatus(state);
	return { color: indicator.color, label: indicator.label };
}

const GREEN = '#2ea043';
const RED = '#cf222e';

const activeStatus = { runtime_disabled: false, interface_disabled: false };

// Core regression: the dropdown shows an unsaved 'DE', but the saved/applied
// country is 'SE' and the exit IP geolocates to 'SE'. Country Match must read
// the SAVED country and report a match, not flip to mismatch off the dropdown.
let r = run({
	appliedEnabled: true,
	currentLocalStatus: activeStatus,
	currentOperationStatus: 'idle',
	applyTargetCountryCode: '',
	appliedCountryCode: 'SE',
	currentPublicCountry: 'SE',
	saveApplyInProgress: false
}, 'DE');
assert.equal(r.color, GREEN, 'unsaved dropdown change must not turn Country Match red');
assert.equal(r.label, 'Match (SE)', 'Country Match reflects the saved country, not the dropdown');

// While a Save & Apply is converging, the in-flight target wins so the indicator
// tracks the country actually being applied.
r = run({
	appliedEnabled: true,
	currentLocalStatus: activeStatus,
	currentOperationStatus: 'idle',
	applyTargetCountryCode: 'DE',
	appliedCountryCode: 'SE',
	currentPublicCountry: 'DE',
	saveApplyInProgress: true
}, 'DE');
assert.equal(r.color, GREEN, 'apply target match turns Country Match green');
assert.equal(r.label, 'Match (DE)', 'during apply Country Match tracks the in-flight target');

// Same apply, not yet converged: exit IP still in the old country -> mismatch.
r = run({
	appliedEnabled: true,
	currentLocalStatus: activeStatus,
	currentOperationStatus: 'idle',
	applyTargetCountryCode: 'DE',
	appliedCountryCode: 'SE',
	currentPublicCountry: 'SE',
	saveApplyInProgress: true
}, 'DE');
assert.equal(r.color, RED, 'apply still converging shows a mismatch');
assert.equal(r.label, 'Mismatch (SE)', 'mismatch reports the actual exit country');

// Transition logging: onCountryMatchChange fires only on a real change of the
// indicator's meaning, and never on the first observation (which just seeds the
// dedup key so a page reload does not spam the log).
const changes = [];
const persistent = {
	appliedEnabled: true,
	currentLocalStatus: activeStatus,
	currentOperationStatus: 'idle',
	applyTargetCountryCode: '',
	appliedCountryCode: 'SE',
	currentPublicCountry: 'SE',
	saveApplyInProgress: false,
	countryMatchLogKey: '',
	onCountryMatchChange: function(info) { changes.push(info); }
};
registry[ids.COUNTRY_FIELD_ID] = makeSelect('');
registry[ids.COUNTRY_MATCH_STATUS_ID] = makeStatusCell();

managerUI.updateCountryMatchStatus(persistent);
assert.equal(changes.length, 0, 'first observation seeds the dedup key without logging');

managerUI.updateCountryMatchStatus(persistent);
assert.equal(changes.length, 0, 'an unchanged indicator logs nothing');

persistent.currentPublicCountry = 'DE';
managerUI.updateCountryMatchStatus(persistent);
assert.equal(changes.length, 1, 'a real transition fires the change callback once');
assert.equal(changes[0].indicator, 'mismatch', 'transition payload carries the new indicator');
assert.equal(changes[0].expected, 'SE', 'transition payload carries the selected country');
assert.equal(changes[0].actual, 'DE', 'transition payload carries the exit country');

persistent.appliedCountryCode = 'DE';
managerUI.updateCountryMatchStatus(persistent);
assert.equal(changes.length, 2, 'returning to a match logs the transition back');
assert.equal(changes[1].indicator, 'match', 'transition back reports the match indicator');

console.log('test-manager-ui.js: ok');
