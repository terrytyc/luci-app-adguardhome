'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const overviewPath = path.join(__dirname,
	'../htdocs/luci-static/resources/view/adguardhome/overview.js');
const source = fs.readFileSync(overviewPath, 'utf8');

function loadOverview() {
	const calls = [];
	const updates = [];
	const errors = [];
	const urlBuilds = [];
	const polls = new Set();
	const elements = [];
	const document = { hidden: false, activeElement: null };
	let active = true;
	let overviewResult = {
		status: { running: true, memory_requested: false, memory_active: false },
		config: { dns_port: 53335, web: { scheme: 'http', host: null, port: 3000 } },
	};
	const handlers = {
		get_overview: () => overviewResult,
		get_version: () => ({ version: 'v0.107.76' }),
		get_settings: () => ({
			enabled: true,
			work_dir: '/etc/AdGuardHome',
			verbose: false,
			redirect: 'dnsmasq-upstream',
			run_from_memory: false,
			memory_writeback_interval: 60,
			revision: 'a'.repeat(64),
		}),
	};
	const scope = { attach: node => node };
	const operation = {
		createPageScope: () => scope,
		isPageActive: () => active,
		isPageInactiveError: error => error?.pageInactive === true,
		pageInactiveError: () => Object.assign(new Error('inactive page'), { pageInactive: true }),
		async requestActive(requestFn) {
			if (!active)
				throw this.pageInactiveError();
			const result = await requestFn();
			if (!active)
				throw this.pageInactiveError();
			return result;
		},
		abandonInactiveLoad: error => { throw error; },
	};
	class JSONMap {
		constructor(data) {
			this.initialData = data;
		}
		section() {
			return { option: () => ({ value() {}, depends() {} }) };
		}
		async render() { return {}; }
		load() { assert.fail('status polling must not reload unsaved form values'); }
		reset() { assert.fail('status polling must not reset unsaved form values'); }
	}
	const context = {
		operation,
		form: { JSONMap },
		poll: {
			add(callback, interval) {
				assert.equal(interval, 10);
				polls.add(callback);
			},
			remove(callback) { polls.delete(callback); },
		},
		rpc: {
			declare(specification) {
				if (specification.method === 'get_overview')
					assert.equal(specification.reject, true, 'RPC failures must not become an empty successful overview');
				return async (...args) => {
					calls.push(specification.method);
					assert.ok(handlers[specification.method], 'unexpected RPC ' + specification.method);
					return handlers[specification.method](...args);
				};
			},
		},
		dom: { content(node, value) {
			if (document.activeElement === node.child)
				document.activeElement = null;
			node.child = value;
			updates.push({ node, value });
		} },
		ui: { createHandlerFn: () => () => {} },
		view: { extend: definition => definition },
		E(tag, attrs, child) {
			const node = { tag, attrs, child };
			elements.push(node);
			return node;
		},
		_: value => value,
		L: { hasViewPermission: () => true },
		URL: class extends URL {
			constructor(value) { super(value); urlBuilds.push(value); }
		},
		console: { error: (...args) => errors.push(args) },
		window: { location: { href: 'https://router.example:8443/cgi-bin/luci/' } },
		document,
	};
	vm.createContext(context);
	const view = vm.runInContext('(function() {\n' + source + '\n})()', context,
		{ filename: overviewPath });
	return {
		view, calls, updates, errors, urlBuilds, polls, handlers, document, elements,
		setActive: value => { active = value; },
		setOverview: value => { overviewResult = value; },
	};
}

function deferred() {
	let resolve, reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
}

async function testUnavailableStatus() {
	for (const initial of [ 'running', 'stopped', 'request-failure', 'invalid-response' ]) {
		const state = loadOverview();
		const failedRequest = () => { throw new Error('temporary RPC failure'); };
		if (initial === 'request-failure')
			state.handlers.get_overview = failedRequest;
		else if (initial === 'invalid-response')
			state.setOverview({});
		else
			state.setOverview({
				status: { running: initial === 'running', memory_requested: true, memory_active: initial === 'running' },
				config: { dns_port: 53335, web: { scheme: 'http', host: null, port: 3000 } },
			});
		await state.view.render(await state.view.load());
		const [ service, storage, management ] = state.elements.filter(node =>
			node.tag === 'span' && [ 'span', 'a' ].includes(node.child?.tag));
		if (initial === 'request-failure' || initial === 'invalid-response') {
			assert.equal(service.child.child, 'Unavailable', 'the initial render must not invent a stopped state');
			assert.equal(storage.child.child, 'Unavailable');
		}
		const committed = state.view.committedSettings;
		const draft = state.view.settingsMap.initialData;
		draft.config.work_dir = '/etc/AdGuardHome-draft';
		state.handlers.get_overview = failedRequest;
		await state.view.statusPollCallback();
		assert.equal(service.child.child, 'Unavailable', `${initial}: a failed query is not a stopped core`);
		assert.equal(storage.child.child, 'Unavailable', `${initial}: a failed query cannot report persistent storage`);
		assert.equal(management.child.child[0].attrs.disabled, 'disabled');
		assert.equal(management.child.child[2].child, 'Service status: Unavailable');
		state.updates.length = 0;
		await state.view.statusPollCallback();
		assert.equal(state.updates.length, 0, 'repeated failures must not redraw an unchanged unknown state');
		state.handlers.get_overview = () => ({
			status: { running: true, memory_requested: true, memory_active: true },
			config: { dns_port: 5354, web: { scheme: 'https', host: 'adg.example', port: 10443 } },
		});
		await state.view.statusPollCallback();
		assert.equal(service.child.child, 'Running');
		assert.equal(storage.child.child, 'Memory');
		assert.equal(management.child.attrs.href, 'https://adg.example:10443/');
		assert.equal(state.polls.size, 1, 'the existing timer must recover without another polling mechanism');
		assert.equal(state.view.committedSettings, committed);
		assert.equal(draft.config.work_dir, '/etc/AdGuardHome-draft', 'status failure/recovery must preserve unsaved settings');
	}
}

async function testManagementURLValidation() {
	const state = loadOverview();
	await state.view.render(await state.view.load());
	const management = state.elements.find(node => node.tag === 'span' && node.child?.tag === 'a');
	for (const web of [
		{ scheme: 'javascript', host: null, port: 3000 },
		{ scheme: 'http', host: null, port: 0 },
		{ scheme: 'http', host: null, port: 65536 },
		{ scheme: 'http', host: 'another.example', port: 3000 },
		{ scheme: 'https', host: null, port: 443 },
		...[ 'bad/host', 'a..b', '127.1', '0177.1', '0x7f000001' ].map(host => ({ scheme: 'https', host, port: 443 })),
	]) {
		state.setOverview({ status: { running: true }, config: { web } });
		await state.view.statusPollCallback();
		assert.equal(management.child.child[0].attrs.disabled, 'disabled', JSON.stringify(web));
	}
	state.setOverview({ status: { running: true }, config: { web: { scheme: 'https', host: 'ADG.EXAMPLE.', port: '443' } } });
	await state.view.statusPollCallback();
	assert.equal(management.child.attrs.href, 'https://adg.example./',
		'normalized endpoints must retain URL assignment checks and valid default ports');
}

async function testApplyRefresh() {
	async function settlesWithoutRefresh(promise) {
		let timeout;
		try {
			return await Promise.race([ promise, new Promise((_resolve, reject) => {
				timeout = setTimeout(() => reject(new Error('Apply waited for the extra status refresh')), 500);
			}) ]);
		} finally {
			clearTimeout(timeout);
		}
	}
	for (const kind of [ 'success', 'rejected', 'rpc-failure', 'rejected-refresh-failure', 'callback-failure', 'inactive', 'hidden' ]) {
		const state = loadOverview();
		await state.view.render(await state.view.load());
		state.calls.length = 0;
		const callback = state.view.statusPollCallback;
		const submission = deferred();
		const refreshReply = deferred();
		const result = { applied: true };
		const failure = new Error('original settings failure');
		let submits = 0;
		let refreshes = 0;
		let refreshCompletion;
		let refreshCallback = callback;
		state.view.submitSettings = () => { submits++; return submission.promise; };
		state.handlers.get_overview = () => {
			refreshes++;
			assert.equal(state.view.settingsSubmission, null, 'release the submission before refreshing status');
			return refreshReply.promise;
		};
		if (kind === 'callback-failure') {
			refreshCallback = async () => {
				refreshes++;
				assert.equal(state.view.settingsSubmission, null);
				throw new Error('status rendering failed');
			};
		}
		state.view.statusPollCallback = () => {
			refreshCompletion = refreshCallback();
			return refreshCompletion;
		};

		const applying = state.view.handleSaveApply();
		assert.equal(state.view.handleSaveApply(), submission.promise,
			'clicking Apply twice must reuse the same submission');
		await callback();
		assert.deepEqual(state.calls, [], 'routine status polling must pause during the settings transaction');
		assert.equal(state.polls.size, 1, 'pausing for Apply must not unregister the normal timer');
		if (kind === 'inactive')
			state.setActive(false);
		if (kind === 'hidden')
			state.document.hidden = true;
		if (kind.startsWith('rejected'))
			submission.reject(failure);
		else
			submission.resolve(result);
		if (kind.startsWith('rejected'))
			await assert.rejects(settlesWithoutRefresh(applying), error => error === failure,
				'the refresh must preserve the original rejected settings result without delaying it');
		else
			assert.equal(await settlesWithoutRefresh(applying), result,
				'a pending status refresh must not delay or replace the settings result');
		if (kind !== 'inactive' && kind !== 'hidden') {
			assert.equal(state.view.settingsSubmission, null);
			state.view.settingsMap.initialData.config.work_dir = '/mnt/storage/AdGuardHome-new-draft';
			if (kind === 'rpc-failure' || kind === 'rejected-refresh-failure')
				refreshReply.reject(new Error('status RPC failed after Apply'));
			else
				refreshReply.resolve({
					status: { running: true, memory_requested: true, memory_active: true },
					config: { dns_port: 5354, web: { scheme: 'https', host: 'adg.example', port: 10443 } },
				});
		}
		if (refreshCompletion)
			await refreshCompletion.catch(() => {});
		assert.equal(submits, 1, 'post-apply refresh must never start a second settings transaction');
		assert.equal(state.view.settingsSubmission, null);
		assert.equal(refreshes, kind === 'inactive' || kind === 'hidden' ? 0 : 1,
			'each visible, active completion must refresh status exactly once');
		if (refreshes) {
			assert.equal(state.view.settingsMap.initialData.config.work_dir,
				'/mnt/storage/AdGuardHome-new-draft', 'the status refresh must preserve a newly edited draft');
		}
		assert.ok(state.calls.every(method => method === 'get_overview'),
			'the extra refresh must not reload or write the full settings form');
		assert.equal(state.errors.length,
			[ 'rpc-failure', 'rejected-refresh-failure', 'callback-failure' ].includes(kind) ? 1 : 0);
		if (kind === 'hidden') {
			state.document.hidden = false;
			refreshReply.resolve({ status: { running: true }, config: { dns_port: 5354 } });
			await callback();
			assert.equal(refreshes, 1, 'the retained regular timer must refresh after returning to the visible page');
		}
	}

	for (const arrival of [ 'during-apply', 'after-refresh' ]) {
		const state = loadOverview();
		await state.view.render(await state.view.load());
		const callback = state.view.statusPollCallback;
		const oldReply = deferred();
		const submission = deferred();
		let refreshCompletion;
		state.handlers.get_overview = () => oldReply.promise;
		const oldPoll = callback();
		state.view.submitSettings = () => submission.promise;
		const applying = state.view.handleSaveApply();
		if (arrival === 'during-apply') {
			oldReply.resolve({ status: { running: false }, config: { dns_port: 53 } });
			await oldPoll;
			assert.equal(state.updates.length, 0, 'a pre-Apply status reply must not render during the transaction');
		}
		state.view.statusPollCallback = () => {
			refreshCompletion = callback();
			return refreshCompletion;
		};
		state.handlers.get_overview = () => ({
			status: { running: true, memory_requested: true, memory_active: true },
			config: { dns_port: 5354 },
		});
		submission.resolve();
		await applying;
		await refreshCompletion;
		assert.ok(state.updates.some(update => update.value === '5354'),
			'the immediate completion refresh must display the final live state');
		if (arrival === 'after-refresh') {
			assert.equal(state.view.settingsSubmission, null);
			const currentUpdates = state.updates.length;
			oldReply.resolve({ status: { running: false }, config: { dns_port: 53 } });
			await oldPoll;
			assert.equal(state.updates.length, currentUpdates,
				'a pre-Apply request arriving after the final refresh must not overwrite the new state');
		}
	}
}

async function main() {
	const state = loadOverview();
	const initial = await state.view.load();
	assert.deepEqual(state.calls.sort(), [ 'get_overview', 'get_settings', 'get_version' ]);
	assert.equal(initial[1].status.running, true);
	assert.equal(initial[1].config.dnsPort, 53335);
	await state.view.render(initial);
	assert.equal(state.urlBuilds.length, 1, 'rendering must reuse the already validated management URL');
	assert.equal(state.polls.size, 1);
	const callback = state.view.statusPollCallback;
	const committed = state.view.committedSettings;
	const draft = state.view.settingsMap.initialData;
	draft.config.work_dir = '/mnt/storage/AdGuardHome-draft';
	const management = state.elements.find(node => node.tag === 'span' && node.child?.tag === 'a');
	assert.ok(management);
	const initialLink = management.child;
	state.document.activeElement = initialLink;
	state.calls.length = 0;
	await callback();
	assert.deepEqual(state.calls, [ 'get_overview' ], 'unchanged displays must still query fresh RPC state');
	assert.equal(state.updates.length, 0, 'the initial display must seed the per-field comparison');
	assert.equal(management.child, initialLink);
	assert.equal(state.document.activeElement, initialLink, 'unchanged management links must retain keyboard focus');

	state.calls.length = 0;
	state.document.hidden = true;
	await callback();
	assert.deepEqual(state.calls, [], 'hidden overview pages must skip routine RPC polling');
	assert.equal(state.updates.length, 0);
	assert.equal(state.polls.size, 1, 'visibility changes must retain the next scheduled poll');
	state.document.hidden = false;
	state.setOverview({
		status: { running: true, memory_requested: true, memory_active: true },
		config: { dns_port: '5353', web: { scheme: 'https', host: 'adg.example', port: 10443 } },
	});
	await callback();
	assert.deepEqual(state.calls, [ 'get_overview' ],
		'each overview poll must issue only one combined status/config RPC');
	assert.equal(state.updates.length, 3, 'the unchanged running status must retain its node');
	assert.equal(state.updates[0].value.child, 'Memory');
	assert.equal(state.updates[1].value, '5353', 'DNS display must use the current YAML value');
	assert.equal(state.updates[2].value.attrs.href, 'https://adg.example:10443/');
	assert.equal(state.view.committedSettings, committed,
		'polling must not replace the authoritative settings revision snapshot');
	assert.equal(state.view.settingsMap.initialData, draft);
	assert.equal(draft.config.work_dir, '/mnt/storage/AdGuardHome-draft',
		'polling must leave unsaved work directory edits intact');
	const activeLink = management.child;
	state.document.activeElement = activeLink;
	state.updates.length = 0;
	state.calls.length = 0;
	state.setOverview({
		status: { running: true, memory_requested: false, memory_active: true },
		config: { dns_port: 5353, web: { scheme: 'https', host: 'adg.example', port: 10443 } },
	});
	await callback();
	assert.deepEqual(state.calls, [ 'get_overview' ], 'display comparison must not cache RPC responses');
	assert.equal(state.updates.length, 0, 'raw flag/type changes with identical display values must not redraw');
	assert.equal(management.child, activeLink);
	assert.equal(state.document.activeElement, activeLink);
	state.setOverview({
		status: { running: true, memory_requested: false, memory_active: true },
		config: { dns_port: 5354, web: { scheme: 'https', host: 'adg.example', port: 10443 } },
	});
	await callback();
	assert.equal(state.updates.length, 1, 'changing only DNS must update only the DNS container');
	assert.equal(state.updates[0].value, '5354');
	assert.equal(management.child, activeLink);
	assert.equal(state.document.activeElement, activeLink, 'unrelated status changes must preserve link focus');
	for (const web of [
		{ scheme: 'https', host: 'new-adg.example', port: 10443 },
		{ scheme: 'https', host: 'new-adg.example', port: 10444 },
		{ scheme: 'http', host: null, port: 10444 },
	]) {
		state.updates.length = 0;
		state.setOverview({
			status: { running: true, memory_requested: false, memory_active: true },
			config: { dns_port: 5354, web },
		});
		await callback();
		assert.equal(state.updates.length, 1, 'each changed management URL must update only its own container');
		assert.equal(state.updates[0].node, management);
		assert.equal(management.child.attrs.href,
			`${web.scheme}://${web.host ?? 'router.example'}:${web.port}/`);
	}
	for (const [status, text, updateCount] of [
		[{ running: true, memory_requested: true, memory_active: false }, 'Persistent storage (memory fallback)', 1],
		[{ running: false, memory_requested: true, memory_active: false }, 'Persistent storage (memory on next start)', 3],
		[{ running: false, memory_requested: false, memory_active: false }, 'Persistent storage', 1],
	]) {
		state.updates.length = 0;
		state.setOverview({
			status,
			config: { dns_port: 5354, web: { scheme: 'http', host: null, port: 10444 } },
		});
		await callback();
		assert.equal(state.updates.length, updateCount, 'only changed display fields may update');
		assert.ok(state.updates.some(update => update.value.child === text),
			'every memory fallback/pending/persistent transition must remain visible');
	}

	state.updates.length = 0;
	state.setOverview({
		status: { running: 'true', memory_requested: 1, memory_active: null },
		config: { dns_port: 65536, web: { scheme: 'https', host: 'bad/host', port: 443 } },
	});
	await callback();
	assert.equal(state.updates.length, 4, 'an invalid running flag must produce unknown status, storage and endpoint state');
	assert.equal(state.updates[2].value, 'Unavailable');
	assert.equal(management.child.tag, 'span');
	state.updates.length = 0;
	state.setOverview({
		status: { running: false, memory_requested: false, memory_active: false },
		config: { dns_port: null, web: { scheme: 'https', host: 'adg.example', port: 10443 } },
	});
	await callback();
	assert.equal(state.updates.length, 3, 'a confirmed stopped response must replace the unknown-state messages');
	state.updates.length = 0;
	await callback();
	assert.equal(state.updates.length, 0, 'endpoint changes while stopped must not rebuild the disabled button');
	assert.equal(management.child.child[0].attrs.disabled, 'disabled');
	assert.match(management.child.child[2].child, /Enable AdGuard Home/);
	state.setOverview({ status: { running: true }, config: {} });
	await callback();
	assert.equal(state.updates.filter(update => update.node === management).length, 1,
		'false (stopped) to null (invalid endpoint) must repaint the disabled-button explanation');
	assert.equal(management.child.child[0].attrs.disabled, 'disabled');
	assert.match(management.child.child[2].child, /YAML management endpoint is unavailable/);
	state.updates.length = 0;
	state.setOverview({ status: { running: false }, config: {} });
	await callback();
	assert.equal(state.updates.filter(update => update.node === management).length, 1,
		'null (invalid endpoint) to false (stopped) must repaint the disabled-button explanation');
	assert.equal(management.child.child[0].attrs.disabled, 'disabled');
	assert.match(management.child.child[2].child, /Enable AdGuard Home/);
	state.updates.length = 0;

	state.handlers.get_overview = () => { throw new Error('temporary RPC failure'); };
	await callback();
	assert.equal(state.errors.length, 1, 'real RPC failures must remain diagnosable');
	assert.equal(state.updates.length, 3, 'a failed status query must not continue to claim that the core is stopped');
	assert.equal(state.polls.size, 1, 'a transient failure must not permanently stop status polling');

	let resolveReply;
	state.handlers.get_overview = () => new Promise(resolve => { resolveReply = resolve; });
	const beforeInactive = state.updates.length;
	const pending = callback();
	state.setActive(false);
	resolveReply({ status: { running: true }, config: { dns_port: 53 } });
	await pending;
	assert.equal(state.updates.length, beforeInactive,
		'a late overview response must not update an obsolete page');
	assert.equal(state.polls.size, 0);
	assert.equal(state.view.statusPollCallback, null);
	assert.equal(state.errors.length, 1, 'discarded page responses must not be reported as XHR errors');
	const beforeInactiveCalls = state.calls.length;
	state.document.hidden = true;
	await callback();
	assert.equal(state.calls.length, beforeInactiveCalls,
		'an inactive view must not start another overview request');

	assert.doesNotMatch(source, /method:\s*'get_status'|method:\s*'get_config_info'/,
		'the overview must no longer declare redundant status/config RPCs');
	assert.doesNotMatch(source, /require adguardhome\.bcrypt/,
		'loading the overview must not load the bcrypt dependency before it is needed');
	await testApplyRefresh();
	await testUnavailableStatus();
	await testManagementURLValidation();
	console.log('combined overview polling, live YAML values and unsaved-form protection tests passed');
}

main().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
