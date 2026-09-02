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

function loadOperation(sharedStorage) {
	const source = fs.readFileSync(operationPath, 'utf8');
	const listeners = new Map();
	const onceListeners = new Map();
	const storage = sharedStorage ?? new Map();
	const rendered = [];
	const bodyClasses = new Set();
	const mutationObservers = new Set();
	let reloads = 0;

	const notifyBodyMutation = () => {
		for (const observer of [ ...mutationObservers ])
			observer.callback([], observer);
	};
	const addBodyClass = bodyClasses.add.bind(bodyClasses);
	const deleteBodyClass = bodyClasses.delete.bind(bodyClasses);
	bodyClasses.add = name => {
		const changed = !bodyClasses.has(name);
		addBodyClass(name);
		if (changed)
			notifyBodyMutation();
		return bodyClasses;
	};
	bodyClasses.delete = name => {
		const changed = deleteBodyClass(name);
		if (changed)
			notifyBodyMutation();
		return changed;
	};

	class FakeMutationObserver {
		constructor(callback) {
			this.callback = callback;
		}

		observe() {
			mutationObservers.add(this);
		}

		disconnect() {
			mutationObservers.delete(this);
		}
	}
	const fakeDocument = {
		body: {
			classList: {
				contains(name) { return bodyClasses.has(name); },
			},
		},
		documentElement: {
			contains(node) { return node.isConnected === true; },
		},
		addEventListener(type, callback, options) {
			if (!listeners.has(type))
				listeners.set(type, []);
			listeners.get(type).push(callback);
			if (options != null && typeof options === 'object' && options.once === true) {
				if (!onceListeners.has(type))
					onceListeners.set(type, new Set());
				onceListeners.get(type).add(callback);
			}
		},
		removeEventListener(type, callback) {
			if (!listeners.has(type))
				return;
			listeners.set(type, listeners.get(type).filter(entry => entry !== callback));
			onceListeners.get(type)?.delete(callback);
		},
	};
	const fakeWindow = {
		addEventListener: fakeDocument.addEventListener.bind(fakeDocument),
		setTimeout(callback) { return setTimeout(callback, 0); },
		clearTimeout(id) { clearTimeout(id); },
		MutationObserver: FakeMutationObserver,
		location: {
			reload() { reloads++; },
		},
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
		storage,
		dispatch(type, event = {}) {
			for (const listener of [ ...(listeners.get(type) ?? []) ]) {
				if (onceListeners.get(type)?.has(listener))
					fakeDocument.removeEventListener(type, listener);
				listener(event);
			}
		},
		observedMutations: () => mutationObservers.size,
		reloads: () => reloads,
	};
}

function loadOverview(operation, ui, rpcHandlers = {}) {
	const overviewPath = path.join(
		packageRoot,
		'htdocs/luci-static/resources/view/adguardhome/overview.js'
	);
	const source = fs.readFileSync(overviewPath, 'utf8');
	const rpc = {
		declare: specification => async (...args) => {
			const handler = rpcHandlers[specification.method];
			return typeof handler === 'function' ? handler(...args) : {};
		},
	};
	const view = { extend: definition => definition };
	const sandbox = {
		E: () => ({}),
		L: { env: {} },
		URL,
		_: translated,
		console,
		window: {
			location: { href: 'https://router.example/cgi-bin/luci/admin/services/adguardhome' },
			setTimeout(callback) { return setTimeout(callback, 0); },
		},
	};
	vm.createContext(sandbox);
	return vm.runInContext(
		'(function(bcrypt, operation, dom, form, poll, rpc, uci, ui, view, window, L, E, _, URL, console) {\n' +
			source +
			'\n}).call(globalThis, {}, operation, {}, {}, {}, rpc, {}, ui, view, window, L, E, _, URL, console)',
		Object.assign(sandbox, { operation, rpc, ui, view }),
		{ filename: overviewPath },
	);
}

async function runSettingsSubmissionScenario(kind) {
	const oldRevision = 'a'.repeat(64);
	const terminalRevision = 'b'.repeat(64);
	const currentRevision = 'c'.repeat(64);
	const values = new Map([
		[ 'config.enabled', '1' ],
		[ 'config.work_dir', '/etc/AdGuardHome' ],
		[ 'config.verbose', '0' ],
		[ 'luci.redirect', 'dnsmasq-upstream' ],
		[ 'luci.run_from_memory', '0' ],
		[ 'luci.memory_writeback_interval', '60' ],
	]);
	const failures = [];
	let successes = 0;
	let setCalls = 0;
	let statusCalls = 0;
	let resetCalls = 0;
	let setArguments = null;
	let context = null;

	const operation = {
		isPageActive: () => true,
		pageInactiveError: () => Object.assign(new Error('inactive'), { pageInactive: true }),
		isPageInactiveError: error => error?.pageInactive === true,
		start: () => ({}),
		failure: message => failures.push(String(message)),
		success: () => { successes++; },
		requestDuringApply: request => request(),
	};
	const rpcHandlers = {
		set_settings: async (...args) => {
			setCalls++;
			setArguments = args;
			if (kind === 'request-transport')
				throw new Error('XHR request failed');
			if (kind === 'bad-token')
				return { accepted: true, token: 'invalid' };
			return { accepted: true, token: 'd'.repeat(32) };
		},
		get_settings_update: async () => {
			statusCalls++;
			if (kind === 'status-transport')
				throw new Error('status XHR failed');
			if (kind === 'indeterminate')
				return {
					state: 'done',
					ok: false,
					indeterminate: true,
					error: 'coordinator outcome unknown',
				};
			return { state: 'done', ok: true, revision: terminalRevision };
		},
		get_settings: async () => {
			if (kind === 'reload-failure')
				throw new Error('authoritative reload failed');
			return {
				enabled: false,
				work_dir: '/mnt/storage/AdGuardHome',
				verbose: true,
				redirect: 'redirect',
				run_from_memory: true,
				memory_writeback_interval: 77,
				revision: currentRevision,
			};
		},
	};
	const view = loadOverview(operation, {}, rpcHandlers);
	const map = {
		readonly: false,
		checkDepends() {},
		async parse() {},
		async reset() {
			resetCalls++;
			if (kind === 'success') {
				assert.equal(context.settingsRevision, oldRevision,
					'the authoritative revision must not be adopted before the visible form resets');
				assert.equal(context.committedSettings.memoryWritebackInterval, 60);
			}
		},
		data: {
			get(_config, section, option) {
				return values.get(`${section}.${option}`);
			},
			set(_config, section, option, value) {
				values.set(`${section}.${option}`, value);
			},
		},
	};
	context = {
		pageScope: {},
		settingsMap: map,
		settingsRevision: oldRevision,
		committedSettings: { memoryWritebackInterval: 60 },
	};

	await view.submitSettings.call(context);
	return {
		context,
		failures,
		map,
		resetCalls,
		setCalls,
		setArguments,
		statusCalls,
		successes,
		values,
		view,
	};
}

async function main() {
	const bfcacheState = loadOperation();
	bfcacheState.operation.createPageScope();
	const bfcacheRoot = { isConnected: true };
	const bfcacheScope = bfcacheState.operation.createPageScope();
	bfcacheScope.attach(bfcacheRoot);
	assert.equal((bfcacheState.listeners.get('pageshow') ?? []).length, 1,
		'multiple view scopes must share one BFCache restoration guard');
	bfcacheState.dispatch('pageshow', { persisted: false });
	assert.equal(bfcacheState.reloads(), 0,
		'an ordinary initial pageshow must not reload the view');
	bfcacheState.dispatch('pagehide', { persisted: true });
	assert.equal(bfcacheScope.active(), false,
		'pagehide must permanently invalidate the old page scope');
	bfcacheState.dispatch('pageshow', { persisted: true });
	bfcacheState.dispatch('pageshow', { persisted: true });
	assert.equal(bfcacheState.reloads(), 1,
		'a BFCache restoration must rebuild the LuCI view exactly once');
	assert.equal(bfcacheScope.active(), false,
		'a BFCache restoration must not reactivate old promises or DOM updates');

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
	assert.equal(state.observedMutations(), 1,
		'marking an apply must watch its modal lifecycle');
	assert.equal(state.operation.applyPending(), true,
		'the marker must survive the synchronous gap before the modal appears');
	state.bodyClasses.add('modal-overlay-active');
	assert.equal(state.operation.applyPending(), true,
		'the marker must remain active while the LuCI apply modal is visible');
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
	assert.equal(state.operation.applyPending(), false,
		'closing or cancelling the observed apply modal must clear the retry marker immediately');
	assert.equal(state.observedMutations(), 0,
		'clearing the retry marker must disconnect its modal observer');
	assert.equal((state.listeners.get('uci-applied') ?? []).length, 0,
		'clearing the retry marker must remove its apply event listener');
	assert.equal((state.listeners.get('uci-reverted') ?? []).length, 0,
		'clearing the retry marker must remove its revert event listener');
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
	assert.equal(state.operation.applyPending(), false);

	state.operation.markApplyPending();
	state.bodyClasses.add('modal-overlay-active');
	state.dispatch('uci-applied');
	assert.equal(state.operation.applyPending(), false,
		'a successful checked apply must clear its marker immediately');
	assert.equal(state.observedMutations(), 0);
	state.bodyClasses.delete('modal-overlay-active');

	state.operation.markApplyPending();
	state.bodyClasses.add('modal-overlay-active');
	state.dispatch('uci-reverted');
	assert.equal(state.operation.applyPending(), false,
		'a reverted checked apply must clear its marker immediately');
	assert.equal(state.observedMutations(), 0);
	state.bodyClasses.delete('modal-overlay-active');

	state.operation.markApplyPending();
	state.operation._applyPendingUntil = Date.now() - 1;
	state.storage.set('luci.adguardhome.applyPendingUntil', String(Date.now() - 1));
	assert.equal(state.operation.applyPending(), false,
		'an expired marker must clear its observer and navigation guard');
	assert.equal(state.observedMutations(), 0);

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

	const sharedStorage = new Map();
	const origin = loadOperation(sharedStorage);
	const originScope = origin.operation.createPageScope();
	originScope.attach({ isConnected: true });
	origin.operation.markApplyPending();
	origin.bodyClasses.add('modal-overlay-active');
	origin.dispatch('pagehide', { persisted: true });
	assert.equal(origin.operation.applyPending(), true,
		'leaving during an active apply must retain the cross-document retry marker');

	const destination = loadOperation(sharedStorage);
	const destinationScope = destination.operation.createPageScope();
	destinationScope.attach({ isConnected: true });
	assert.equal(destination.operation.applyPending(), true,
		'a YAML or log page must inherit an in-progress apply marker');
	let destinationAttempts = 0;
	const destinationResult = await destination.operation.requestDuringApply(async () => {
		destinationAttempts++;
		if (destinationAttempts === 1) {
			const error = new Error('XHR request timed out');
			error.name = 'RequestError';
			throw error;
		}
		return 'loaded';
	}, destinationScope);
	assert.equal(destinationResult, 'loaded');
	assert.equal(destinationAttempts, 2,
		'the destination tab must retry a transient initial RPC failure during apply');

	const completedStorage = new Map();
	const completedOrigin = loadOperation(completedStorage);
	completedOrigin.operation.markApplyPending();
	completedOrigin.bodyClasses.add('modal-overlay-active');
	completedOrigin.bodyClasses.delete('modal-overlay-active');
	const completedDestination = loadOperation(completedStorage);
	assert.equal(completedDestination.operation.applyPending(), false,
		'a cancelled or failed apply must not leak retry state into a later tab');

	const applyEvents = [];
	const overviewOperation = { isPageActive: () => true };
	const overviewUi = {};
	const overviewView = loadOverview(overviewOperation, overviewUi);
	let resolveSave;
	const savePromise = new Promise(resolve => { resolveSave = resolve; });
	const overviewContext = { handleSave() {
		applyEvents.push('save');
		return savePromise;
	} };
	const applyPromise = overviewView.handleSaveApply.call(overviewContext, null, '0');
	assert.deepEqual(applyEvents, [ 'save' ],
		'Save & Apply must delegate to the single RPC settings transaction');
	resolveSave('settings-result');
	assert.equal(await applyPromise, 'settings-result');
	assert.deepEqual(applyEvents, [ 'save' ],
		'Save & Apply must not invoke a second global LuCI apply path');

	for (const kind of [
		'request-transport',
		'status-transport',
		'indeterminate',
		'reload-failure',
		'bad-token',
	]) {
		const result = await runSettingsSubmissionScenario(kind);
		assert.equal(result.context.settingsRevision, null,
			`${kind} must invalidate the stale settings revision`);
		assert.equal(result.context.committedSettings, null,
			`${kind} must discard the stale committed snapshot`);
		assert.equal(result.map.readonly, true,
			`${kind} must lock the visible form until a full reload`);
		assert.equal(result.resetCalls, 1,
			`${kind} must redraw the settings form in read-only mode`);
		assert.equal(result.failures.length, 1,
			`${kind} must show one explicit settings failure`);
		assert.equal(result.successes, 0);

		await result.view.submitSettings.call(result.context);
		assert.equal(result.setCalls, 1,
			`${kind} must reject another submission locally after invalidating CAS state`);
	}

	const statusTransport = await runSettingsSubmissionScenario('status-transport');
	assert.equal(statusTransport.statusCalls, 10,
		'settings status transport failures must be bounded before the form is locked');

	const successfulSettings = await runSettingsSubmissionScenario('success');
	assert.equal(successfulSettings.failures.length, 0);
	assert.equal(successfulSettings.successes, 1);
	assert.equal(successfulSettings.resetCalls, 1,
		'a successful transaction must redraw the authoritative settings once');
	assert.equal(successfulSettings.context.settingsRevision, 'c'.repeat(64));
	assert.equal(successfulSettings.context.committedSettings.workDir, '/mnt/storage/AdGuardHome');
	assert.deepEqual(successfulSettings.setArguments, [
		true,
		'/etc/AdGuardHome',
		false,
		'dnsmasq-upstream',
		false,
		60,
		'a'.repeat(64),
	], 'the frontend settings update must not submit the derived config_file');
	assert.equal(successfulSettings.values.get('config.work_dir'), '/mnt/storage/AdGuardHome',
		'the visible JSON model must contain the authoritative work directory');
	assert.equal(successfulSettings.values.get('luci.memory_writeback_interval'), '77',
		'the visible JSON model must contain the authoritative write-back interval');

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
		/handleSaveApply\(\)\s*\{\s*return this\.handleSave\(\);\s*\}/,
		'Save & Apply must use only the RPC-backed save transaction',
	);
	assert.doesNotMatch(overview, /operation\.markApplyPending\(|ui\.changes\.apply\(/,
		'the settings page must not enter LuCI global UCI apply');
	assert.match(
		overview,
		/result\?\.indeterminate === true[\s\S]*?throw uncertainSettingsUpdateError[\s\S]*?error\?\.settingsUpdateUncertain === true[\s\S]*?this\.settingsRevision = null;[\s\S]*?this\.committedSettings = null;[\s\S]*?map\.readonly = true;[\s\S]*?await map\.reset\(\);/,
		'an indeterminate settings update must invalidate the stale CAS state and lock the form until reload',
	);
	assert.match(
		overview,
		/throw uncertainSettingsUpdateError\(lastError[\s\S]*?The settings update is still running/,
		'a lost settings status response must also invalidate the form because the job may still commit',
	);
	assert.match(
		overview,
		/response\?\.unchanged !== true[\s\S]*?response\.token[\s\S]*?throw uncertainSettingsUpdateError\([\s\S]*?did not return a valid status token/,
		'an accepted settings job without a valid token must be treated as an uncertain outcome',
	);
	assert.match(
		overview,
		/committed = await getSettings\(scope\);\s*updateSettingsMap\(map, committed\);\s*await map\.reset\(\);[\s\S]*?this\.settingsRevision = committed\.revision;/,
		'the visible settings form must be reset to the authoritative snapshot before adopting its revision',
	);
	assert.match(
		overview,
		/if \(typeof this\.settingsRevision !== 'string' \|\|[\s\S]*?!\/\^\[0-9a-f\]\{64\}\$\/\.test\(this\.settingsRevision\)\)[\s\S]*?Reload this page before applying settings again/,
		'a settings form whose reconciliation failed must reject another submission locally',
	);
	assert.doesNotMatch(overview, /require uci|uci\.load\(|new form\.Map\(/,
		'the settings page must not read or write UCI directly');
	assert.match(overview, /new form\.JSONMap\(/,
		'the settings page must render from an RPC-owned local JSON model');
	assert.match(overview, /map\.readonly = !L\.hasViewPermission\(\);/,
		'the local JSON settings model must honor the menu write permission');
	assert.match(
		overview,
		/poll\.remove\(this\.statusPollCallback\)[\s\S]*?this\.statusPollCallback = statusPollCallback;[\s\S]*?poll\.add\(statusPollCallback, POLL_INTERVAL\);/,
		'the settings view must replace its previous status poll callback',
	);
	assert.match(
		overview,
		/if \(!operation\.isPageActive\(pageScope\)\) \{\s*removeStatusPoll\(\);\s*return;\s*\}/,
		'an inactive settings page must unregister its status poll callback',
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
