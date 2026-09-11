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

const extractFunction = require('./lib/source').extractFunction.bind(null, source);

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
	'MAX_WORK_DIR_LENGTH',
	'MAX_WORK_DIR_COMPONENT_LENGTH',
].map(extractConstant).join('\n');
const functions = [
	'valid_work_dir',
	'configured_boolean',
	'configured_interval',
	'settings_revision',
	'settings_snapshot',
	'settings_candidate',
].map(extractFunction).join('\n')
	.replace(/for \(let component in components\)/g,
		'for (let component of components)');

const fixture = {
	enabled: '1',
	configFile: '/etc/AdGuardHome/AdGuardHome.yaml',
	workDir: '/etc/AdGuardHome',
	verbose: '0',
	redirect: 'dnsmasq-upstream',
	runFromMemory: '0',
	interval: '60',
	lstatCalls: 0,
	mountReads: 0,
	fstab: null,
	mounts: '/dev/root / ext4 rw 0 0\ntmpfs /tmp tmpfs rw 0 0\n' +
		'tmpfs /opt/ram tmpfs rw 0 0\n/dev/sda1 /tmp/disk ext4 rw 0 0\n',
};

function cursor() {
	return {
		load() { return true; },
		foreach(config, section, callback) {
			for (const entry of fixture.fstab ?? []) callback(entry);
		},
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
	readfile() {
		fixture.mountReads++;
		return fixture.mounts;
	},
	lstat(pathname) {
		fixture.lstatCalls++;
		if (pathname === '/etc/config/fstab')
			return fixture.fstab ? { type: 'file' } : null;
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
	valid_work_dir,
	configured_boolean,
	settings_snapshot,
	settings_candidate,
};`, sandbox, { filename: rpcPath });

for (const value of [ '1', 'on', 'true', 'yes', 'enabled' ])
	assert.equal(sandbox.api.configured_boolean(value), true, `${value}: native true value`);
for (const value of [ '0', 'off', 'false', 'no', 'disabled', 'ON', 'Yes', 'TRUE',
	'ENABLED', 'invalid', '', undefined, null ])
	assert.equal(sandbox.api.configured_boolean(value), false, `${value}: native default false`);

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
for (const workDir of [ '/opt/dns-custom', '/srv/dns', '/dns', '/opt/ramdisk/dns', '/tmp/disk/dns' ]) {
	assert.ok(sandbox.api.settings_candidate(true, workDir, false, 'none', false, 60),
		`${workDir}: persistent directories must not require a specific name or prefix`);
}
for (const workDir of [ '/', '/etc', '/opt/ram/dns', '/tmp/dns', '/srv/../dns' ]) {
	assert.equal(sandbox.api.settings_candidate(true, workDir, false, 'none', false, 60), null,
		`${workDir}: unsafe or memory-backed directories must be rejected`);
}

const component255 = 'a'.repeat(255);
const component256 = `${component255}a`;
const maxWorkDir = `${Array(15).fill(`/${component255}`).join('')}/${'b'.repeat(199)}`;
assert.equal(maxWorkDir.length, 4040);
assert.ok(sandbox.api.settings_candidate(true, `/opt/${component255}`, false, 'none', false, 60),
	'a 255-byte component must remain valid');
let lstatCalls = fixture.lstatCalls;
let mountReads = fixture.mountReads;
assert.equal(sandbox.api.settings_candidate(
	true, `/opt/${component256}`, false, 'none', false, 60), null,
	'a 256-byte component must be rejected');
assert.equal(fixture.lstatCalls, lstatCalls, 'component bounds must run before lstat');
assert.equal(fixture.mountReads, mountReads, 'component bounds must run before mount parsing');
assert.ok(sandbox.api.settings_candidate(true, maxWorkDir, false, 'none', false, 60),
	'a 4040-byte work directory must remain valid');
lstatCalls = fixture.lstatCalls;
mountReads = fixture.mountReads;
assert.equal(sandbox.api.settings_candidate(
	true, `${maxWorkDir}b`, false, 'none', false, 60), null,
	'a 4041-byte work directory must be rejected');
assert.equal(fixture.lstatCalls, lstatCalls, 'total bounds must run before lstat');
assert.equal(fixture.mountReads, mountReads, 'total bounds must run before mount parsing');

const mountedFilesystems = fixture.mounts;

// Missing external mounts block reads/starts, while saved settings retain a
// revision so the user can disable the service or select another directory.
fixture.fstab = [ { target: '/mnt/disk/', enabled: '0' } ];
fixture.workDir = '/mnt/disk/AdGuardHome';
fixture.configFile = `${fixture.workDir}/AdGuardHome.yaml`;
assert.equal(sandbox.api.valid_work_dir(fixture.workDir), null);
assert.ok(sandbox.api.settings_snapshot()?.revision);
assert.equal(sandbox.api.settings_candidate(true, fixture.workDir, false, 'none', false, 60), null);
assert.ok(sandbox.api.settings_candidate(false, fixture.workDir, false, 'none', false, 60));
assert.ok(sandbox.api.valid_work_dir('/mnt/disk-other/AdGuardHome'));
fixture.mounts += '/dev/sda1 /mnt/disk ext4 ro 0 0\n';
assert.equal(sandbox.api.valid_work_dir(fixture.workDir), null);
fixture.mounts += '/dev/sda1 /mnt/disk ext4 rw 0 0\n';
assert.equal(sandbox.api.valid_work_dir(fixture.workDir), fixture.workDir);
fixture.mounts += '/dev/sda1 /mnt/disk ext4 ro 0 0\n';
assert.equal(sandbox.api.valid_work_dir(fixture.workDir), null, 'the topmost mount controls access');
fixture.fstab = null;
fixture.workDir = '/etc/AdGuardHome';
fixture.configFile = `${fixture.workDir}/AdGuardHome.yaml`;
fixture.mounts = '';
assert.equal(sandbox.api.settings_snapshot(), null, 'unknown storage must not be accepted');
fixture.mounts = mountedFilesystems;
assert.equal(sandbox.api.settings_candidate(
	true,
	fixture.workDir,
	false,
	fixture.redirect,
	false,
	10081
), null, 'oversized write-back intervals must fail closed');

const updateSource = extractFunction('update_settings');
const startSource = extractFunction('start_settings_process');
assert.doesNotMatch(updateSource, /\blaunched\b/,
	'settings must not retain an unreachable post-launch catch branch');
assert.match(updateSource,
	/prepare_yaml_job\(token, expected_revision, candidate\.revision\)/,
	'settings and YAML transactions must share one job lock');
assert.doesNotMatch(updateSource, /candidate\.revision == current\.revision|unchanged/,
	'every Save & Apply must reach the coordinator even when values are unchanged');
assert.match(updateSource,
	/let locked_current = settings_snapshot\(\);[\s\S]*?locked_current\.revision != expected_revision[\s\S]*?discard_yaml_job\(token\)[\s\S]*?close_yaml_job_lock\(\{ file: job\.lock \}\)/,
	'the settings revision must be rechecked and stale job state removed while holding the shared lock');
assert.match(updateSource,
	/start_settings_process\(job, expected_revision, candidate\.revision, \[\s*'settings_update'/,
	'settings must be applied asynchronously through the coordinator command');
assert.match(updateSource,
	/`\$\{candidate\.memory_writeback_interval\}`,\s*expected_revision,\s*token,\s*candidate\.revision,\s*`\$\{job\.lock_descriptor\}`,\s*\]\)/,
	'the coordinator must receive the CAS revision, one-shot credential and inherited lock descriptor');
assert.match(startSource,
	/function\(\) \{\s*finish_settings_process\(\s*token, expected_hash, candidate_hash, job\.lock/,
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
vm.runInContext(`${startSource}\n${updateSource}\n${extractFunction('memory_writeback')}\nthis.update = update_settings; this.writeback = memory_writeback;`, launchSandbox);
assert.equal(launchSandbox.update(true, fixture.workDir, false, fixture.redirect,
	true, 120, snapshot.revision).accepted, true);
assert.deepEqual(launchedArguments, [
	'settings_update', '1', fixture.workDir, '0', fixture.redirect, '1', '120',
	snapshot.revision, token, candidate.revision, '193',
], 'the worker must receive ten arguments with the numeric lock descriptor last');

launchSandbox.sha256 = sandbox.sha256;
launchSandbox.memory_state_active = () => true;
launchSandbox.service_running = () => true;
launchSandbox.settings_snapshot = () => ({ ...snapshot, run_from_memory: true });
let writebackJob;
launchSandbox.prepare_yaml_job = (jobToken, expected, hash) => {
	writebackJob = [ jobToken, expected, hash ];
	return { token: jobToken, lock: {}, lock_descriptor: 193 };
};
assert.equal(launchSandbox.writeback(snapshot.revision).accepted, true);
const writebackHash = sandbox.sha256(`memory_writeback:${snapshot.revision}`);
assert.deepEqual(writebackJob, [ token, snapshot.revision, writebackHash ]);
assert.deepEqual(launchedArguments, [
	'memory_writeback_job', snapshot.revision, writebackHash, token, '193',
], 'write-back accepts only a committed revision, never draft settings');
launchSandbox.prepare_yaml_job = () => ({ token, reused: true });
launchedArguments = null;
assert.equal(launchSandbox.writeback(snapshot.revision).reused, true);
assert.equal(launchedArguments, null, 'repeated requests must reuse the running job');
for (const revision of [ '', null, 'bad', expectedHash ])
	assert.ok(launchSandbox.writeback(revision).error);
launchSandbox.memory_state_active = () => false;
assert.ok(launchSandbox.writeback(snapshot.revision).error);
launchSandbox.memory_state_active = () => true;
launchSandbox.service_running = () => false;
assert.ok(launchSandbox.writeback(snapshot.revision).error);
launchSandbox.service_running = () => true;
launchSandbox.settings_snapshot = () => snapshot;
assert.ok(launchSandbox.writeback(snapshot.revision).error);
launchSandbox.prepare_yaml_job = () => ({ token, lock: {}, lock_descriptor: 193 });

for (const failure of [ 'unavailable', 'exception' ]) {
	let discarded = 0;
	let released = 0;
	launchSandbox.discard_yaml_job = () => { discarded++; return true; };
	launchSandbox.close_yaml_job_lock = () => { released++; return true; };
	launchSandbox.uloop.process = () => {
		if (failure === 'exception') throw new Error('spawn failed');
		return null;
	};
	assert.ok(launchSandbox.update(true, fixture.workDir, false, fixture.redirect,
		true, 120, snapshot.revision).error);
	assert.equal(discarded, 1, `${failure}: failed launch must discard its pending job`);
	assert.equal(released, 1, `${failure}: failed launch must release its held lock`);
}

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
assert.match(source, /return update_job_status\(request.args.token, false\);/);
assert.match(source, /return update_job_status\(request.args.token, true\);/);
assert.doesNotMatch(source, /\bconsume\s*[:,)]|request\.args\.consume/);
assert.doesNotMatch(source, /function (yaml_job_status|settings_job_status)\(/);

const jobFixture = {
	record: null,
	lockAvailable: true,
	lockError: null,
	recoverySucceeds: true,
	stageRemovalSucceeds: true,
	closeSucceeds: true,
	reads: 0,
	closes: 0,
	stageRemovals: 0,
	recoveries: 0,
	jobs: { active: [] },
};
const jobSandbox = {
	length: value => value.length,
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
	scan_yaml_jobs(cleanTemporary) {
		assert.equal(cleanTemporary, false, 'observing a later worker must not clean its files');
		return jobFixture.jobs;
	},
	close_yaml_job_lock() {
		jobFixture.closes++;
		return jobFixture.closeSucceeds;
	},
	discard_yaml_job() {
		assert.fail('reading a shared result must never delete its record');
	},
	remove_yaml_stage(jobToken) {
		assert.equal(jobToken, token);
		jobFixture.stageRemovals++;
		return jobFixture.stageRemovalSucceeds;
	},
	replace_yaml_job(jobToken, content) {
		assert.equal(jobToken, token);
		assert.equal(content, `indeterminate:${expectedHash}:${candidateHash}\n`);
		jobFixture.recoveries++;
		if (jobFixture.recoverySucceeds)
			jobFixture.record = { ...jobFixture.record, state: 'indeterminate' };
		return jobFixture.recoverySucceeds;
	},
};
vm.createContext(jobSandbox);
vm.runInContext(extractFunction('mark_yaml_job_indeterminate') + '\n' +
extractFunction('update_job_status') + '\nthis.query = update_job_status;',
jobSandbox, { filename: rpcPath });

function resetJob(state) {
	Object.assign(jobFixture, {
		record: state ? {
			state, expected_hash: expectedHash, candidate_hash: candidateHash,
			sha256: candidateHash, restarted: true,
		} : null,
		lockAvailable: true, lockError: null, recoverySucceeds: true,
		stageRemovalSucceeds: true, closeSucceeds: true,
		reads: 0, closes: 0, stageRemovals: 0, recoveries: 0,
		jobs: { active: [] },
	});
}

for (const settings of [ false, true ]) {
	const query = token => jobSandbox.query(token, settings);
	const label = settings ? 'settings' : 'YAML';
	const title = settings ? 'Settings' : 'YAML';
	resetJob(null);
	assert.equal(query(token).error, `${title} update job is unavailable`);
	assert.equal(jobFixture.closes, 0, 'an unavailable job must not acquire or close a lock');

	for (const state of [ 'pending', 'running', 'success' ]) {
		resetJob(state);
		jobFixture.lockAvailable = false;
		assert.equal(query(token).state, state === 'pending' ? 'pending' : 'running',
			'a busy worker must hide terminal bytes until its lock is released');
		assert.equal(jobFixture.closes, 0);
	}

	resetJob('running');
	jobFixture.lockAvailable = false;
	jobFixture.lockError = 'unsafe lock';
	assert.equal(query(token).error, 'unsafe lock');

	for (const state of [ 'pending', 'running' ]) {
		resetJob(state);
		let result = query(token);
		assert.equal(result.state, 'done');
		assert.equal(result.ok, false);
		assert.equal(result.indeterminate, true);
		assert.equal(jobFixture.stageRemovals, settings ? 0 : 1,
			'only an interrupted YAML transaction must enter stage cleanup');
		assert.equal(jobFixture.recoveries, 1,
			'both job types must publish indeterminate through the shared helper');
		assert.equal(jobFixture.reads, 3, 'recovery must re-read the authenticated terminal record');
		assert.equal(jobFixture.closes, 1);
	}

	resetJob('running');
	jobFixture.recoverySucceeds = false;
	assert.equal(query(token).error, `Unable to recover interrupted ${label} update state`);
	assert.equal(jobFixture.closes, 1);

	resetJob('success');
	let result = query(token);
	assert.equal(result.ok, true);
	assert.equal(result.restarted, true);
	assert.equal(result[settings ? 'revision' : 'sha256'], candidateHash,
		'the two public result shapes must retain their distinct revision field');
	assert.equal(result[settings ? 'sha256' : 'revision'], undefined);
	assert.equal(jobFixture.closes, 1);
	assert.deepEqual(query(token), result,
		'a second observer of the reused token must receive the same successful result');

	resetJob('failure');
	result = query(token);
	assert.equal(result.ok, false);
	assert.equal(result.error, settings ? 'Settings were rejected or changed concurrently' :
		'YAML was rejected or changed concurrently');

	assert.deepEqual(query(token), result, 'failure results must also remain readable');
	resetJob('indeterminate');
	result = query(token);
	assert.deepEqual(query(token), result, 'unknown outcomes must remain unknown to every observer');

	resetJob('success');
	jobFixture.closeSucceeds = false;
	assert.equal(query(token).error, `Unable to release ${label} update lock`);
}

for (const jobs of [ { active: [] }, { active: [ { token } ] },
	{ active: [ { token: 'other' }, { token: 'third' } ] },
	{ active: [ { token: 'other' } ], error: 'unsafe state' },
	{ active: [ { token: 'other' } ], maintenance: true } ]) {
	resetJob('success');
	jobFixture.lockAvailable = false;
	jobFixture.jobs = jobs;
	assert.equal(jobSandbox.query(token, true).state, 'running',
		'without one distinct active worker, terminal bytes must remain hidden during lock handoff');
	assert.equal(jobFixture.stageRemovals, 0);
	assert.equal(jobFixture.recoveries, 0);
}

resetJob('running');
jobFixture.stageRemovalSucceeds = false;
assert.match(jobSandbox.query(token, false).error, /Unable to recover interrupted YAML/);
assert.equal(jobFixture.recoveries, 0, 'failed stage cleanup must retain the pending recovery record');

for (const state of [ 'success', 'failure', 'running', 'indeterminate' ]) {
	resetJob(state);
	jobFixture.record.restarted = false;
	const result = jobSandbox.query(token, 'writeback');
	assert.equal(result.state, 'done');
	assert.equal(result.ok, state === 'success');
	assert.equal(result.revision, undefined, 'write-back does not publish a new settings revision');
	assert.equal(result.sha256, undefined, 'write-back does not publish a new YAML revision');
	if (state === 'success')
		assert.equal(result.restarted, false);
	else if (state === 'failure')
		assert.match(result.error, /Write-back failed/);
	else
		assert.equal(result.indeterminate, true);
	assert.equal(jobFixture.stageRemovals, 0);
	assert.deepEqual(jobSandbox.query(token, 'writeback'), result,
		'write-back results must survive repeated reads');
}
console.log('asynchronous settings and memory write-back RPC transaction tests passed');

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
		busy: false, lockCloses: 0,
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
	YAML_MAINTENANCE_MARKER: `${jobDirectory}/removing`,
	YAML_JOB_STATE_LIMIT: 256,
	MAX_CONFIG_LENGTH: 512 * 1024,
	type: value => Array.isArray(value) ? 'array' : typeof value,
	length: value => value.length,
	match: (value, expression) => value.match(expression),
	substr: (value, start) => value.substr(start),
	push: (values, value) => values.push(value),
	config_path: () => '/etc/AdGuardHome/AdGuardHome.yaml',
	random_token: () => '4'.repeat(32),
	lstat: jobMetadata,
	lsdir: () => Array.from(writeFixture.entries.keys())
		.filter(name => name.startsWith(`${jobDirectory}/`))
		.map(name => name.slice(jobDirectory.length + 1)),
	open_yaml_job_lock: () => writeFixture.busy
		? { busy: true } : { file: {}, descriptor: 193 },
	close_yaml_job_lock: () => { writeFixture.lockCloses++; return true; },
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
	'root_private_temporary_file', 'root_private_lock_file', 'read_yaml_job',
	'discard_yaml_job', 'yaml_stage_path', 'remove_yaml_stage', 'scan_yaml_jobs',
	'mark_yaml_job_indeterminate', 'prepare_yaml_job', 'update_job_status',
].map(extractFunction).join('\n').replace(/for \(let (\w+) in (.+)\)/g, 'for (let $1 of $2)') +
'\nthis.api = { write_new_yaml_job, replace_yaml_job, prepare_yaml_job, update_job_status };',
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

resetWrites();
writeFixture.entries.set(jobPath, pending);
writeFixture.busy = true;
const reused = writeSandbox.api.prepare_yaml_job('5'.repeat(32), expectedHash, candidateHash);
assert.equal(reused.token, token);
assert.equal(reused.reused, true);
writeFixture.entries.set(jobPath, `success:${candidateHash}:1:${expectedHash}:${candidateHash}\n`);
writeFixture.busy = false;
const firstObserver = writeSandbox.api.update_job_status(token, false);
assert.equal(firstObserver.ok, true);
assert.deepEqual(writeSandbox.api.update_job_status(reused.token, false), firstObserver,
	'two callers sharing a real stored token must both read its terminal result');
assert.equal(writeFixture.entries.has(jobPath), true);

resetWrites();
writeFixture.entries.set(`${jobDirectory}/removing`, '');
const maintenance = writeSandbox.api.prepare_yaml_job(
	'5'.repeat(32), expectedHash, candidateHash);
assert.match(maintenance.error, /package maintenance/);
assert.equal(writeFixture.entries.size, 1, 'maintenance must not create a pending job');
assert.equal(writeFixture.lockCloses, 1);

for (const settings of [ false, true, 'writeback' ]) {
	for (const terminalState of [
		`success:${candidateHash}:1:${expectedHash}:${candidateHash}\n`,
		`failure:${expectedHash}:${candidateHash}\n`,
		`indeterminate:${expectedHash}:${candidateHash}\n`,
	]) {
		resetWrites();
		writeFixture.entries.set(jobPath, terminalState);
		const completed = writeSandbox.api.update_job_status(token, settings);
		const nextToken = '5'.repeat(32);
		assert.equal(writeSandbox.api.prepare_yaml_job(
			nextToken, candidateHash, '6'.repeat(64)).reused, false);
		writeFixture.busy = true;
		assert.deepEqual(writeSandbox.api.update_job_status(token, settings), completed,
			'a later transaction must not turn a completed task back into running');
		assert.equal(writeFixture.entries.get(jobPath), terminalState);
		assert.match(writeFixture.entries.get(`${jobDirectory}/${nextToken}`), /^pending:/,
			'observing the completed task must preserve the later worker');
	}
}

const activeYaml = '/etc/AdGuardHome/AdGuardHome.yaml';
for (const retained of [ 1, 15, 16 ]) {
	resetWrites();
	writeFixture.entries.set(activeYaml, 'active YAML must survive');
	const oldTokens = Array.from({ length: retained }, (_, index) => index.toString(16).padStart(32, '0'));
	for (const oldToken of oldTokens)
		writeFixture.entries.set(`${jobDirectory}/${oldToken}`, terminal);
	const oldStage = `${activeYaml}.luci-${oldTokens[0]}`;
	writeFixture.entries.set(oldStage, 'orphaned stage');
	assert.equal(writeSandbox.api.prepare_yaml_job(token, expectedHash, candidateHash).reused, false);
	assert.equal(writeFixture.entries.has(oldStage), false,
		'orphaned YAML stages must be cleaned by the next write, before its workdir can change');
	assert.equal(writeFixture.entries.get(activeYaml), 'active YAML must survive');
	for (const oldToken of oldTokens)
		assert.equal(writeFixture.entries.has(`${jobDirectory}/${oldToken}`), retained < 16,
			'terminal records stay readable below the existing retention bound');
}

resetWrites();
writeFixture.entries.set(jobPath, terminal);
const oversizedStage = `${activeYaml}.luci-${token}`;
writeFixture.entries.set(oversizedStage, 'x'.repeat(512 * 1024 + 1));
assert.ok(writeSandbox.api.prepare_yaml_job('5'.repeat(32), expectedHash, candidateHash).error);
assert.equal(writeFixture.entries.has(oversizedStage), true, 'unsafe stage files must never be removed');
assert.equal(writeFixture.entries.get(jobPath), terminal, 'failed cleanup must retain the recovery record');
assert.equal(writeFixture.lockCloses, 1);
console.log('reused-token observations and bounded terminal/stage retention tests passed');

let randomBytes;
const randomSandbox = {
	type: value => typeof value,
	length: value => value.length,
	hexenc: value => Buffer.from(value, 'latin1').toString('hex'),
	readfile(filename, limit) {
		assert.equal(filename, '/dev/urandom');
		assert.equal(limit, 16, 'random reads must remain bounded to 128 bits');
		return randomBytes;
	},
};
vm.createContext(randomSandbox);
vm.runInContext(extractFunction('random_token') + '\nthis.token = random_token;', randomSandbox);
for (const bytes of [ null, '', 'a'.repeat(15), 'a'.repeat(17) ]) {
	randomBytes = bytes;
	assert.equal(randomSandbox.token(), null, 'failed or short random reads must be rejected');
}
randomBytes = '\x00\xff'.repeat(8);
assert.equal(randomSandbox.token(), '00ff'.repeat(8), 'binary random bytes must survive hex encoding');
console.log('bounded native random-token read contract tests passed');
