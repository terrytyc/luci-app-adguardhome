'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/view/adguardhome/yaml.js'), 'utf8');
const context = vm.createContext({ rpc: { declare() {} } });
vm.runInContext(source.slice(0, source.indexOf('return view.extend')), context);

for (const [value, expected] of [
	['', ''],
	[' \t ', ' \t '],
	['  true\t', '  <span class="adguardhome-yaml-literal">true</span>\t'],
	['\t12  ', '\t<span class="adguardhome-yaml-number">12</span>  '],
	[' &<> ', ' <span class="adguardhome-yaml-scalar">&amp;&lt;&gt;</span> '],
	['  first   last  ', '  first   last  '],
]) {
	context.value = value;
	assert.equal(vm.runInContext('highlightYamlScalar(value)', context), expected);
}

// Stay below the normal highlighting limit; the old whitespace regex takes seconds.
context.value = 'first' + ' '.repeat(120000) + 'last';
for (const prefix of ['', 'key: ', '- ']) {
	context.line = prefix + context.value;
	const expected = prefix === 'key: '
		? '<span class="adguardhome-yaml-key">key</span>: ' + context.value
		: context.line;
	assert.equal(vm.runInContext('highlightYamlLine(line)', context, { timeout: 1000 }), expected);
}

console.log('YAML scalar whitespace, escaping and bounded highlighting tests passed');
