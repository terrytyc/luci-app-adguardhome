'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const rpcPath = path.join(packageRoot, 'root/usr/share/rpcd/ucode/luci.adguardhome');
const source = fs.readFileSync(rpcPath, 'utf8');

const extractFunction = require('./lib/source').extractFunction.bind(null, source);

const functions = [
	'configured_boolean', 'configuration_state', 'service_running', 'service_status',
	'same_inode', 'read_yaml', 'read_config', 'credentials_info', 'update_credentials', 'reset_yaml',
	'yaml_scalar', 'yaml_config_values', 'yaml_section_value',
	'valid_port', 'yaml_bool', 'valid_dns_name', 'http_port', 'yaml_material_value',
	'tls_material_complete', 'config_info', 'probe_overview', 'overview_info',
	'root_private_temporary_file', 'root_private_lock_file', 'scan_yaml_jobs',
	'parse_yaml_job_state', 'mark_yaml_job_indeterminate',
].map(extractFunction).join('\n')
	.replace(/for \(let (\w+) in (.+)\)/g, 'for (let $1 of $2)');

const fixture = {};
function reset() {
	Object.assign(fixture, {
		workDir: '/etc/AdGuardHome', configFile: '/etc/AdGuardHome/AdGuardHome.yaml',
		requested: '0', active: false, running: true, locked: false,
		redirect: 'dnsmasq-upstream', integration: 0, integrationProbes: [],
		busy: false, unsafeLock: false, closeSucceeds: true, throwRead: false,
		jobEntries: [], jobRecords: {}, temporaryMetadata: null,
		maintenanceMetadata: { type: 'file', uid: 0, gid: 0, mode: 0o600, nlink: 1, size: 0 },
		recoverySucceeds: true, recoveries: [],
		yaml: 'dns:\n  port: 53335\nhttp:\n  address: 0.0.0.0:3000\n',
		listening: [ 3000 ], reads: 0, cursors: 0, serviceCalls: 0,
		jobChecks: 0, locks: 0, closes: 0, probes: [], hashes: 0,
		badInode: false, badDevice: false, badSize: false, fileCloseSucceeds: true,
		hashUnavailable: false, connectionUnavailable: false, serviceFailure: false,
		emptyService: false,
		probeCalls: [], probeFailure: null, probeOutput: null, probeCloses: 0,
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
	YAML_JOB_DIRECTORY: '/var/run/luci-app-adguardhome-yaml',
	YAML_MAINTENANCE_MARKER: '/var/run/luci-app-adguardhome-yaml/removing',
	YAML_JOB_STATE_LIMIT: 256,
	TEMPLATE_DIRECTORY: '/usr/share/luci-app-adguardhome',
	core_version: () => 'AdGuard Home, version v0.107.76',
	readfile: pathname => pathname === '/usr/share/luci-app-adguardhome/version' ? '3.0.0-r6\n' : null,
	type: value => value == null ? 'null' : Array.isArray(value) ? 'array' : Number.isInteger(value) ? 'int' : typeof value,
	push: (values, value) => values.push(value),
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
					'luci.redirect': fixture.redirect,
				}[`${section}.${option}`];
			},
			unload() {},
		};
	},
	connect() {
		if (fixture.connectionUnavailable)
			return null;
		return {
			call(object, method, args) {
				assert.equal(object, 'service');
				assert.equal(method, 'list');
				assert.equal(args.name, 'adguardhome');
				fixture.serviceCalls++;
				if (fixture.serviceFailure)
					throw new Error('service lookup failed');
				if (fixture.emptyService)
					return {};
				return { adguardhome: { instances: { adguardhome: { running: fixture.running } } } };
			},
			disconnect() {},
		};
	},
	config_path: () => fixture.configFile,
	lstat(pathname) {
		if (pathname === fixture.configFile)
			return metadata();
		if (pathname === '/var/run/luci-app-adguardhome-yaml/removing')
			return fixture.maintenanceMetadata;
		if (pathname.startsWith('/var/run/luci-app-adguardhome-yaml/.'))
			return fixture.temporaryMetadata;
		return null;
	},
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
		fixture.locked = !fixture.busy && !fixture.unsafeLock;
		return { file: fixture.locked ? {} : null };
	},
	lsdir(pathname) {
		assert.equal(pathname, '/var/run/luci-app-adguardhome-yaml');
		assert.equal(fixture.locked, true, 'job state must only be queried while holding the lock');
		fixture.jobChecks++;
		return fixture.jobEntries;
	},
	read_yaml_job(token) {
		return fixture.jobRecords[token] ?? null;
	},
	replace_yaml_job(token, content) {
		assert.equal(fixture.locked, true, 'orphan recovery must hold the exclusive task lock');
		fixture.recoveries.push(token);
		if (fixture.recoverySucceeds)
			fixture.jobRecords[token] = sandbox.parse_yaml_job_state(content);
		return fixture.recoverySucceeds;
	},
	remove_yaml_stage() { assert.fail('read ACL overview must never remove a YAML stage'); },
	unlink() { assert.fail('overview must leave file cleanup to the next write operation'); },
	close_yaml_job_lock() {
		fixture.closes++;
		fixture.locked = false;
		return fixture.closeSucceeds;
	},
	popen(command, mode) {
		assert.equal(fixture.locked, true, 'the combined probe must hold the task lock');
		assert.equal(mode, 'r');
		const args = command.match(/^\/etc\/init\.d\/AdGuardHome overview_status (\d+) (none|redirect|dnsmasq-upstream|unknown) (\d+) (\d+) 2>\/dev\/null$/);
		assert.ok(args, 'the shell command may contain only validated ports and a fixed mode');
		const [ dns, redirect, https, http ] = args.slice(1);
		fixture.probeCalls.push(args.slice(1));
		if (fixture.probeFailure === 'open')
			return null;
		if (Number(dns) && redirect !== 'unknown')
			fixture.integrationProbes.push([ dns, redirect ]);
		for (const port of [ https, http ])
			if (Number(port)) fixture.probes.push(Number(port));
		const integration = !Number(dns) || redirect === 'unknown' ? 'unknown' :
			fixture.integration === 0 ? redirect === 'none' ? 'none' : 'ready' :
			fixture.integration === 1 ? 'pending' : 'unknown';
		return {
			read(limit) {
				assert.equal(limit, 128, 'combined status output must remain bounded');
				if (fixture.probeFailure === 'read') throw new Error('probe read failed');
				return fixture.probeOutput ?? `integration=${integration}\nhttps=${fixture.listening.includes(Number(https)) ? 1 : 0}\nhttp=${fixture.listening.includes(Number(http)) ? 1 : 0}\n`;
			},
			close() {
				fixture.probeCloses++;
				return fixture.probeFailure === 'exit' ? 2 : 0;
			},
		};
	},
};
vm.createContext(sandbox);
const methodsSource = source.slice(source.indexOf('const methods = {'),
	source.indexOf("\nreturn { 'luci.adguardhome': methods };"));
vm.runInContext(`${functions}\n${methodsSource}\nthis.rpc = methods; this.overview = overview_info;`,
	sandbox, { filename: rpcPath });

let result = sandbox.overview();
assert.equal(sandbox.rpc.get_version.call().plugin_version, '3.0.0-r6');
assert.equal(result.status.running, true);
assert.equal(result.status.memory_requested, false);
assert.equal(result.status.memory_active, false);
assert.equal(result.status.dns_integration, 'ready');
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
assert.equal(fixture.probeCalls.length, 1, 'Web and DNS status must use one init process');
assert.deepEqual(Array.from(fixture.integrationProbes[0]), [ '53335', 'dnsmasq-upstream' ]);
fixture.integration = 1;
assert.equal(sandbox.overview().status.dns_integration, 'pending');
fixture.integration = 2;
assert.equal(sandbox.overview().status.dns_integration, 'unknown');
fixture.redirect = 'none';
fixture.integration = 0;
assert.equal(sandbox.overview().status.dns_integration, 'none');
fixture.running = false;
result = sandbox.overview();
assert.equal(result.status.dns_integration, 'none', 'none requires no core listener');
assert.equal(result.config.web, null, 'a stopped core must not advertise its Web UI');
fixture.busy = true;
assert.equal(sandbox.overview().status.dns_integration, 'unknown',
	'none must still respect the shared transaction lock');
fixture.busy = false;
fixture.jobEntries = [ 'removing' ];
assert.equal(sandbox.overview().status.dns_integration, 'unknown',
	'none must not probe during package maintenance');
for (const unavailable of [ 'connectionUnavailable', 'serviceFailure' ]) {
	reset();
	fixture[unavailable] = true;
	result = sandbox.overview();
	assert.equal(result.status.running, null, `${unavailable}: unknown is not stopped`);
	assert.equal(result.config.web, null);
	assert.deepEqual(fixture.integrationProbes, []);
}
reset();
fixture.emptyService = true;
assert.equal(sandbox.overview().status.running, false,
	'a successful lookup with no instance means stopped');
reset();
sandbox.overview();

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
assert.equal(fixture.probeCalls.length, 1, 'HTTPS, HTTP fallback and DNS must share one init process');

fixture.listening = [ 1029, 3000 ];
assert.equal(sandbox.overview().config.web.scheme, 'https', 'a listening HTTPS candidate must take precedence');
fixture.yaml += '  force_https: true\n';
fixture.listening = [ 3000 ];
assert.equal(sandbox.overview().config.web, null, 'forced HTTPS must never fall back to HTTP');
assert.equal(fixture.probeCalls[fixture.probeCalls.length - 1][3], '0', 'forced HTTPS must not request an HTTP probe');

for (const failure of [ 'open', 'read', 'exit' ]) {
	reset();
	fixture.probeFailure = failure;
	const failed = sandbox.overview();
	assert.equal(failed.status.running, true);
	assert.equal(failed.config.dns_port, 53335);
	assert.equal(failed.status.dns_integration, 'unknown');
	assert.equal(failed.config.web, null, `${failure}: failed combined probes must not advertise endpoints`);
	assert.equal(fixture.probeCloses, failure === 'open' ? 0 : 1);
}
for (const output of [ '', 'integration=ready\nhttps=0\nhttp=1\nextra',
	'integration=invalid\nhttps=0\nhttp=1\n', 'integration=ready\nhttps=0\nhttp=2\n' ]) {
	reset();
	fixture.probeOutput = output;
	const failed = sandbox.overview();
	assert.equal(failed.status.dns_integration, 'unknown', 'malformed output must fail closed');
	assert.equal(failed.config.web, null);
}
reset();
fixture.redirect = 'none; injected-command';
assert.equal(sandbox.overview().config.web.port, 3000, 'invalid DNS mode may still expose a verified Web endpoint');
assert.equal(fixture.probeCalls[0][1], 'unknown', 'untrusted redirect bytes must never enter a shell command');
reset();
fixture.yaml = 'http:\n  address: 0.0.0.0:3000\n';
result = sandbox.overview();
assert.equal(result.config.web.port, 3000, 'unavailable DNS port must not suppress an independent Web probe');
assert.equal(result.status.dns_integration, 'unknown');
assert.equal(fixture.probeCalls[0][0], '0');

for (const gate of [ 'busy', 'unsafeLock', 'stopped' ]) {
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

const jobToken = 'a'.repeat(32);
const orphan = state => ({ state, expected_hash: 'b'.repeat(64), candidate_hash: 'c'.repeat(64) });
for (const state of [ 'pending', 'running' ]) {
	reset();
	fixture.jobEntries = [ jobToken ];
	fixture.jobRecords[jobToken] = orphan(state);
	result = sandbox.overview();
	assert.equal(result.config.web.port, 3000, `${state}: a free lock permits recovery and probing`);
	assert.equal(result.status.dns_integration, 'ready');
	assert.equal(fixture.jobRecords[jobToken].state, 'indeterminate',
		'recovery must never infer transaction success from current service state');
	assert.deepEqual(fixture.recoveries, [ jobToken ]);
	assert.equal(sandbox.overview().config.web.port, 3000);
	assert.deepEqual(fixture.recoveries, [ jobToken ], 'later polls must preserve the terminal record');
}

const temporary = `.${jobToken}.rpcd-${'d'.repeat(32)}`;
for (const gate of [ 'busy', 'unsafeLock', 'maintenance', 'unsafe-marker', 'unsafe-entry',
	'invalid-record', 'unavailable-directory', 'unsafe-temporary', 'recovery-failure' ]) {
	reset();
	fixture.jobEntries = [ jobToken ];
	fixture.jobRecords[jobToken] = orphan('running');
	if (gate === 'busy' || gate === 'unsafeLock')
		fixture[gate] = true;
	else if (gate === 'maintenance' || gate === 'unsafe-marker') {
		fixture.jobEntries.push('removing');
		if (gate === 'unsafe-marker')
			fixture.maintenanceMetadata.mode = 0o644;
	}
	else if (gate === 'unsafe-entry')
		fixture.jobEntries.push('unexpected');
	else if (gate === 'invalid-record')
		fixture.jobRecords[jobToken] = null;
	else if (gate === 'unavailable-directory')
		fixture.jobEntries = null;
	else if (gate === 'unsafe-temporary') {
		fixture.jobEntries.push(temporary);
		fixture.temporaryMetadata = { type: 'link' };
	}
	else
		fixture.recoverySucceeds = false;
	result = sandbox.overview();
	assert.equal(result.config.web, null, `${gate}: no endpoint should be advertised`);
	assert.equal(result.status.dns_integration, 'unknown');
	assert.deepEqual(fixture.probes, []);
	assert.deepEqual(fixture.recoveries, gate === 'recovery-failure' ? [ jobToken ] : [],
		`${gate}: an unsafe or active task must never be recovered`);
	if (fixture.jobRecords[jobToken])
		assert.equal(fixture.jobRecords[jobToken].state, 'running');
}

reset();
fixture.jobEntries = [ temporary ];
fixture.temporaryMetadata = { type: 'file', uid: 0, gid: 0, mode: 0o600, nlink: 1, size: 0 };
assert.equal(sandbox.overview().config.web.port, 3000,
	'an abandoned safe temporary task record must not suppress the management link');
assert.deepEqual(fixture.jobEntries, [ temporary ], 'overview leaves temporary-file cleanup to a write request');

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
assert.equal(fixture.hashes, 0, 'the overview RPC must use the hashless reader');
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
assert.equal(restored.sha256, undefined, 'reset must not return an unused template revision');
assert.equal(fixture.hashes, 3, 'reset verifies only the active revision; it does not hash the template');
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
for (const unused of [ 'get_status', 'get_config_info' ]) {
	assert.equal(sandbox.rpc[unused], undefined);
	assert.ok(!acl['luci-app-adguardhome'].read.ubus['luci.adguardhome'].includes(unused));
}

console.log('single-snapshot overview RPC and locked endpoint probe tests passed');
