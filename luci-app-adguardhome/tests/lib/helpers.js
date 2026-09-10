'use strict';

function translated(value) {
	const result = new String(value);
	result.format = (...args) => {
		let offset = 0;
		return value.replace(/%[sd]/g, () => String(args[offset++]));
	};
	return result;
}

function deferred() {
	let resolve, reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
}

module.exports = { translated, deferred };
