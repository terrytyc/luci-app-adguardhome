'use strict';

const assert = require('node:assert/strict');
const { extractFunction } = require('./lib/source');

const selected = 'function selected(value) { if (value) { return { ok: true }; } }';
const source = `function before() {}\n${selected}\nfunction after() {}`;
assert.equal(extractFunction(source, 'selected'), selected);
assert.equal(extractFunction(source, 'before'), 'function before() {}');
assert.equal(extractFunction(source, 'after'), 'function after() {}');
assert.throws(() => extractFunction(source, 'missing'), /missing missing\(\)/);
assert.throws(() => extractFunction('function body()', 'body'), /missing body\(\) body/);
assert.throws(() => extractFunction('function unfinished() {', 'unfinished'), /unterminated unfinished\(\)/);

console.log('shared named-function source extraction tests passed');
