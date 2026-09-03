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
assert.doesNotMatch(updateSource, /candidate\.revision == current\.revision|unchanged/,
	'every Save & Apply must reach the coordinator even when values are unchanged');
assert.match(updateSource,
	/let locked_current = settings_snapshot\(\);[\s\S]*?locked_current\.revision != expected_revision[\s\S]*?discard_yaml_job\(token\)[\s\S]*?close_yaml_job_lock\(\{ file: job\.lock \}\)/,
	'the settings revision must be rechecked and stale job state removed while holding the shared lock');
assert.match(updateSource,
	/uloop\.process\(YAML_UPDATE_COMMAND, \[\s*'settings_update'/,
	'settings must be applied asynchronously through the coordinator command');
assert.match(updateSource,
	/`\$\{candidate\.memory_writeback_interval\}`,\s*expected_revision,\s*token,\s*candidate\.revision,\s*`\$\{job\.lock_descriptor\}`,\s*\], \{ PATH:/,
	'the coordinator must receive the CAS revision, one-shot credential and inherited lock descriptor');
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
assert.doesNotMatch(setSettingsMethod, /lock_descriptor/,
	'the public RPC must not accept the internal inherited lock descriptor');
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
let launchedArguments = null;
const launchSandbox = {
	type: sandbox.type,
	match: sandbox.match,
	settings_candidate: () => candidate,
	settings_snapshot: () => snapshot,
	random_token: () => token,
	prepare_yaml_job: () => ({ token, lock: {}, lock_descriptor: 193 }),
	YAML_UPDATE_COMMAND: '/etc/init.d/AdGuardHome',
	uloop: {
		process(command, args) {
			assert.equal(command, '/etc/init.d/AdGuardHome');
			launchedArguments = Array.from(args);
			return {};
		},
	},
	discard_yaml_job() { assert.fail('an accepted job must not be discarded'); },
	close_yaml_job_lock() { assert.fail('the parent lock must remain held for the callback'); },
};
vm.createContext(launchSandbox);
vm.runInContext(`${updateSource}\nthis.update = update_settings;`, launchSandbox);
assert.equal(launchSandbox.update(true, fixture.workDir, false, fixture.redirect,
	true, 120, snapshot.revision).accepted, true);
assert.deepEqual(launchedArguments, [
	'settings_update', '1', fixture.workDir, '0', fixture.redirect, '1', '120',
	snapshot.revision, token, candidate.revision, '193',
], 'the worker must receive ten arguments with the numeric lock descriptor last');

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

const jobFixture = {
	record: null,
	lockAvailable: true,
	lockError: null,
	recoverySucceeds: true,
	consumeSucceeds: true,
	closeSucceeds: true,
	reads: 0,
	closes: 0,
	consumes: 0,
	yamlRecoveries: 0,
	settingsRecoveries: 0,
};
const jobSandbox = {
	read_yaml_job() {
		jobFixture.reads++;
		return jobFixture.record;
	},
	open_yaml_job_lock() {
		return {
			file: jobFixture.lockAvailable ? {} : null,
			error: jobFixture.lockError,
		};
	},
	close_yaml_job_lock() {
		jobFixture.closes++;
		return jobFixture.closeSucceeds;
	},
	discard_yaml_job() {
		jobFixture.consumes++;
		return jobFixture.consumeSucceeds;
	},
	mark_yaml_job_indeterminate(item) {
		assert.equal(item.token, token);
		jobFixture.yamlRecoveries++;
		if (jobFixture.recoverySucceeds)
			jobFixture.record = { ...item.record, state: 'indeterminate' };
		return jobFixture.recoverySucceeds;
	},
	replace_yaml_job(jobToken, content) {
		assert.equal(jobToken, token);
		assert.equal(content, `indeterminate:${expectedHash}:${candidateHash}\n`);
		jobFixture.settingsRecoveries++;
		if (jobFixture.recoverySucceeds)
			jobFixture.record = { ...jobFixture.record, state: 'indeterminate' };
		return jobFixture.recoverySucceeds;
	},
};
vm.createContext(jobSandbox);
vm.runInContext([
	'update_job_status', 'yaml_job_status', 'settings_job_status',
].map(extractFunction).join('\n') + '\nthis.api = { yaml_job_status, settings_job_status };',
jobSandbox, { filename: rpcPath });

function resetJob(state) {
	Object.assign(jobFixture, {
		record: state ? {
			state, expected_hash: expectedHash, candidate_hash: candidateHash,
			sha256: candidateHash, restarted: true,
		} : null,
		lockAvailable: true, lockError: null, recoverySucceeds: true,
		consumeSucceeds: true, closeSucceeds: true,
		reads: 0, closes: 0, consumes: 0,
		yamlRecoveries: 0, settingsRecoveries: 0,
	});
}

for (const settings of [ false, true ]) {
	const query = settings ? jobSandbox.api.settings_job_status : jobSandbox.api.yaml_job_status;
	const label = settings ? 'settings' : 'YAML';
	const title = settings ? 'Settings' : 'YAML';
	resetJob(null);
	assert.equal(query(token, false).error, `${title} update job is unavailable`);
	assert.equal(jobFixture.closes, 0, 'an unavailable job must not acquire or close a lock');

	for (const state of [ 'pending', 'running', 'success' ]) {
		resetJob(state);
		jobFixture.lockAvailable = false;
		assert.equal(query(token, true).state, state === 'pending' ? 'pending' : 'running',
			'a busy worker must hide terminal bytes until its lock is released');
		assert.equal(jobFixture.consumes, 0, 'a busy result must never be consumed');
		assert.equal(jobFixture.closes, 0);
	}

	resetJob('running');
	jobFixture.lockAvailable = false;
	jobFixture.lockError = 'unsafe lock';
	assert.equal(query(token, false).error, 'unsafe lock');

	for (const state of [ 'pending', 'running' ]) {
		resetJob(state);
		let result = query(token, false);
		assert.equal(result.state, 'done');
		assert.equal(result.ok, false);
		assert.equal(result.indeterminate, true);
		assert.equal(jobFixture.yamlRecoveries, settings ? 0 : 1,
			'only an interrupted YAML transaction must enter stage cleanup');
		assert.equal(jobFixture.settingsRecoveries, settings ? 1 : 0,
			'interrupted settings must recover without a YAML stage');
		assert.equal(jobFixture.reads, 3, 'recovery must re-read the authenticated terminal record');
		assert.equal(jobFixture.closes, 1);
		assert.equal(jobFixture.consumes, 0);
	}

	resetJob('running');
	jobFixture.recoverySucceeds = false;
	assert.equal(query(token, true).error, `Unable to recover interrupted ${label} update state`);
	assert.equal(jobFixture.closes, 1);
	assert.equal(jobFixture.consumes, 0);

	resetJob('success');
	let result = query(token, true);
	assert.equal(result.ok, true);
	assert.equal(result.restarted, true);
	assert.equal(result[settings ? 'revision' : 'sha256'], candidateHash,
		'the two public result shapes must retain their distinct revision field');
	assert.equal(result[settings ? 'sha256' : 'revision'], undefined);
	assert.equal(jobFixture.consumes, 1);
	assert.equal(jobFixture.closes, 1);

	resetJob('failure');
	result = query(token, false);
	assert.equal(result.ok, false);
	assert.equal(result.error, settings ? 'Settings were rejected or changed concurrently' :
		'YAML was rejected or changed concurrently');

	resetJob('success');
	jobFixture.consumeSucceeds = false;
	assert.equal(query(token, true).error, `Unable to consume ${label} update result`);
	assert.equal(jobFixture.closes, 1);

	resetJob('success');
	jobFixture.closeSucceeds = false;
	assert.equal(query(token, false).error, `Unable to release ${label} update lock`);
}

console.log('2.4 asynchronous RPC settings transaction tests passed');

// The shared writer retains separate creation and replacement policies while
// using one audited exclusive-create / flush / rename sequence.
const writeFixture = {};
const jobDirectory = '/var/run/luci-app-adguardhome-yaml';
const jobPath = `${jobDirectory}/${token}`;
const temporaryPath = `${jobDirectory}/.${token}.rpcd-${'4'.repeat(32)}`;
const pending = `pending:${expectedHash}:${candidateHash}\n`;
const terminal = `indeterminate:${expectedHash}:${candidateHash}\n`;
function resetWrites() {
	Object.assign(writeFixture, {
		directory: true, entries: new Map(), ensureCalls: 0,
		failure: null, unlinked: [], renamed: false,
	});
}
function jobMetadata(name) {
	if (name === jobDirectory)
		return writeFixture.directory ? { type: 'directory', uid: 0, gid: 0, mode: 0o700 } : null;
	const content = writeFixture.entries.get(name);
	return content === undefined ? null : {
		type: 'file', uid: 0, gid: 0, mode: 0o600, nlink: 1, size: content.length,
	};
}
const writeSandbox = {
	YAML_JOB_DIRECTORY: jobDirectory,
	YAML_JOB_STATE_LIMIT: 256,
	type: value => typeof value,
	length: value => value.length,
	match: (value, expression) => value.match(expression),
	random_token: () => '4'.repeat(32),
	lstat: jobMetadata,
	ensure_yaml_job_directory() {
		writeFixture.ensureCalls++;
		writeFixture.directory = true;
		return true;
	},
	readfile(name) {
		return writeFixture.renamed && writeFixture.failure === 'post-validation'
			? 'broken' : writeFixture.entries.get(name);
	},
	open(name, mode, permissions) {
		assert.equal(mode, 'wx');
		assert.equal(permissions, 0o600);
		if (writeFixture.entries.has(name))
			return null;
		writeFixture.entries.set(name, '');
		return {
			write(content) {
				if (writeFixture.failure === 'throw')
					throw new Error('write failed');
				writeFixture.entries.set(name, content);
				return content.length - (writeFixture.failure === 'partial-write' ? 1 : 0);
			},
			flush: () => writeFixture.failure !== 'flush',
			close: () => writeFixture.failure !== 'close',
		};
	},
	rename(from, to) {
		if (writeFixture.failure === 'rename')
			return false;
		writeFixture.entries.set(to, writeFixture.entries.get(from));
		writeFixture.entries.delete(from);
		writeFixture.renamed = true;
		return true;
	},
	unlink(name) {
		writeFixture.unlinked.push(name);
		return writeFixture.entries.delete(name);
	},
};
vm.createContext(writeSandbox);
vm.runInContext([
	'yaml_job_path', 'root_private_directory', 'root_private_file', 'parse_yaml_job_state',
	'write_yaml_job', 'write_new_yaml_job', 'replace_yaml_job',
].map(extractFunction).join('\n') + '\nthis.api = { write_new_yaml_job, replace_yaml_job };',
writeSandbox, { filename: rpcPath });

resetWrites();
writeFixture.directory = false;
assert.equal(writeSandbox.api.write_new_yaml_job(token, expectedHash, candidateHash), true);
assert.equal(writeFixture.ensureCalls, 1, 'only creation may establish the private job directory');
assert.equal(writeFixture.entries.get(jobPath), pending);
assert.equal(writeFixture.entries.has(temporaryPath), false);
assert.equal(writeSandbox.api.write_new_yaml_job(token, expectedHash, candidateHash), false,
	'create-only must refuse an existing job record');
assert.equal(writeFixture.entries.get(jobPath), pending);
assert.equal(writeSandbox.api.replace_yaml_job(token, terminal), true);
assert.equal(writeFixture.entries.get(jobPath), terminal);

resetWrites();
writeFixture.directory = false;
assert.equal(writeSandbox.api.replace_yaml_job(token, terminal), false,
	'replacement must not reconstruct a removed job directory');
assert.equal(writeFixture.ensureCalls, 0);
assert.equal(writeFixture.entries.size, 0);

for (const operation of [ 'create', 'replace' ]) {
	const write = () => operation === 'create'
		? writeSandbox.api.write_new_yaml_job(token, expectedHash, candidateHash)
		: writeSandbox.api.replace_yaml_job(token, terminal);
	for (const failure of [ 'partial-write', 'flush', 'close', 'rename', 'throw' ]) {
		resetWrites();
		writeFixture.failure = failure;
		if (operation === 'replace')
			writeFixture.entries.set(jobPath, pending);
		assert.equal(write(), false, `${operation}: ${failure} must fail`);
		assert.equal(writeFixture.entries.has(temporaryPath), false,
			`${operation}: ${failure} must remove its own temporary file`);
		assert.equal(writeFixture.entries.get(jobPath), operation === 'replace' ? pending : undefined,
			`${operation}: ${failure} must preserve the prior target`);
	}
	resetWrites();
	writeFixture.entries.set(temporaryPath, 'owned-by-another-writer');
	assert.equal(write(), false);
	assert.equal(writeFixture.entries.get(temporaryPath), 'owned-by-another-writer',
		'exclusive-create failure must never remove an unowned temporary file');

	resetWrites();
	writeFixture.failure = 'post-validation';
	assert.equal(write(), false);
	assert.equal(writeFixture.entries.has(jobPath), operation === 'replace',
		'failed final validation may remove only a record created by this call');
}

resetWrites();
assert.equal(writeSandbox.api.replace_yaml_job(token, 'invalid'), false);
assert.equal(writeFixture.entries.size, 0, 'invalid state bytes must be rejected before staging');
console.log('shared atomic job writer creation/replacement policy tests passed');
