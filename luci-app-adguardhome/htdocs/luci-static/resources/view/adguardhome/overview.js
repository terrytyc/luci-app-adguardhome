// SPDX-License-Identifier: Apache-2.0

'use strict';

'require adguardhome.bcrypt as bcrypt';
'require adguardhome.operation as operation';
'require dom';
'require form';
'require poll';
'require rpc';
'require ui';
'require view';

const CORE_SECTION_NAME = 'config';
const LUCI_SECTION_NAME = 'luci';

const DEFAULT_WORK_DIR = '/etc/AdGuardHome';
const DEFAULT_MEMORY_WRITEBACK_INTERVAL = 60;
const MAX_MEMORY_WRITEBACK_INTERVAL = 10080;

const POLL_INTERVAL = 5;
const SAFE_PATH_RE = /^\/[A-Za-z0-9_./+@%:,=-]+$/;
const USERNAME_RE = /^[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}$/;

const callGetServiceStatus = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_status',
	expect: { '': { running: false, memory_requested: false, memory_active: false } },
});

const callGetCoreVersion = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_version',
	expect: { '': { version: null } },
});

const callGetConfigInfo = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_config_info',
	expect: { '': { dns_port: null, web: null } },
});

const callGetSettings = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_settings',
	expect: { '': {} },
	reject: true,
});

const callSetSettings = rpc.declare({
	object: 'luci.adguardhome',
	method: 'set_settings',
	params: [
		'enabled',
		'work_dir',
		'verbose',
		'redirect',
		'run_from_memory',
		'memory_writeback_interval',
		'revision',
	],
	expect: { '': { accepted: false, token: '', reused: false } },
	reject: true,
});

const callGetSettingsUpdate = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_settings_update',
	params: [ 'token', 'consume' ],
	expect: { '': { state: '', ok: false, revision: '' } },
	reject: true,
});

const callGetCredentials = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_credentials',
	expect: { '': { available: false, username: '', sha256: '' } },
	reject: true,
});

const callSetCredentials = rpc.declare({
	object: 'luci.adguardhome',
	method: 'set_credentials',
	params: [ 'username', 'password_hash', 'sha256' ],
	expect: { '': { accepted: false, token: '', reused: false } },
	reject: true,
});

const callGetYamlUpdate = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_yaml_update',
	params: [ 'token', 'consume' ],
	expect: { '': { state: '', ok: false, sha256: '', restarted: false } },
	reject: true,
});

function errorMessage(error) {
	return String(error?.message ?? error ?? _('Unknown error'));
}

function uncertainSettingsUpdateError(message) {
	const error = new Error(message);
	error.settingsUpdateUncertain = true;
	return error;
}

function waitForYamlUpdate(token, scope) {
	return operation.waitForJob(callGetYamlUpdate, token, scope, {
		unknown: _('The credential update returned an unknown job state.'),
		unavailable: _('The credential update is still running, but its status is temporarily unavailable: %s. Do not submit it again; reload this page later.'),
		pending: _('The credential update is still running. Do not submit it again; reload this page later.'),
	});
}

function waitForSettingsUpdate(token, scope) {
	return operation.waitForJob(callGetSettingsUpdate, token, scope, {
		unknown: _('The settings update returned an unknown job state.'),
		unavailable: _('The settings update is still running, but its status is temporarily unavailable: %s. Do not submit it again; reload this page later.'),
		pending: _('The settings update is still running. Do not submit it again; reload this page later.'),
	}, uncertainSettingsUpdateError);
}

async function getServiceStatus(scope) {
	try {
		const result = await operation.requestActive(callGetServiceStatus, scope);
		return {
			running: result?.running === true,
			memoryRequested: result?.memory_requested === true,
			memoryActive: result?.memory_active === true,
		};
	} catch (error) {
		if (operation.isPageInactiveError(error))
			throw error;
		console.error('Unable to query AdGuard Home service status:', error);
		return { running: false, memoryRequested: false, memoryActive: false };
	}
}

async function getCoreVersion(scope) {
	try {
		const result = await operation.requestActive(callGetCoreVersion, scope);
		return String(result?.version ?? '').trim() || _('Unknown');
	} catch (error) {
		if (operation.isPageInactiveError(error))
			throw error;
		console.error('Unable to query AdGuard Home version:', error);
		return _('Unknown');
	}
}

function normalizePort(value) {
	const port = Number(value);
	return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : null;
}

function normalizeConfigInfo(result) {
	const dnsPort = normalizePort(result?.dns_port);
	const rawWeb = result?.web;
	let web = null;

	if (rawWeb && (rawWeb.scheme === 'http' || rawWeb.scheme === 'https')) {
		const port = normalizePort(rawWeb.port);
		const host = rawWeb.host == null ? null : String(rawWeb.host);
		const httpHostIsValid = rawWeb.scheme === 'http' && host == null;
		const httpsHostIsValid = rawWeb.scheme === 'https' && host != null &&
			/^[A-Za-z0-9.-]+$/.test(host) && !host.includes('..');

		if (port != null && (httpHostIsValid || httpsHostIsValid))
			web = { scheme: rawWeb.scheme, host, port };
	}

	return { dnsPort, web };
}

async function getConfigInfo(scope) {
	try {
		return normalizeConfigInfo(await operation.requestActive(callGetConfigInfo, scope));
	} catch (error) {
		if (operation.isPageInactiveError(error))
			throw error;
		console.error('Unable to query the AdGuard Home YAML configuration:', error);
		return { dnsPort: null, web: null };
	}
}

function renderServiceStatus(running) {
	return E('span', {
		style: `color: var(${running ? '--success-color-high, #2e7d32' : '--error-color-high, #c62828'}); font-weight: bold`,
	}, running ? _('Running') : _('Not running'));
}

function renderStorageStatus(status) {
	if (status.memoryActive)
		return E('span', { style: 'color: var(--success-color-high, #2e7d32); font-weight: bold' }, _('Memory'));
	if (status.memoryRequested && status.running)
		return E('span', { style: 'color: var(--warning-color-high, #b26a00); font-weight: bold' }, _('Persistent storage (memory fallback)'));
	if (status.memoryRequested)
		return E('span', {}, _('Persistent storage (memory on next start)'));
	return E('span', {}, _('Persistent storage'));
}

function buildManagementURL(endpoint) {
	if (!endpoint)
		return null;

	const port = normalizePort(endpoint.port);
	if (port == null || (endpoint.scheme !== 'http' && endpoint.scheme !== 'https'))
		return null;

	const url = new URL(window.location.href);
	url.protocol = `${endpoint.scheme}:`;
	url.username = '';
	url.password = '';
	if (endpoint.scheme === 'https') {
		if (typeof endpoint.host !== 'string' || !/^[A-Za-z0-9.-]+$/.test(endpoint.host))
			return null;

		const expectedHost = endpoint.host.toLowerCase().replace(/\.$/, '');
		try {
			url.hostname = endpoint.host;
		} catch (error) {
			return null;
		}
		const assignedHost = url.hostname.toLowerCase().replace(/\.$/, '');
		if (assignedHost !== expectedHost)
			return null;
	}
	url.port = String(port);
	url.pathname = '/';
	url.search = '';
	url.hash = '';

	return url.toString();
}

function renderManagementLink(endpoint, running) {
	if (!running) {
		return E('span', {}, [
			E('button', {
				class: 'cbi-button cbi-button-action',
				type: 'button',
				disabled: 'disabled',
			}, _('Open Web Interface')),
			' ',
			E('em', {}, _('Enable AdGuard Home and click Save & Apply; the management interface becomes available after the service is running.')),
		]);
	}

	const url = buildManagementURL(endpoint);
	if (!url) {
		return E('span', {}, [
			E('button', {
				class: 'cbi-button cbi-button-action',
				type: 'button',
				disabled: 'disabled',
			}, _('Open Web Interface')),
			' ',
			E('em', {}, _('The YAML management endpoint is unavailable or invalid.')),
		]);
	}

	return E('a', {
		class: 'cbi-button cbi-button-action',
		href: url,
		target: '_blank',
		rel: 'noopener noreferrer',
		referrerpolicy: 'no-referrer',
	}, _('Open Web Interface'));
}

function validateWorkDir(_sectionId, value) {
	if (value == null || value === '')
		return _('This field is required.');

	value = String(value);

	if (!value.startsWith('/'))
		return _('Path must be absolute.');

	if (value === '/')
		return _('The working directory must not be the filesystem root.');

	if (value.includes('//'))
		return _('Path must not contain repeated slashes.');

	if (value.endsWith('/'))
		return _('Path must not end with a slash.');

	if (!SAFE_PATH_RE.test(value))
		return _('Path contains characters that are unsafe for the current service script.');

	const segments = value.split('/');
	if (segments.includes('.') || segments.includes('..'))
		return _('Path must not contain "." or ".." components.');

	const components = segments.filter(Boolean);
	if (components.length < 2)
		return _('The working directory must contain at least two path components below the filesystem root (for example, /etc/AdGuardHome).');

	if (value === '/tmp' || value.startsWith('/tmp/') ||
	    value === '/var' || value.startsWith('/var/'))
		return _('Working directories under /tmp or /var are volatile on ImmortalWrt and are not allowed.');

	const leaf = components[components.length - 1];
	const dedicatedLeaf = leaf === 'AdGuardHome' ||
		(leaf.startsWith('AdGuardHome-') && leaf.length > 'AdGuardHome-'.length);
	const dedicatedEtc = components[0] === 'etc' && components.length === 2;
	const dedicatedMount = components[0] === 'mnt' && components.length >= 3;
	if (!dedicatedLeaf || (!dedicatedEtc && !dedicatedMount))
		return _('Use /etc/AdGuardHome, an /etc/AdGuardHome-* directory, or a dedicated AdGuardHome[-*] directory below /mnt.');

	return true;
}

function validateMemoryWritebackInterval(_sectionId, value) {
	if (value == null || value === '')
		return _('This field is required.');

	value = String(value);
	if (!/^(0|[1-9][0-9]*)$/.test(value))
		return _('Enter 0 to disable periodic write-back, or a whole number from 1 to 10080.');

	const interval = Number(value);
	if (!Number.isSafeInteger(interval) || interval > MAX_MEMORY_WRITEBACK_INTERVAL)
		return _('Enter 0 to disable periodic write-back, or a whole number from 1 to 10080.');

	return true;
}

function normalizeSettings(result) {
	if (typeof result?.error === 'string' && result.error)
		throw new Error(result.error);

	const workDir = typeof result?.work_dir === 'string'
		? result.work_dir
		: '';
	const interval = Number(result?.memory_writeback_interval);
	if (typeof result?.enabled !== 'boolean' ||
	    typeof result?.verbose !== 'boolean' ||
	    typeof result?.run_from_memory !== 'boolean' ||
	    validateWorkDir(null, workDir) !== true ||
	    ![ 'none', 'dnsmasq-upstream', 'redirect' ].includes(result?.redirect) ||
	    !Number.isInteger(interval) || interval < 0 ||
	    interval > MAX_MEMORY_WRITEBACK_INTERVAL ||
	    typeof result?.revision !== 'string' ||
	    !/^[0-9a-f]{64}$/.test(result.revision))
		throw new Error(_('The settings returned by the service are invalid.'));

	return {
		enabled: result.enabled,
		workDir,
		verbose: result.verbose,
		redirect: result.redirect,
		runFromMemory: result.run_from_memory,
		memoryWritebackInterval: interval,
		revision: result.revision,
	};
}

async function getSettings(scope) {
	return normalizeSettings(await operation.requestActive(callGetSettings, scope));
}

function settingsMapData(settings) {
	return {
		_status: {},
		config: {
			enabled: settings.enabled ? '1' : '0',
			work_dir: settings.workDir,
			verbose: settings.verbose ? '1' : '0',
		},
		luci: {
			redirect: settings.redirect,
			run_from_memory: settings.runFromMemory ? '1' : '0',
			memory_writeback_interval: String(settings.memoryWritebackInterval),
		},
	};
}

function settingsFromMap(map, revision, fallbackInterval) {
	const get = (section, option) => map.data.get('json', section, option);
	const workDir = String(get(CORE_SECTION_NAME, 'work_dir') ?? '');
	const intervalValue = get(LUCI_SECTION_NAME, 'memory_writeback_interval');
	const interval = Number(intervalValue == null ? fallbackInterval : intervalValue);
	if (!Number.isInteger(interval) || interval < 0 ||
	    interval > MAX_MEMORY_WRITEBACK_INTERVAL)
		throw new Error(_('The memory write-back interval is invalid.'));

	return {
		enabled: get(CORE_SECTION_NAME, 'enabled') === '1',
		workDir,
		verbose: get(CORE_SECTION_NAME, 'verbose') === '1',
		redirect: String(get(LUCI_SECTION_NAME, 'redirect') ?? ''),
		runFromMemory: get(LUCI_SECTION_NAME, 'run_from_memory') === '1',
		memoryWritebackInterval: interval,
		revision,
	};
}

function updateSettingsMap(map, settings) {
	const data = settingsMapData(settings);
	for (const section of [ CORE_SECTION_NAME, LUCI_SECTION_NAME ])
		for (const option in data[section])
			map.data.set('json', section, option, data[section][option]);
}

async function reloadSettingsMap(map, settings) {
	updateSettingsMap(map, settings);
	// JSONMap options cache their cfgvalue during load().  Merely replacing the
	// JSON data and calling reset() would redraw the old cached values.
	await map.load();
	return map.reset();
}

function credentialField(title, input) {
	return E('label', {
		class: 'adguardhome-credential-field',
		style: 'display: block; width: 100%; margin: .75rem 0; box-sizing: border-box',
	}, [
		E('span', {
			class: 'adguardhome-credential-title',
			style: 'display: block; margin-bottom: .25rem; text-align: left; line-height: 1.4',
		}, title),
		input,
	]);
}

return view.extend({
	async load() {
		const pageScope = operation.createPageScope();
		this.pageScope = pageScope;
		try {
			const result = await Promise.all([
				getSettings(pageScope),
				getServiceStatus(pageScope),
				getCoreVersion(pageScope),
				getConfigInfo(pageScope),
			]);
			return [ ...result, pageScope ];
		} catch (error) {
			return operation.abandonInactiveLoad(error);
		}
	},

	async render([settings, serviceStatus, version, configInfo, pageScope]) {
		if (!operation.isPageActive(pageScope))
			return operation.abandonInactiveLoad(operation.pageInactiveError());

		let running = serviceStatus.running;
		const map = new form.JSONMap(
			settingsMapData(settings),
			_('AdGuard Home'),
			_('The core is provided and updated by the official ImmortalWrt adguardhome package. Default web login: admin / admin.'),
		);
		// JSONMap deliberately skips the UCI ACL probe performed by form.Map.
		// Derive its read-only state from the menu ACL so read-only sessions do
		// not receive editable controls or enabled page action buttons.
		map.readonly = !L.hasViewPermission();

		const statusContainer = E('span', {}, renderServiceStatus(running));
		const storageContainer = E('span', {}, renderStorageStatus(serviceStatus));
		const dnsPortContainer = E('span', {}, String(configInfo.dnsPort ?? _('Unavailable')));
		const managementContainer = E('span', {}, renderManagementLink(configInfo.web, running));

		const statusSection = map.section(form.TypedSection, '_status', _('Overview'));
		statusSection.anonymous = true;
		statusSection.addremove = false;
		statusSection.cfgsections = () => [ '_status' ];

		const statusOption = statusSection.option(
			form.DummyValue,
			'_service_status',
			_('Service status'),
		);
		statusOption.renderWidget = () => statusContainer;

		const storageOption = statusSection.option(
			form.DummyValue,
			'_storage_status',
			_('Active storage'),
		);
		storageOption.renderWidget = () => storageContainer;

		const versionOption = statusSection.option(
			form.DummyValue,
			'_core_version',
			_('Core version'),
		);
		versionOption.cfgvalue = () => version;

		const dnsPortOption = statusSection.option(
			form.DummyValue,
			'_dns_port',
			_('DNS listening port (YAML)'),
		);
		dnsPortOption.renderWidget = () => dnsPortContainer;

		const webOption = statusSection.option(
			form.DummyValue,
			'_web_interface',
			_('Management interface'),
		);
		webOption.renderWidget = () => managementContainer;

		const coreSection = map.section(
			form.NamedSection,
			CORE_SECTION_NAME,
			CORE_SECTION_NAME,
			_('Settings'),
		);
		coreSection.addremove = false;

		let option = coreSection.option(form.Flag, 'enabled', _('Enable'));
		option.default = '0';
		option.rmempty = false;

		option = coreSection.option(
			form.Value,
			'work_dir',
			_('Working directory'),
			_('Runtime data is stored here. The YAML configuration is fixed at WORKDIR/AdGuardHome.yaml.'),
		);
		option.default = DEFAULT_WORK_DIR;
		option.placeholder = DEFAULT_WORK_DIR;
		option.rmempty = false;
		option.validate = validateWorkDir;

		option = coreSection.option(form.Flag, 'verbose', _('Verbose logging'));
		option.default = '0';
		option.rmempty = false;

		option = coreSection.option(
			form.DummyValue,
			'_change_credentials',
			_('Change Username and Password'),
		);
		option.renderWidget = () => E('button', {
			class: 'cbi-button cbi-button-action',
			type: 'button',
			disabled: !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'openCredentialsDialog'),
		}, _('Change Username and Password'));

		const luciSection = map.section(
			form.NamedSection,
			LUCI_SECTION_NAME,
			LUCI_SECTION_NAME,
			_('DNS and memory integration'),
		);
		luciSection.addremove = false;

		option = luciSection.option(
			form.ListValue,
			'redirect',
			_('DNS redirect mode'),
			_('Choose how LAN DNS traffic is routed to the DNS port read dynamically from WORKDIR/AdGuardHome.yaml.'),
		);
		option.value('none', _('None'));
		option.value('dnsmasq-upstream', _('Use AdGuard Home as dnsmasq upstream'));
		option.value('redirect', _('Redirect LAN port 53 to AdGuard Home'));
		option.default = 'dnsmasq-upstream';
		option.rmempty = false;

		option = luciSection.option(
			form.Flag,
			'run_from_memory',
			_('Run from memory'),
			_('At startup, copies only the persistent data directory into RAM and runs the official core there. AdGuardHome.yaml always remains in and is read from the persistent work directory. Manual and periodic write-back copy the live RAM data directly to persistent storage without restarting the core or DNS service and do not guarantee consistency during concurrent changes or an unexpected power loss. A normal stop or restart still performs a complete write-back.'),
		);
		option.default = '0';
		option.rmempty = false;

		option = luciSection.option(
			form.Value,
			'memory_writeback_interval',
			_('Memory write-back interval (minutes)'),
			_('At each interval, the plugin directly copies the live RAM data to the persistent working directory without restarting the core or DNS service. This copy does not guarantee consistency during concurrent changes or an unexpected power loss. Use 60 minutes or longer to reduce flash wear. Set 0 to disable periodic write-back; a normal stop or restart still performs a complete write-back.'),
		);
		option.default = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);
		option.placeholder = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);
		option.rmempty = false;
		option.retain = true;
		option.validate = validateMemoryWritebackInterval;
		option.depends('run_from_memory', '1');

		this.settingsMap = map;
		this.committedSettings = settings;

		const rendered = await map.render();
		if (!operation.isPageActive(pageScope))
			return operation.abandonInactiveLoad(operation.pageInactiveError());

		if (typeof this.statusPollCallback === 'function')
			poll.remove(this.statusPollCallback);

		const removeStatusPoll = () => {
			poll.remove(statusPollCallback);
			if (this.statusPollCallback === statusPollCallback)
				this.statusPollCallback = null;
		};
		const statusPollCallback = async () => {
			if (!operation.isPageActive(pageScope)) {
				removeStatusPoll();
				return;
			}

			let currentStatus = null;
			let currentConfigInfo = null;
			try {
				[currentStatus, currentConfigInfo] = await Promise.all([
					getServiceStatus(pageScope),
					getConfigInfo(pageScope),
				]);
			} catch (error) {
				if (operation.isPageInactiveError(error)) {
					removeStatusPoll();
					return;
				}
				throw error;
			}
			if (!operation.isPageActive(pageScope)) {
				removeStatusPoll();
				return;
			}

			dom.content(statusContainer, renderServiceStatus(currentStatus.running));
			dom.content(storageContainer, renderStorageStatus(currentStatus));
			dom.content(
				dnsPortContainer,
				String(currentConfigInfo.dnsPort ?? _('Unavailable')),
			);
			dom.content(managementContainer, renderManagementLink(currentConfigInfo.web, currentStatus.running));
		};
		this.statusPollCallback = statusPollCallback;
		poll.add(statusPollCallback, POLL_INTERVAL);

		return pageScope.attach(E('div', {}, rendered));
	},

	async openCredentialsDialog() {
		const scope = this.pageScope;
		let info = null;
		try {
			info = await operation.requestActive(callGetCredentials, scope);
			if (typeof info?.error === 'string' && info.error)
				throw new Error(info.error);
			if (info?.available !== true || typeof info.username !== 'string' ||
			    !USERNAME_RE.test(info.username) ||
			    typeof info.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(info.sha256))
				throw new Error(_('The YAML user account is unavailable or ambiguous. Use the YAML editor to review the users section.'));
		} catch (error) {
			if (operation.isPageInactiveError(error))
				return;
			operation.failure(
				_('Unable to prepare the username or password change: %s').format(errorMessage(error)),
			);
			return;
		}

		const usernameInput = E('input', {
			class: 'cbi-input-text',
			type: 'text',
			autocomplete: 'username',
			maxlength: '64',
			placeholder: _('Leave empty to keep the current username'),
			style: 'width: 100%; max-width: 100%; min-width: 0; box-sizing: border-box',
		});
		const passwordInput = E('input', {
			class: 'cbi-input-password',
			type: 'password',
			autocomplete: 'new-password',
			maxlength: '256',
			style: 'width: 100%; max-width: 100%; min-width: 0; box-sizing: border-box',
		});
		const confirmationInput = E('input', {
			class: 'cbi-input-password',
			type: 'password',
			autocomplete: 'new-password',
			maxlength: '256',
			style: 'width: 100%; max-width: 100%; min-width: 0; box-sizing: border-box',
		});
		const status = E('p', { class: 'alert-message', style: 'display: none' });
		const cancelButton = E('button', {
			class: 'cbi-button',
			type: 'button',
			click: () => {
				usernameInput.value = '';
				passwordInput.value = '';
				confirmationInput.value = '';
				ui.hideModal();
			},
		}, _('Cancel'));
		const submitButton = E('button', {
			class: 'cbi-button cbi-button-positive',
			type: 'button',
		}, _('Change Username and Password'));
		submitButton.addEventListener('click', ui.createHandlerFn(this, async () => {
			await this.changeCredentials(
				info,
				usernameInput,
				passwordInput,
				confirmationInput,
				status,
				submitButton,
				cancelButton,
			);
		}));

		ui.showModal(_('Change Username and Password'), [
			E('p', {}, [
				`${_('Current username')}: `,
				E('strong', {}, info.username),
			]),
			E('p', {}, _('Leave either field empty to keep it unchanged. A new password must contain at least 8 characters and no more than 72 UTF-8 bytes.')),
			credentialField(_('New username'), usernameInput),
			credentialField(_('New password'), passwordInput),
			credentialField(_('Confirm password'), confirmationInput),
			status,
			E('div', { class: 'right' }, [
				cancelButton,
				' ',
				submitButton,
			]),
		]);
		window.setTimeout(() => usernameInput.focus(), 0);
	},

	async changeCredentials(info, usernameInput, passwordInput, confirmationInput, status, submitButton, cancelButton) {
		const scope = this.pageScope;
		let username = String(usernameInput.value ?? '');
		let password = String(passwordInput.value ?? '');
		let confirmation = String(confirmationInput.value ?? '');
		const showError = message => {
			status.style.display = '';
			status.className = 'alert-message error';
			status.textContent = message;
		};

		if (!username && !password && !confirmation) {
			showError(_('Enter a new username, a new password, or both.'));
			return;
		}
		if (username && !USERNAME_RE.test(username)) {
			showError(_('The username must be 1 to 64 characters and may contain only letters, numbers, dot, underscore, at sign, plus sign, or hyphen. It must start with a letter or number.'));
			return;
		}
		if (username === info.username && !password && !confirmation) {
			showError(_('The username is unchanged and no new password was entered.'));
			return;
		}
		if (password !== confirmation) {
			showError(_('The two passwords do not match.'));
			return;
		}
		if (password && Array.from(password).length < 8) {
			showError(_('The password must contain at least 8 characters.'));
			return;
		}
		if (password && bcrypt.truncates(password)) {
			showError(_('The password exceeds the 72-byte BCrypt limit.'));
			return;
		}
		confirmation = null;

		submitButton.disabled = true;
		cancelButton.disabled = true;
		const operationTicket = operation.start();
		try {
			const passwordHash = password ? await bcrypt.hash(password) : '';
			if (!operation.isPageActive(scope))
				return;
			password = null;
			usernameInput.value = '';
			passwordInput.value = '';
			confirmationInput.value = '';
			const response = await callSetCredentials(username, passwordHash, info.sha256);
			if (typeof response?.error === 'string' && response.error)
				throw new Error(response.error);
			if (response?.accepted !== true || typeof response.token !== 'string' ||
			    !/^[0-9a-f]{32}$/.test(response.token))
				throw new Error(_('The server did not accept the credential update job.'));

			const result = await waitForYamlUpdate(response.token, scope);
			if (result?.ok !== true)
				throw new Error(typeof result?.error === 'string' && result.error
					? result.error
					: _('The server rejected the credential update.'));

			operation.success(undefined, operationTicket);
		} catch (error) {
			if (operation.isPageInactiveError(error) || !operation.isPageActive(scope))
				return;
			usernameInput.value = '';
			passwordInput.value = '';
			confirmationInput.value = '';
			operation.failure(
				_('Unable to change the username or password: %s').format(errorMessage(error)),
				operationTicket,
			);
		} finally {
			username = null;
			password = null;
			confirmation = null;
			if (operation.isPageActive(scope)) {
				submitButton.disabled = false;
				cancelButton.disabled = false;
			}
		}
	},

	async submitSettings() {
		const scope = this.pageScope;
		const map = this.settingsMap;
		if (!map || !operation.isPageActive(scope))
			return;
		const revision = this.committedSettings?.revision;
		if (typeof revision !== 'string' || !/^[0-9a-f]{64}$/.test(revision)) {
			const operationTicket = operation.start();
			operation.failure(
				_('The current settings state is unknown. Reload this page before applying settings again.'),
				operationTicket,
			);
			return;
		}

		try {
			map.checkDepends();
			await map.parse();
		} catch (error) {
			return;
		}
		if (!operation.isPageActive(scope))
			return;

		const operationTicket = operation.start();
		try {
			const candidate = settingsFromMap(
				map,
				revision,
				this.committedSettings?.memoryWritebackInterval,
			);
			let response = null;
			try {
				response = await operation.requestActive(() => callSetSettings(
					candidate.enabled,
					candidate.workDir,
					candidate.verbose,
					candidate.redirect,
					candidate.runFromMemory,
					candidate.memoryWritebackInterval,
					candidate.revision,
				), scope);
			} catch (error) {
				if (operation.isPageInactiveError(error) || !operation.isPageActive(scope))
					throw operation.pageInactiveError();
				throw uncertainSettingsUpdateError(
					_('The settings update request may have reached the router, but its result could not be read: %s. Reload this page before applying settings again.').format(errorMessage(error)),
				);
			}
			if (typeof response?.error === 'string' && response.error)
				throw new Error(response.error);
			if (response?.accepted !== true)
				throw new Error(_('The server did not accept the settings update job.'));

			if (typeof response.token !== 'string' ||
			    !/^[0-9a-f]{32}$/.test(response.token))
				throw uncertainSettingsUpdateError(
					_('The server accepted the settings update job but did not return a valid status token. Reload this page before applying settings again.'),
				);
			const result = await waitForSettingsUpdate(response.token, scope);
			if (result?.indeterminate === true)
				throw uncertainSettingsUpdateError(typeof result?.error === 'string' && result.error
					? result.error
					: _('The settings update outcome is unknown. Reload this page before applying settings again.'));
			if (result?.ok === true &&
			    (typeof result.revision !== 'string' ||
			     !/^[0-9a-f]{64}$/.test(result.revision)))
				throw uncertainSettingsUpdateError(
					_('The settings update succeeded, but its result could not be verified. Reload this page before applying settings again.'),
				);
			if (result?.ok !== true)
				throw new Error(typeof result?.error === 'string' && result.error
					? result.error
					: _('The server rejected the settings update.'));

			let committed = null;
			try {
				committed = await getSettings(scope);
				await reloadSettingsMap(map, committed);
				if (!operation.isPageActive(scope))
					throw operation.pageInactiveError();
			} catch (error) {
				if (operation.isPageInactiveError(error) || !operation.isPageActive(scope))
					throw operation.pageInactiveError();
				throw uncertainSettingsUpdateError(
					_('The settings update finished, but the page could not reload its result: %s. Reload this page before applying settings again.').format(errorMessage(error)),
				);
			}
			this.committedSettings = committed;
			operation.success(undefined, operationTicket);
		} catch (error) {
			if (operation.isPageInactiveError(error) || !operation.isPageActive(scope))
				return;
			if (error?.settingsUpdateUncertain === true) {
				this.committedSettings = null;
				map.readonly = true;
				try { await map.reset(); }
				catch (resetError) { }
				if (!operation.isPageActive(scope))
					return;
			}
			operation.failure(
				_('Unable to apply settings: %s').format(errorMessage(error)),
				operationTicket,
			);
		}
	},

	handleSave: null,

	handleSaveApply() {
		if (this.settingsSubmission)
			return this.settingsSubmission;

		const submission = this.submitSettings();
		this.settingsSubmission = submission;
		return submission.finally(() => {
			if (this.settingsSubmission === submission)
				this.settingsSubmission = null;
		});
	},

	handleReset() {
		if (!this.settingsMap || !this.committedSettings)
			return Promise.resolve();
		return reloadSettingsMap(this.settingsMap, this.committedSettings);
	},
});
