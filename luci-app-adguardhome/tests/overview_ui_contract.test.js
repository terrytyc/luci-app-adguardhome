'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const overviewPath = path.join(
	packageRoot,
	'htdocs/luci-static/resources/view/adguardhome/overview.js'
);
const source = fs.readFileSync(overviewPath, 'utf8');

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

const credentialFieldSource = extractFunction('credentialField');
const sandbox = {
	E(tag, attrs, children) {
		return { tag, attrs: attrs ?? {}, children };
	},
};
vm.createContext(sandbox);
vm.runInContext(
	`${credentialFieldSource}\nthis.credentialField = credentialField;`,
	sandbox,
	{ filename: overviewPath },
);

const input = { tag: 'input' };
const field = sandbox.credentialField('New username', input);
assert.equal(field.tag, 'label');
assert.equal(field.attrs.class, 'adguardhome-credential-field');
assert.match(field.attrs.style, /display:\s*block/);
assert.match(field.attrs.style, /width:\s*100%/);
assert.equal(field.children.length, 2);
assert.equal(field.children[0].tag, 'span');
assert.equal(field.children[0].attrs.class, 'adguardhome-credential-title');
assert.match(field.children[0].attrs.style, /display:\s*block/);
assert.match(field.children[0].attrs.style, /text-align:\s*left/);
assert.equal(field.children[1], input);

assert.doesNotMatch(source, /class:\s*'cbi-value(?:-title|-field)?'/,
	'the modal must not inherit page-width CBI label columns from a theme');
for (const title of [ 'New username', 'New password', 'Confirm password' ])
	assert.match(source, new RegExp(`credentialField\\(_\\('${title}'\\), [^)]+\\)`));

const boundedInputStyles = source.match(
	/style:\s*'width: 100%; max-width: 100%; min-width: 0; box-sizing: border-box'/g
) ?? [];
assert.equal(boundedInputStyles.length, 3,
	'all credential inputs must remain within the modal at desktop and mobile widths');

console.log('overview credential modal layout contract tests passed');
