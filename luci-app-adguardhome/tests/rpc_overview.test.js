'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const rpcPath = path.join(packageRoot, 'root/usr/share/rpcd/ucode/luci.adguardhome');
const source = fs.readFileSync(rpcPath, 'utf8');

function extractFunction(name) {
	const start = source.indexOf(`function ${name}(`);
	assert.notEqual(start, -1, `missing ${name}()`);
	const next = source.indexOf('\nfunction ', start + 1);
	return source.slice(start, next);
}

const functions = [
	'configured_boolean', 'configuration_state', 'service_running', 'service_status',
	'same_inode', 'read_yaml', 'read_config', 'credentials_info', 'update_credentials', 'reset_yaml',
	'yaml_scalar', 'yaml_config_values', 'yaml_section_value',
	'valid_port', 'yaml_bool', 'valid_dns_name', 'http_port', 'yaml_material_value',
	'tls_material_complete', 'web_port_listening', 'config_info', 'overview_info',
].map(extractFunction).join('\n')
	.replace(/for \(let (\w+) in (.+)\) \{/g, 'for (let $1 of $2) {');

const fixture = {};
function reset() {
	Object.assign(fixture, {
		workDir: '/etc/AdGuardHome', configFile: '/etc/AdGuardHome/AdGuardHome.yaml',
		requested: '0', active: false, running: true, locked: false,
		busy: false, jobActive: false, closeSucceeds: true, throwRead: false,
		yaml: 'dns:\n  port: 53335\nhttp:\n  address: 0.0.0.0:3000\n',
		listening: [ 3000 ], reads: 0, cursors: 0, serviceCalls: 0,
		jobChecks: 0, locks: 0, closes: 0, probes: [], hashes: 0,
		badInode: false, badDevice: false, badSize: false, fileCloseSucceeds: true,
		hashUnavailable: false,
	});
}
reset();

function metadata() {
	return { type: 'file', inode: 31, size: fixture.yaml.length, dev: { major: 8, minor: 1 } };
}
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const template = 'users:\n  - name: admin\n    password: template-hash\ndns:\n  port: 53335\n';

const sandbox = {
	CONFIG_NAME: 'adguardhome', CONFIG_SECTION: 'config', LUCI_SECTION: 'luci',
	CONFIG_FILENAME: 'AdGuardHome.yaml', SERVICE_NAME: 'adguardhome',
	INSTANCE_NAME: 'adguardhome', YAML_UPDATE_COMMAND: '/etc/init.d/AdGuardHome',
	MAX_CONFIG_LENGTH: 512 * 1024,
	type: value => Number.isInteger(value) ? 'int' : typeof value,
	lc: value => value.toLowerCase(), match: (value, expression) => value.match(expression),
	int: value => Math.trunc(Number(value)), length: value => value?.length ?? 0,
	split: (value, separator) => value.split(separator),
	substr: (value, start, count) => value.substr(start, count),
	trim: value => value.trim(), replace: (value, pattern, replacement) => value.replace(pattern, replacement),
	// These fixtures use canonical addresses; the native ucode parser test
	// covers iptoarr()/arrtoip() normalization and mapped/scoped IPv6 addresses.
	iptoarr: value => value, arrtoip: value => value,
	valid_work_dir: value => value === fixture.workDir ? value : null,
	memory_state_active: () => fixture.active,
	cursor() {
		fixture.cursors++;
		return {
			get(_config, section, option) {
				return {
					'config.work_dir': fixture.workDir, 'config.config_file': fixture.configFile,
					'luci.run_from_memory': fixture.requested,
				}[`${section}.${option}`];
			},
			unload() {},
		};
	},
	connect() {
		return {
			call(object, method, args) {
				assert.equal(object, 'service');
				assert.equal(method, 'list');
				assert.equal(args.name, 'adguardhome');
				fixture.serviceCalls++;
				return { adguardhome: { instances: { adguardhome: { running: fixture.running } } } };
			},
			disconnect() {},
		};
	},
	config_path: () => fixture.configFile,
	lstat: pathname => pathname === fixture.configFile ? metadata() : null,
	stat(pathname) {
		assert.equal(pathname, '/proc/self/fd/42');
		const value = metadata();
		if (fixture.badInode)
			value.inode++;
		if (fixture.badDevice)
			value.dev.minor++;
		if (fixture.badSize)
			value.size++;
		return value;
	},
	open(pathname, mode) {
		assert.equal(pathname, fixture.configFile);
		assert.equal(mode, 'r');
		return {
			fileno: () => 42,
			read(limit) {
				assert.equal(limit, 512 * 1024 + 1);
				fixture.reads++;
				if (fixture.throwRead)
					throw new Error('read failed');
				return fixture.yaml;
			},
			close: () => fixture.fileCloseSucceeds,
		};
	},
	sha256(content) {
		fixture.hashes++;
		return fixture.hashUnavailable ? null : digest(content);
	},
	credential_record: () => ({ username: 'admin' }),
	read_template: () => template,
	open_yaml_job_lock() {
		fixture.locks++;
		fixture.locked = !fixture.busy;
		return { file: fixture.locked ? {} : null };
	},
	yaml_job_active() {
		assert.equal(fixture.locked, true, 'job state must only be queried while holding the lock');
		fixture.jobChecks++;
		return fixture.jobActive;
	},
	close_yaml_job_lock() {
		fixture.closes++;
		fixture.locked = false;
		return fixture.closeSucceeds;
	},
	system(args) {
		assert.equal(fixture.locked, true, 'every core endpoint probe must hold the same job lock');
		assert.equal(args[0], '/etc/init.d/AdGuardHome');
		assert.equal(args[1], 'web_listening');
		const port = Number(args[2]);
		fixture.probes.push(port);
		return fixture.listening.includes(port) ? 0 : 1;
	},
};
vm.createContext(sandbox);
const methodsSource = source.slice(source.indexOf('const methods = {'),
	source.indexOf("\nreturn { 'luci.adguardhome': methods };"));
vm.runInContext(`${functions}\n${methodsSource}\nthis.rpc = methods; this.overview = overview_info;`,
	sandbox, { filename: rpcPath });

let result = sandbox.overview();
assert.equal(result.status.running, true);
assert.equal(result.status.memory_requested, false);
assert.equal(result.status.memory_active, false);
assert.equal(result.config.dns_port, 53335);
assert.equal(result.config.web.scheme, 'http');
assert.equal(result.config.web.host, null);
assert.equal(result.config.web.port, 3000);
assert.equal(fixture.cursors, 1, 'status and YAML path must share one UCI cursor');
assert.equal(fixture.serviceCalls, 1, 'status and endpoint gate must share one service lookup');
assert.equal(fixture.reads, 1, 'the YAML must be read once per request');
assert.equal(fixture.hashes, 0, 'overview must not calculate an unused YAML revision');
assert.equal(fixture.locks, 1);
assert.equal(fixture.closes, 1);
assert.equal(fixture.jobChecks, 1);
assert.deepEqual(fixture.probes, [ 3000 ]);

fixture.yaml = 'dns:\n  port: 5354\nhttp:\n  address: 0.0.0.0:3080\n';
fixture.listening = [ 3080 ];
fixture.requested = '1';
fixture.active = true;
result = sandbox.overview();
assert.equal(result.status.memory_requested, true);
assert.equal(result.status.memory_active, true);
assert.equal(result.config.dns_port, 5354, 'a new request must not reuse stale YAML values');
assert.equal(result.config.web.port, 3080);
assert.equal(fixture.cursors, 2);
assert.equal(fixture.serviceCalls, 2);
assert.equal(fixture.reads, 2);
assert.equal(fixture.hashes, 0, 'fresh polling must keep skipping the unused revision');

reset();
fixture.yaml += 'tls:\n  enabled: true\n  server_name: router.example.com\n' +
	'  port_https: 1029\n  certificate_path: /etc/cert.pem\n  private_key_path: /etc/key.pem\n';
result = sandbox.overview();
assert.deepEqual(fixture.probes, [ 1029, 3000 ], 'HTTPS failure may fall back to HTTP');
assert.equal(result.config.web.scheme, 'http');
assert.equal(fixture.locks, 1, 'fallback must reuse the same task lock');
assert.equal(fixture.jobChecks, 1, 'fallback must not rescan task records');
assert.equal(fixture.serviceCalls, 1, 'fallback must not re-query the core service');

for (const gate of [ 'busy', 'jobActive', 'stopped' ]) {
	reset();
	if (gate === 'stopped')
		fixture.running = false;
	else
		fixture[gate] = true;
	result = sandbox.overview();
	assert.equal(result.config.dns_port, 53335, `${gate}: YAML DNS port remains available`);
	assert.equal(result.config.web, null, `${gate}: no endpoint should be advertised`);
	assert.deepEqual(fixture.probes, [], `${gate}: rc.common must not be invoked`);
	assert.equal(fixture.closes, 1);
}

reset();
fixture.configFile = '/etc/AdGuardHome/other.yaml';
result = sandbox.overview();
assert.equal(result.config.dns_port, null, 'inconsistent UCI config_file must not be read');
assert.equal(result.config.web, null);
assert.deepEqual(fixture.probes, []);

reset();
fixture.throwRead = true;
result = sandbox.overview();
assert.equal(result.status.running, true, 'a failed YAML read must retain the measured service status');
assert.equal(result.config.web, null);
assert.equal(fixture.closes, 1, 'an exception must not leak the job lock');

reset();
fixture.closeSucceeds = false;
assert.equal(sandbox.overview().config.web, null, 'failed lock cleanup must hide the endpoint');

for (const failure of [ 'badInode', 'badDevice', 'badSize', 'fileCloseSucceeds' ]) {
	reset();
	fixture[failure] = failure !== 'fileCloseSucceeds';
	assert.equal(sandbox.overview().config.dns_port, null,
		`${failure}: hashless status reads must retain the checked-file boundary`);
	assert.equal(sandbox.rpc.get_yaml.call().error, 'YAML configuration is unavailable',
		`${failure}: editor reads must retain the same checked-file boundary`);
}

reset();
assert.equal(sandbox.rpc.get_overview.call().config.dns_port, 53335);
assert.equal(sandbox.rpc.get_config_info.call().dns_port, 53335);
assert.equal(fixture.hashes, 0, 'both status RPC entry points must use the hashless reader');
const editor = sandbox.rpc.get_yaml.call();
const originalHash = digest(fixture.yaml);
assert.equal(editor.sha256, originalHash, 'the editor must still receive its exact YAML revision');
assert.equal(editor.content, fixture.yaml);
assert.equal(fixture.hashes, 1);
const credentials = sandbox.rpc.get_credentials.call();
assert.equal(credentials.sha256, originalHash, 'credentials must retain a fresh CAS revision');
assert.equal(credentials.username, 'admin');
assert.equal(fixture.hashes, 2);
const restored = sandbox.rpc.reset_yaml.call({ args: { sha256: originalHash } });
assert.equal(restored.content, template);
assert.equal(restored.sha256, digest(template), 'reset must still hash the returned packaged template');
assert.equal(fixture.hashes, 4, 'reset verifies the active revision and hashes the template independently');
assert.equal(fixture.yaml, editor.content, 'reset must remain an editor-only operation');

fixture.yaml += '# external edit\n';
assert.equal(sandbox.rpc.reset_yaml.call({ args: { sha256: originalHash } }).error,
	'YAML changed since the page was loaded', 'reset must reject an outdated editor revision');
assert.equal(sandbox.rpc.set_credentials.call({ args: {
	username: 'operator', password_hash: '', sha256: originalHash,
} }).error, 'YAML changed since the credential dialog was opened',
'credential updates must reject the outdated revision before staging any write');
assert.equal(sandbox.rpc.get_yaml.call().sha256, digest(fixture.yaml),
	'the next editor read must return the new revision, not a cached hash');

reset();
fixture.hashUnavailable = true;
assert.equal(sandbox.rpc.get_overview.call().config.dns_port, 53335,
	'status must not depend on an unused digest');
assert.equal(fixture.hashes, 0);
assert.equal(sandbox.rpc.get_yaml.call().error, 'YAML configuration is unavailable',
	'an editor read must still fail closed if its required digest is unavailable');

const readConfigSource = extractFunction('read_config');
assert.match(readConfigSource, /read_yaml\(configuration, false\)/);
assert.equal((source.match(/read_yaml\([^)]*, false\)/g) ?? []).length, 1,
	'only the status-only reader may suppress hashing; editor/CAS paths keep the default');

const acl = JSON.parse(fs.readFileSync(path.join(packageRoot,
	'root/usr/share/rpcd/acl.d/luci-app-adguardhome.json'), 'utf8'));
assert.ok(acl['luci-app-adguardhome'].read.ubus['luci.adguardhome'].includes('get_overview'));
assert.match(source, /get_overview:\s*\{\s*call: function\(\) \{\s*return overview_info\(\);/);
assert.match(source, /get_config_info:\s*\{\s*call: function\(\) \{\s*return overview_info\(\)\.config;/,
	'the existing config-info API must share the same safe implementation');

console.log('single-snapshot overview RPC and locked endpoint probe tests passed');
