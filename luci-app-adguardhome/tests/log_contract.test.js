'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const rpcPath = path.join(
	packageRoot,
	'root/usr/share/rpcd/ucode/luci.adguardhome'
);
const viewPath = path.join(
	packageRoot,
	'htdocs/luci-static/resources/view/adguardhome/log.js'
);
const rpcSource = fs.readFileSync(rpcPath, 'utf8');
const viewSource = fs.readFileSync(viewPath, 'utf8');

function translated(value) {
	const result = new String(value);
	result.format = (...args) => {
		let offset = 0;
		return value.replace(/%[sd]/g, () => String(args[offset++]));
	};
	return result;
}

function extractFunction(source, name) {
	const start = source.indexOf(`function ${name}(`);
	assert.notEqual(start, -1, `missing ${name}()`);
	const body = source.indexOf('{', start);
	assert.notEqual(body, -1, `missing ${name}() body`);

	let depth = 0;
	for (let offset = body; offset < source.length; offset++) {
		if (source[offset] === '{')
			depth++;
		else if (source[offset] === '}' && --depth === 0)
			return source.slice(start, offset + 1);
	}

	assert.fail(`unterminated ${name}()`);
}

function loadLogView(handler) {
	const failures = [];
	const notifications = [];
	const successes = [];
	const scope = { attach: node => node };
	const operation = {
		createPageScope: () => scope,
		isPageActive: () => true,
		isPageInactiveError: error => error?.pageInactive === true,
		pageInactiveError: () => Object.assign(new Error('inactive'), { pageInactive: true }),
		abandonInactiveLoad: error => { throw error; },
		requestDuringApply: request => request(),
		start: () => ({}),
		failure: message => failures.push(String(message)),
		success: message => successes.push(String(message)),
	};
	const rpc = {
		declare: specification => async (...args) => handler(specification.method, ...args),
	};
	const ui = {
		createHandlerFn: () => () => {},
		addNotification(_title, node, level) {
			notifications.push({ level, text: String(node.textContent ?? '') });
		},
	};
	const element = (tag, attrs = {}, children = []) => {
		const childList = Array.isArray(children) ? children : [ children ];
		const text = childList.map(child => {
			if (child != null && typeof child === 'object' && 'textContent' in child)
				return child.textContent;
			return String(child ?? '');
		}).join('');
		return {
			tag,
			attrs,
			children: childList,
			disabled: attrs?.disabled != null,
			scrollTop: null,
			textContent: text,
			value: text,
		};
	};
	const view = { extend: definition => definition };
	const sandbox = {
		E: element,
		_: translated,
		operation,
		rpc,
		ui,
		view,
	};
	vm.createContext(sandbox);
	const definition = vm.runInContext(
		'(function(operation, rpc, ui, view, E, _) {\n' + viewSource +
			'\n}).call(globalThis, operation, rpc, ui, view, E, _)',
		sandbox,
		{ filename: viewPath },
	);

	return { definition, failures, notifications, successes };
}

async function testLogErrorPresentation() {
	const initialFailure = loadLogView(async (method, source) => {
		assert.equal(method, 'get_log');
		return { error: `${source} reader failed`, source };
	});
	const failedLoad = await initialFailure.definition.load.call(initialFailure.definition);
	initialFailure.definition.render.call(initialFailure.definition, failedLoad);
	assert.equal(initialFailure.notifications.length, 2,
		'initial core and plugin reader failures must each produce a visible notification');
	assert.deepEqual(initialFailure.notifications.map(item => item.level), [ 'error', 'error' ]);
	assert.match(initialFailure.notifications[0].text, /Unable to read the AdGuard Home core log: core reader failed/);
	assert.match(initialFailure.notifications[1].text, /Unable to read the plugin runtime log: plugin reader failed/);

	let refresh = false;
	const partialFailure = loadLogView(async (_method, source) => {
		if (!refresh)
			return { log: `${source}-old`, lines: 1, source };
		if (source === 'core')
			return { error: 'core refresh failed', source };
		return { log: 'plugin-new', lines: 1, source };
	});
	const initial = await partialFailure.definition.load.call(partialFailure.definition);
	partialFailure.definition.render.call(partialFailure.definition, initial);
	assert.equal(partialFailure.definition.logOutputs.core.value, 'core-old');
	assert.equal(partialFailure.definition.logOutputs.plugin.value, 'plugin-old');
	partialFailure.definition.lineSelect.value = '100';
	refresh = true;
	await partialFailure.definition.handleRefresh.call(partialFailure.definition);
	assert.equal(partialFailure.definition.logOutputs.core.value, 'core-old',
		'a failed core refresh must preserve the previously displayed core log');
	assert.equal(partialFailure.definition.logOutputs.plugin.value, 'plugin-new',
		'a successful plugin refresh must still update independently');
	assert.equal(partialFailure.failures.length, 1);
	assert.match(partialFailure.failures[0], /Unable to read the AdGuard Home core log: core refresh failed/);
	assert.equal(partialFailure.successes.length, 0,
		'a partial refresh failure must not be reported as a successful refresh');
}

const helpers = [
	'requested_log_lines',
	'requested_log_source',
	'newest_first_log',
].map(name => extractFunction(rpcSource, name)).join('\n')
	// ucode's `for (value in array)` iterates values; JavaScript spells that
	// dependency-free host-test operation as `for (value of array)`.
	.replace('for (let line in split(output, \'\\n\'))',
		'for (let line of split(output, \'\\n\'))');

const sandbox = {
	type(value) {
		if (Number.isInteger(value))
			return 'int';
		return typeof value;
	},
	length: value => value.length,
	split: (value, separator) => value.split(separator),
	push: (array, value) => array.push(value),
	join: (separator, array) => array.join(separator),
};
vm.createContext(sandbox);
vm.runInContext(`${helpers}\nthis.testHelpers = {
	requested_log_lines,
	requested_log_source,
	newest_first_log,
};`, sandbox, { filename: rpcPath });

const tested = sandbox.testHelpers;
assert.equal(tested.requested_log_lines(1), 100);
assert.equal(tested.requested_log_lines(100), 100);
assert.equal(tested.requested_log_lines(101), 300);
assert.equal(tested.requested_log_lines(300), 300);
assert.equal(tested.requested_log_lines(301), 500);
assert.equal(tested.requested_log_lines(9999), 500);
assert.equal(tested.requested_log_lines('500'), 100);

assert.equal(tested.requested_log_source('core'), 'core');
assert.equal(tested.requested_log_source('plugin'), 'plugin');
assert.equal(tested.requested_log_source('all'), 'core');
assert.equal(tested.requested_log_source(undefined), 'core');

assert.deepEqual(
	JSON.parse(JSON.stringify(tested.newest_first_log(
		'oldest\nmiddle\nnewest\n', 'plugin'
	))),
	{ log: 'newest\nmiddle\noldest', lines: 3, source: 'plugin' }
);
assert.deepEqual(
	JSON.parse(JSON.stringify(tested.newest_first_log('', 'core'))),
	{ log: '', lines: 0, source: 'core' }
);

assert.ok(rpcSource.includes(
	"/sbin/logread -e '^AdGuardHome[[]' | /usr/bin/tail -n ${requested}"
), 'core log command must filter the exact PID-bearing tag before tailing');
assert.ok(rpcSource.includes(
	"/sbin/logread -e '^AdGuardHome:' | /usr/bin/tail -n ${requested}"
), 'plugin log command must filter the exact PID-less tag before tailing');
assert.doesNotMatch(rpcSource, /logread[^\n]*\$\{requested_source\}/,
	'caller-controlled source must never enter a shell command');
assert.match(rpcSource, /pipe\.read\(MAX_LOG_LENGTH \+ 1\)/,
	'log reads must remain bounded');
const readLogSource = extractFunction(rpcSource, 'read_log');
assert.doesNotMatch(readLogSource, /return \{ log: '', lines: 0, source \};/,
	'log reader failures must not be reported as a successful empty log');
assert.match(readLogSource, /return \{ error: 'Unable to read the system log', source \};/,
	'log read exceptions must be exposed to the caller');
assert.match(readLogSource, /status != 0[\s\S]*?error:/,
	'non-zero log pipeline status must be exposed to the caller');
assert.match(rpcSource, /args: \{ source: 'core', lines: 100 \}/,
	'get_log must declare the bounded source and line arguments');

assert.match(viewSource, /params: \[ 'source', 'lines' \]/);
assert.match(viewSource, /fetchLog\('core', DEFAULT_LINES, pageScope\)/);
assert.match(viewSource, /fetchLog\('plugin', DEFAULT_LINES, pageScope\)/);
assert.match(viewSource, /Promise\.all\(\[/,
	'the two independent sources should load together');
assert.match(viewSource, /typeof result\?\.error === 'string'[\s\S]*?throw new Error\(result\.error\)/,
	'the log view must surface RPC reader failures instead of showing an empty success');
const normalizeLogSource = extractFunction(viewSource, 'normalizeLog');
const normalizeSandbox = {};
vm.createContext(normalizeSandbox);
vm.runInContext(`${normalizeLogSource}; this.normalizeLog = normalizeLog;`, normalizeSandbox);
assert.throws(
	() => normalizeSandbox.normalizeLog({ error: 'reader failed', source: 'core' }),
	/reader failed/,
	'an RPC reader error must be executed as a failure, not normalized to an empty log',
);
assert.deepEqual(
	JSON.parse(JSON.stringify(normalizeSandbox.normalizeLog({
		log: 'newest',
		lines: 1,
		source: 'plugin',
	}))),
	{ log: 'newest', lines: 1, source: 'plugin' },
);
assert.match(viewSource, /AdGuard Home Core Log/);
assert.match(viewSource, /Plugin Runtime Log/);
assert.match(viewSource, /\.scrollTop = 0;/,
	'refresh must return both newest-first views to the top');
assert.doesNotMatch(viewSource, /innerHTML/,
	'log bytes must not be interpreted as HTML');

testLogErrorPresentation().then(() => {
	console.log('split newest-first log RPC and view contract tests passed');
}).catch(error => {
	console.error(error);
	process.exitCode = 1;
});
