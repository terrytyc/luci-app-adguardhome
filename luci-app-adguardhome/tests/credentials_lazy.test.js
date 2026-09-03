'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const overviewPath = path.join(__dirname,
	'../htdocs/luci-static/resources/view/adguardhome/overview.js');
const source = fs.readFileSync(overviewPath, 'utf8');
const info = { available: true, username: 'admin', sha256: 'a'.repeat(64) };
const encodedHash = '$2b$10$' + 'a'.repeat(53);

function deferred() {
	let resolve, reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
}

function loadOverview() {
	const events = [];
	const nodes = [];
	const modals = [];
	const failures = [];
	const timers = [];
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
		start() { events.push('operation-start'); return scope; },
		success(_message, ticket) { assert.equal(ticket, scope); events.push('operation-success'); },
		failure(message) { failures.push(String(message)); },
		async waitForJob(statusFn, token, currentScope) {
			assert.equal(currentScope, scope);
			const result = await statusFn(token, false);
			await statusFn(token, true);
			return result;
		},
	};
	class BcryptInstance {
		truncates(password) {
			assert.equal(this, bcrypt, 'methods must run on the loaded class instance');
			return Buffer.byteLength(password, 'utf8') > 72;
		}
		async hash(password) {
			assert.equal(this, bcrypt);
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
		get_yaml_update: (token, consume) => {
			events.push([ 'get_yaml_update', token, consume ]);
			return { state: 'done', ok: true };
		},
	};
	const context = {
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
		view, bcrypt, credentialReply, moduleReply, events, nodes, modals, failures, timers,
		setActive(value) { active = value; },
		inputs() { return nodes.filter(node => node.tag === 'input'); },
		submit() { return nodes.find(node => node.tag === 'button' && node.events.click).events.click(); },
	};
}

async function readyDialog() {
	const state = loadOverview();
	assert.deepEqual(state.events, [], 'overview module initialization must not load bcrypt');
	const pending = state.view.openCredentialsDialog();
	assert.deepEqual(state.events, [ 'get_credentials', 'require-bcrypt' ],
		'credentials and the optional class must load in parallel only when opening the dialog');
	state.credentialReply.resolve(info);
	await Promise.resolve();
	assert.equal(state.modals.length, 0, 'the dialog must wait for its hashing dependency');
	state.moduleReply.resolve(state.bcrypt);
	await pending;
	assert.equal(state.modals.length, 1);
	assert.equal(state.modals[0].title, 'Change AdGuard Home Account');
	assert.equal(state.inputs().length, 3);
	assert.equal(state.failures.length, 0);
	return state;
}

async function main() {
	const success = await readyDialog();
	const [ username, password, confirmation ] = success.inputs();
	username.value = 'operator';
	password.value = confirmation.value = 'eight-characters';
	await success.submit();
	assert.deepEqual(success.events.filter(Array.isArray), [
		[ 'hash', 'eight-characters' ],
		[ 'set_credentials', 'operator', encodedHash, info.sha256 ],
		[ 'get_yaml_update', 'b'.repeat(32), false ],
		[ 'get_yaml_update', 'b'.repeat(32), true ],
	]);
	assert.equal(success.events.includes('operation-success'), true);
	assert.equal(success.inputs().every(input => input.value === ''), true,
		'credential inputs must still be cleared after submission');

	for (const [ value, expected ] of [
		[ 'short', 'at least 8 characters' ],
		[ '界'.repeat(25), '72-byte BCrypt limit' ],
	]) {
		const state = await readyDialog();
		state.inputs()[1].value = state.inputs()[2].value = value;
		await state.submit();
		const error = state.nodes.find(node => node.tag === 'p' && node.className === 'alert-message error');
		assert.equal(String(error?.textContent).includes(expected), true);
		assert.equal(state.events.some(Array.isArray), false, 'invalid passwords must not hash or submit');
	}

	const renamed = await readyDialog();
	renamed.inputs()[0].value = 'operator';
	await renamed.submit();
	assert.deepEqual(renamed.events.find(Array.isArray), [ 'set_credentials', 'operator', '', info.sha256 ],
		'username-only updates must preserve the password without hashing an empty string');

	for (const failedDependency of [ 'moduleReply', 'credentialReply' ]) {
		const state = loadOverview();
		const pending = state.view.openCredentialsDialog();
		state[failedDependency].reject(new Error('load failed'));
		await pending;
		assert.equal(state.modals.length, 0);
		assert.equal(state.failures.length, 1);
		assert.match(state.failures[0], /Unable to prepare.*load failed/);
		state.moduleReply.resolve(state.bcrypt);
		state.credentialReply.resolve(info);
	}

	const inactive = loadOverview();
	const pending = inactive.view.openCredentialsDialog();
	inactive.setActive(false);
	inactive.credentialReply.resolve(info);
	inactive.moduleReply.reject(new Error('late class load failure'));
	await pending;
	assert.equal(inactive.modals.length, 0);
	assert.equal(inactive.failures.length, 0, 'obsolete class-load errors must not become XHR/modals on a new page');

	const alreadyInactive = loadOverview();
	alreadyInactive.setActive(false);
	await alreadyInactive.view.openCredentialsDialog();
	assert.deepEqual(alreadyInactive.events, [], 'an inactive page must not initiate the optional module or credential request');

	const hashing = await readyDialog();
	const hashReply = deferred();
	hashing.bcrypt.hash = () => hashReply.promise;
	hashing.inputs()[1].value = hashing.inputs()[2].value = 'eight-characters';
	const pendingHash = hashing.submit();
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
