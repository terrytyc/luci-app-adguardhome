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
const yamlSource = fs.readFileSync(path.join(
	packageRoot,
	'htdocs/luci-static/resources/view/adguardhome/yaml.js'
), 'utf8');
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
		assert.ok(selector.trim() === '.adguardhome-view' ||
			selector.trim().startsWith('.adguardhome-view '),
			`plugin styling must not change the global LuCI theme: ${selector}`);
}
assert.doesNotMatch(css, /!important/);
assert.match(css, /\.adguardhome-view\s*\{[^}]*width:\s*100%;[^}]*margin-inline:\s*0/,
	'the page content must align with the full-width tab bar');
assert.doesNotMatch(css, /\.adguardhome-view\s*\{[^}]*max-width:/,
	'the page must not retain a fixed desktop width cap');
assert.match(css, /\.adguardhome-status-grid\s*> div\s*\{[^}]*grid-template-columns:\s*12\.5rem minmax\(0, 1fr\)/,
	'overview rows must use one aligned label/value pair');
assert.match(css, /\.adguardhome-status-grid dt\s*\{[^}]*text-align:\s*right/);
assert.match(css, /\.adguardhome-status-grid\s*\{[^}]*margin:\s*0 1rem 1rem/);
assert.match(css, /\.adguardhome-version\s*\{[^}]*margin:\s*1rem 1\.25rem;[^}]*padding:\s*0/,
	'the core version must sit outside the settings card at the same page inset');
assert.match(css, /@media\s*\(max-width:\s*700px\)[\s\S]*\.adguardhome-status-grid > div\s*\{[^}]*grid-template-columns:\s*1fr/);
assert.match(css, /\.adguardhome-action-button\s*\{[^}]*width:\s*150px;[^}]*min-width:\s*150px;[^}]*min-height:\s*40px/);
assert.match(css, /\.adguardhome-action-button\s*\{[^}]*padding-block:\s*0;[^}]*line-height:\s*1\.5/,
	'the two actions must share the same compact dimensions');
assert.match(css, /#cbi-json-config-_change_credentials \.cbi-value-title\s*\{[^}]*min-height:\s*40px/,
	'the empty credential label must keep the theme value column aligned');
assert.match(css, /@media\s*\(max-width:\s*700px\)[\s\S]*#cbi-json-config-_change_credentials \.cbi-value-title\s*\{[^}]*display:\s*none/,
	'the empty credential label must disappear with the mobile label column');
assert.match(css, /\[data-section-id="config"\] \.cbi-value-title\s*\{[^}]*width:\s*13\.5rem/,
	'the settings values must align with the overview values');
assert.match(css, /\[data-widget="CBI\.FlagValue"\] > \.cbi-value-title\s*\{[^}]*min-height:\s*40px;[^}]*line-height:\s*40px/,
	'checkbox labels must share the checkbox row centerline');
assert.match(css, /\.adguardhome-log-output\s*\{[^}]*font-size:\s*14px;[^}]*line-height:\s*1\.5/);
assert.match(css, /\.adguardhome-log-output\s*\{[^}]*min-height:\s*0/,
	'empty logs must remain compact');
assert.match(css, /\.adguardhome-yaml-editor\s*\{[^}]*height:\s*calc\(100vh - 24rem\);[^}]*min-height:\s*18rem;[^}]*max-height:\s*65vh;[^}]*resize:\s*vertical/,
	'the YAML editor must follow the viewport while retaining useful resize bounds');
assert.match(css, /\.adguardhome-yaml-editor\s*\{[^}]*width:\s*calc\(100% - 2rem\);[^}]*margin-inline:\s*1rem/,
	'the editor must not touch the section boundary');
assert.match(css, /\.adguardhome-yaml-heading > h3\s*\{[^}]*width:\s*auto;[^}]*background:\s*transparent/,
	'the theme heading background must not separate the draft indicator');
assert.match(css, /\.adguardhome-yaml-editor:focus-within\s*\{[^}]*border-color:/,
	'the transparent native editor must retain a visible focus indicator');
assert.match(css, /\.adguardhome-yaml-editor::before\s*\{[^}]*width:\s*3rem;[^}]*background:\s*rgba\(127, 127, 127, \.08\)/,
	'only the stable line-number gutter needs a neutral background');
assert.match(css, /\.adguardhome-yaml-line\s*\{[^}]*display:\s*block;[^}]*background:\s*transparent/);
assert.match(css, /\.adguardhome-yaml-line\.active\s*\{[^}]*background:\s*rgba\(80, 120, 220, \.08\)/);
assert.match(css, /\.adguardhome-editor\s*\{[^}]*color:\s*transparent;[^}]*caret-color:/,
	'the native textarea caret must remain visible over the presentation layer');
assert.match(css, /@media\s*\(forced-colors:\s*active\)[\s\S]*-webkit-text-fill-color:\s*CanvasText/,
	'forced-colors mode must fall back to readable native textarea text');
assert.match(yamlSource, /class:\s*'adguardhome-editor'/);
assert.doesNotMatch(yamlSource, /cbi-input-textarea/,
	'theme textarea backgrounds must not cover the YAML presentation layer');
assert.match(yamlSource, /this\.pathValue = E\('span'/,
	'the YAML path must not inherit the theme code-token background');
assert.match(css, /\[data-section-id="config"\]\.cbi-section-node\s*\{[^}]*padding-bottom:\s*1rem/,
	'the account action needs space from the bottom of the settings card');
assert.match(css, /\.adguardhome-yaml-path\s*\{[^}]*margin:\s*0;[^}]*padding:\s*0 1rem 1rem/,
	'the theme paragraph padding must not double-indent the YAML path');
assert.match(css, /\.adguardhome-yaml-heading ~ \.adguardhome-actions\s*\{[^}]*margin:\s*0;[^}]*padding-inline:\s*1rem/,
	'the theme action padding must be normalized without an extra margin');
assert.match(css, /\.adguardhome-actions,\s*\.adguardhome-view \.adguardhome-actions-secondary\s*\{[^}]*flex-wrap:\s*wrap/);
assert.match(css, /\.adguardhome-log-toolbar\s*\{[^}]*gap:\s*\.75rem 1rem;[^}]*padding:\s*\.75rem 1rem/,
	'the log controls must have consistent spacing and section padding');
assert.match(css, /\.adguardhome-log-toolbar label\s*\{[^}]*display:\s*inline-flex;[^}]*align-items:\s*center;[^}]*gap:\s*\.5rem/,
	'the log control labels and inputs must align as compact groups');
assert.match(css, /\.adguardhome-log-toolbar label > input\[type="checkbox"\]\s*\{[^}]*position:\s*static;[^}]*margin:\s*0/,
	'the wrap checkbox must not inherit the theme offset');
assert.match(css, /\.adguardhome-log-toolbar \.cbi-button\s*\{[^}]*margin-left:\s*auto/,
	'the refresh action must sit apart from the log display controls');
assert.match(css, /details\.cbi-section > summary\s*\{[^}]*min-height:\s*40px;[^}]*padding:\s*\.75rem 1rem;[^}]*list-style-position:\s*inside/,
	'the collapsible log headings must keep their native marker and section spacing');
assert.match(css, /\.cbi-value-description\s*\{[^}]*font-size:\s*13px;[^}]*line-height:\s*1\.5;[^}]*color:\s*inherit;[^}]*opacity:\s*1/,
	'help must remain readable without overriding light or dark theme text colors');
assert.match(source, /Only data is copied to RAM; the core executable and YAML stay in place/);
assert.equal((source.match(/power loss/g) ?? []).length, 1,
	'the RAM consistency warning should be explained once, not repeated for the interval');
assert.match(source, /0 disables scheduled write-back\. A normal stop or restart still writes data back/);
assert.match(source, /form\.DummyValue, '_change_credentials', ' '\)/,
	'the credential action must keep form alignment without a visible row label');
assert.equal((source.match(/adguardhome-action-button/g) ?? []).length, 3,
	'the management link, disabled management button and credential action must share one compact size');
assert.doesNotMatch(source, /adguardhome-management-url|_\('Management interface'\)/,
	'the overview must not show a management label or target URL');
for (const label of [ 'None', 'Use AdGuard Home as dnsmasq upstream', 'Redirect port 53' ])
	assert.match(source, new RegExp(`option\\.value\\([^\\n]+_\\('${label}'\\)\\)`));
assert.match(source, /ui\.showModal\(_\('Change AdGuard Home Account'\)/);

console.log('scoped responsive overview, readable shared styles and credential modal contracts passed');
