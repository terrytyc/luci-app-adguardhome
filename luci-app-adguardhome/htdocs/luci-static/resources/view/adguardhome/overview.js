// SPDX-License-Identifier: Apache-2.0

'use strict';

'require adguardhome.bcrypt as bcrypt';
'require dom';
'require form';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

const CONFIG_NAME = 'AdGuardHome';
const SECTION_NAME = 'AdGuardHome';

const DEFAULT_WORK_DIR = '/etc/AdGuardHome';
const DEFAULT_MEMORY_WRITEBACK_INTERVAL = 60;
const MAX_MEMORY_WRITEBACK_INTERVAL = 10080;

const POLL_INTERVAL = 5;
const YAML_POLL_INTERVAL = 1000;
const YAML_POLL_LIMIT = 360;
const SAFE_PATH_RE = /^\/[A-Za-z0-9_./+@%:,=-]+$/;

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

const callGetPasswordInfo = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_password_info',
	expect: { '': { available: false, username: '', sha256: '' } },
	reject: true,
});

const callSetPassword = rpc.declare({
	object: 'luci.adguardhome',
	method: 'set_password',
	params: [ 'password_hash', 'sha256' ],
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

function delay(milliseconds) {
	return new Promise(resolve => window.setTimeout(resolve, milliseconds));
}

async function waitForYamlUpdate(token) {
	let consecutiveErrors = 0;
	let lastError = null;

	for (let attempt = 0; attempt < YAML_POLL_LIMIT; attempt++) {
		let result = null;
		try {
			result = await callGetYamlUpdate(token, false);
			consecutiveErrors = 0;
			lastError = null;
		} catch (error) {
			lastError = error;
			consecutiveErrors++;
			if (consecutiveErrors >= 10)
				break;
			await delay(YAML_POLL_INTERVAL);
			continue;
		}

		if (result?.state == 'done') {
			try { await callGetYamlUpdate(token, true); }
			catch (error) { }
			return result;
		}
		if (typeof result?.error === 'string' && result.error)
			throw new Error(result.error);
		if (result?.state != 'pending' && result?.state != 'running')
			throw new Error(_('The password update returned an unknown job state.'));

		await delay(YAML_POLL_INTERVAL);
	}

	throw new Error(lastError
		? _('The password update is still running, but its status is temporarily unavailable: %s. Do not submit it again; reload this page later.').format(errorMessage(lastError))
		: _('The password update is still running. Do not submit it again; reload this page later.'));
}

async function getServiceStatus() {
	try {
		const result = await callGetServiceStatus();
		return {
			running: result?.running === true,
			memoryRequested: result?.memory_requested === true,
			memoryActive: result?.memory_active === true,
		};
	} catch (error) {
		console.error('Unable to query AdGuard Home service status:', error);
		return { running: false, memoryRequested: false, memoryActive: false };
	}
}

async function getCoreVersion() {
	try {
		const result = await callGetCoreVersion();
		return String(result?.version ?? '').trim() || _('Unknown');
	} catch (error) {
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

async function getConfigInfo() {
	try {
		return normalizeConfigInfo(await callGetConfigInfo());
	} catch (error) {
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

return view.extend({
	load() {
		return Promise.all([
			uci.load(CONFIG_NAME),
			getServiceStatus(),
			getCoreVersion(),
			getConfigInfo(),
		]);
	},

	async render([_config, serviceStatus, version, configInfo]) {
		let running = serviceStatus.running;
		const map = new form.Map(
			CONFIG_NAME,
			_('AdGuard Home'),
			_('The core is provided and updated by the official ImmortalWrt adguardhome package. Default web login: admin / admin.'),
		);

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
			_('HTTP keeps the host used to access LuCI and uses the port from YAML http.address. HTTPS uses YAML tls.server_name and tls.port_https.'),
		);
		webOption.renderWidget = () => managementContainer;

		const section = map.section(
			form.NamedSection,
			SECTION_NAME,
			'AdGuardHome',
			_('Settings'),
		);
		section.addremove = false;

		let option = section.option(form.Flag, 'enabled', _('Enable'));
		option.default = '0';
		option.rmempty = false;

		option = section.option(
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

		option = section.option(
			form.Value,
			'workdir',
			_('Working directory'),
			_('Runtime data is stored here. The YAML configuration is fixed at WORKDIR/AdGuardHome.yaml.'),
		);
		option.default = DEFAULT_WORK_DIR;
		option.placeholder = DEFAULT_WORK_DIR;
		option.rmempty = false;
		option.validate = validateWorkDir;

		option = section.option(form.Flag, 'verbose', _('Verbose logging'));
		option.default = '0';
		option.rmempty = false;

		option = section.option(
			form.Flag,
			'run_from_memory',
			_('Run from memory'),
			_('At startup, copies the persistent data directory into RAM and runs the official core there. Normal stop or restart, and enabled periodic write-back, save a consistent checkpoint; an unexpected power loss can lose changes made since the last successful checkpoint.'),
		);
		option.default = '0';
		option.rmempty = false;

		option = section.option(
			form.Value,
			'memory_writeback_interval',
			_('Memory write-back interval (minutes)'),
			_('At each interval, the plugin briefly stops and restarts the official core and its DNS service to write a consistent data checkpoint to the persistent working directory. Each checkpoint writes to persistent storage; use 60 minutes or longer to reduce flash wear. Set 0 to disable periodic write-back; normal stop or restart still writes back.'),
		);
		option.default = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);
		option.placeholder = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);
		option.rmempty = false;
		option.validate = validateMemoryWritebackInterval;
		option.depends('run_from_memory', '1');

		option = section.option(
			form.DummyValue,
			'_change_password',
			_('Management password'),
			_('Changes the password for the admin account stored in AdGuardHome.yaml. The password is BCrypt-hashed in this browser and the plaintext is never sent to the router.'),
		);
		option.renderWidget = () => E('button', {
			class: 'cbi-button cbi-button-action',
			type: 'button',
			disabled: !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'openPasswordDialog'),
		}, _('Change Password'));

		const rendered = await map.render();

		poll.add(async () => {
			const [currentStatus, currentConfigInfo] = await Promise.all([
				getServiceStatus(),
				getConfigInfo(),
			]);
			dom.content(statusContainer, renderServiceStatus(currentStatus.running));
			dom.content(storageContainer, renderStorageStatus(currentStatus));
			dom.content(
				dnsPortContainer,
				String(currentConfigInfo.dnsPort ?? _('Unavailable')),
			);
			dom.content(managementContainer, renderManagementLink(currentConfigInfo.web, currentStatus.running));
		}, POLL_INTERVAL);

		return rendered;
	},

	async openPasswordDialog() {
		let info = null;
		try {
			info = await callGetPasswordInfo();
			if (typeof info?.error === 'string' && info.error)
				throw new Error(info.error);
			if (info?.available !== true || info.username !== 'admin' ||
			    typeof info.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(info.sha256))
				throw new Error(_('The YAML admin account is unavailable or ambiguous. Use the YAML editor to review the users section.'));
		} catch (error) {
			ui.addNotification(null, E('p', {},
				_('Unable to prepare the password change: %s').format(errorMessage(error))), 'error');
			return;
		}

		const passwordInput = E('input', {
			class: 'cbi-input-password',
			type: 'password',
			autocomplete: 'new-password',
			maxlength: '256',
			style: 'width: 100%',
		});
		const confirmationInput = E('input', {
			class: 'cbi-input-password',
			type: 'password',
			autocomplete: 'new-password',
			maxlength: '256',
			style: 'width: 100%',
		});
		const status = E('p', { class: 'alert-message', style: 'display: none' });
		const cancelButton = E('button', {
			class: 'cbi-button',
			type: 'button',
			click: () => {
				passwordInput.value = '';
				confirmationInput.value = '';
				ui.hideModal();
			},
		}, _('Cancel'));
		const submitButton = E('button', {
			class: 'cbi-button cbi-button-positive',
			type: 'button',
		}, _('Change Password'));
		submitButton.addEventListener('click', ui.createHandlerFn(this, async () => {
			await this.changePassword(
				info.sha256,
				passwordInput,
				confirmationInput,
				status,
				submitButton,
				cancelButton,
			);
		}));

		ui.showModal(_('Change AdGuard Home Password'), [
			E('p', {}, _('Enter a new password for the admin account. Use at least 8 characters and no more than 72 UTF-8 bytes.')),
			E('label', { class: 'cbi-value' }, [
				E('span', { class: 'cbi-value-title' }, _('New password')),
				E('span', { class: 'cbi-value-field' }, passwordInput),
			]),
			E('label', { class: 'cbi-value' }, [
				E('span', { class: 'cbi-value-title' }, _('Confirm password')),
				E('span', { class: 'cbi-value-field' }, confirmationInput),
			]),
			status,
			E('div', { class: 'right' }, [
				cancelButton,
				' ',
				submitButton,
			]),
		]);
		window.setTimeout(() => passwordInput.focus(), 0);
	},

	async changePassword(revision, passwordInput, confirmationInput, status, submitButton, cancelButton) {
		let password = String(passwordInput.value ?? '');
		let confirmation = String(confirmationInput.value ?? '');
		const showError = message => {
			status.style.display = '';
			status.className = 'alert-message error';
			status.textContent = message;
		};

		if (password !== confirmation) {
			showError(_('The two passwords do not match.'));
			return;
		}
		if (Array.from(password).length < 8) {
			showError(_('The password must contain at least 8 characters.'));
			return;
		}
		if (bcrypt.truncates(password)) {
			showError(_('The password exceeds the 72-byte BCrypt limit.'));
			return;
		}
		confirmation = null;

		submitButton.disabled = true;
		cancelButton.disabled = true;
		status.style.display = '';
		status.className = 'alert-message notice';
		status.textContent = _('Hashing the password securely in this browser…');
		let accepted = false;
		try {
			const passwordHash = await bcrypt.hash(password);
			password = null;
			passwordInput.value = '';
			confirmationInput.value = '';
			const response = await callSetPassword(passwordHash, revision);
			if (typeof response?.error === 'string' && response.error)
				throw new Error(response.error);
			if (response?.accepted !== true || typeof response.token !== 'string' ||
			    !/^[0-9a-f]{32}$/.test(response.token))
				throw new Error(_('The server did not accept the password update job.'));

			accepted = true;
			ui.hideModal();
			ui.addNotification(null, E('p', {},
				_('The password update was accepted and is being applied in the background.')), 'info');
			const result = await waitForYamlUpdate(response.token);
			if (result?.ok !== true)
				throw new Error(typeof result?.error === 'string' && result.error
					? result.error
					: _('The server rejected the password update.'));

			ui.addNotification(null, E('p', {}, result.restarted === true
				? _('The admin password was changed and AdGuard Home restarted successfully.')
				: _('The admin password was changed.')), 'info');
		} catch (error) {
			passwordInput.value = '';
			confirmationInput.value = '';
			if (accepted)
				ui.addNotification(null, E('p', {},
					_('Unable to finish the password change: %s').format(errorMessage(error))), 'error');
			else
				showError(_('Unable to change the password: %s').format(errorMessage(error)));
		} finally {
			password = null;
			confirmation = null;
			submitButton.disabled = false;
			cancelButton.disabled = false;
		}
	},
});
