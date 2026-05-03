#!/usr/bin/env node

'use strict';
/* global require, __dirname, console, process */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const rootDir = path.resolve(__dirname, '..', '..');
const advancedPath = path.join(
	rootDir,
	'openwrt-packages',
	'luci-app-nordvpn-easy',
	'htdocs',
	'luci-static',
	'resources',
	'view',
	'nordvpn-easy',
	'advanced.js'
);

const source = fs.readFileSync(advancedPath, 'utf8');

assert.doesNotMatch(source, /hk318/, 'advanced fallback UI must not suggest a known-problematic HK318 station');
assert.match(source, /fallbackStatusLabel/, 'advanced fallback UI renders a fallback status');
assert.match(source, /buildServerCatalogIndex/, 'advanced fallback UI validates against the server catalog when available');
assert.match(source, /Fallback server must be different from the preferred server/, 'advanced fallback UI rejects preferred=fallback');

console.log('test-advanced.js: ok');
