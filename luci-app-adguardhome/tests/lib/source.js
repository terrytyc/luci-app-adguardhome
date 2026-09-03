'use strict';

const assert = require('node:assert/strict');

// ponytail: current fixtures have balanced literal braces; use a parser only if that changes.
function extractFunction(source, name) {
	const start = source.indexOf(`function ${name}(`);
	assert.notEqual(start, -1, `missing ${name}()`);
	const body = source.indexOf('{', start);
	assert.notEqual(body, -1, `missing ${name}() body`);
	let depth = 0;
	for (let offset = body; offset < source.length; offset++) {
		if (source[offset] === '{')
			depth++;
		else if (source[offset] === '}' && --depth === 0)
			return source.slice(start, offset + 1);
	}
	assert.fail(`unterminated ${name}()`);
}

module.exports = { extractFunction };
