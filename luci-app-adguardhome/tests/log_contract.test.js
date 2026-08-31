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
assert.match(rpcSource, /args: \{ source: 'core', lines: 100 \}/,
	'get_log must declare the bounded source and line arguments');

assert.match(viewSource, /params: \[ 'source', 'lines' \]/);
assert.match(viewSource, /fetchLog\('core', DEFAULT_LINES\)/);
assert.match(viewSource, /fetchLog\('plugin', DEFAULT_LINES\)/);
assert.match(viewSource, /Promise\.all\(\[/,
	'the two independent sources should load together');
assert.match(viewSource, /AdGuard Home Core Log/);
assert.match(viewSource, /Plugin Runtime Log/);
assert.match(viewSource, /\.scrollTop = 0;/,
	'refresh must return both newest-first views to the top');
assert.doesNotMatch(viewSource, /innerHTML/,
	'log bytes must not be interpreted as HTML');

console.log('split newest-first log RPC and view contract tests passed');
