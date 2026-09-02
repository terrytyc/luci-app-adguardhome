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
	const polls = new Set();
	const document = { hidden: false };
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
				return async (...args) => {
					calls.push(specification.method);
					assert.ok(handlers[specification.method], 'unexpected RPC ' + specification.method);
					return handlers[specification.method](...args);
				};
			},
		},
		dom: { content(node, value) { updates.push({ node, value }); } },
		ui: { createHandlerFn: () => () => {} },
		view: { extend: definition => definition },
		E: (tag, attrs, child) => ({ tag, attrs, child }),
		_: value => value,
		L: { hasViewPermission: () => true },
		URL,
		console: { error: (...args) => errors.push(args) },
		window: { location: { href: 'https://router.example:8443/cgi-bin/luci/' } },
		document,
	};
	vm.createContext(context);
	const view = vm.runInContext('(function() {\n' + source + '\n})()', context,
		{ filename: overviewPath });
	return {
		view, calls, updates, errors, polls, handlers, document,
		setActive: value => { active = value; },
		setOverview: value => { overviewResult = value; },
	};
}

async function main() {
	const state = loadOverview();
	const initial = await state.view.load();
	assert.deepEqual(state.calls.sort(), [ 'get_overview', 'get_settings', 'get_version' ]);
	assert.equal(initial[1].status.running, true);
	assert.equal(initial[1].config.dnsPort, 53335);
	await state.view.render(initial);
	assert.equal(state.polls.size, 1);
	const callback = state.view.statusPollCallback;
	const committed = state.view.committedSettings;
	const draft = state.view.settingsMap.initialData;
	draft.config.work_dir = '/mnt/storage/AdGuardHome-draft';

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
	assert.equal(state.updates.length, 4);
	assert.equal(state.updates[0].value.child, 'Running');
	assert.equal(state.updates[1].value.child, 'Memory');
	assert.equal(state.updates[2].value, '5353', 'DNS display must use the current YAML value');
	assert.equal(state.updates[3].value.attrs.href, 'https://adg.example:10443/');
	assert.equal(state.view.committedSettings, committed,
		'polling must not replace the authoritative settings revision snapshot');
	assert.equal(state.view.settingsMap.initialData, draft);
	assert.equal(draft.config.work_dir, '/mnt/storage/AdGuardHome-draft',
		'polling must leave unsaved work directory edits intact');

	state.setOverview({
		status: { running: 'true', memory_requested: 1, memory_active: null },
		config: { dns_port: 65536, web: { scheme: 'https', host: 'bad/host', port: 443 } },
	});
	await callback();
	assert.equal(state.updates.at(-4).value.child, 'Not running');
	assert.equal(state.updates.at(-3).value.child, 'Persistent storage');
	assert.equal(state.updates.at(-2).value, 'Unavailable');
	assert.equal(state.updates.at(-1).value.tag, 'span');

	state.handlers.get_overview = () => { throw new Error('temporary RPC failure'); };
	await callback();
	assert.equal(state.errors.length, 1, 'real RPC failures must remain diagnosable');
	assert.equal(state.updates.at(-4).value.child, 'Not running');
	assert.equal(state.updates.at(-2).value, 'Unavailable');
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
	console.log('combined overview polling, live YAML values and unsaved-form protection tests passed');
}

main().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
