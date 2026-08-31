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
const source = fs.readFileSync(rpcPath, 'utf8');

function extractFunction(name) {
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

function extractConstant(name) {
	const match = source.match(new RegExp(`^const ${name} = .+;$`, 'm'));
	assert.ok(match, `missing ${name} constant`);
	return match[0];
}

const constants = [
	'SERVICE_NAME',
	'INSTANCE_NAME',
	'CONFIG_NAME',
	'CONFIG_SECTION',
	'CONFIG_FILENAME',
	'MEMORY_RUNTIME_DIRECTORY',
	'MEMORY_WORK_DIRECTORY',
	'LEGACY_MEMORY_CONFIG_PATH',
	'MEMORY_STATE_PATH',
	'ADGUARD_UID',
	'ADGUARD_GID',
].map(extractConstant).join('\n');

const functionNames = [
	'valid_work_dir',
	'encoded_device',
	'same_inode',
	'memory_state_active',
	'memory_active',
	'config_path',
	'service_running',
	'service_status',
];
const functions = functionNames.map(extractFunction).join('\n')
	// ucode iterates array values with `for (value in array)`; JavaScript uses
	// `of` for the same dependency-free host-test operation.
	.replace('for (let component in components)',
		'for (let component of components)');

const PERSISTENT_WORK_DIR = '/etc/AdGuardHome';
const PERSISTENT_CONFIG = `${PERSISTENT_WORK_DIR}/AdGuardHome.yaml`;
const MEMORY_RUNTIME_DIR = '/tmp/luci-app-adguardhome-memory';
const MEMORY_WORK_DIR = `${MEMORY_RUNTIME_DIR}/work`;
const STATE_PATH = `${MEMORY_RUNTIME_DIR}/state`;
const BACKING_DEVICE = 2049;
const BACKING_INODE = 42;

const fixture = {
	requested: '0',
	serviceRunning: true,
	entries: [ 'data' ],
	version: 3,
};

const directory = (uid, gid, mode, inode, major = 8, minor = 1) => ({
	type: 'directory', uid, gid, mode, inode,
	dev: { major, minor },
});
const stateMetadata = content => ({
	type: 'file', uid: 0, gid: 0, mode: 0o600, nlink: 1,
	size: content.length, inode: 99, dev: { major: 0, minor: 23 },
});

function stateContent() {
	return `version=${fixture.version}\n` +
		`persistent_work_dir=${PERSISTENT_WORK_DIR}\n` +
		`backing_device=${BACKING_DEVICE}\n` +
		`backing_inode=${BACKING_INODE}\n`;
}

function metadata(pathname) {
	if (pathname === '/etc')
		return directory(0, 0, 0o755, 20);
	if (pathname === PERSISTENT_WORK_DIR)
		return directory(853, 853, 0o700, BACKING_INODE);
	if (pathname === MEMORY_RUNTIME_DIR)
		return directory(0, 853, 0o710, 50, 0, 23);
	if (pathname === MEMORY_WORK_DIR)
		return directory(853, 853, 0o700, 51, 0, 23);
	if (pathname === `${MEMORY_WORK_DIR}/data`)
		return directory(853, 853, 0o700, 52, 0, 23);
	if (pathname === STATE_PATH || pathname === '/proc/self/fd/77')
		return stateMetadata(stateContent());
	return null;
}

function uciCursor() {
	return {
		get(config, section, option) {
			const key = `${config}.${section}.${option}`;
			return {
				'AdGuardHome.AdGuardHome.workdir': PERSISTENT_WORK_DIR,
				'AdGuardHome.AdGuardHome.run_from_memory': fixture.requested,
				'adguardhome.config.work_dir': MEMORY_WORK_DIR,
				'adguardhome.config.config_file': PERSISTENT_CONFIG,
			}[key];
		},
		unload() {},
	};
}

const sandbox = {
	type(value) {
		if (Array.isArray(value))
			return 'array';
		if (Number.isInteger(value))
			return 'int';
		if (value === null)
			return 'null';
		return typeof value;
	},
	length: value => value.length,
	split: (value, separator) => value.split(separator),
	substr: (value, start, count) => value.substr(start, count),
	match: (value, expression) => value.match(expression),
	int: value => Math.trunc(value),
	lc: value => value.toLowerCase(),
	lstat: metadata,
	stat: metadata,
	lsdir(pathname) {
		return pathname === MEMORY_WORK_DIR ? [ ...fixture.entries ] : null;
	},
	open(pathname) {
		if (pathname !== STATE_PATH)
			return null;
		return {
			fileno: () => 77,
			read: () => stateContent(),
			close: () => true,
		};
	},
	cursor: uciCursor,
	connect() {
		return {
			call: () => ({
				adguardhome: {
					instances: {
						adguardhome: { running: fixture.serviceRunning },
					},
				},
			}),
			disconnect() {},
		};
	},
};
vm.createContext(sandbox);
vm.runInContext(`${constants}\n${functions}\nthis.memoryApi = {
	memory_state_active,
	memory_active,
	config_path,
	service_status,
};`, sandbox, { filename: rpcPath });

const api = sandbox.memoryApi;

assert.match(source, /lines\[0\] == 'version=3'/,
	'only the r2 version=3 RAM state layout may be active');
assert.doesNotMatch(source, /^const MEMORY_CONFIG_PATH\b/m,
	'the RPC must not define an active YAML path in RAM');
const configPathSource = extractFunction('config_path');
assert.doesNotMatch(configPathSource, /return\s+LEGACY_MEMORY_CONFIG_PATH/,
	'the stale r1 RAM YAML sentinel must never be returned');
assert.doesNotMatch(configPathSource,
	/work_dir\s*=\s*MEMORY_WORK_DIRECTORY/,
	'config_path must never select the RAM work directory for YAML');

assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), true,
	'a valid version=3 data-only RAM generation should be active');
assert.equal(api.config_path(), PERSISTENT_CONFIG,
	'valid RAM mode must keep YAML in the persistent work directory');
assert.equal(api.memory_active(), true,
	'the independent RAM state validator should report the active generation');

fixture.requested = '0';
let status = api.service_status();
assert.equal(status.memory_requested, false);
assert.equal(status.memory_active, true,
	'memory_active must not be derived from the requested checkbox');

fixture.requested = '1';
fixture.entries = [ 'data', 'AdGuardHome.yaml' ];
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a YAML file or any second top-level RAM work entry must invalidate RAM mode');
assert.equal(api.config_path(), null,
	'an invalid present RAM namespace must not fall back to any RAM YAML path');
status = api.service_status();
assert.equal(status.memory_requested, true);
assert.equal(status.memory_active, false,
	'a requested checkbox must not manufacture an active RAM state');

fixture.entries = [ 'data' ];
fixture.version = 2;
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a pre-r2 state record must not activate the data-only layout');

console.log('r2 data-only RPC memory layout contract tests passed');
