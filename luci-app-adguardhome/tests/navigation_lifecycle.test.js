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
	const onceListeners = new Map();
	const rendered = [];
	let reloads = 0;
	let hidden = 0;

	const fakeDocument = {
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
		location: {
			reload() { reloads++; },
		},
	};
	const fakeUi = {
		showModal(_title, child) { rendered.push(child); },
		hideModal() { hidden++; },
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
		listeners,
		rendered,
		dispatch(type, event = {}) {
			for (const listener of [ ...(listeners.get(type) ?? []) ]) {
				if (onceListeners.get(type)?.has(listener))
					fakeDocument.removeEventListener(type, listener);
				listener(event);
			}
		},
		reloads: () => reloads,
		hidden: () => hidden,
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
	let loadCalls = 0;
	let resetCalls = 0;
	let setArguments = null;
	let context = null;
	const optionCache = new Map(values);
	const visibleValues = new Map(optionCache);

	const operation = Object.assign(loadOperation().operation, {
		isPageActive: () => true,
		pageInactiveError: () => Object.assign(new Error('inactive'), { pageInactive: true }),
		isPageInactiveError: error => error?.pageInactive === true,
		start: () => ({}),
		failure: message => failures.push(String(message)),
		success: () => { successes++; },
		requestActive: request => request(),
	});
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
		async load() {
			loadCalls++;
			optionCache.clear();
			for (const [ key, value ] of values)
				optionCache.set(key, value);
		},
		async reset() {
			resetCalls++;
			visibleValues.clear();
			for (const [ key, value ] of optionCache)
				visibleValues.set(key, value);
			if (kind === 'success') {
				assert.equal(context.committedSettings?.revision, oldRevision,
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
		committedSettings: { revision: oldRevision, memoryWritebackInterval: 60 },
	};

	await view.submitSettings.call(context);
	return {
		context,
		failures,
		map,
		loadCalls,
		resetCalls,
		setCalls,
		setArguments,
		statusCalls,
		successes,
		values,
		visibleValues,
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
	assert.equal(state.hidden(), 1,
		'a new page scope must dismiss the old pending spinner even without a countdown timer');
	await new Promise(resolve => setTimeout(resolve, 5));
	state.operation.success('late result from old view', oldTicket);
	assert.equal(state.rendered.length, afterOldStart,
		'creating a new scope must cancel the old timer and reject its late result');

	let attempts = 0;
	await assert.rejects(state.operation.requestActive(async () => {
		attempts++;
		throw new Error('XHR request timed out');
	}, currentScope), /XHR request timed out/);
	assert.equal(attempts, 1,
		'ordinary requests must not be replayed after a transport failure');

	const jobMessages = {
		unknown: translated('unknown job state'),
		unavailable: translated('job unavailable: %s'),
		pending: translated('job still pending'),
	};
	const jobEvents = [];
	let jobReads = 0;
	const completedJob = await state.operation.waitForJob(async (token, consume) => {
		assert.equal(token, 'job-token');
		jobEvents.push(consume ? 'consume' : 'read');
		if (consume)
			throw new Error('cleanup unavailable');
		jobReads++;
		if (jobReads === 1)
			return { state: 'pending' };
		if (jobReads === 2)
			throw new Error('temporary status failure');
		if (jobReads === 3)
			return { state: 'running' };
		return { state: 'done', ok: true };
	}, 'job-token', currentScope, jobMessages);
	assert.equal(completedJob.ok, true);
	assert.deepEqual(jobEvents, [ 'read', 'read', 'read', 'read', 'consume' ],
		'terminal results must be consumed once, with best-effort cleanup');

	for (const result of [ null, {}, { state: 'invalid' } ]) {
		await assert.rejects(
			state.operation.waitForJob(async () => result, 'token', currentScope, jobMessages),
			/unknown job state/,
		);
	}
	await assert.rejects(
		state.operation.waitForJob(async () => ({ error: 'expired job' }), 'token', currentScope, jobMessages),
		/expired job/,
	);

	let pendingReads = 0;
	await assert.rejects(state.operation.waitForJob(async () => {
		pendingReads++;
		return { state: 'running' };
	}, 'token', currentScope, jobMessages), /job still pending/);
	assert.equal(pendingReads, 360, 'job polling must have a bounded total duration');

	let resettingReads = 0;
	const resetErrorCount = await state.operation.waitForJob(async (_token, consume) => {
		if (consume)
			return {};
		resettingReads++;
		if (resettingReads === 10)
			return { state: 'running' };
		if (resettingReads === 20)
			return { state: 'done', ok: false, error: 'rejected' };
		throw new Error('temporary status failure');
	}, 'token', currentScope, jobMessages);
	assert.equal(resetErrorCount.ok, false,
		'a terminal failure belongs to the caller, not the transport error path');
	assert.equal(resettingReads, 20,
		'a successful status read must reset the consecutive failure counter');

	let permanentAttempts = 0;
	await assert.rejects(
		state.operation.requestActive(async () => {
			permanentAttempts++;
			const error = new Error('invalid YAML');
			error.name = 'RPCError';
			throw error;
		}, currentScope),
		/invalid YAML/,
	);
	assert.equal(permanentAttempts, 1,
		'a real method failure must remain visible without retry masking');

	const pending = state.operation.requestActive(
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

	let inactiveCalls = 0;
	await assert.rejects(state.operation.requestActive(async () => {
		inactiveCalls++;
	}, currentScope), error => error?.pageInactive === true);
	assert.equal(inactiveCalls, 0,
		'an inactive page must not start another request');

	const jobState = loadOperation();
	const jobScope = jobState.operation.createPageScope();
	const jobRoot = { isConnected: true };
	jobScope.attach(jobRoot);
	let consumeCalls = 0;
	await assert.rejects(jobState.operation.waitForJob(async (_token, consume) => {
		if (consume)
			consumeCalls++;
		jobRoot.isConnected = false;
		return { state: 'done', ok: true };
	}, 'token', jobScope, jobMessages), error => error?.pageInactive === true);
	assert.equal(consumeCalls, 0,
		'a terminal response owned by an inactive page must not continue its load chain');

	const operationSource = fs.readFileSync(operationPath, 'utf8');
	assert.doesNotMatch(operationSource,
		/markApplyPending|sessionStorage|MutationObserver|uci-applied|uci-reverted|requestDuringApply/,
		'the RPC-only frontend must not retain the old global UCI apply mechanism');

	const applyEvents = [];
	const overviewOperation = { isPageActive: () => true };
	const overviewUi = {};
	const overviewView = loadOverview(overviewOperation, overviewUi);
	let resolveSave;
	const savePromise = new Promise(resolve => { resolveSave = resolve; });
	const overviewContext = { settingsSubmission: null, submitSettings() {
		applyEvents.push('apply');
		return savePromise;
	} };
	const applyPromise = overviewView.handleSaveApply.call(overviewContext, null, '0');
	assert.deepEqual(applyEvents, [ 'apply' ],
		'Save & Apply must start the single RPC settings transaction');
	resolveSave('settings-result');
	assert.equal(await applyPromise, 'settings-result');
	assert.deepEqual(applyEvents, [ 'apply' ],
		'Save & Apply must not invoke a second global LuCI apply path');
	assert.equal(overviewView.handleSave, null,
		'the standalone Save action must remain hidden and must not commit settings');

	for (const kind of [
		'request-transport',
		'status-transport',
		'indeterminate',
		'reload-failure',
		'bad-token',
	]) {
		const result = await runSettingsSubmissionScenario(kind);
		assert.equal(result.context.committedSettings, null,
			`${kind} must discard the stale committed snapshot`);
		assert.equal(result.map.readonly, true,
			`${kind} must lock the visible form until a full reload`);
		assert.equal(result.resetCalls, 1,
			`${kind} must redraw the settings form in read-only mode`);
		assert.equal(result.loadCalls, 0,
			`${kind} must not adopt an unconfirmed candidate into option caches`);
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
	assert.equal(successfulSettings.loadCalls, 1,
		'a successful transaction must reload JSONMap option caches once');
	assert.equal(successfulSettings.context.committedSettings?.revision, 'c'.repeat(64));
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
	assert.equal(successfulSettings.visibleValues.get('config.enabled'), '0',
		'the redrawn enabled flag must show the authoritative value');
	assert.equal(successfulSettings.visibleValues.get('config.work_dir'), '/mnt/storage/AdGuardHome',
		'the redrawn work directory must show the authoritative value');
	assert.equal(successfulSettings.visibleValues.get('config.verbose'), '1',
		'the redrawn verbose flag must show the authoritative value');
	assert.equal(successfulSettings.visibleValues.get('luci.redirect'), 'redirect',
		'the redrawn DNS mode must show the authoritative value');
	assert.equal(successfulSettings.visibleValues.get('luci.run_from_memory'), '1',
		'the redrawn memory checkbox must show the authoritative value without a browser refresh');
	assert.equal(successfulSettings.visibleValues.get('luci.memory_writeback_interval'), '77',
		'dependent fields must redraw from the authoritative option cache');

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
		if (name === 'log')
			continue;
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
		/handleSave:\s*null,[\s\S]*?handleSaveApply\(\)\s*\{[\s\S]*?this\.submitSettings\(\)/,
		'only Save & Apply may start the RPC-backed settings transaction',
	);
	assert.doesNotMatch(overview, /return this\.handleSave\(\)/,
		'Save & Apply must not delegate to a standalone Save action');
	assert.doesNotMatch(overview, /operation\.markApplyPending\(|ui\.changes\.apply\(/,
		'the settings page must not enter LuCI global UCI apply');
	assert.match(
		overview,
		/result\?\.indeterminate === true[\s\S]*?throw uncertainSettingsUpdateError[\s\S]*?error\?\.settingsUpdateUncertain === true[\s\S]*?this\.committedSettings = null;[\s\S]*?map\.readonly = true;[\s\S]*?await map\.reset\(\);/,
		'an indeterminate settings update must invalidate the stale CAS state and lock the form until reload',
	);
	assert.match(
		overview,
		/operation\.waitForJob\(callGetSettingsUpdate,[\s\S]*?uncertainSettingsUpdateError\);/,
		'lost settings job status must preserve the uncertain update error semantics',
	);
	assert.match(
		overview,
		/response\.token[\s\S]*?throw uncertainSettingsUpdateError\([\s\S]*?did not return a valid status token/,
		'every accepted settings apply must return a valid coordinator status token',
	);
	assert.match(
		overview,
		/committed = await getSettings\(scope\);\s*await reloadSettingsMap\(map, committed\);[\s\S]*?this\.committedSettings = committed;/,
		'the visible settings form must be reset to the authoritative snapshot before adopting its revision',
	);
	assert.match(
		overview,
		/async function reloadSettingsMap\(map, settings\)\s*\{\s*updateSettingsMap\(map, settings\);[\s\S]*?await map\.load\(\);\s*return map\.reset\(\);\s*\}/,
		'the settings redraw must reload JSONMap option caches before resetting the form',
	);
	assert.match(
		overview,
		/const revision = this\.committedSettings\?\.revision;[\s\S]*?typeof revision !== 'string'[\s\S]*?Reload this page before applying settings again/,
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

	console.log('navigation lifecycle, shared job polling and settings reconciliation tests passed');
}

main().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
