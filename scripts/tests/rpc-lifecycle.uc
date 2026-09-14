// SPDX-License-Identifier: Apache-2.0
import * as uloop from 'uloop';
import { readfile, writefile, lsdir } from 'fs';
import { cursor } from 'uci';

let methods = loadfile('/tmp/rpc.uc', { raw_mode: true })()['luci.adguardhome'];
const JOBS = '/var/run/luci-app-adguardhome-yaml';
function check(value, message) { if (!value) die(message); }
function call(name, args) { return methods[name].call({ args: args || {} }); }
function wait(submit, method, handoff) {
	check(submit.accepted, sprintf('Submission failed: %J', submit));
	let released = false;
	for (let i = 0; i < 500; i++) {
		let timer = uloop.timer(10, function() { uloop.end(); });
		uloop.run();
		let result = call(method, { token: submit.token });
		if (handoff && !released && index(readfile(`${JOBS}/${submit.token}`), 'success:') == 0) {
			check(result.state == 'running', 'Published success escaped the worker lock');
			writefile('/tmp/release-worker', '1');
			released = true;
		}
		if (result.state == 'done') {
			check(!handoff || released, 'The worker lock handoff was not exercised');
			return result;
		}
		check(!result.error, sprintf('Polling failed: %J', result));
	}
	die('Native RPC task did not complete');
}

uloop.init();
let settings = call('get_settings');
let descriptors = length(lsdir('/proc/self/fd'));
let previous = null;
for (let mode in ['success', 'failure', 'success', 'exit', 'success', 'handoff']) {
	writefile('/tmp/worker-mode', mode);
	let submit = call('set_settings', settings);
	let result = wait(submit, 'get_settings_update', mode == 'handoff');
	check(result.ok == (mode == 'success' || mode == 'handoff'), `${mode}: incorrect result`);
	check(!!result.indeterminate == (mode == 'exit'), `${mode}: incorrect recovery`);
	check(sprintf('%J', call('get_settings_update', { token: submit.token })) == sprintf('%J', result),
		'The current completed result must remain readable');
	if (previous) check(!!call('get_settings_update', { token: previous }).error, 'Previous result was retained');
	check(length(lsdir(JOBS)) == 2, 'Expected only the current result and lock');
	check(length(lsdir('/proc/self/fd')) == descriptors, `${mode}: leaked descriptor`);
	previous = submit.token;
}

// Exercise the second native callback and its held read-only YAML descriptor.
writefile('/tmp/worker-mode', 'success');
let credentials = call('get_credentials');
check(wait(call('set_credentials', { username: 'admin2', password_hash: '', sha256: credentials.sha256 }),
	'get_yaml_update').ok, 'Credential update failed');
check(call('get_credentials').username == 'admin2', 'Credential update did not reach YAML');
let yaml = call('get_yaml');
check(wait(call('set_yaml', { content: `${yaml.content}# test\n`, sha256: yaml.sha256 }),
	'get_yaml_update').ok, 'Direct YAML update failed');
check(length(filter(lsdir('/mnt/adguardhome'), (name) => index(name, '.luci-') >= 0)) == 0,
	'YAML callback left its staging file');
check(length(lsdir('/proc/self/fd')) == descriptors, 'YAML callback leaked a descriptor');
let uci = cursor();
uci.set('adguardhome', 'config', 'config_file', '/tmp/untrusted');
uci.commit('adguardhome');
uci.unload('adguardhome');
check(!!call('set_yaml', { content: yaml.content, sha256: yaml.sha256, verified_path: yaml.path }).error,
	'The public YAML method bypassed configured-path validation');
printf('RPC_LIFECYCLE_OK tasks=8 handoff=running records=1 descriptors=stable\n');
