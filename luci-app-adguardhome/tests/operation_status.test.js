'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const modulePath = path.join(
	packageRoot,
	'htdocs/luci-static/resources/adguardhome/operation.js'
);

function createLuCIClass() {
	function LuCIClass() {}
	LuCIClass.extend = function(definition) {
		function DerivedClass() {}
		DerivedClass.prototype = Object.create(this.prototype);
		Object.assign(DerivedClass.prototype, definition);
		DerivedClass.extend = this.extend;
		return DerivedClass;
	};
	LuCIClass.isSubclass = candidate =>
		typeof candidate === 'function' && candidate.prototype instanceof LuCIClass;
	return LuCIClass;
}

function translated(value) {
	const result = new String(value);
	result.format = (...args) => {
		let offset = 0;
		return value.replace(/%[sd]/g, () => String(args[offset++]));
	};
	return result;
}

function loadOperation() {
	const source = fs.readFileSync(modulePath, 'utf8');
	const LuCIClass = createLuCIClass();
	const rendered = [];
	const timers = new Map();
	let nextTimer = 1;
	let now = 1000;
	let hidden = 0;

	const fakeWindow = {
		setTimeout(callback, delay) {
			const id = nextTimer++;
			timers.set(id, { callback, delay });
			return id;
		},
		clearTimeout(id) {
			timers.delete(id);
		},
	};
	const fakeUi = {
		showModal(title, child, ...classes) {
			rendered.push({ title, child, classes });
			return {};
		},
		hideModal() {
			hidden++;
		},
	};
	const sandbox = {
		Date: { now: () => now },
		E: (tag, attrs, child) => ({ tag, attrs, text: String(child) }),
		L: { env: { apply_display: 2 } },
		Number,
		String,
		_: translated,
		window: fakeWindow,
	};
	vm.createContext(sandbox);
	const ModuleClass = vm.runInContext(
		'(function(window, document, L, baseclass, ui) {\n' + source +
			'\n}).call(globalThis, window, null, L, LuCIClass, fakeUi)',
		Object.assign(sandbox, { LuCIClass, fakeUi }),
		{ filename: modulePath }
	);
	assert.equal(LuCIClass.isSubclass(ModuleClass), true,
		'operation resource must yield an L.Class constructor');

	return {
		operation: new ModuleClass(),
		rendered,
		timers,
		advanceOne() {
			const entry = timers.entries().next().value;
			assert.ok(entry, 'expected a pending timer');
			const [ id, timer ] = entry;
			timers.delete(id);
			now += timer.delay;
			timer.callback();
		},
		hidden: () => hidden,
	};
}

const state = loadOperation();
state.operation.start();
assert.equal(state.rendered.at(-1).child.text,
	'Applying configuration changes… 90s');
assert.deepEqual(state.rendered.at(-1).classes,
	[ 'alert-message', 'notice', 'spinning' ]);
assert.equal(state.rendered.at(-1).child.tag, 'p');
state.advanceOne();
assert.equal(state.rendered.at(-1).child.text,
	'Applying configuration changes… 89s');

state.operation.success();
assert.equal(state.rendered.at(-1).child.text, 'Configuration changes applied.');
assert.deepEqual(state.rendered.at(-1).classes, [ 'alert-message', 'notice' ]);
assert.equal(state.hidden(), 0);
state.advanceOne();
assert.equal(state.hidden(), 1, 'success status must close automatically');

state.operation.success('saved, reload required');
assert.equal(state.rendered.at(-1).child.text, 'saved, reload required');
assert.deepEqual(state.rendered.at(-1).classes, [ 'alert-message', 'notice' ]);
state.advanceOne();
assert.equal(state.hidden(), 2, 'custom success status must close automatically');

state.operation.failure('failed');
assert.equal(state.rendered.at(-1).child.text, 'failed');
assert.deepEqual(state.rendered.at(-1).classes, [ 'alert-message', 'error' ]);
state.advanceOne();
assert.equal(state.hidden(), 3, 'failure status must close automatically');

const overview = fs.readFileSync(path.join(
	packageRoot,
	'htdocs/luci-static/resources/view/adguardhome/overview.js'
), 'utf8');
const yaml = fs.readFileSync(path.join(
	packageRoot,
	'htdocs/luci-static/resources/view/adguardhome/yaml.js'
), 'utf8');
const log = fs.readFileSync(path.join(
	packageRoot,
	'htdocs/luci-static/resources/view/adguardhome/log.js'
), 'utf8');

for (const [ name, source ] of [ [ 'overview', overview ], [ 'yaml', yaml ], [ 'log', log ] ]) {
	assert.match(source, /require adguardhome\.operation as operation/,
		`${name} view must use the shared operation status`);
	assert.match(source, /operation\.start\(\)/,
		`${name} view must show operation progress`);
	assert.match(source, /operation\.success\(\)/,
		`${name} view must show operation success`);
	assert.match(source, /operation\.failure\(/,
		`${name} view must show operation failure`);
}

assert.match(overview, /Change Username and Password/);
assert.doesNotMatch(overview,
	/Changes the password for the admin account stored in AdGuardHome\.yaml/);
assert.doesNotMatch(overview,
	/HTTP keeps the host used to access LuCI and uses the port from YAML http\.address/);
assert.match(overview, /const YAML_POLL_LIMIT = 360;/);
assert.match(yaml, /const YAML_POLL_LIMIT = 360;/);

console.log('operation status and view integration tests passed');
