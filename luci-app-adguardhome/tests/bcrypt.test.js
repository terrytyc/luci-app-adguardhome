'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');

const modulePath = path.resolve(
	__dirname,
	'../htdocs/luci-static/resources/adguardhome/bcrypt.js'
);
const moduleSource = fs.readFileSync(modulePath, 'utf8');

function createLuCIClass() {
	function LuCIClass() {}

	LuCIClass.extend = function(definition) {
		function DerivedClass() {}

		DerivedClass.prototype = Object.create(this.prototype);
		Object.assign(DerivedClass.prototype, definition);
		Object.defineProperty(DerivedClass.prototype, 'constructor', {
			value: DerivedClass,
			writable: true,
			configurable: true
		});
		DerivedClass.extend = this.extend;
		return DerivedClass;
	};

	LuCIClass.isSubclass = function(candidate) {
		return typeof candidate === 'function' &&
			candidate.prototype instanceof LuCIClass;
	};
	assert.equal(LuCIClass.isSubclass({}), false,
		'plain-object factories must be rejected like the real LuCI loader');

	return LuCIClass;
}

function loadModule(cryptoImplementation) {
	const LuCIClass = createLuCIClass();
	const sandbox = {
		crypto: cryptoImplementation,
		setImmediate: setImmediate,
		setTimeout: setTimeout
	};

	vm.createContext(sandbox);

	const ModuleClass = vm.runInContext(
		'(function(window, document, L, baseclass) {\n' + moduleSource +
			'\n}).call(globalThis, globalThis, null, {}, LuCIClass)',
		Object.assign(sandbox, { LuCIClass: LuCIClass }),
		{ filename: modulePath }
	);

	assert.equal(
		LuCIClass.isSubclass(ModuleClass),
		true,
		'LuCI resource factory must yield an L.Class constructor'
	);

	return new ModuleClass();
}

async function main() {
	assert.doesNotMatch(moduleSource, /\beval\s*\(/);
	assert.doesNotMatch(moduleSource, /\bnew\s+Function\b/);
	assert.doesNotMatch(moduleSource, /Math\.random/);
	assert.match(moduleSource, /^'use strict';\s*'require baseclass';/);

	let randomCalls = 0;
	const trackedCrypto = {
		getRandomValues: function(array) {
			randomCalls++;
			return webcrypto.getRandomValues(array);
		}
	};
	const bcrypt = loadModule(trackedCrypto);
	assert.equal(bcrypt.COST, 10);
	assert.equal(bcrypt.MAX_PASSWORD_BYTES, 72);
	assert.equal(typeof bcrypt.hash, 'function');
	assert.equal(typeof bcrypt.compare, 'function');
	assert.equal(typeof bcrypt.truncates, 'function');

	assert.equal(bcrypt.truncates('x'.repeat(72)), false);
	assert.equal(bcrypt.truncates('x'.repeat(73)), true);
	assert.equal(bcrypt.truncates('界'.repeat(24)), false);
	assert.equal(bcrypt.truncates('界'.repeat(25)), true);
	assert.throws(() => bcrypt.truncates(null), /password must be a string/);

	let settled = false;
	const pendingHash = bcrypt.hash('correct horse battery staple');
	pendingHash.finally(() => {
		settled = true;
	});
	assert.equal(settled, false, 'hash() must not settle synchronously');

	const encodedHash = await pendingHash;
	assert.match(encodedHash, /^\$2b\$10\$[./A-Za-z0-9]{53}$/);
	assert.equal(await bcrypt.compare('correct horse battery staple', encodedHash), true);
	assert.equal(await bcrypt.compare('wrong password', encodedHash), false);

	const secondHash = await bcrypt.hash('correct horse battery staple');
	assert.notEqual(secondHash, encodedHash, 'each hash must use a fresh random salt');
	assert.equal(randomCalls, 2, 'each generated salt must use browser Web Crypto once');

	const defaultAdminHash =
		'$2y$10$vHRcARdPCieYG3RXWomV5evDYN.Nj/edtwEkQgQJZcK6z7qTLaIc6';
	assert.equal(await bcrypt.compare('admin', defaultAdminHash), true);
	assert.equal(await bcrypt.compare('not-admin', defaultAdminHash), false);

	await assert.rejects(
		bcrypt.hash('x'.repeat(73)),
		/72-byte UTF-8 limit/
	);
	await assert.rejects(bcrypt.hash(null), /password must be a string/);
	await assert.rejects(
		loadModule(null).hash('password'),
		/Web Crypto getRandomValues\(\) is required/
	);

	console.log('bcrypt module tests passed');
}

main().catch((err) => {
	console.error(err);
	process.exitCode = 1;
});
