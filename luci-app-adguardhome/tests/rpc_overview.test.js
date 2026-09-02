'use strict';

const assert = require('node:assert/strict');
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
	'read_config', 'yaml_scalar', 'yaml_config_values', 'yaml_section_value',
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
		jobChecks: 0, locks: 0, closes: 0, probes: [],
	});
}
reset();

const sandbox = {
	CONFIG_NAME: 'adguardhome', CONFIG_SECTION: 'config', LUCI_SECTION: 'luci',
	CONFIG_FILENAME: 'AdGuardHome.yaml', SERVICE_NAME: 'adguardhome',
	INSTANCE_NAME: 'adguardhome', YAML_UPDATE_COMMAND: '/etc/init.d/AdGuardHome',
	type: value => Number.isInteger(value) ? 'int' : typeof value,
	lc: value => value.toLowerCase(), match: (value, expression) => value.match(expression),
	int: value => Math.trunc(Number(value)), length: value => value?.length ?? 0,
	split: (value, separator) => value.split(separator),
	substr: (value, start, count) => value.substr(start, count),
	trim: value => value.trim(), replace: (value, pattern, replacement) => value.replace(pattern, replacement),
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
	read_yaml(configuration) {
		fixture.reads++;
		if (fixture.throwRead)
			throw new Error('read failed');
		assert.equal(configuration.work_dir, configuration.path ? fixture.workDir : null);
		return configuration.path ? { content: fixture.yaml } : null;
	},
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
vm.runInContext(`${functions}\nthis.overview = overview_info;`, sandbox, { filename: rpcPath });

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

const acl = JSON.parse(fs.readFileSync(path.join(packageRoot,
	'root/usr/share/rpcd/acl.d/luci-app-adguardhome.json'), 'utf8'));
assert.ok(acl['luci-app-adguardhome'].read.ubus['luci.adguardhome'].includes('get_overview'));
assert.match(source, /get_overview:\s*\{\s*call: function\(\) \{\s*return overview_info\(\);/);
assert.match(source, /get_config_info:\s*\{\s*call: function\(\) \{\s*return overview_info\(\)\.config;/,
	'the existing config-info API must share the same safe implementation');

console.log('single-snapshot overview RPC and locked endpoint probe tests passed');
