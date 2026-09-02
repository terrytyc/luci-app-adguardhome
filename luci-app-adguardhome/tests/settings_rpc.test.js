'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
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
	'CONFIG_NAME',
	'CONFIG_SECTION',
	'LUCI_SECTION',
	'CONFIG_FILENAME',
	'MAX_MEMORY_WRITEBACK_INTERVAL',
].map(extractConstant).join('\n');
const functions = [
	'valid_work_dir',
	'configured_boolean',
	'configured_interval',
	'settings_revision',
	'settings_snapshot',
	'settings_candidate',
].map(extractFunction).join('\n')
	.replace('for (let component in components)',
		'for (let component of components)');

const fixture = {
	enabled: '1',
	configFile: '/etc/AdGuardHome/AdGuardHome.yaml',
	workDir: '/etc/AdGuardHome',
	verbose: '0',
	redirect: 'dnsmasq-upstream',
	runFromMemory: '0',
	interval: '60',
};

function cursor() {
	return {
		get(config, section, option) {
			return {
				'adguardhome.config.enabled': fixture.enabled,
				'adguardhome.config.config_file': fixture.configFile,
				'adguardhome.config.work_dir': fixture.workDir,
				'adguardhome.config.verbose': fixture.verbose,
				'adguardhome.luci.redirect': fixture.redirect,
				'adguardhome.luci.run_from_memory': fixture.runFromMemory,
				'adguardhome.luci.memory_writeback_interval': fixture.interval,
			}[`${config}.${section}.${option}`];
		},
		unload() {},
	};
}

const sandbox = {
	type(value) {
		if (typeof value === 'boolean')
			return 'bool';
		if (Number.isInteger(value))
			return 'int';
		if (value === null)
			return 'null';
		return typeof value;
	},
	lc: value => value.toLowerCase(),
	match: (value, expression) => value.match(expression),
	int: value => Math.trunc(Number(value)),
	length: value => value.length,
	split: (value, separator) => value.split(separator),
	substr: (value, start, count) => value.substr(start, count),
	lstat(pathname) {
		if (pathname === '/etc')
			return { type: 'directory', uid: 0, gid: 0, mode: 0o755 };
		if (pathname === '/etc/AdGuardHome')
			return { type: 'directory', uid: 853, gid: 853, mode: 0o700 };
		return null;
	},
	sha256: value => crypto.createHash('sha256').update(value).digest('hex'),
	cursor,
};
vm.createContext(sandbox);
vm.runInContext(`${constants}\n${functions}\nthis.api = {
	settings_snapshot,
	settings_candidate,
};`, sandbox, { filename: rpcPath });

const snapshot = sandbox.api.settings_snapshot();
assert.equal(snapshot.enabled, true);
assert.equal(snapshot.config_file, undefined,
	'config_file must remain an internal value derived from work_dir');
assert.equal(snapshot.work_dir, fixture.workDir);
assert.equal(snapshot.verbose, false);
assert.equal(snapshot.redirect, fixture.redirect);
assert.equal(snapshot.run_from_memory, false);
assert.equal(snapshot.memory_writeback_interval, 60);
assert.match(snapshot.revision, /^[0-9a-f]{64}$/);
fixture.configFile = '/etc/AdGuardHome/other.yaml';
assert.equal(sandbox.api.settings_snapshot(), null,
	'a hand-edited official config_file inconsistent with work_dir must fail closed');
fixture.configFile = '/etc/AdGuardHome/AdGuardHome.yaml';

const candidate = sandbox.api.settings_candidate(
	true,
	fixture.workDir,
	false,
	fixture.redirect,
	true,
	120
);
assert.equal(candidate.run_from_memory, true);
assert.equal(candidate.memory_writeback_interval, 120);
assert.match(candidate.revision, /^[0-9a-f]{64}$/);
assert.equal(candidate.config_file, undefined,
	'the settings candidate must not accept or expose config_file');
assert.equal(candidate.revision, crypto.createHash('sha256').update(
	`enabled=1\n` +
	`config_file=${fixture.workDir}/AdGuardHome.yaml\n` +
	`work_dir=${fixture.workDir}\n` +
	`verbose=0\n` +
	`redirect=${fixture.redirect}\n` +
	`run_from_memory=1\n` +
	`memory_writeback_interval=120\n`
).digest('hex'), 'the revision must derive config_file from work_dir');
assert.equal(sandbox.api.settings_candidate(
	true,
	'/tmp/AdGuardHome',
	false,
	fixture.redirect,
	false,
	60
), null, 'volatile work_dir values must fail closed');
assert.equal(sandbox.api.settings_candidate(
	true,
	fixture.workDir,
	false,
	fixture.redirect,
	false,
	10081
), null, 'oversized write-back intervals must fail closed');

const updateSource = extractFunction('update_settings');
assert.match(updateSource,
	/prepare_yaml_job\(token, expected_revision, candidate\.revision\)/,
	'settings and YAML transactions must share one job lock');
assert.match(updateSource,
	/let locked_current = settings_snapshot\(\);[\s\S]*?locked_current\.revision != expected_revision[\s\S]*?discard_yaml_job\(token\)[\s\S]*?close_yaml_job_lock\(\{ file: job\.lock \}\)/,
	'the settings revision must be rechecked and stale job state removed while holding the shared lock');
assert.match(updateSource,
	/uloop\.process\(YAML_UPDATE_COMMAND, \[\s*'settings_update'/,
	'settings must be applied asynchronously through the coordinator command');
assert.match(updateSource,
	/`\$\{candidate\.memory_writeback_interval\}`,\s*expected_revision,\s*token,\s*candidate\.revision,\s*\], \{ PATH:/,
	'the coordinator must receive the CAS revision and one-shot job credential');
assert.match(updateSource,
	/function\(\) \{\s*finish_settings_process\(\s*token, expected_revision, candidate\.revision, job\.lock/,
	'the process callback must not forward or interpret a raw wait status');
assert.doesNotMatch(updateSource, /system\(|popen\(|\/bin\/sh|uci\.(?:set|commit)/,
	'the RPC transaction must not use a shell or commit UCI itself');
assert.doesNotMatch(source, /uci\.(?:set|commit)\(/,
	'the RPC backend must remain read-only with respect to UCI');
assert.doesNotMatch(source, /function settings_process_succeeded\(/,
	'raw wait status must never be treated as settings convergence proof');

assert.match(source,
	/function update_settings\(enabled, work_dir, verbose, redirect,\s*run_from_memory, interval, expected_revision\)/,
	'the settings update API must derive config_file instead of accepting it');
const setSettingsStart = source.indexOf('\tset_settings: {');
const setSettingsEnd = source.indexOf('\tget_settings_update: {', setSettingsStart);
assert.ok(setSettingsStart >= 0 && setSettingsEnd > setSettingsStart);
const setSettingsMethod = source.slice(setSettingsStart, setSettingsEnd);
assert.doesNotMatch(setSettingsMethod, /config_file/,
	'the set_settings RPC schema and call must not expose config_file');
assert.doesNotMatch(source, /\bget_password_info\s*:/,
	'the unused legacy password information RPC must be removed');
assert.doesNotMatch(source, /\bset_password\s*:/,
	'the unused legacy password update RPC must be removed');

const finishSettingsSource = extractFunction('finish_settings_process');
assert.doesNotMatch(finishSettingsSource,
	/settings_snapshot|service_running|exitcode|\.code|\.signal|settings_process_succeeded/,
	'the callback may only trust the init-written authenticated terminal record');
assert.match(finishSettingsSource,
	/^function finish_settings_process\(token, expected_hash, candidate_hash,\s*held_lock\)/,
	'the callback signature must not accept a process wait status');

const expectedHash = '1'.repeat(64);
const candidateHash = '2'.repeat(64);
const token = '3'.repeat(32);
let record;
let replacements;
let closes;
const finishSandbox = {
	read_yaml_job() { return record; },
	replace_yaml_job(jobToken, content) {
		replacements.push({ token: jobToken, content });
		return true;
	},
	close_yaml_job_lock() {
		closes++;
		return true;
	},
};
vm.createContext(finishSandbox);
vm.runInContext(`${finishSettingsSource}\nthis.finish = finish_settings_process;`,
	finishSandbox, { filename: rpcPath });

record = {
	state: 'success',
	sha256: candidateHash,
	expected_hash: expectedHash,
	candidate_hash: candidateHash,
};
replacements = [];
closes = 0;
finishSandbox.finish(token, expectedHash, candidateHash, {});
assert.deepEqual(replacements, [],
	'a valid init-written success terminal must survive callback completion');
assert.equal(closes, 1);

record = {
	state: 'running',
	expected_hash: expectedHash,
	candidate_hash: candidateHash,
};
replacements = [];
closes = 0;
finishSandbox.finish(token, expectedHash, candidateHash, {});
assert.deepEqual(replacements, [{
	token,
	content: `indeterminate:${expectedHash}:${candidateHash}\n`,
}], 'a killed coordinator without a terminal marker must be indeterminate');
assert.equal(closes, 1);

record = null;
replacements = [];
closes = 0;
finishSandbox.finish(token, expectedHash, candidateHash, {});
assert.deepEqual(replacements, [{
	token,
	content: `indeterminate:${expectedHash}:${candidateHash}\n`,
}], 'a missing terminal marker must never become success');
assert.equal(closes, 1);
assert.match(source, /get_settings:\s*\{/);
assert.match(source, /set_settings:\s*\{/);
assert.match(source, /get_settings_update:\s*\{/);

console.log('2.4 asynchronous RPC settings transaction tests passed');
