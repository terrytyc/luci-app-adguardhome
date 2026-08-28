// SPDX-License-Identifier: Apache-2.0

'use strict';

'require rpc';
'require ui';
'require view';

const callGetYaml = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_yaml',
	expect: { '': { content: '', sha256: '', path: '' } },
	reject: true,
});

const callSetYaml = rpc.declare({
	object: 'luci.adguardhome',
	method: 'set_yaml',
	params: [ 'content', 'sha256' ],
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

const YAML_POLL_INTERVAL = 1000;
const YAML_POLL_LIMIT = 360;

function normalizeYaml(result) {
	return {
		content: typeof result?.content === 'string' ? result.content : '',
		sha256: typeof result?.sha256 === 'string' ? result.sha256 : '',
		path: typeof result?.path === 'string' ? result.path : '',
		error: typeof result?.error === 'string' && result.error ? result.error : null,
	};
}

function errorMessage(error) {
	return String(error?.message ?? error ?? _('Unknown error'));
}

function delay(milliseconds) {
	return new Promise(resolve => window.setTimeout(resolve, milliseconds));
}

return view.extend({
	async load() {
		try {
			const result = normalizeYaml(await callGetYaml());
			return result.error ? { ...result, error: new Error(result.error) } : result;
		} catch (error) {
			return { content: '', sha256: '', path: '', error };
		}
	},

	render(result) {
		this.yamlHash = result.sha256;
		this.yamlPath = result.path;
		this.yamlEditor = E('textarea', {
			class: 'cbi-input-textarea',
			rows: 32,
			spellcheck: 'false',
			wrap: 'off',
			readonly: result.error || !result.sha256 || !L.hasViewPermission() ? 'readonly' : null,
			style: 'box-sizing: border-box; width: 100%; padding: .75em; font-family: monospace; tab-size: 2; resize: vertical;',
		}, [ result.content ]);
		this.pathValue = E('code', {}, result.path || _('Unavailable'));
		this.saveButton = E('button', {
			class: 'cbi-button cbi-button-positive',
			type: 'button',
			disabled: result.error || !result.sha256 || !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'handleSaveClick'),
		}, _('Validate, Save & Apply'));
		this.reloadButton = E('button', {
			class: 'cbi-button',
			type: 'button',
			click: ui.createHandlerFn(this, 'handleReload'),
		}, _('Reload from disk'));

		if (result.error) {
			ui.addNotification(null, E('p', {},
				_('Unable to read the YAML configuration: %s').format(errorMessage(result.error))), 'error');
		}

		return E('div', {}, [
			E('h2', {}, _('AdGuard Home')),
			E('div', { class: 'cbi-map-descr' }, [
				_('Edit the active AdGuard Home configuration file directly.'),
				' ',
				_('Saving validates and atomically applies the YAML. A running service is restarted; a disabled service remains stopped.'),
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('YAML Configuration')),
				E('p', {}, [ E('strong', {}, `${_('Path')}: `), this.pathValue ]),
				E('p', { class: 'alert-message warning' },
					_('A content hash prevents overwriting changes made after this page was loaded. If a conflict is reported, reload the file and merge your changes before saving. Invalid YAML is rejected without replacing the current file.')),
				this.yamlEditor,
				E('div', { class: 'cbi-page-actions' }, [
					this.reloadButton,
					' ',
					this.saveButton,
				]),
			]),
		]);
	},

	async handleReload() {
		this.reloadButton.disabled = true;

		try {
			const result = normalizeYaml(await callGetYaml());
			if (result.error)
				throw new Error(result.error);
			if (!result.sha256)
				throw new Error(_('The YAML configuration is unavailable.'));

			this.yamlEditor.value = result.content;
			this.yamlHash = result.sha256;
			this.yamlPath = result.path;
			this.pathValue.textContent = result.path || _('Unavailable');
			this.yamlEditor.readOnly = !L.hasViewPermission();
			this.saveButton.disabled = !L.hasViewPermission();
			ui.addNotification(null, E('p', {}, _('The YAML configuration was reloaded from disk.')), 'info');
		} catch (error) {
			ui.addNotification(null, E('p', {},
				_('Unable to read the YAML configuration: %s').format(errorMessage(error))), 'error');
		} finally {
			this.reloadButton.disabled = false;
		}
	},

	handleSaveClick() {
		ui.showModal(_('Save YAML Configuration'), [
			E('p', {}, _('The configuration will be validated and applied atomically. A running service will restart; a disabled service will remain stopped. Continue?')),
			E('div', { class: 'right' }, [
				E('button', {
					class: 'cbi-button',
					type: 'button',
					click: ui.hideModal,
				}, _('Cancel')),
				' ',
				E('button', {
					class: 'cbi-button cbi-button-positive',
					type: 'button',
					click: ui.createHandlerFn(this, async () => {
						ui.hideModal();
						await this.saveYaml();
					}),
				}, _('Validate, Save & Apply')),
			]),
		]);
	},

	async saveYaml() {
		if (!this.yamlHash)
			return;

		this.saveButton.disabled = true;
		const content = String(this.yamlEditor.value ?? '').replace(/\r\n?/g, '\n');

		try {
			const accepted = await callSetYaml(content, this.yamlHash);
			if (typeof accepted?.error === 'string' && accepted.error)
				throw new Error(accepted.error);
			if (accepted?.accepted !== true ||
			    typeof accepted.token !== 'string' ||
			    !/^[0-9a-f]{32}$/.test(accepted.token))
				throw new Error(_('The server did not accept the YAML update job.'));

			ui.addNotification(null, E('p', {},
				_('The YAML update was accepted and is being applied in the background.')), 'info');
			const result = await this.waitForYamlUpdate(accepted.token);
			if (result?.ok !== true || typeof result.sha256 !== 'string' || !result.sha256)
				throw new Error(typeof result?.error === 'string' && result.error
					? result.error
					: _('The server rejected the YAML configuration. Check its syntax and protected settings.'));

			this.yamlHash = result.sha256;
			try {
				const current = normalizeYaml(await callGetYaml());
				if (current.error)
					throw new Error(current.error);
				if (current.sha256) {
					this.yamlEditor.value = current.content;
					this.yamlHash = current.sha256;
					this.yamlPath = current.path;
					this.pathValue.textContent = current.path || _('Unavailable');
				}
			} catch (error) {
				ui.addNotification(null, E('p', {},
					_('The YAML configuration was saved, but the editor could not reload it: %s').format(errorMessage(error))), 'warning');
			}

			ui.addNotification(null, E('p', {}, result.restarted === true
				? _('The YAML configuration was saved and AdGuard Home restarted successfully.')
				: _('The YAML configuration was saved.')), 'info');
		} catch (error) {
			ui.addNotification(null, E('div', {}, [
				E('p', {}, _('Unable to save the YAML configuration: %s').format(errorMessage(error))),
				E('p', {}, _('If the file changed since it was loaded, reload it and merge your changes. Otherwise, check the YAML syntax and protected settings.')),
			]), 'error');
		} finally {
			this.saveButton.disabled = !this.yamlHash || !L.hasViewPermission();
		}
	},

	async waitForYamlUpdate(token) {
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
				try {
					await callGetYamlUpdate(token, true);
				} catch (error) {
					// The terminal result is already known; cleanup is best effort.
				}
				return result;
			}
			if (typeof result?.error === 'string' && result.error)
				throw new Error(result.error);
			if (result?.state != 'pending' && result?.state != 'running')
				throw new Error(_('The YAML update returned an unknown job state.'));

			await delay(YAML_POLL_INTERVAL);
		}

		throw new Error(lastError
			? _('The YAML update is still running, but its status is temporarily unavailable: %s. Do not submit it again; reload this page later.').format(errorMessage(lastError))
			: _('The YAML update is still running. Do not submit it again; reload this page later.'));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
});
