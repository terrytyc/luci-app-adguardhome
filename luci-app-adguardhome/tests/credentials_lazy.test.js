'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { deferred } = require('./lib/helpers');

const overviewPath = path.join(__dirname,
	'../htdocs/luci-static/resources/view/adguardhome/overview.js');
const source = fs.readFileSync(overviewPath, 'utf8');
const info = { available: true, username: 'admin', sha256: 'a'.repeat(64) };
const encodedHash = '$2b$10$' + 'a'.repeat(53);

function loadOverview() {
	const events = [];
	const nodes = [];
	const modals = [];
	const failures = [];
	const timers = [];
	const preparations = [];
	const credentialReply = deferred();
	const moduleReply = deferred();
	let active = true;
	const scope = {};
	const operation = {
		isPageActive: () => active,
		isPageInactiveError: error => error?.pageInactive === true,
		async requestActive(requestFn) {
			if (!active)
				throw { pageInactive: true };
			try {
				const value = await requestFn();
				if (!active)
					throw { pageInactive: true };
				return value;
			} catch (error) {
				if (!active)
					throw { pageInactive: true };
				throw error;
			}
		},
		start(message) {
			events.push('operation-start');
			if (message) preparations.push(String(message));
			return scope;
		},
		success(_message, ticket) { assert.equal(ticket, scope); events.push('operation-success'); },
		failure(message) { failures.push(String(message)); },
		async waitForJob(statusFn, token, currentScope, messages, makeError) {
			assert.equal(currentScope, scope);
			assert.equal(typeof makeError, 'function', 'credential polling must mark uncertain results');
			let result = null;
			try {
				result = await statusFn(token);
			} catch (error) {
				throw makeError(messages.unavailable.format(String(error.message ?? error)));
			}
			if (result?.state === 'done')
				return result;
			if (typeof result?.error === 'string' && result.error)
				throw makeError(result.error);
			if (result?.state !== 'pending' && result?.state !== 'running')
				throw makeError(messages.unknown);
			return result;
		},
	};
	class BcryptInstance {
		async hash(password) {
			assert.equal(this, bcrypt, 'methods must run on the loaded class instance');
			events.push([ 'hash', password ]);
			return encodedHash;
		}
	}
	const bcrypt = new BcryptInstance();
	const handlers = {
		get_credentials: () => credentialReply.promise,
		set_credentials: (...args) => {
			events.push([ 'set_credentials', ...args ]);
			return { accepted: true, token: 'b'.repeat(32) };
		},
		get_yaml_update: token => {
			events.push([ 'get_yaml_update', token ]);
			return { state: 'done', ok: true };
		},
	};
	const context = {
		TextEncoder,
		operation,
		rpc: {
			declare: specification => async (...args) => {
				if (specification.method === 'get_credentials')
					events.push('get_credentials');
				return handlers[specification.method](...args);
			},
		},
		ui: {
			createHandlerFn: (owner, handler) => (...args) => handler.apply(owner, args),
			showModal: (title, children) => modals.push({ title: String(title), children }),
			hideModal: () => events.push('modal-hidden'),
		},
		view: { extend: definition => definition },
		E(tag, attrs, children) {
			const node = {
				tag, attrs: attrs ?? {}, children, style: {}, value: '', events: {},
				addEventListener(name, handler) { this.events[name] = handler; },
				focus() { events.push('input-focused'); },
			};
			nodes.push(node);
			return node;
		},
		_: value => {
			const translated = new String(value);
			translated.format = replacement => value.replace('%s', replacement);
			return translated;
		},
		L: {
			hasViewPermission: () => true,
			require(name) {
				assert.equal(name, 'adguardhome.bcrypt');
				events.push('require-bcrypt');
				return moduleReply.promise;
			},
		},
		window: { setTimeout: callback => timers.push(callback) },
	};
	vm.createContext(context);
	const view = vm.runInContext('(function() {\n' + source + '\n})()', context,
		{ filename: overviewPath });
	view.pageScope = scope;
	return {
		view, bcrypt, credentialReply, moduleReply, handlers, events, nodes, modals, failures, timers, preparations,
		setActive(value) { active = value; },
		inputs() { return nodes.filter(node => node.tag === 'input').slice(-3); },
		submit() { return nodes.filter(node => node.tag === 'button' && node.events.click).slice(-1)[0].events.click(); },
	};
}

async function readyDialog() {
	const state = loadOverview();
	assert.deepEqual(state.events, [], 'overview module initialization must not load bcrypt');
	const pending = state.view.openCredentialsDialog();
	assert.deepEqual(state.events, [ 'operation-start', 'get_credentials' ],
		'opening the dialog must only request account information');
	assert.deepEqual(state.preparations, [ 'Preparing account change…' ]);
	assert.equal(state.view.credentialsPreparing, true);
	Object.assign(state.view, {
		memoryWritebackAvailable: true, memoryWritebackButton: {}, credentialsButton: {},
		committedSettings: { revision: 'a'.repeat(64) },
		submitSettings() { assert.fail('Apply must not replace the pending credential preparation'); },
	});
	state.view.updateMemoryWritebackButton();
	assert.equal(state.view.memoryWritebackButton.disabled, true);
	assert.equal(state.view.credentialsButton.disabled, true);
	await state.view.openCredentialsDialog();
	await state.view.handleSaveApply();
	await state.view.handleMemoryWriteback();
	assert.deepEqual(state.events, [ 'operation-start', 'get_credentials' ],
		'duplicate clicks, Apply and write-back must not overlap delayed credential preparation');
	state.credentialReply.resolve(info);
	await pending;
	assert.equal(state.modals.length, 1);
	assert.equal(state.modals[0].title, 'Change AdGuard Home Account');
	assert.equal(state.inputs().length, 3);
	assert.equal(state.failures.length, 0);
	assert.equal(state.view.credentialsPreparing, false);
	assert.equal(state.view.memoryWritebackButton.disabled, false);
	assert.equal(state.view.credentialsButton.disabled, false);
	return state;
}

async function main() {
	for (const busy of [ 'credentialsPreparing', 'credentialsUncertain', 'settingsSubmission', 'memoryWritebackBusy', 'memoryWritebackUncertain' ]) {
		const state = loadOverview();
		state.view[busy] = true;
		await state.view.openCredentialsDialog();
		assert.deepEqual(state.events, [], `${busy}: credential preparation must not replace another operation`);
	}
	const cancelled = await readyDialog();
	cancelled.inputs()[0].value = 'operator';
	cancelled.inputs()[1].value = cancelled.inputs()[2].value = 'eight-characters';
	cancelled.nodes.find(node => node.tag === 'button' && node.attrs.click).attrs.click();
	assert.equal(cancelled.events.includes('require-bcrypt'), false, 'cancelling must not load bcrypt');
	assert.equal(cancelled.inputs().every(input => input.value === ''), true);
	assert.equal(cancelled.events.some(Array.isArray), false);

	const success = await readyDialog();
	const [ username, password, confirmation ] = success.inputs();
	username.value = 'operator';
	password.value = confirmation.value = 'eight-characters';
	const pendingSuccess = success.submit();
	assert.equal(success.events.filter(event => event === 'require-bcrypt').length, 1);
	assert.equal(success.view.credentialsPreparing, true, 'module loading must hold the existing action guard');
	assert.equal(success.inputs().every(input => input.value === ''), true,
		'sensitive inputs must be cleared before waiting for the module');
	const waitingEvents = success.events.slice();
	await success.view.openCredentialsDialog();
	await success.view.handleSaveApply();
	await success.view.handleMemoryWriteback();
	assert.deepEqual(success.events, waitingEvents, 'other actions must remain paused while the module loads');
	success.moduleReply.resolve(success.bcrypt);
	await pendingSuccess;
	assert.deepEqual(success.events.filter(Array.isArray), [
		[ 'hash', 'eight-characters' ],
		[ 'set_credentials', 'operator', encodedHash, info.sha256 ],
		[ 'get_yaml_update', 'b'.repeat(32) ],
	]);
	assert.equal(success.events.includes('operation-success'), true);
	assert.equal(success.view.credentialsPreparing, false, 'successful submission must release its action guard');
	assert.equal(success.inputs().every(input => input.value === ''), true,
		'credential inputs must still be cleared after submission');

	for (const [ value, expected ] of [
		[ 'short', 'at least 8 characters' ],
		[ 'x'.repeat(73), '72-byte BCrypt limit' ],
		[ '界'.repeat(25), '72-byte BCrypt limit' ],
	]) {
		const state = await readyDialog();
		state.inputs()[1].value = state.inputs()[2].value = value;
		await state.submit();
		const error = state.nodes.find(node => node.tag === 'p' && node.className === 'alert-message error');
		assert.equal(error?.attrs.role, 'alert', 'credential validation errors must be announced');
		assert.equal(String(error?.textContent).includes(expected), true);
		assert.equal(state.events.some(Array.isArray), false, 'invalid passwords must not hash or submit');
		assert.equal(state.events.includes('require-bcrypt'), false, 'invalid passwords must not load bcrypt');
	}
	for (const password of [ 'x'.repeat(72), '界'.repeat(24) ]) {
		const state = await readyDialog();
		state.inputs()[1].value = state.inputs()[2].value = password;
		state.moduleReply.resolve(state.bcrypt);
		await state.submit();
		assert.deepEqual(state.events.find(Array.isArray), [ 'hash', password ],
			'exactly 72 UTF-8 bytes must reach hashing');
		assert.equal(state.failures.length, 0);
	}

	const renamed = await readyDialog();
	renamed.inputs()[0].value = 'operator';
	await renamed.submit();
	assert.equal(renamed.events.includes('require-bcrypt'), false, 'username-only updates must not load bcrypt');
	assert.deepEqual(renamed.events.find(Array.isArray), [ 'set_credentials', 'operator', '', info.sha256 ],
		'username-only updates must preserve the password without hashing an empty string');

	for (const scenario of [
		{
			name: 'lost response',
			reply: () => { throw new Error('accepted response was lost'); },
			expected: /outcome is unknown.*may have reached.*accepted response was lost.*Reload this page/,
			uncertain: true,
		},
		{
			name: 'accepted without token',
			reply: () => ({ accepted: true, token: 'invalid' }),
			expected: /outcome is unknown.*accepted the update job.*valid status token.*Reload this page/,
			uncertain: true,
		},
		{
			name: 'rejected',
			reply: () => ({ accepted: false }),
			expected: /Unable to change.*did not accept/,
			uncertain: false,
		},
		{
			name: 'status unavailable',
			reply: () => ({ accepted: true, token: 'b'.repeat(32) }),
			statusReply: () => { throw new Error('status transport failed'); },
			expected: /status is temporarily unavailable.*status transport failed.*reload this page/,
			uncertain: true,
		},
		{
			name: 'unknown job state',
			reply: () => ({ accepted: true, token: 'b'.repeat(32) }),
			statusReply: () => ({ state: 'expired', ok: false }),
			expected: /credential update returned an unknown job state/,
			uncertain: true,
		},
		{
			name: 'indeterminate completion',
			reply: () => ({ accepted: true, token: 'b'.repeat(32) }),
			statusReply: () => ({ state: 'done', ok: false, indeterminate: true }),
			expected: /outcome is unknown.*Reload this page/,
			uncertain: true,
		},
	]) {
		const state = await readyDialog();
		state.handlers.set_credentials = (...args) => {
			state.events.push([ 'set_credentials', ...args ]);
			return scenario.reply();
		};
		if (scenario.statusReply)
			state.handlers.get_yaml_update = token => {
				state.events.push([ 'get_yaml_update', token ]);
				return scenario.statusReply();
			};
		state.inputs()[0].value = 'operator';
		await state.submit();
		assert.equal(state.failures.length, 1, `${scenario.name}: report one result`);
		assert.equal(state.view.credentialsPreparing, false, `${scenario.name}: completed submission must release its action guard`);
		assert.match(state.failures[0], scenario.expected);
		assert.equal(state.view.credentialsUncertain === true, scenario.uncertain,
			`${scenario.name}: retain an uncertain outcome until reload`);
		const mutations = state.events.filter(event => Array.isArray(event));
		assert.deepEqual(mutations[0], [ 'set_credentials', 'operator', '', info.sha256 ],
			`${scenario.name}: submit the CAS-protected mutation only once`);
		assert.equal(mutations.filter(event => event[0] === 'set_credentials').length, 1);
		assert.equal(mutations.some(event => event[0] === 'get_yaml_update'), !!scenario.statusReply,
			`${scenario.name}: poll only after receiving a valid token`);
		if (scenario.uncertain) {
			assert.equal(state.view.memoryWritebackButton.disabled, true);
			assert.equal(state.view.credentialsButton.disabled, true);
			const before = state.events.slice();
			await state.view.openCredentialsDialog();
			await state.view.handleMemoryWriteback();
			await state.view.handleSaveApply();
			assert.deepEqual(state.events, before,
				`${scenario.name}: no write may start before the page is reloaded`);
			assert.match(state.failures.at(-1), /outcome is unknown.*Reload this page/);
		}
	}

	{
		const state = loadOverview();
		const pending = state.view.openCredentialsDialog();
		state.credentialReply.reject(new Error('load failed'));
		await pending;
		assert.equal(state.modals.length, 0);
		assert.equal(state.failures.length, 1);
		assert.equal(state.view.credentialsPreparing, false, 'failed preparation must release its action guard');
		assert.match(state.failures[0], /Unable to prepare.*load failed/);
		assert.equal(state.events.includes('require-bcrypt'), false);
	}
	const failedModule = await readyDialog();
	failedModule.inputs()[1].value = failedModule.inputs()[2].value = 'eight-characters';
	const failedLoad = failedModule.submit();
	failedModule.moduleReply.reject(new Error('class load failed'));
	await failedLoad;
	assert.match(failedModule.failures[0], /Unable to change.*class load failed/);
	assert.equal(failedModule.view.credentialsPreparing, false);
	assert.equal(failedModule.view.credentialsUncertain, undefined, 'a failed class load has not submitted a change');
	assert.equal(failedModule.view.credentialsButton.disabled, false);
	assert.equal(failedModule.view.memoryWritebackButton.disabled, false);
	assert.equal(failedModule.inputs().every(input => input.value === ''), true);
	assert.equal(failedModule.events.some(Array.isArray), false, 'a failed class load must neither hash nor submit');
	// LuCI retains a rejected class-load promise until the page is reloaded.
	// Reopening the dialog and changing only the username must still work.
	await failedModule.view.openCredentialsDialog();
	failedModule.inputs()[0].value = 'operator';
	await failedModule.submit();
	assert.equal(failedModule.events.filter(event => event === 'require-bcrypt').length, 1);
	assert.deepEqual(failedModule.events.find(Array.isArray), [ 'set_credentials', 'operator', '', info.sha256 ]);
	assert.equal(failedModule.events.includes('operation-success'), true);

	for (const rejects of [ false, true ]) {
		const state = await readyDialog();
		state.inputs()[1].value = state.inputs()[2].value = 'eight-characters';
		const pending = state.submit();
		state.setActive(false);
		if (rejects)
			state.moduleReply.reject(new Error('late class load failure'));
		else
			state.moduleReply.resolve(state.bcrypt);
		await pending;
		assert.equal(state.events.some(Array.isArray), false, 'leaving during module loading must prevent hashing and submission');
		assert.equal(state.failures.length, 0, 'an obsolete module response must not display an error');
		assert.equal(state.inputs().every(input => input.value === ''), true);
	}

	const inactive = loadOverview();
	const pending = inactive.view.openCredentialsDialog();
	inactive.setActive(false);
	inactive.credentialReply.resolve(info);
	await pending;
	assert.equal(inactive.modals.length, 0);
	assert.equal(inactive.failures.length, 0, 'obsolete account information must not become XHR/modals on a new page');

	const alreadyInactive = loadOverview();
	alreadyInactive.setActive(false);
	await alreadyInactive.view.openCredentialsDialog();
	assert.deepEqual(alreadyInactive.events, [], 'an inactive page must not initiate the optional module or credential request');

	const hashing = await readyDialog();
	const hashReply = deferred();
	const hashingStarted = deferred();
	hashing.bcrypt.hash = () => { hashingStarted.resolve(); return hashReply.promise; };
	hashing.moduleReply.resolve(hashing.bcrypt);
	hashing.inputs()[1].value = hashing.inputs()[2].value = 'eight-characters';
	const pendingHash = hashing.submit();
	await hashingStarted.promise;
	assert.equal(hashing.view.credentialsPreparing, true, 'hashing must hold the same guard as the credential worker');
	hashing.setActive(false);
	hashReply.resolve(encodedHash);
	await pendingHash;
	assert.equal(hashing.events.some(Array.isArray), false,
		'finishing a hash after leaving the page must not submit a credential mutation');
	assert.equal(hashing.failures.length, 0);

	const focus = await readyDialog();
	focus.setActive(false);
	for (const timer of focus.timers)
		timer();
	assert.equal(focus.events.includes('input-focused'), false,
		'the deferred focus must not target an inactive page');
	assert.doesNotMatch(source, /require adguardhome\.bcrypt as/);
	console.log('lazy bcrypt loading, credential validation/submission and inactive-page protection tests passed');
}

main().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
