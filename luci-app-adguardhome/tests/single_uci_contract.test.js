'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const packageRoot = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(packageRoot, relative), 'utf8');

const overview = read('htdocs/luci-static/resources/view/adguardhome/overview.js');
const yamlView = read('htdocs/luci-static/resources/view/adguardhome/yaml.js');
const rpc = read('root/usr/share/rpcd/ucode/luci.adguardhome');
const acl = JSON.parse(read('root/usr/share/rpcd/acl.d/luci-app-adguardhome.json'));
const menu = JSON.parse(read('root/usr/share/luci/menu.d/luci-app-adguardhome.json'));
const ucitrackPath = path.join(
	packageRoot,
	'root/usr/share/ucitrack/luci-app-adguardhome.json'
);

function extractFunction(source, name) {
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

async function testYamlViewPermissionGuard() {
	let yamlReads = 0;
	let writeCalls = 0;
	let successes = 0;
	const notifications = [];
	const scope = {
		attach(node) { return node; },
	};
	const rpcHandlers = {
		get_yaml: async () => {
			yamlReads++;
			return {
				content: 'http:\n  address: 0.0.0.0:3000\n',
				sha256: 'a'.repeat(64),
				path: '/etc/AdGuardHome/AdGuardHome.yaml',
			};
		},
		set_yaml: async () => { writeCalls++; return {}; },
		reset_yaml: async () => { writeCalls++; return {}; },
		get_yaml_update: async () => { writeCalls++; return {}; },
	};
	const operation = {
		createPageScope: () => scope,
		isPageActive: () => true,
		isPageInactiveError: () => false,
		pageInactiveError: () => Object.assign(new Error('inactive'), { pageInactive: true }),
		abandonInactiveLoad: error => { throw error; },
		requestDuringApply: request => request(),
		start: () => ({}),
		success: () => { successes++; },
		failure: message => { throw new Error(String(message)); },
	};
	const declaredRpc = {
		declare: specification => async (...args) => rpcHandlers[specification.method](...args),
	};
	const ui = {
		createHandlerFn: () => () => {},
		addNotification: (...args) => notifications.push(args),
		showModal() {},
	};
	const element = (tag, attrs = {}, children = []) => {
		const childList = Array.isArray(children) ? children : [ children ];
		const node = {
			tag,
			attrs,
			children: childList,
			disabled: attrs?.disabled != null,
			readOnly: attrs?.readonly != null,
			textContent: childList.map(value => String(value ?? '')).join(''),
			value: childList.map(value => String(value ?? '')).join(''),
		};
		return node;
	};
	const view = { extend: definition => definition };
	const translate = value => Object.assign(new String(value), {
		format: replacement => value.replace('%s', String(replacement)),
	});
	const sandbox = {
		E: element,
		L: { hasViewPermission: () => false },
		_: translate,
		window: { setTimeout },
	};
	vm.createContext(sandbox);
	const definition = vm.runInContext(
		'(function(operation, rpc, ui, view, window, L, E, _) {\n' + yamlView +
			'\n}).call(globalThis, operation, rpc, ui, view, window, L, E, _)',
		Object.assign(sandbox, { operation, rpc: declaredRpc, ui, view }),
		{ filename: 'yaml.js' },
	);

	const loaded = await definition.load.call(definition);
	definition.render.call(definition, loaded);
	assert.equal(definition.yamlEditor.readOnly, true,
		'the frontend must keep the YAML editor read-only without write permission');
	assert.equal(definition.saveButton.disabled, true,
		'the frontend must disable YAML saving without write permission');
	assert.equal(definition.resetButton.disabled, true,
		'the frontend must disable template reset without write permission');
	assert.equal(definition.reloadButton.disabled, false,
		'the frontend permission guard must not break an already authorized YAML reload');

	await definition.handleReload.call(definition);
	assert.equal(yamlReads, 2,
		'the YAML page must load once and permit one explicit reload');
	assert.equal(writeCalls, 0,
		'the permission guard must not invoke a YAML mutation RPC');
	assert.equal(successes, 1);
	assert.equal(definition.yamlEditor.readOnly, true);
	assert.equal(definition.saveButton.disabled, true);
	assert.equal(definition.resetButton.disabled, true);

	rpcHandlers.get_yaml = async () => {
		yamlReads++;
		throw new Error('Access denied');
	};
	const denied = await definition.load.call(definition);
	assert.equal(denied.content, '',
		'an ACL denial must not expose stale YAML content');
	assert.equal(denied.sha256, '',
		'an ACL denial must not expose a usable YAML revision');
	assert.match(String(denied.error?.message), /Access denied/,
		'the YAML page must retain an ACL denial as a handled load error');
	definition.render.call(definition, denied);
	assert.equal(definition.yamlEditor.value, '',
		'the ACL-denied editor must be empty');
	assert.equal(definition.yamlEditor.readOnly, true,
		'the ACL-denied editor must remain read-only');
	assert.equal(definition.saveButton.disabled, true,
		'the ACL-denied page must disable YAML saving');
	assert.equal(definition.resetButton.disabled, true,
		'the ACL-denied page must disable template reset');
	assert.equal(notifications.length, 1,
		'the ACL denial must be reported through the handled page notification');
	assert.equal(writeCalls, 0,
		'the ACL-denied path must not invoke a YAML mutation RPC');
}

assert.match(overview, /^const CORE_SECTION_NAME = 'config';$/m,
	'the local settings model must keep official options in config');
assert.match(overview, /^const LUCI_SECTION_NAME = 'luci';$/m,
	'the local settings model must keep plugin options in luci');
assert.doesNotMatch(overview, /require uci|uci\.load\(|new form\.Map\(/,
	'the settings page must not access UCI or the global UCI form path');
assert.match(overview, /new form\.JSONMap\(/,
	'the settings page must use an RPC-backed local JSON model');
assert.match(overview, /method: 'get_settings'/,
	'the settings page must load its local model through RPC');
assert.match(overview, /method: 'set_settings'/,
	'the settings page must submit its local model through one RPC transaction');
assert.match(overview, /method: 'get_settings_update'/,
	'the settings page must poll the asynchronous transaction through RPC');
const setDeclarationStart = overview.indexOf('const callSetSettings = rpc.declare({');
const setDeclarationEnd = overview.indexOf('const callGetSettingsUpdate', setDeclarationStart);
assert.ok(setDeclarationStart >= 0 && setDeclarationEnd > setDeclarationStart);
assert.doesNotMatch(overview.slice(setDeclarationStart, setDeclarationEnd), /config_file/,
	'the frontend settings RPC must not submit the workdir-derived config_file');
assert.doesNotMatch(overview, /ui\.changes\.apply\(|operation\.markApplyPending\(/,
	'the settings page must not invoke a second global LuCI apply');

const coreStart = overview.indexOf('const coreSection = map.section(');
const luciStart = overview.indexOf('const luciSection = map.section(');
const renderStart = overview.indexOf('const rendered = await map.render();');
assert.ok(coreStart >= 0 && luciStart > coreStart && renderStart > luciStart,
	'the settings form must define core and LuCI sections before rendering');

const coreBlock = overview.slice(coreStart, luciStart);
const luciBlock = overview.slice(luciStart, renderStart);
for (const option of [ 'enabled', 'work_dir', 'verbose' ])
	assert.ok(coreBlock.includes(`'${option}'`),
		`official option ${option} must be rendered from config`);
assert.ok(!coreBlock.includes("'config_file'"),
	'config_file must stay derived from work_dir instead of becoming a separate form field');
for (const option of [ 'redirect', 'run_from_memory', 'memory_writeback_interval' ])
	assert.ok(luciBlock.includes(`'${option}'`),
		`plugin option ${option} must be rendered from luci`);
for (const option of [ 'redirect', 'run_from_memory', 'memory_writeback_interval' ])
	assert.ok(!coreBlock.includes(`'${option}'`),
		`plugin option ${option} must not be stored in config`);
for (const option of [ 'enabled', 'work_dir', 'verbose', 'config_file' ])
	assert.ok(!luciBlock.includes(`'${option}'`),
		`official option ${option} must not be stored in luci`);
assert.doesNotMatch(overview, /['"]workdir['"]/,
	'the settings form must not expose the obsolete workdir option');
assert.match(luciBlock, /option\.retain = true;[\s\S]*?option\.depends\('run_from_memory', '1'\);/,
	'the hidden write-back interval must remain in the JSON model while RAM is disabled');

const settingsFromMapSource = extractFunction(overview, 'settingsFromMap');
const settingsMapDataSource = extractFunction(overview, 'settingsMapData');
assert.doesNotMatch(settingsMapDataSource, /config_file|configFile/,
	'the frontend JSON model must not carry the derived config_file');
const settingsSandbox = {
	CORE_SECTION_NAME: 'config',
	LUCI_SECTION_NAME: 'luci',
	MAX_MEMORY_WRITEBACK_INTERVAL: 10080,
	_: value => value,
};
const hiddenIntervalMap = {
	data: {
		get(_type, section, option) {
			return {
				'config.enabled': '1',
				'config.work_dir': '/etc/AdGuardHome',
				'config.verbose': '0',
				'luci.redirect': 'dnsmasq-upstream',
				'luci.run_from_memory': '0',
				'luci.memory_writeback_interval': null,
			}[`${section}.${option}`];
		},
	},
};
vm.createContext(settingsSandbox);
vm.runInContext(`${settingsFromMapSource}; this.settingsFromMap = settingsFromMap;`, settingsSandbox);
const hiddenIntervalCandidate = settingsSandbox.settingsFromMap(
	hiddenIntervalMap,
	'a'.repeat(64),
	60,
);
assert.equal(hiddenIntervalCandidate.runFromMemory, false);
assert.equal(hiddenIntervalCandidate.memoryWritebackInterval, 60,
	'a RAM-off save must retain the loaded write-back interval');

assert.match(rpc, /^const CONFIG_NAME = 'adguardhome';$/m,
	'the RPC backend must read the single lowercase UCI package');
assert.match(rpc, /^const CONFIG_SECTION = 'config';$/m,
	'the RPC backend must read official options from config');
assert.match(rpc, /^const LUCI_SECTION = 'luci';$/m,
	'the RPC backend must read plugin options from luci');
assert.doesNotMatch(rpc, /uci\.get\([^\n]*['"]workdir['"]/,
	'the RPC backend must not fall back to the obsolete workdir option');
assert.doesNotMatch(rpc, /uci\.(?:get|unload)\(['"]AdGuardHome['"]/,
	'the RPC backend must not access the removed mixed-case UCI package');

const permission = acl['luci-app-adguardhome'];
assert.equal(permission.read.uci, undefined,
	'the browser must not receive direct UCI read access');
assert.equal(permission.write.uci, undefined,
	'the browser must not receive direct UCI write access');
assert.ok(permission.read.ubus['luci.adguardhome'].includes('get_settings'),
	'the read ACL must expose the settings snapshot RPC');
assert.ok(!permission.read.ubus['luci.adguardhome'].includes('get_yaml'),
	'the read ACL must not expose YAML secrets to read-only sessions');
assert.ok(permission.write.ubus['luci.adguardhome'].includes('get_yaml'),
	'the YAML snapshot RPC must require write access');
assert.ok(permission.write.ubus['luci.adguardhome'].includes('set_settings'),
	'the write ACL must expose the settings transaction RPC');
assert.ok(permission.write.ubus['luci.adguardhome'].includes('get_settings_update'),
	'the write ACL must expose settings job polling');
for (const legacyMethod of [ 'get_password_info', 'set_password' ]) {
	assert.ok(!permission.write.ubus['luci.adguardhome'].includes(legacyMethod),
		`the write ACL must not expose removed legacy RPC ${legacyMethod}`);
}
assert.deepEqual(
	menu['admin/services/adguardhome'].depends.uci,
	{ adguardhome: true },
	'the menu must depend on the lowercase UCI package'
);
assert.equal(fs.existsSync(ucitrackPath), false,
	'the app must not register a duplicate global UCI apply trigger');

testYamlViewPermissionGuard().then(() => {
	console.log('2.4 RPC-owned single-UCI frontend and metadata contract tests passed');
}).catch(error => {
	console.error(error);
	process.exitCode = 1;
});
