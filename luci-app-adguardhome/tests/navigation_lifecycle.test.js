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
	const timerDelays = [];
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
		setTimeout(callback, delay) { timerDelays.push(delay); return setTimeout(callback, 0); },
		clearTimeout(id) { clearTimeout(id); },
		location: {
			reload() { reloads++; },
		},
	};
	const fakeUi = {
		showModal(_title, child) { rendered.push(Array.isArray(child) ? child[0] : child); },
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
		timerDelays,
		document: fakeDocument,
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

function loadView(name, operation, ui, rpcHandlers = {}) {
	const viewPath = path.join(
		packageRoot,
		`htdocs/luci-static/resources/view/adguardhome/${name}.js`
	);
	const source = fs.readFileSync(viewPath, 'utf8');
	const animationFrames = new Map();
	const windowEvents = new EventTarget();
	const beforeUnloadListeners = new Set();
	let nextAnimationFrame = 1;
	const rpc = {
		declare: specification => async (...args) => {
			const handler = rpcHandlers[specification.method];
			return typeof handler === 'function' ? handler(...args) : {};
		},
	};
	const view = { extend: definition => definition };
	const sandbox = {
		E: (tag, attrs = {}, children = []) => {
			const childList = Array.isArray(children) ? children : [ children ];
			const text = childList.map(child => String(child?.textContent ?? child ?? '')).join('');
			const classes = new Set();
			return { tag, attrs, children: childList, textContent: text, value: text,
				classList: { toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); },
					contains: name => classes.has(name) },
				innerHTML: '', style: { setProperty(name, value) { this[name] = value; } },
				scrollLeft: 0, scrollTop: 0, selectionStart: 0,
				hidden: attrs.hidden === true, readOnly: attrs.readonly != null, disabled: attrs.disabled != null };
		},
		L: { env: {}, hasViewPermission: () => true, resource: value => value },
		URL,
		_: translated,
		console,
		window: {
			location: { href: 'https://router.example/cgi-bin/luci/admin/services/adguardhome' },
			addEventListener(type, callback, options) {
				if (type === 'beforeunload') beforeUnloadListeners.add(callback);
				windowEvents.addEventListener(type, callback, options);
			},
			removeEventListener(type, callback) {
				if (type === 'beforeunload') beforeUnloadListeners.delete(callback);
				windowEvents.removeEventListener(type, callback);
			},
			setTimeout(callback) { return setTimeout(callback, 0); },
			requestAnimationFrame(callback) {
				const id = nextAnimationFrame++;
				animationFrames.set(id, callback);
				return id;
			},
			cancelAnimationFrame(id) { animationFrames.delete(id); },
		},
	};
	vm.createContext(sandbox);
	const loadedView = vm.runInContext(
		'(function(bcrypt, operation, dom, form, poll, rpc, uci, ui, view, window, L, E, _, URL, console) {\n' +
			source +
			'\n}).call(globalThis, {}, operation, {}, {}, {}, rpc, {}, ui, view, window, L, E, _, URL, console)',
		Object.assign(sandbox, { operation, rpc, ui, view }),
		{ filename: viewPath },
	);
	loadedView.beforeUnloadListenerCount = () => beforeUnloadListeners.size;
	loadedView.dispatchWindowEvent = event => windowEvents.dispatchEvent(event);
	loadedView.pendingAnimationFrames = () => animationFrames.size;
	loadedView.flushAnimationFrames = () => {
		for (const [ id, callback ] of [ ...animationFrames ]) {
			animationFrames.delete(id);
			callback();
		}
	};
	return loadedView;
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
	let refreshCalls = 0;
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
	const view = loadView('overview', operation, {}, rpcHandlers);
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
	context = Object.assign(Object.create(view), {
		pageScope: {},
		settingsMap: map,
		committedSettings: { revision: oldRevision, memoryWritebackInterval: 60 },
		submitSettings: () => view.submitSettings.call(context),
		async statusPollCallback() {
			refreshCalls++;
			assert.equal(context.settingsSubmission, null);
			assert.equal(successes + failures.length, 1,
				'the original settings outcome must be reported before the extra status refresh');
			if (kind === 'success') {
				assert.equal(context.committedSettings.revision, currentRevision);
				assert.equal(loadCalls, 1);
				assert.equal(resetCalls, 1);
			}
		},
	});

	await view.handleSaveApply.call(context);
	assert.equal(refreshCalls, 1, 'success and failure must each trigger only one post-apply status refresh');
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

async function testYamlTemplateReset() {
	for (const accepted of [ true, false ]) {
		const state = loadOperation();
		const scope = state.operation.createPageScope();
		const oldHash = 'a'.repeat(64), draft = '# unsaved draft\n', template = 'dns:\n  port: 53335\n';
		const calls = [];
		const view = loadView('yaml', state.operation, {}, {
			async reset_yaml(hash) {
				calls.push([ 'template', hash ]);
				return accepted ? { content: template } : { error: 'YAML changed since the page was loaded' };
			},
			async set_yaml(content, hash) {
				calls.push([ 'save', content, hash ]);
				return { error: 'YAML changed since the page was loaded' };
			},
		});
		Object.assign(view, {
			pageScope: scope, yamlHash: oldHash, yamlEditor: { value: draft },
			yamlLineNumbers: { style: {} }, yamlHighlight: { children: [], style: {} },
			yamlEditorFrame: { style: { setProperty() {} }, classList: { toggle() {} } }, highlightNotice: {},
			loadedYaml: '# active YAML\n', editorNotice: {}, draftStatus: {},
			pathValue: {}, reloadButton: {}, saveButton: {}, resetButton: {},
		});
		await view.resetYaml(true);
		assert.deepEqual(calls, [[ 'template', oldHash ]], 'loading the template must not save, apply or poll a job');
		assert.equal(view.yamlEditor.value, accepted ? template : draft);
		assert.equal(view.yamlHash, oldHash, 'a template response without SHA must retain the active file revision');
		assert.equal(view.yamlEditor.readOnly, false);
		if (accepted)
			assert.equal(view.draftStatus.hidden, false, 'loaded template must be marked unsaved');
		if (accepted) {
			view.yamlEditor.value += '# edited before save\n';
			await view.saveYaml();
			assert.deepEqual(calls[1], [ 'save', view.yamlEditor.value, oldHash ],
				'saving an edited template must still compare against the originally loaded active YAML');
			assert.equal(view.yamlEditor.value, template + '# edited before save\n', 'a CAS rejection must retain the edited template');
		}
		assert.match(state.rendered.at(-1).text, /YAML changed since the page was loaded/);
		state.operation._clearTimer();
	}
}

async function testYamlSubmissions() {
	for (const kind of [ 'success', 'cas-rejected', 'response-lost', 'bad-token', 'reload-failure', 'leave-request', 'leave-status', 'leave-reload' ]) {
		const state = loadOperation();
		const scope = state.operation.createPageScope();
		const oldHash = 'a'.repeat(64), newHash = 'b'.repeat(64), token = 'c'.repeat(32);
		const draft = 'dns:\r\n  port: 5354\r\n';
		const committed = 'dns:\n  port: 5354\n';
		let accepted = false, setCalls = 0, reads = 0;
		const polls = [];
		const view = loadView('yaml', state.operation, {}, {
			async set_yaml(content, hash) {
				setCalls++;
				assert.equal(content, committed, 'normalize editor newlines before submission');
				assert.equal(hash, oldHash, 'submit the loaded file revision, not the candidate hash');
				if (kind === 'cas-rejected')
					return { error: 'YAML changed after page load' };
				accepted = true;
				if (kind === 'leave-request')
					state.dispatch('pagehide');
				if (kind === 'response-lost')
					throw new Error('accepted request response was lost');
				return { accepted: true, token: kind === 'bad-token' ? 'invalid' : token };
			},
			async get_yaml_update(receivedToken, consume) {
				assert.equal(receivedToken, token);
				polls.push(consume);
				if (kind === 'leave-status')
					state.dispatch('pagehide');
				return { state: 'done', ok: true, sha256: newHash };
			},
			async get_yaml() {
				reads++;
				if (kind === 'reload-failure')
					throw new Error('post-save read failed');
				if (kind === 'leave-reload')
					state.dispatch('pagehide');
				return { content: committed, sha256: newHash, path: '/etc/AdGuardHome/AdGuardHome.yaml' };
			},
		});
		Object.assign(view, {
			pageScope: scope, yamlHash: oldHash, yamlEditor: { value: draft },
			yamlLineNumbers: { style: {} }, yamlHighlight: { children: [], style: {} },
			yamlEditorFrame: { style: { setProperty() {} }, classList: { toggle() {} } }, highlightNotice: {},
			loadedYaml: '# active YAML\n', editorNotice: {}, draftStatus: {},
			pathValue: {}, reloadButton: {}, saveButton: {}, resetButton: {},
		});
		await view.saveYaml();
		assert.equal(setCalls, 1, `${kind}: never replay a mutation automatically`);
		assert.equal(accepted, kind !== 'cas-rejected');
		if (kind === 'success') {
			assert.equal(view.yamlEditor.value, committed);
			assert.equal(view.yamlHash, newHash);
			assert.equal(view.pathValue.textContent, '/etc/AdGuardHome/AdGuardHome.yaml');
			assert.equal(reads, 1, 'reload the authoritative YAML after a confirmed save');
			assert.deepEqual(polls, [ false, true ], 'read and consume the completed job once');
			assert.equal(view.saveButton.disabled, false);
			assert.equal(view.yamlEditor.readOnly, false);
			assert.equal(state.rendered.at(-1).text, 'Configuration changes applied.');
		} else if (kind === 'reload-failure' || kind === 'leave-reload') {
			assert.equal(view.yamlEditor.value, draft, 'failed post-save reload preserves the draft');
			assert.equal(view.yamlHash, '');
			assert.equal(reads, 1);
			assert.deepEqual(polls, [ false, true ]);
			if (kind === 'leave-reload') {
				assert.equal(state.rendered.length, 1, 'post-save reload must not report on an obsolete page');
			} else {
				assert.equal(view.yamlEditor.readOnly, true);
				assert.equal(view.saveButton.disabled, true);
				assert.equal(view.reloadButton.disabled, false);
				assert.equal(view.editorNotice.hidden, false);
				assert.match(view.editorNotice.textContent, /post-save read failed.*Use Reload from disk/);
				assert.match(state.rendered.at(-1).text, /was saved and applied, but the editor could not reload it/);
				assert.equal(state.operation._timer, null, 'a post-save reload error must await manual dismissal');
			}
		} else {
			assert.equal(view.yamlEditor.value, draft, `${kind}: preserve the editor draft`);
			assert.equal(reads, 0, `${kind}: do not overwrite the draft with an unconfirmed reload`);
			assert.deepEqual(polls, kind === 'leave-status' ? [ false ] : []);
			if (kind.startsWith('leave-')) {
				assert.equal(state.rendered.length, 1, 'late replies must not display results on another page');
				assert.equal(view.yamlHash, oldHash, 'an obsolete continuation must not mutate editor state');
			} else if (kind === 'cas-rejected') {
				assert.match(state.rendered.at(-1).text, /YAML changed after page load/);
				assert.equal(view.yamlHash, oldHash);
				assert.equal(view.yamlEditor.readOnly, false);
				assert.equal(view.saveButton.disabled, false);
			} else {
				assert.match(state.rendered.at(-1).text, /outcome is unknown.*Reload the page/);
				assert.equal(view.yamlHash, '', `${kind}: invalidate the uncertain revision`);
				assert.equal(view.yamlEditor.readOnly, true);
				assert.equal(view.saveButton.disabled, true);
				assert.equal(view.resetButton.disabled, true);
				assert.equal(view.reloadButton.disabled, false, 'allow explicit recovery from disk');
				assert.equal(view.editorNotice.hidden, false);
				assert.match(view.editorNotice.textContent, /outcome is unknown.*Use Reload from disk/);
				await view.saveYaml();
				assert.equal(setCalls, 1, 'require a reload before another uncertain submission');
				await view.handleReload(true);
				assert.equal(view.yamlHash, newHash, 'an explicit reload adopts the authoritative file revision');
				assert.equal(view.yamlEditor.value, committed);
				assert.equal(view.saveButton.disabled, false);
			}
		}
		state.operation._clearTimer();
	}
}

async function testMemoryWriteback() {
	for (const kind of [ 'success', 'reused', 'rejected', 'failed', 'bad-token', 'request-lost',
		'status-lost', 'indeterminate', 'inactive-request', 'inactive-status' ]) {
		const state = loadOperation();
		const scope = state.operation.createPageScope();
		const revision = 'a'.repeat(64), token = 'b'.repeat(32);
		const calls = [];
		let releaseRequest, refreshes = 0, settingsSubmits = 0;
		const requestBarrier = new Promise(resolve => { releaseRequest = resolve; });
		const view = loadView('overview', state.operation, {}, {
			async memory_writeback(...args) {
				calls.push([ 'writeback', ...args ]);
				await requestBarrier;
				if (kind === 'request-lost') throw new Error('request timed out');
				if (kind === 'inactive-request') state.dispatch('pagehide');
				if (kind === 'rejected') return { error: 'settings revision changed' };
				return { accepted: true, token: kind === 'bad-token' ? '' : token, reused: kind === 'reused' };
			},
			async get_memory_writeback(receivedToken, consume) {
				assert.equal(receivedToken, token);
				calls.push([ 'status', consume ]);
				if (kind === 'status-lost') throw new Error('status unavailable');
				if (kind === 'inactive-status') state.dispatch('pagehide');
				return { state: 'done', ok: ![ 'failed', 'indeterminate' ].includes(kind),
					indeterminate: kind === 'indeterminate', error: 'write-back failed' };
			},
		});
		const draft = { workDir: '/mnt/unsaved-workdir', interval: 99 };
		const committed = { revision };
		Object.assign(view, {
			pageScope: scope, memoryWritebackAvailable: true, memoryWritebackButton: {},
			committedSettings: committed,
			settingsMap: { draft, reset() { assert.fail('write-back must not reset form drafts'); },
				parse() { assert.fail('write-back must not parse unsaved settings'); } },
			submitSettings() { settingsSubmits++; return Promise.resolve(); },
			async statusPollCallback() {
				assert.equal(view.memoryWritebackBusy, false);
				refreshes++;
			},
		});
		const writeback = view.handleMemoryWriteback();
		assert.equal(view.memoryWritebackButton.disabled, true);
		assert.equal(state.rendered.at(-1).text, 'Writing memory data back…');
		await view.handleMemoryWriteback();
		await view.handleSaveApply();
		assert.deepEqual(calls, [ [ 'writeback', revision ] ],
			'repeated clicks must not submit again, and only the committed revision may be sent');
		assert.equal(settingsSubmits, 0, 'Apply must not overlap a running write-back');
		releaseRequest();
		await writeback;
		assert.equal(view.committedSettings, committed);
		assert.equal(view.settingsMap.draft, draft);
		assert.deepEqual(draft, { workDir: '/mnt/unsaved-workdir', interval: 99 });
		if (kind.startsWith('inactive')) {
			assert.equal(refreshes, 0);
			assert.equal(state.rendered.length, 1, 'obsolete jobs must not show results or refresh the new view');
		} else {
			assert.equal(refreshes, 1, 'completion must refresh only the overview once');
			const uncertain = [ 'bad-token', 'request-lost', 'status-lost', 'indeterminate' ].includes(kind);
			assert.equal(view.memoryWritebackButton.disabled, uncertain);
			if (kind === 'success' || kind === 'reused') {
				assert.equal(state.rendered.at(-1).text, 'Memory data written back.');
				assert.deepEqual(calls, [ [ 'writeback', revision ], [ 'status', false ], [ 'status', true ] ]);
			} else {
				assert.match(state.rendered.at(-1).text, /Unable to write back memory data:/);
			}
			if (uncertain) {
				assert.match(state.rendered.at(-1).text, /Reload this page before trying again/);
				const beforeRetry = calls.length;
				await view.handleMemoryWriteback();
				await view.handleSaveApply();
				assert.equal(calls.length, beforeRetry, 'unknown outcomes must not allow a second write-back');
				assert.equal(settingsSubmits, 0, 'unknown jobs may still be running and must not overlap Apply');
			}
		}
		state.operation._clearTimer();
	}
}

async function testYamlEditing() {
	const state = loadOperation();
	const modals = [], notifications = [], calls = [];
	const active = 'dns:\n  port: 53335\n';
	const template = '# template\n' + active;
	let failRead = false;
	const ui = {
		createHandlerFn: (context, method) => (...args) => typeof method === 'function'
			? method.apply(context, args) : context[method](...args),
		showModal: (title, children) => modals.push({ title: String(title), children }),
		hideModal() {},
		addNotification: (...args) => notifications.push(args),
	};
	const view = loadView('yaml', state.operation, ui, {
		async get_yaml() {
			calls.push('read');
			if (failRead) throw new Error('disk read failed');
			return { content: active.replace(/\n/g, '\r\n'), sha256: 'a'.repeat(64), path: '/etc/AdGuardHome/AdGuardHome.yaml' };
		},
		async reset_yaml() { calls.push('template'); return { content: template }; },
		async set_yaml() { calls.push('save'); return { error: 'invalid YAML' }; },
	});
	const root = view.render(await view.load());
	assert.equal(root.attrs.class, 'adguardhome-view');
	assert.equal(root.children[0].attrs.href, 'adguardhome/style.css');
	assert.equal(view.yamlEditor.attrs.class, 'adguardhome-editor',
		'the YAML overlay must not inherit theme textarea backgrounds');
	assert.equal(view.yamlEditor.attrs.autocapitalize, 'none');
	assert.equal(view.yamlEditor.attrs.autocorrect, 'off');
	assert.equal(view.yamlEditorFrame.children.length, 3);
	assert.equal(view.yamlEditorFrame.children[0], view.yamlLineNumbers);
	assert.equal(view.yamlEditorFrame.children[1], view.yamlHighlight);
	assert.equal(view.yamlEditorFrame.children[2], view.yamlEditor,
		'the native textarea must share one editor frame with its line and highlight layers');
	assert.equal(view.yamlLineNumbers.attrs['aria-hidden'], 'true');
	assert.equal(view.yamlHighlight.attrs['aria-hidden'], 'true');
	assert.equal(view.yamlLineNumbers.textContent, '1\n2\n3');
	assert.match(view.yamlHighlight.innerHTML, /adguardhome-yaml-key[^>]*>dns</);
	assert.match(view.yamlHighlight.innerHTML, /adguardhome-yaml-number[^>]*>53335</);
	assert.equal(view.hasDraft(), false);
	assert.equal(view.beforeUnloadListenerCount(), 0, 'clean YAML must not register a leave warning');
	assert.equal(view.saveButton.disabled, false, 'unchanged YAML can still be applied');
	await view.handleReload();
	assert.equal(modals.length, 0, 'clean reload needs no confirmation');
	assert.deepEqual(calls, [ 'read', 'read' ]);
	let lineNumberWrites = 0;
	let lineNumberText = view.yamlLineNumbers.textContent;
	Object.defineProperty(view.yamlLineNumbers, 'textContent', {
		get: () => lineNumberText,
		set: value => { lineNumberWrites++; lineNumberText = value; },
	});
	view.yamlEditor.value = 'unsafe: <img src=x onerror=alert(1)>\nflag: false # note\n';
	view.yamlEditor.selectionStart = view.yamlEditor.value.indexOf('flag');
	view.yamlEditor.attrs.input();
	view.yamlEditor.attrs.input();
	view.yamlEditor.attrs.keyup();
	assert.equal(view.beforeUnloadListenerCount(), 1, 'the first edit must protect the draft before the next animation frame');
	const leaveWithDraft = new Event('beforeunload', { cancelable: true });
	view.dispatchWindowEvent(leaveWithDraft);
	assert.equal(leaveWithDraft.defaultPrevented, true, 'refreshing or leaving must request the native draft warning');
	assert.equal(view.pendingAnimationFrames(), 1,
		'multiple input events in one frame must schedule only one YAML redraw');
	assert.equal(view.activeYamlLine, 0,
		'keyup must leave the pending input redraw to calculate the new active line once');
	view.flushAnimationFrames();
	assert.equal(lineNumberWrites, 0,
		'editing without changing the line count must not rebuild line numbers');
	assert.equal(view.activeYamlLine, 1, 'the coalesced redraw must retain the cursor line');
	assert.doesNotMatch(view.yamlHighlight.innerHTML, /<img/i,
		'YAML highlighting must not turn editor text into HTML');
	assert.match(view.yamlHighlight.innerHTML, /&lt;img src=x onerror=alert\(1\)&gt;/);
	assert.match(view.yamlHighlight.innerHTML, /adguardhome-yaml-literal[^>]*>false</);
	assert.match(view.yamlHighlight.innerHTML, /adguardhome-yaml-comment[^>]*># note</);
	assert.equal((view.yamlHighlight.innerHTML.match(/adguardhome-yaml-line active/g) ?? []).length, 1);
	view.yamlEditor.scrollLeft = 13;
	view.yamlEditor.scrollTop = 27;
	view.yamlEditor.attrs.scroll();
	assert.equal(view.yamlLineNumbers.style.transform, 'translateY(-27px)');
	assert.equal(view.yamlHighlight.style.transform, 'translate(-13px, -27px)');
	const whitespace = ' \t'.repeat(32768);
	const highlightCases = [
		[ whitespace, whitespace ],
		[ whitespace + 'value', whitespace + '<span class="adguardhome-yaml-scalar">value</span>' ],
		[ whitespace + '# note', whitespace + '<span class="adguardhome-yaml-comment"># note</span>' ],
	];
	for (const separator of [ '\u2028', '\u2029' ]) {
		for (const prefix of [ '', 'key: ', '- ' ])
			highlightCases.push([
				`${prefix}before${separator}after &<>`,
				`${prefix}before${separator}after &amp;&lt;&gt;`,
			]);
		highlightCases.push([
			`"before${separator}after"`,
			`<span class="adguardhome-yaml-scalar">&quot;before${separator}after&quot;</span>`,
		]);
	}
	for (const [ line, highlighted ] of highlightCases) {
		const content = `${line}\nflag: false\n`;
		view.yamlEditor.value = content;
		view.yamlEditor.selectionStart = line.length + 1;
		view.yamlEditor.attrs.input();
		view.flushAnimationFrames();
		assert.equal(view.yamlEditor.value, content, 'highlighting must preserve the editor text');
		assert.equal(view.yamlLineNumbers.textContent, '1\n2\n3');
		assert.equal(view.activeYamlLine, 1, 'only newlines change the cursor line');
		assert.equal(view.yamlHighlight.innerHTML,
			`<span class="adguardhome-yaml-line">${highlighted}</span>` +
			'<span class="adguardhome-yaml-line active"><span class="adguardhome-yaml-key">flag</span>: ' +
			'<span class="adguardhome-yaml-literal">false</span></span>' +
			'<span class="adguardhome-yaml-line">&#8203;</span>');
	}
	view.yamlEditor.value = '# draft\n';
	view.yamlEditor.selectionStart = 0;
	view.yamlEditor.attrs.input();
	view.flushAnimationFrames();
	assert.equal(lineNumberWrites, 1, 'changing the line count must rebuild line numbers once');
	assert.equal(view.draftStatus.hidden, false);
	for (const content of [ '# ' + 'x'.repeat(128 * 1024),
		Array.from({ length: 18001 }, (_, i) => `  - ||ads${i}.example^`).join('\n') ]) {
		view.yamlEditor.value = content;
		view.yamlEditor.selectionStart = content.length;
		view.yamlEditor.scrollTop = 210;
		view.yamlEditor.scrollLeft = 27;
		view.yamlEditor.attrs.input();
		view.flushAnimationFrames();
		assert.equal(view.yamlPlainText, true, 'large content and large line counts must both use native text');
		assert.equal(view.yamlEditorFrame.classList.contains('adguardhome-yaml-plain'), true);
		assert.equal(view.highlightNotice.hidden, false);
		assert.equal(view.yamlHighlight.innerHTML, '', 'large files must not construct the syntax DOM');
		assert.equal(view.yamlEditor.value, content);
		assert.equal(view.yamlEditor.selectionStart, content.length, 'changing presentation must preserve the cursor');
		assert.equal(view.yamlEditor.scrollLeft, 27);
		assert.equal(view.yamlEditor.scrollTop, 210);
		assert.equal(view.yamlLineNumbers.style.transform, 'translateY(-210px)');
		assert.equal(view.yamlEditor.readOnly, false);
		assert.equal(view.saveButton.disabled, false, 'plain presentation must retain save and validation');
		assert.equal(view.hasDraft(), true);
		assert.equal(view.beforeUnloadListenerCount(), 1);
		const lineCount = content.split('\n').length;
		assert.equal(view.yamlLineNumbers.textContent.split('\n').at(-1), String(lineCount));
		assert.equal(view.yamlEditorFrame.style['--adguardhome-yaml-gutter'],
			`max(3rem, calc(${String(lineCount).length}ch + 1rem))`, 'all line number digits must fit the gutter');
		view.yamlEditor.selectionStart = 0;
		view.updateActiveYamlLine();
		assert.equal(view.activeYamlLine, 0, 'plain mode must not access nonexistent highlight children');
	}
	view.yamlEditor.value = '# draft\n';
	view.refreshYamlEditor();
	assert.equal(view.yamlPlainText, false, 'shrinking a draft restores syntax highlighting');
	assert.equal(view.yamlEditorFrame.classList.contains('adguardhome-yaml-plain'), false);
	assert.equal(view.highlightNotice.hidden, true);
	assert.match(view.yamlHighlight.innerHTML, /adguardhome-yaml-comment/);
	await view.handleReload();
	assert.equal(modals.at(-1).title, 'Discard unsaved changes?');
	assert.equal(calls.length, 2, 'showing confirmation must not read or overwrite a draft');
	modals.at(-1).children[1].children[0].attrs.click();
	assert.equal(view.yamlEditor.value, '# draft\n', 'Cancel preserves draft text');
	await modals.at(-1).children[1].children.at(-1).attrs.click();
	assert.equal(view.yamlEditor.value, active);
	assert.equal(view.draftStatus.hidden, true);
	assert.equal(view.beforeUnloadListenerCount(), 0, 'successful reload removes the leave warning');
	assert.equal(view.editorNotice.hidden, true);
	const modalCount = modals.length;
	await view.resetButton.attrs.click();
	assert.equal(modals.length, modalCount, 'loading a template is an ordinary editor action');
	assert.doesNotMatch(view.resetButton.attrs.class, /negative/);
	assert.equal(view.yamlEditor.value, template);
	assert.equal(view.draftStatus.hidden, false);
	assert.equal(view.beforeUnloadListenerCount(), 1, 'loading a template creates a protected draft');
	assert.equal(calls.filter(call => call === 'save').length, 0, 'template loading must not apply');
	view.yamlEditor.value += '# keep my draft\n';
	view.yamlEditor.attrs.input();
	const templateCalls = calls.filter(call => call === 'template').length;
	await view.resetButton.attrs.click();
	assert.equal(modals.at(-1).title, 'Discard unsaved changes?');
	assert.equal(calls.filter(call => call === 'template').length, templateCalls,
		'a dirty template load must wait for confirmation before issuing its RPC');
	modals.at(-1).children[1].children[0].attrs.click();
	assert.equal(view.yamlEditor.value, template + '# keep my draft\n', 'Cancel preserves the template draft');
	assert.equal(view.beforeUnloadListenerCount(), 1);
	await modals.at(-1).children[1].children.at(-1).attrs.click();
	assert.equal(view.yamlEditor.value, template);
	assert.equal(calls.filter(call => call === 'template').length, templateCalls + 1);
	failRead = true;
	await view.handleReload(true);
	assert.equal(view.yamlEditor.value, template, 'read failure preserves the editor draft');
	assert.equal(view.yamlEditor.readOnly, true);
	assert.equal(view.editorNotice.hidden, false);
	assert.match(view.editorNotice.textContent, /disk read failed.*Use Reload from disk/);
	assert.equal(view.reloadButton.disabled, false);
	assert.equal(view.saveButton.disabled, true);
	assert.equal(view.beforeUnloadListenerCount(), 1, 'a failed reload must keep protecting the retained draft');
	failRead = false;
	await view.handleReload(true);
	assert.equal(view.editorNotice.hidden, true);
	assert.equal(view.yamlEditor.readOnly, false);
	assert.equal(view.draftStatus.hidden, true);
	view.yamlEditor.value = '# temporary draft\n';
	view.yamlEditor.attrs.input();
	assert.equal(view.beforeUnloadListenerCount(), 1);
	view.yamlEditor.value = active;
	view.yamlEditor.attrs.input();
	assert.equal(view.beforeUnloadListenerCount(), 0, 'undoing all edits removes the leave warning immediately');
	const leaveClean = new Event('beforeunload', { cancelable: true });
	view.dispatchWindowEvent(leaveClean);
	assert.equal(leaveClean.defaultPrevented, false);
	failRead = true;
	view.render(await view.load());
	assert.equal(view.editorNotice.hidden, false, 'initial read errors need a persistent inline reason');
	assert.match(view.editorNotice.textContent, /disk read failed.*Use Reload from disk/);
	assert.equal(view.yamlEditor.readOnly, true);

	view.yamlEditor.value = '# obsolete input\n';
	view.yamlEditor.attrs.input();
	assert.equal(view.pendingAnimationFrames(), 1);
	const obsoleteHighlight = view.yamlHighlight.innerHTML;
	state.dispatch('pagehide');
	const leaveInactive = new Event('beforeunload', { cancelable: true });
	view.dispatchWindowEvent(leaveInactive);
	assert.equal(leaveInactive.defaultPrevented, false, 'an obsolete YAML page must not warn for another view');
	view.dispatchWindowEvent(new Event('pagehide'));
	assert.equal(view.beforeUnloadListenerCount(), 0, 'leaving the page removes its draft listener');
	view.flushAnimationFrames();
	assert.equal(view.yamlHighlight.innerHTML, obsoleteHighlight,
		'a queued editor redraw must not update an inactive page');
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
	const beforeJobTimers = state.timerDelays.length;
	state.document.hidden = true;
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
	assert.deepEqual(state.timerDelays.slice(beforeJobTimers), [ 2000, 2000, 2000 ],
		'job polling must continue every two seconds even while the document is hidden');
	state.document.hidden = false;

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
	const beforePendingTimers = state.timerDelays.length;
	await assert.rejects(state.operation.waitForJob(async () => {
		pendingReads++;
		return { state: 'running' };
	}, 'token', currentScope, jobMessages), /job still pending/);
	assert.equal(pendingReads, 180, 'job polling must have a bounded attempt count');
	assert.equal(state.timerDelays.slice(beforePendingTimers).reduce((sum, delay) => sum + delay, 0), 360000,
		'the retry-delay budget stays at six minutes, excluding RPC response times');

	let resettingReads = 0;
	const resetErrorCount = await state.operation.waitForJob(async (_token, consume) => {
		if (consume)
			return {};
		resettingReads++;
		if (resettingReads === 6)
			return { state: 'running' };
		if (resettingReads === 12)
			return { state: 'done', ok: false, error: 'rejected' };
		throw new Error('temporary status failure');
	}, 'token', currentScope, jobMessages);
	assert.equal(resetErrorCount.ok, false,
		'a terminal failure belongs to the caller, not the transport error path');
	assert.equal(resettingReads, 12,
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
	const rejectedScope = state.operation.createPageScope();
	await assert.rejects(state.operation.requestActive(async () => {
		state.dispatch('pagehide');
		throw new Error('obsolete transport error');
	}, rejectedScope), error => error?.pageInactive === true,
		'finally must discard a stale rejection as well as a stale successful reply');
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
	const overviewView = loadView('overview', overviewOperation, overviewUi);
	let resolveSave;
	const savePromise = new Promise(resolve => { resolveSave = resolve; });
	const overviewContext = Object.assign(Object.create(overviewView), { settingsSubmission: null, submitSettings() {
		applyEvents.push('apply');
		return savePromise;
	} });
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
	assert.equal(statusTransport.statusCalls, 6,
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
	assert.ok(yaml.includes("const mapping = content.includes(':') && content.match("),
		'lines without a colon must skip mapping backtracking before the large-input checks');

	await testYamlTemplateReset();
	await testYamlSubmissions();
	await testMemoryWriteback();
	await testYamlEditing();
	console.log('navigation lifecycle, shared job polling and settings/YAML reconciliation tests passed');
}

main().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
