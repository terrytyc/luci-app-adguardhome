// SPDX-License-Identifier: Apache-2.0

'use strict';

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

const POLL_INTERVAL = 10;
const SAFE_PATH_RE = /^\/[A-Za-z0-9_./+@%:,=-]+$/;
const USERNAME_RE = /^[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}$/;

const callGetOverview = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_overview',
	expect: { '': { status: {}, config: {} } },
	reject: true,
});

const callGetCoreVersion = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_version',
	expect: { '': { version: null } },
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

async function getOverview(scope) {
	try {
		const result = await operation.requestActive(callGetOverview, scope);
		return {
			status: {
				running: typeof result?.status?.running === 'boolean' ? result.status.running : null,
				memoryRequested: result?.status?.memory_requested === true,
				memoryActive: result?.status?.memory_active === true,
			},
			config: normalizeConfigInfo(result?.config),
		};
	} catch (error) {
		if (operation.isPageInactiveError(error))
			throw error;
		console.error('Unable to query the AdGuard Home overview:', error);
		return {
			status: { running: null, memoryRequested: false, memoryActive: false },
			config: { dnsPort: null, web: null },
		};
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

function renderServiceStatus(running) {
	if (running == null)
		return E('span', {}, _('Unavailable'));
	return E('span', {
		style: `color: ${running
			? 'var(--success-color-high, var(--success, #2e7d32))'
			: 'var(--error-color-high, var(--danger, #c62828))'}; font-weight: bold`,
	}, running ? _('Running') : _('Not running'));
}

function renderStorageStatus(mode) {
	if (mode === 'unknown')
		return E('span', {}, _('Unavailable'));
	if (mode === 'memory')
		return E('span', { style: 'color: var(--success-color-high, var(--success, #2e7d32)); font-weight: bold' }, _('Memory'));
	if (mode === 'fallback')
		return E('span', { style: 'color: var(--warn-color-high, var(--warning, #b26a00)); font-weight: bold' }, _('Persistent storage (memory fallback)'));
	if (mode === 'pending')
		return E('span', {}, _('Persistent storage (memory on next start)'));
	return E('span', {}, _('Persistent storage'));
}

function buildManagementURL(endpoint) {
	if (!endpoint)
		return null;

	const url = new URL(window.location.href);
	url.protocol = `${endpoint.scheme}:`;
	url.username = '';
	url.password = '';
	if (endpoint.scheme === 'https') {
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
	url.port = String(endpoint.port);
	url.pathname = '/';
	url.search = '';
	url.hash = '';

	return url.toString();
}

function overviewDisplayValues({ status, config }) {
	return {
		running: status.running,
		storage: status.running == null ? 'unknown' : status.memoryActive ? 'memory'
			: status.memoryRequested ? (status.running ? 'fallback' : 'pending') : 'persistent',
		dnsPort: String(config.dnsPort ?? _('Unavailable')),
		management: status.running ? buildManagementURL(config.web) : null,
	};
}

function renderManagementLink(url) {
	if (!url) {
		return E('button', {
			class: 'cbi-button cbi-button-action adguardhome-action-button',
			type: 'button',
			disabled: 'disabled',
		}, _('Open Web Interface'));
	}

	return E('a', {
		class: 'cbi-button cbi-button-action adguardhome-action-button',
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
				getOverview(pageScope),
				getCoreVersion(pageScope),
			]);
			return [ ...result, pageScope ];
		} catch (error) {
			return operation.abandonInactiveLoad(error);
		}
	},

	async render([settings, overview, version, pageScope]) {
		if (!operation.isPageActive(pageScope))
			return operation.abandonInactiveLoad(operation.pageInactiveError());

		let displayed = overviewDisplayValues(overview);
		const map = new form.JSONMap(
			settingsMapData(settings),
			_('AdGuard Home'),
			_('The core is provided and updated by the official ImmortalWrt adguardhome package. Default web login: admin / admin.'),
		);
		// JSONMap deliberately skips the UCI ACL probe performed by form.Map.
		// Derive its read-only state from the menu ACL so read-only sessions do
		// not receive editable controls or enabled page action buttons.
		map.readonly = !L.hasViewPermission();

		const statusContainer = E('span', {}, renderServiceStatus(displayed.running));
		const storageContainer = E('span', {}, renderStorageStatus(displayed.storage));
		const dnsPortContainer = E('span', { class: 'adguardhome-primary-value' }, displayed.dnsPort);
		const managementContainer = E('span', { class: 'adguardhome-management' },
			renderManagementLink(displayed.management));

		const statusSection = map.section(form.TypedSection, '_status', _('Overview'));
		statusSection.anonymous = true;
		statusSection.addremove = false;
		statusSection.cfgsections = () => [ '_status' ];

		statusSection.render = () => E('section', { class: 'cbi-section adguardhome-overview' }, [
			E('h3', {}, _('Overview')),
			E('dl', { class: 'adguardhome-status-grid' }, [
				[ _('Service status'), statusContainer ],
				[ _('Active storage'), storageContainer ],
				[ _('Listening port'), dnsPortContainer ],
				[ '', managementContainer ],
			].map(([label, value]) => E('div', {}, [
				E('dt', {}, label), E('dd', {}, value),
			]))),
		]);

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
			_('Persistent data and AdGuardHome.yaml are stored in this directory.'),
		);
		option.default = DEFAULT_WORK_DIR;
		option.placeholder = DEFAULT_WORK_DIR;
		option.rmempty = false;
		option.validate = validateWorkDir;

		option = coreSection.option(form.Flag, 'verbose', _('Verbose logging'));
		option.default = '0';
		option.rmempty = false;

		option = coreSection.option(
			form.ListValue,
			'redirect',
			_('DNS redirect mode'),
			_('Choose how LAN DNS reaches AdGuard Home. The listening port is read from YAML.'),
		);
		option.ucisection = LUCI_SECTION_NAME;
		option.value('none', _('None'));
		option.value('dnsmasq-upstream', _('Use AdGuard Home as dnsmasq upstream'));
		option.value('redirect', _('Redirect port 53'));
		option.default = 'dnsmasq-upstream';
		option.rmempty = false;

		option = coreSection.option(
			form.Flag,
			'run_from_memory',
			_('Run from memory'),
			_('Only data is copied to RAM; the core executable and YAML stay in place. Live write-back does not restart services and cannot guarantee consistency during concurrent changes or power loss.'),
		);
		option.ucisection = LUCI_SECTION_NAME;
		option.default = '0';
		option.rmempty = false;

		option = coreSection.option(
			form.Value,
			'memory_writeback_interval',
			_('Memory write-back interval (minutes)'),
			_('0 disables scheduled write-back. A normal stop or restart still writes data back. Use 60 minutes or longer to reduce flash wear.'),
		);
		option.ucisection = LUCI_SECTION_NAME;
		option.default = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);
		option.placeholder = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);
		option.rmempty = false;
		option.retain = true;
		option.validate = validateMemoryWritebackInterval;
		option.depends(`${map.config}.${CORE_SECTION_NAME}.run_from_memory`, '1');

		option = coreSection.option(form.DummyValue, '_change_credentials', ' ');
		option.renderWidget = () => E('button', {
			class: 'cbi-button cbi-button-action adguardhome-action-button',
			type: 'button',
			disabled: !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'openCredentialsDialog'),
		}, _('Change Username and Password'));

		this.settingsMap = map;
		this.committedSettings = settings;

		const rendered = await map.render();
		if (!operation.isPageActive(pageScope))
			return operation.abandonInactiveLoad(operation.pageInactiveError());

		if (typeof this.statusPollCallback === 'function')
			poll.remove(this.statusPollCallback);

		let statusRequestId = 0;
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
			if (document.hidden || this.settingsSubmission)
				return;

			const requestId = ++statusRequestId;
			let current = null;
			try {
				current = await getOverview(pageScope);
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
			if (this.settingsSubmission || requestId !== statusRequestId)
				return;

			const next = overviewDisplayValues(current);
			if (next.running !== displayed.running)
				dom.content(statusContainer, renderServiceStatus(next.running));
			if (next.storage !== displayed.storage)
				dom.content(storageContainer, renderStorageStatus(next.storage));
			if (next.dnsPort !== displayed.dnsPort)
				dom.content(dnsPortContainer, next.dnsPort);
			if (next.management !== displayed.management)
				dom.content(managementContainer, renderManagementLink(next.management));
			displayed = next;
		};
		this.statusPollCallback = statusPollCallback;
		poll.add(statusPollCallback, POLL_INTERVAL);

		return pageScope.attach(E('div', { class: 'adguardhome-view' }, [
			E('link', { rel: 'stylesheet', href: L.resource('adguardhome/style.css') }),
			rendered,
			E('p', { class: 'adguardhome-version adguardhome-help' },
				`${_('Core version')}: ${version}`),
		]));
	},

	async openCredentialsDialog() {
		const scope = this.pageScope;
		let info = null;
		let bcrypt = null;
		try {
			[info, bcrypt] = await operation.requestActive(() => Promise.all([
				callGetCredentials(),
				L.require('adguardhome.bcrypt'),
			]), scope);
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
				bcrypt,
				info,
				usernameInput,
				passwordInput,
				confirmationInput,
				status,
				submitButton,
				cancelButton,
			);
		}));

		ui.showModal(_('Change AdGuard Home Account'), [
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
		window.setTimeout(() => {
			if (operation.isPageActive(scope))
				usernameInput.focus();
		}, 0);
	},

	async changeCredentials(bcrypt, info, usernameInput, passwordInput, confirmationInput, status, submitButton, cancelButton) {
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

		const scope = this.pageScope;
		const submission = this.submitSettings();
		this.settingsSubmission = submission;
		return submission.finally(() => {
			if (this.settingsSubmission !== submission)
				return;
			this.settingsSubmission = null;
			if (!operation.isPageActive(scope) || typeof this.statusPollCallback !== 'function')
				return;
			this.statusPollCallback().catch(error => {
				if (!operation.isPageInactiveError(error) && operation.isPageActive(scope))
					console.error('Unable to refresh AdGuard Home status after applying settings:', error);
			});
		});
	},

	handleReset() {
		if (!this.settingsMap || !this.committedSettings)
			return Promise.resolve();
		return reloadSettingsMap(this.settingsMap, this.committedSettings);
	},
});
