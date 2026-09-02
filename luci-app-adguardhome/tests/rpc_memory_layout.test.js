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
	'LUCI_SECTION',
	'CONFIG_FILENAME',
	'MEMORY_RUNTIME_DIRECTORY',
	'MEMORY_WORK_DIRECTORY',
	'MEMORY_BACKING_DATA_MOUNT',
	'MEMORY_STATE_PATH',
	'ADGUARD_UID',
	'ADGUARD_GID',
].map(extractConstant).join('\n');

const functionNames = [
	'valid_work_dir',
	'configured_boolean',
	'encoded_device',
	'same_inode',
	'same_directory_inode',
	'memory_state_active',
	'configuration_state',
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
const CUSTOM_WORK_DIR = '/mnt/storage/AdGuardHome';
const CUSTOM_CONFIG = `${CUSTOM_WORK_DIR}/AdGuardHome.yaml`;
const MEMORY_RUNTIME_DIR = '/tmp/luci-app-adguardhome-memory';
const MEMORY_WORK_DIR = `${MEMORY_RUNTIME_DIR}/work`;
const MEMORY_BACKING_DATA = `${MEMORY_RUNTIME_DIR}/backing-data`;
const STATE_PATH = `${MEMORY_RUNTIME_DIR}/state`;
const BACKING_DEVICE = 2049;
const BACKING_INODE = 42;
const PERSISTENT_DATA_DEVICE = 2049;
const MEMORY_DATA_DEVICE = 23;

const fixture = {
	cursorReads: 0,
	requested: '0',
	serviceRunning: true,
	workDir: PERSISTENT_WORK_DIR,
	configFile: PERSISTENT_CONFIG,
	dataPresent: true,
	entries: [ 'data' ],
	version: 4,
	persistentDataInode: 43,
	memoryDataInode: 52,
	visibleDataInode: 52,
	statePersistentDataInode: 43,
	stateMemoryDataInode: 52,
	symlinkPath: null,
	writablePath: null,
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
		`persistent_work_dir=${fixture.workDir}\n` +
		`backing_device=${BACKING_DEVICE}\n` +
		`backing_inode=${BACKING_INODE}\n` +
		`persistent_data_device=${PERSISTENT_DATA_DEVICE}\n` +
		`persistent_data_inode=${fixture.statePersistentDataInode}\n` +
		`memory_data_device=${MEMORY_DATA_DEVICE}\n` +
		`memory_data_inode=${fixture.stateMemoryDataInode}\n`;
}

function metadata(pathname) {
	if (pathname === fixture.symlinkPath)
		return { type: 'link', uid: 0, gid: 0, mode: 0o777 };
	if (pathname === fixture.writablePath)
		return {
			...directory(0, 0, 0o777, 32),
			perm: { group_write: true, other_write: true },
		};
	if (pathname === '/etc')
		return directory(0, 0, 0o755, 20);
	if (pathname === PERSISTENT_WORK_DIR)
		return directory(853, 853, 0o700, BACKING_INODE);
	if (pathname === '/mnt')
		return directory(0, 0, 0o755, 30);
	if (pathname === '/mnt/storage')
		return directory(0, 0, 0o755, 31);
	if (pathname === CUSTOM_WORK_DIR)
		return directory(853, 853, 0o700, BACKING_INODE);
	if (pathname === MEMORY_RUNTIME_DIR)
		return directory(0, 853, 0o710, 50, 0, 23);
	if (pathname === MEMORY_WORK_DIR)
		return directory(853, 853, 0o700, 51, 0, 23);
	if (pathname === `${MEMORY_WORK_DIR}/data`)
		return fixture.dataPresent
			? directory(853, 853, 0o700, fixture.memoryDataInode, 0, 23)
			: null;
	if (pathname === `${fixture.workDir}/data`)
		return fixture.dataPresent
			? directory(853, 853, 0o700, fixture.visibleDataInode, 0, 23)
			: null;
	if (pathname === MEMORY_BACKING_DATA)
		return directory(853, 853, 0o700, fixture.persistentDataInode);
	if (pathname === STATE_PATH || pathname === '/proc/self/fd/77')
		return stateMetadata(stateContent());
	return null;
}

function uciCursor() {
	fixture.cursorReads++;
	return {
		get(config, section, option) {
			const key = `${config}.${section}.${option}`;
			return {
				'adguardhome.config.work_dir': fixture.workDir,
				'adguardhome.config.config_file': fixture.configFile,
				'adguardhome.luci.run_from_memory': fixture.requested,
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
	config_path,
	service_status,
};`, sandbox, { filename: rpcPath });

const api = sandbox.memoryApi;

assert.match(source, /lines\[0\] == 'version=4'/,
	'only the bind-authenticated version=4 RAM state layout may be active');
assert.match(source, /persistent_data_device=/,
	'the RPC must authenticate the persistent data alias identity');
assert.match(source, /memory_data_device=/,
	'the RPC must authenticate the RAM data identity');
assert.doesNotMatch(source, /^const MEMORY_CONFIG_PATH\b/m,
	'the RPC must not define an active YAML path in RAM');
assert.doesNotMatch(source, /^const LEGACY_MEMORY_CONFIG_PATH\b/m,
	'the RPC must not retain an obsolete RAM YAML path');
assert.match(source, /^const CONFIG_NAME = 'adguardhome';$/m,
	'the RPC must read the single lowercase UCI package');
assert.match(source, /^const CONFIG_SECTION = 'config';$/m,
	'the RPC must read official core settings from config');
assert.match(source, /^const LUCI_SECTION = 'luci';$/m,
	'the RPC must read plugin settings from luci');
assert.doesNotMatch(source, /'AdGuardHome'\s*,\s*'AdGuardHome'/,
	'the RPC must not read the removed mixed-case UCI package');
const configPathSource = extractFunction('config_path');
assert.doesNotMatch(configPathSource,
	/work_dir\s*=\s*MEMORY_WORK_DIRECTORY/,
	'config_path must never select the RAM work directory for YAML');
assert.doesNotMatch(configPathSource, /memory_namespace/,
	'a stale data-only RAM namespace must not independently hide persistent YAML');

assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), true,
	'a valid version=4 data-only RAM generation and both bind aliases should be active');
assert.equal(api.config_path(), PERSISTENT_CONFIG,
	'valid RAM mode must keep YAML in the persistent work directory');
assert.equal(api.service_status().memory_active, true,
	'the independent RAM state validator should report the active generation');

fixture.visibleDataInode = 53;
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a work_dir/data mount which does not resolve to the RAM data inode must fail closed');
fixture.visibleDataInode = fixture.memoryDataInode;

fixture.persistentDataInode = 44;
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a backing-data alias which no longer matches the recorded persistent inode must fail closed');
fixture.persistentDataInode = fixture.statePersistentDataInode;

fixture.stateMemoryDataInode = 53;
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a state record which no longer matches the RAM data inode must fail closed');
fixture.stateMemoryDataInode = fixture.memoryDataInode;

fixture.requested = '0';
fixture.cursorReads = 0;
let status = api.service_status();
assert.equal(fixture.cursorReads, 1,
	'each status request must use one UCI cursor for requested and active state');
assert.equal(status.memory_requested, false);
assert.equal(status.memory_active, true,
	'memory_active must not be derived from the requested checkbox');

fixture.requested = '1';
fixture.entries = [ 'data', 'AdGuardHome.yaml' ];
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a YAML file or any second top-level RAM work entry must invalidate RAM mode');
assert.equal(api.config_path(), PERSISTENT_CONFIG,
	'corrupt RAM data must not hide the independently bound persistent YAML');
status = api.service_status();
assert.equal(status.memory_requested, true);
assert.equal(status.memory_active, false,
	'a requested checkbox must not manufacture an active RAM state');

fixture.entries = [];
fixture.dataPresent = false;
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'a missing RAM data directory must invalidate the data generation');
assert.equal(api.config_path(), PERSISTENT_CONFIG,
	'missing RAM data must keep persistent YAML available');

fixture.configFile = `${PERSISTENT_WORK_DIR}/other.yaml`;
assert.equal(api.config_path(), null,
	'a mismatched config_file must fail closed');
assert.equal(api.service_status().memory_active, false,
	'a mismatched config_file must not report RAM mode active');

fixture.configFile = `${MEMORY_WORK_DIR}/AdGuardHome.yaml`;
assert.equal(api.config_path(), null,
	'a YAML path in RAM must remain unavailable');

fixture.entries = [ 'data' ];
fixture.dataPresent = true;
fixture.configFile = PERSISTENT_CONFIG;
fixture.version = 3;
assert.equal(api.memory_state_active(PERSISTENT_WORK_DIR), false,
	'an obsolete state record must not activate the data-only layout');

fixture.version = 4;
fixture.workDir = CUSTOM_WORK_DIR;
fixture.configFile = CUSTOM_CONFIG;
assert.equal(api.config_path(), CUSTOM_CONFIG,
	'an exact single-UCI binding may anchor a validated custom persistent work directory');

fixture.symlinkPath = '/mnt/storage';
assert.equal(api.config_path(), null,
	'a symlink ancestor must invalidate a custom persistent YAML namespace');

fixture.symlinkPath = null;
fixture.writablePath = '/mnt/storage';
assert.equal(api.config_path(), null,
	'a writable mount ancestor must invalidate a custom persistent YAML namespace');

fixture.writablePath = null;
fixture.workDir = '/mnt/storage/../AdGuardHome';
fixture.configFile = `${fixture.workDir}/AdGuardHome.yaml`;
assert.equal(api.config_path(), null,
	'path traversal must remain invalid even with an exact single-UCI binding');

fixture.workDir = MEMORY_WORK_DIR;
fixture.configFile = `${MEMORY_WORK_DIR}/AdGuardHome.yaml`;
assert.equal(api.config_path(), null,
	'the internal RAM directory must never become the configured work_dir');
assert.equal(api.service_status().memory_active, false,
	'an invalid work_dir must return boolean false, not null');

fixture.workDir = PERSISTENT_WORK_DIR;
fixture.configFile = PERSISTENT_CONFIG;
for (const value of [ '1', 'ON', 'true', 'Yes', 'enabled' ]) {
	fixture.requested = value;
	assert.equal(api.service_status().memory_requested, true,
		`status must reuse the settings boolean parser for ${value}`);
}
for (const value of [ '0', 'OFF', 'false', 'No', 'disabled', '', undefined ]) {
	fixture.requested = value;
	assert.equal(api.service_status().memory_requested, false,
		`status must reject a disabled or invalid memory request: ${value}`);
}

console.log('2.4 single-UCI data-only RPC memory layout contract tests passed');
