// SPDX-License-Identifier: Apache-2.0

'use strict';

'require dom';
'require form';
'require poll';
'require rpc';
'require uci';
'require view';

const CONFIG_NAME = 'AdGuardHome';
const SECTION_NAME = 'AdGuardHome';

const DEFAULT_WORK_DIR = '/etc/AdGuardHome';

const POLL_INTERVAL = 5;
const SAFE_PATH_RE = /^\/[A-Za-z0-9_./+@%:,=-]+$/;

const callGetServiceStatus = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_status',
	expect: { '': { running: false } },
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

async function getServiceStatus() {
	try {
		const result = await callGetServiceStatus();
		return result?.running === true;
	} catch (error) {
		console.error('Unable to query AdGuard Home service status:', error);
		return false;
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

	if (segments.filter(Boolean).length < 2)
		return _('The working directory must contain at least two path components below the filesystem root (for example, /etc/AdGuardHome).');

	if (value === '/tmp' || value.startsWith('/tmp/') ||
	    value === '/var' || value.startsWith('/var/'))
		return _('Working directories under /tmp or /var are volatile on ImmortalWrt and are not allowed.');

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

	async render([_config, running, version, configInfo]) {
		const map = new form.Map(
			CONFIG_NAME,
			_('AdGuard Home'),
			_('The core is provided and updated by the official ImmortalWrt adguardhome package. Default web login: admin / admin.'),
		);

		const statusContainer = E('span', {}, renderServiceStatus(running));
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

		section.tab('general', _('General Settings'));
		section.tab('dns', _('DNS Integration'));
		section.tab('paths', _('Paths'));

		let option = section.taboption('general', form.Flag, 'enabled', _('Enable'));
		option.default = '0';
		option.rmempty = false;

		option = section.taboption(
			'dns',
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

		option = section.taboption(
			'paths',
			form.Value,
			'workdir',
			_('Working directory'),
			_('Runtime data is stored here. The YAML configuration is fixed at WORKDIR/AdGuardHome.yaml.'),
		);
		option.default = DEFAULT_WORK_DIR;
		option.placeholder = DEFAULT_WORK_DIR;
		option.rmempty = false;
		option.validate = validateWorkDir;

		option = section.taboption('general', form.Flag, 'verbose', _('Verbose logging'));
		option.default = '0';
		option.rmempty = false;

		const rendered = await map.render();

		poll.add(async () => {
			const [isRunning, currentConfigInfo] = await Promise.all([
				getServiceStatus(),
				getConfigInfo(),
			]);
			dom.content(statusContainer, renderServiceStatus(isRunning));
			dom.content(
				dnsPortContainer,
				String(currentConfigInfo.dnsPort ?? _('Unavailable')),
			);
			dom.content(managementContainer, renderManagementLink(currentConfigInfo.web, isRunning));
		}, POLL_INTERVAL);

		return rendered;
	},
});
