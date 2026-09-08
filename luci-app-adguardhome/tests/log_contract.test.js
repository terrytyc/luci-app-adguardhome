'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { extractFunction } = require('./lib/source');

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
		requestActive: request => request(),
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
			rows: attrs.rows,
			wrap: attrs.wrap,
		};
	};
	const view = { extend: definition => definition };
	const sandbox = {
		E: element,
		L: { resource: path => path },
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

async function testLogPresentation() {
	let queries = 0;
	let refreshed = false;
	const state = loadLogView(async (method, source) => {
		assert.equal(method, 'get_log');
		queries++;
		return { log: refreshed && source === 'core' ? 'newest\noldest' : '', source, lines: 0 };
	});
	const view = state.definition;
	const root = view.render(await view.load());
	assert.equal(root.attrs.class, 'adguardhome-view');
	assert.equal(root.children[0].attrs.href, 'adguardhome/style.css');
	const toolbar = root.children[3].children[0];
	assert.equal(toolbar.attrs.class, 'adguardhome-actions adguardhome-log-toolbar');
	const wrapLabel = toolbar.children[1];
	const wrap = wrapLabel.children[1];
	assert.equal(String(wrapLabel.children[0]), 'Wrap lines');
	assert.equal(wrap.attrs.type, 'checkbox');
	const details = root.children.filter(node => node.tag === 'details');
	assert.equal(details.length, 2);
	for (const section of details) {
		assert.equal(section.attrs.open, true);
		assert.equal(section.children[0].tag, 'summary');
		section.attrs.open = false;
	}
	for (const output of Object.values(view.logOutputs)) {
		assert.equal(output.rows, 1, 'empty logs must not reserve a large blank editor');
		assert.equal(output.wrap, 'off');
		assert.match(output.attrs.class, /adguardhome-log-output/);
	}
	wrap.attrs.change({ target: { checked: true } });
	assert.equal(view.logOutputs.core.wrap, 'soft');
	assert.equal(view.logOutputs.plugin.wrap, 'soft');
	wrap.attrs.change({ target: { checked: false } });
	assert.equal(view.logOutputs.core.wrap, 'off');
	assert.equal(queries, 2, 'folding and wrapping must not issue log queries');
	view.lineSelect.value = '100';
	refreshed = true;
	await view.handleRefresh();
	assert.equal(queries, 4, 'manual refresh must query each source exactly once');
	assert.equal(view.logOutputs.core.rows, 20);
	assert.equal(view.logOutputs.plugin.rows, 1);
	assert.equal(view.logOutputs.core.scrollTop, 0);
}

async function testLogErrorPresentation() {
	const initialFailure = loadLogView(async (method, source) => {
		assert.equal(method, 'get_log');
		return { error: `${source} reader failed`, source };
	});
	const failedLoad = await initialFailure.definition.load.call(initialFailure.definition);
	initialFailure.definition.render.call(initialFailure.definition, failedLoad);
	assert.equal(String(initialFailure.definition.logOutputs.core.attrs['aria-label']), 'AdGuard Home Core Log');
	assert.equal(String(initialFailure.definition.logOutputs.plugin.attrs['aria-label']), 'Plugin Runtime Log');
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
	assert.equal(partialFailure.failures.length, 0,
		'a read-only refresh must not open an application failure modal');
	assert.equal(partialFailure.notifications.length, 1);
	assert.equal(partialFailure.notifications[0].level, 'error');
	assert.match(partialFailure.notifications[0].text, /Unable to read the AdGuard Home core log: core refresh failed/);
	assert.equal(partialFailure.successes.length, 0,
		'a partial refresh failure must not be reported as a successful refresh');
}

const helpers = [
	'requested_log_lines',
	'requested_log_source',
	'newest_first_log',
	'read_log',
].map(name => extractFunction(rpcSource, name)).join('\n')
	// ucode's `for (value in array)` iterates values; JavaScript spells that
	// dependency-free host-test operation as `for (value of array)`.
	.replace('for (let line in split(output, \'\\n\'))',
		'for (let line of split(output, \'\\n\'))');

const MAX_LOG_LENGTH = 512 * 1024;
let logInput = '';
let logStatus = 0;
let logProcess;
const sandbox = {
	MAX_LOG_LENGTH,
	type(value) {
		if (Number.isInteger(value))
			return 'int';
		return typeof value;
	},
	length: value => value.length,
	split: (value, separator) => value.split(separator),
	push: (array, value) => array.push(value),
	reverse: array => Array.from(array).reverse(),
	join: (separator, array) => array.join(separator),
	substr: (value, start, count) => value.substr(start, count),
	index: (value, search) => value.indexOf(search),
	popen(command, mode) {
		assert.equal(mode, 'r');
		// Feed fixture bytes to logread; execute the generated pipeline with the
		// target's BusyBox shell and tail, including its original -n/-c arguments.
		const script = `logread() { busybox grep -E "$2"; return ${logStatus}; }\n` +
			command.replace('/sbin/logread', 'logread').replaceAll('/usr/bin/tail', 'busybox tail');
		const args = [ 'ash', '-c', script ];
		logProcess = process.platform === 'win32'
			? spawnSync('wsl.exe', [ '--exec', 'busybox', ...args ], { input: logInput, encoding: 'utf8', windowsHide: true })
			: spawnSync('busybox', args, { input: logInput, encoding: 'utf8' });
		assert.ifError(logProcess.error);
		return {
			read(limit) {
				assert.equal(limit, MAX_LOG_LENGTH + 1);
				return logProcess.stdout.slice(0, limit);
			},
			close: () => logProcess.status,
		};
	},
};
vm.createContext(sandbox);
vm.runInContext(`${helpers}\nthis.testHelpers = {
	requested_log_lines,
	requested_log_source,
	newest_first_log,
	read_log,
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

logInput = 'AdGuardHome[1]: oldest\nAdGuardHome: plugin\nAdGuardHome[1]: newest\n';
for (const source of [ 'core', 'plugin' ]) {
	const result = tested.read_log(100, source);
	assert.equal(result.log, source === 'core'
		? 'AdGuardHome[1]: newest\nAdGuardHome[1]: oldest' : 'AdGuardHome: plugin');
	assert.equal(result.lines, source === 'core' ? 2 : 1);
	assert.equal(result.source, source);
}
const largeLines = Array.from({ length: 500 }, (_, i) =>
	`AdGuardHome[1]: ${String(i).padStart(3, '0')}:`.padEnd(1104, 'x'));
logInput = largeLines.join('\n') + '\n';
assert.ok(Buffer.byteLength(logInput) > MAX_LOG_LENGTH);
const largeLog = tested.read_log(500, 'core');
assert.equal(largeLog.log.split('\n')[0], largeLines[499],
	'over-limit reads must retain the complete newest record, not the old prefix');
assert.equal(largeLog.log, largeLines.slice(-474).reverse().join('\n'),
	'only the oldest incomplete record may be discarded at the byte limit');
assert.equal(largeLog.lines, 474);
assert.ok(Buffer.byteLength(largeLog.log) <= MAX_LOG_LENGTH);
assert.equal(Buffer.byteLength(logProcess.stdout), MAX_LOG_LENGTH + 1,
	'the pipeline itself must bound output before read() consumes it');
logInput = 'AdGuardHome[1]:'.padEnd(MAX_LOG_LENGTH - 1, 'x') + '\n';
assert.equal(tested.read_log(100, 'core').log, logInput.slice(0, -1),
	'a complete record exactly at the byte limit must remain intact');
const boundaryLines = Array.from({ length: 257 }, (_, i) =>
	`AdGuardHome[1]: ${i}:`.padEnd(2047, 'x'));
logInput = boundaryLines.join('\n') + '\n';
const boundaryLog = tested.read_log(300, 'core');
assert.equal(boundaryLog.lines, 256,
	'a newline sentinel must not discard a complete record that fits the byte limit');
assert.equal(boundaryLog.log, boundaryLines.slice(1).reverse().join('\n'));
logInput = largeLines.map(line => line.slice(0, 19)).join('\n') + '\n';
for (const lines of [ 100, 300, 500 ])
	assert.equal(tested.read_log(lines, 'core').lines, lines);
logStatus = 7;
assert.equal(tested.read_log(100, 'core').error,
	'The system log reader exited unsuccessfully',
	'pipefail must expose a failed logread even when both tail commands succeed');
logStatus = 0;
logInput = '';
assert.equal(tested.read_log(100, 'core').log, '');

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

Promise.all([ testLogErrorPresentation(), testLogPresentation() ]).then(() => {
	console.log('split newest-first log RPC and view contract tests passed');
}).catch(error => {
	console.error(error);
	process.exitCode = 1;
});
