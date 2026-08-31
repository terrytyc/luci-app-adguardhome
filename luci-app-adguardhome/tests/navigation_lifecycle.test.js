'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const operationPath = path.join(
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
	const source = fs.readFileSync(operationPath, 'utf8');
	const listeners = new Map();
	const storage = new Map();
	const rendered = [];
	const bodyClasses = new Set();
	const fakeDocument = {
		body: {
			classList: {
				contains(name) { return bodyClasses.has(name); },
			},
		},
		documentElement: {
			contains(node) { return node.isConnected === true; },
		},
		addEventListener(type, callback) {
			if (!listeners.has(type))
				listeners.set(type, []);
			listeners.get(type).push(callback);
		},
		removeEventListener(type, callback) {
			if (!listeners.has(type))
				return;
			listeners.set(type, listeners.get(type).filter(entry => entry !== callback));
		},
	};
	const fakeWindow = {
		addEventListener: fakeDocument.addEventListener.bind(fakeDocument),
		setTimeout(callback) { return setTimeout(callback, 0); },
		clearTimeout(id) { clearTimeout(id); },
		sessionStorage: {
			getItem(key) { return storage.has(key) ? storage.get(key) : null; },
			setItem(key, value) { storage.set(key, String(value)); },
			removeItem(key) { storage.delete(key); },
		},
	};
	const fakeUi = {
		showModal(_title, child) { rendered.push(child); },
		hideModal() {},
	};
	const LuCIClass = createLuCIClass();
	const sandbox = {
		E: (tag, attrs, child) => ({ tag, attrs, text: String(child) }),
		L: { env: { apply_display: 2, apply_holdoff: 1, apply_rollback: 90 } },
		_: translated,
		window: fakeWindow,
		document: fakeDocument,
		setTimeout,
		clearTimeout,
	};
	vm.createContext(sandbox);
	const ModuleClass = vm.runInContext(
		'(function(window, document, L, baseclass, ui) {\n' + source +
			'\n}).call(globalThis, window, document, L, LuCIClass, fakeUi)',
		Object.assign(sandbox, { LuCIClass, fakeUi }),
		{ filename: operationPath }
	);

	return {
		operation: new ModuleClass(),
		bodyClasses,
		listeners,
		rendered,
	};
}

async function main() {
	const state = loadOperation();
	const root = { isConnected: false };
	const scope = state.operation.createPageScope();
	scope.attach(root);
	assert.equal(scope.active(), true,
		'a newly rendered root may be checked before LuCI inserts it');
	root.isConnected = true;
	assert.equal(scope.active(), true);
	root.isConnected = false;
	assert.equal(scope.active(), false,
		'a root removed after insertion must invalidate the page scope');

	const before = state.rendered.length;
	state.operation.failure('stale XHR error');
	assert.equal(state.rendered.length, before,
		'an inactive page must not show a late failure modal');

	const oldRoot = { isConnected: true };
	const oldScope = state.operation.createPageScope();
	oldScope.attach(oldRoot);
	const oldTicket = state.operation.start();
	const afterOldStart = state.rendered.length;
	const currentRoot = { isConnected: true };
	const currentScope = state.operation.createPageScope();
	currentScope.attach(currentRoot);
	await new Promise(resolve => setTimeout(resolve, 5));
	state.operation.success('late result from old view', oldTicket);
	assert.equal(state.rendered.length, afterOldStart,
		'creating a new scope must cancel the old timer and reject its late result');

	state.operation.markApplyPending();
	assert.equal(state.operation.applyPending(), true);
	state.bodyClasses.add('modal-overlay-active');
	const modalButtonClick = {
		target: {
			closest: selector => selector === 'button' ? {} : null,
		},
		prevented: false,
		preventDefault() { this.prevented = true; },
		stopPropagation() {},
	};
	for (const listener of state.listeners.get('click') ?? [])
		listener(modalButtonClick);
	assert.equal(modalButtonClick.prevented, false,
		'LuCI apply and connectivity-warning buttons must remain usable');

	const linkedButtonClick = {
		target: {
			closest: selector => selector === 'button' || selector === 'a[href]'
				? {}
				: null,
		},
		prevented: false,
		preventDefault() { this.prevented = true; },
		stopPropagation() {},
		stopImmediatePropagation() {},
	};
	for (const listener of state.listeners.get('click') ?? [])
		listener(linkedButtonClick);
	assert.equal(linkedButtonClick.prevented, true,
		'a button nested in a link must not bypass the navigation guard');

	const guardedClick = {
		target: { closest: selector => selector === 'a[href]' ? {} : null },
		prevented: false,
		stopped: false,
		immediate: false,
		preventDefault() { this.prevented = true; },
		stopPropagation() { this.stopped = true; },
		stopImmediatePropagation() { this.immediate = true; },
	};
	for (const listener of state.listeners.get('click') ?? [])
		listener(guardedClick);
	assert.equal(guardedClick.prevented, true,
		'an exposed theme link must not leave a checked apply confirmation page');
	assert.equal(guardedClick.stopped, true);
	assert.equal(guardedClick.immediate, true);

	state.bodyClasses.delete('modal-overlay-active');
	const releasedClick = {
		target: { closest: selector => selector === 'a[href]' ? {} : null },
		prevented: false,
		preventDefault() { this.prevented = true; },
		stopPropagation() {},
	};
	for (const listener of [ ...(state.listeners.get('click') ?? []) ])
		listener(releasedClick);
	assert.equal(releasedClick.prevented, false,
		'navigation must be released as soon as LuCI closes its apply modal');
	assert.equal(state.operation.applyPending(), false,
		'closing the modal must clear a stale retry marker');

	state.operation.markApplyPending();

	let attempts = 0;
	const recovered = await state.operation.requestDuringApply(async () => {
		attempts++;
		if (attempts === 1) {
			const error = new Error('XHR request timed out');
			error.name = 'RequestError';
			throw error;
		}
		return 'ready';
	}, currentScope);
	assert.equal(recovered, 'ready');
	assert.equal(attempts, 2,
		'a transient request failure is retried only during a marked apply');

	let permanentAttempts = 0;
	await assert.rejects(
		state.operation.requestDuringApply(async () => {
			permanentAttempts++;
			const error = new Error('invalid YAML');
			error.name = 'RPCError';
			throw error;
		}, currentScope),
		/invalid YAML/,
	);
	assert.equal(permanentAttempts, 1,
		'a real method failure must remain visible without retry masking');

	const pending = state.operation.requestDuringApply(
		() => Promise.resolve('late reply'),
		currentScope,
	);
	currentRoot.isConnected = false;
	let inactiveError = null;
	await assert.rejects(pending, error => {
		inactiveError = error;
		return error?.pageInactive === true;
	},
		'a reply reaching a destroyed page must be discarded');
	let obsoleteLoadSettled = false;
	state.operation.abandonInactiveLoad(inactiveError).then(() => {
		obsoleteLoadSettled = true;
	});
	await new Promise(resolve => setTimeout(resolve, 5));
	assert.equal(obsoleteLoadSettled, false,
		'an obsolete LuCI load chain must remain pending instead of rendering an empty old view');

	for (const name of [ 'overview', 'yaml', 'log' ]) {
		const source = fs.readFileSync(path.join(
			packageRoot,
			`htdocs/luci-static/resources/view/adguardhome/${name}.js`
		), 'utf8');
		assert.match(source, /operation\.createPageScope\(\)/,
			`${name} must establish a page lifecycle scope`);
		assert.match(source, /const pageScope = operation\.createPageScope\(\);/,
			`${name} must retain the lifecycle scope created by load`);
		assert.match(source, /pageScope\.attach\(/,
			`${name} must attach its rendered root to the lifecycle scope`);
		assert.match(source, /operation\.isPageActive\(pageScope\)/,
			`${name} render must reject results owned by a stale load scope`);
		assert.match(source, /operation\.isPageActive\(/,
			`${name} must guard asynchronous DOM updates`);
		assert.match(source, /operation\.abandonInactiveLoad\(/,
			`${name} must prevent an obsolete load continuation from rendering`);
		assert.match(source, /const operationTicket = operation\.start\(\)/,
			`${name} must retain the operation ticket for its long request`);
		assert.match(source, /operation\.success\([\s\S]*?operationTicket[\s\S]*?\)/,
			`${name} success must be scoped to its originating operation ticket`);
		assert.match(source, /operation\.failure\([\s\S]*?operationTicket[\s\S]*?\)/,
			`${name} failure must be scoped to its originating operation ticket`);
	}

	const overview = fs.readFileSync(path.join(
		packageRoot,
		'htdocs/luci-static/resources/view/adguardhome/overview.js'
	), 'utf8');
	assert.match(
		overview,
		/handleSaveApply\(ev, mode\)\s*\{\s*return this\.handleSave\(ev\)\.then\(\(\) => \{[\s\S]*?operation\.markApplyPending\(\);\s*return ui\.changes\.apply\(mode == '0'\);[\s\S]*?\}\);\s*\}/,
		'the cross-tab retry window must begin after save succeeds and immediately before LuCI applies changes',
	);
	assert.match(
		overview,
		/const rendered = await map\.render\(\);\s*if \(!operation\.isPageActive\(pageScope\)\)\s*return operation\.abandonInactiveLoad\(operation\.pageInactiveError\(\)\);/s,
		'the async settings form must not render after its page scope becomes stale',
	);
	const yaml = fs.readFileSync(path.join(
		packageRoot,
		'htdocs/luci-static/resources/view/adguardhome/yaml.js'
	), 'utf8');
	assert.doesNotMatch(yaml, /inactive:\s*true/,
		'an inactive YAML load must not render an empty editor');

	console.log('navigation lifecycle and apply retry tests passed');
}

main().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
