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
const extractFunction = require('./lib/source').extractFunction.bind(null, source);
const css = fs.readFileSync(path.join(packageRoot,
	'htdocs/luci-static/resources/adguardhome/style.css'), 'utf8');

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

for (const match of css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{/g)) {
	const selectors = match[1].trim();
	if (selectors.startsWith('@media'))
		continue;
	for (const selector of selectors.split(','))
		assert.ok(selector.trim().startsWith('.adguardhome-view '),
			`plugin styling must not change the global LuCI theme: ${selector}`);
}
assert.doesNotMatch(css, /!important/);
assert.match(css, /grid-template-columns:\s*repeat\(2, minmax\(0, 1fr\)\)/);
assert.match(css, /\.adguardhome-status-grid\s*\{[^}]*margin:\s*0 1\.25rem/);
assert.match(css, /\.adguardhome-version\s*\{[^}]*margin:\s*1rem 1\.25rem;[^}]*padding:\s*0/,
	'overview values and version text must align with the native section heading');
assert.match(css, /@media\s*\(max-width:\s*700px\)[\s\S]*grid-template-columns:\s*1fr/);
assert.match(css, /\.adguardhome-management-button\s*\{[^}]*min-height:\s*40px/);
assert.match(css, /\.adguardhome-management-button\s*\{[^}]*padding-block:\s*0;[^}]*line-height:\s*1\.5/,
	'the link must not retain oversized theme padding or an inherited form-row line height');
assert.match(css, /\.adguardhome-log-output\s*\{[^}]*font-size:\s*14px;[^}]*line-height:\s*1\.5/);
assert.match(css, /\.adguardhome-editor,\s*\.adguardhome-view \.adguardhome-log-output\s*\{[^}]*min-width:\s*0/,
	'both textareas must override the theme minimum width on narrow screens');
assert.match(css, /\.adguardhome-editor,\s*\.adguardhome-view \.adguardhome-log-output\s*\{[^}]*color:\s*inherit/,
	'editor and log text must follow the theme body color instead of a fixed pale input color');
assert.doesNotMatch(css.match(/\.adguardhome-log-output\s*\{([^}]*)\}/)[1], /^\s*(?:min-|max-)?height\s*:/m,
	'empty one-row logs must not be forced into a tall viewport');
assert.match(css, /\.adguardhome-view \.adguardhome-log-output\s*\{\s*min-height:\s*0;\s*\}/,
	'empty logs must override the theme textarea minimum height so rows=1 works');
assert.match(css, /\.adguardhome-actions\s*\{[^}]*flex-wrap:\s*wrap/);
assert.match(css, /\.cbi-value-description\s*\{[^}]*font-size:\s*13px;[^}]*line-height:\s*1\.5;[^}]*color:\s*inherit;[^}]*opacity:\s*1/,
	'help must remain readable without overriding light or dark theme text colors');
assert.match(source, /Only data is copied to RAM; the core executable and YAML stay in place/);
assert.equal((source.match(/power loss/g) ?? []).length, 1,
	'the RAM consistency warning should be explained once, not repeated for the interval');
assert.match(source, /0 disables scheduled write-back\. A normal stop or restart still writes data back/);
assert.match(source, /_\('AdGuard Home account'\)/);
assert.match(source, /ui\.showModal\(_\('Change AdGuard Home Account'\)/);

console.log('scoped responsive overview, readable shared styles and credential modal contracts passed');
