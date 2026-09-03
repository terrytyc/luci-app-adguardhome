// SPDX-License-Identifier: Apache-2.0

'use strict';

'require adguardhome.operation as operation';
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

const callResetYaml = rpc.declare({
	object: 'luci.adguardhome',
	method: 'reset_yaml',
	params: [ 'sha256' ],
	expect: { '': { content: '' } },
	reject: true,
});

const callGetYamlUpdate = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_yaml_update',
	params: [ 'token', 'consume' ],
	expect: { '': { state: '', ok: false, sha256: '', restarted: false } },
	reject: true,
});

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

function uncertainYamlUpdateError(message = _('The YAML update outcome is unknown. Reload the page before editing it again.')) {
	const error = new Error(message);
	error.yamlUpdateUncertain = true;
	return error;
}

return view.extend({
	async load() {
		const pageScope = operation.createPageScope();
		this.pageScope = pageScope;
		try {
			const result = normalizeYaml(await operation.requestActive(
				callGetYaml,
				pageScope,
			));
			return result.error
				? { ...result, error: new Error(result.error), pageScope }
				: { ...result, pageScope };
		} catch (error) {
			if (operation.isPageInactiveError(error))
				return operation.abandonInactiveLoad(error);
			return { content: '', sha256: '', path: '', error, pageScope };
		}
	},

	render(result) {
		const pageScope = result.pageScope;
		if (!operation.isPageActive(pageScope))
			return operation.abandonInactiveLoad(operation.pageInactiveError());

		this.yamlHash = result.sha256;
		this.yamlEditor = E('textarea', {
			class: 'cbi-input-textarea',
			'aria-label': _('YAML Configuration'),
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
		this.resetButton = E('button', {
			class: 'cbi-button cbi-button-negative',
			type: 'button',
			disabled: result.error || !result.sha256 || !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'handleTemplateResetClick'),
		}, _('Restore Template'));
		this.reloadButton = E('button', {
			class: 'cbi-button',
			type: 'button',
			click: ui.createHandlerFn(this, 'handleReload'),
		}, _('Reload from disk'));

		if (result.error && operation.isPageActive(pageScope)) {
			ui.addNotification(null, E('p', {},
				_('Unable to read the YAML configuration: %s').format(errorMessage(result.error))), 'error');
		}

		const root = E('div', {}, [
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
					this.resetButton,
					' ',
					this.saveButton,
				]),
			]),
		]);
		return pageScope.attach(root);
	},

	async handleReload() {
		const scope = this.pageScope;
		if (this.operationBusy || !operation.isPageActive(scope))
			return;
		this.setBusy(true);
		try {
			await this.reloadYaml();
		} catch (error) {
			if (operation.isPageInactiveError(error))
				return;
			this.invalidateYamlEditor();
			ui.addNotification(null, E('p', {},
				_('Unable to read the YAML configuration: %s').format(errorMessage(error))), 'error');
		} finally {
			if (operation.isPageActive(scope))
				this.setBusy(false);
		}
	},

	async reloadYaml() {
		const result = normalizeYaml(await operation.requestActive(
			callGetYaml,
			this.pageScope,
		));
		if (result.error)
			throw new Error(result.error);
		if (!result.sha256)
			throw new Error(_('The YAML configuration is unavailable.'));

		this.yamlEditor.value = result.content;
		this.yamlHash = result.sha256;
		this.pathValue.textContent = result.path || _('Unavailable');
		this.yamlEditor.readOnly = this.operationBusy || !this.yamlHash || !L.hasViewPermission();
	},

	invalidateYamlEditor() {
		this.yamlHash = '';
		this.yamlEditor.readOnly = true;
	},

	setBusy(busy) {
		this.operationBusy = busy === true;
		this.yamlEditor.readOnly = this.operationBusy || !this.yamlHash || !L.hasViewPermission();
		this.reloadButton.disabled = this.operationBusy;
		this.saveButton.disabled = this.operationBusy || !this.yamlHash || !L.hasViewPermission();
		this.resetButton.disabled = this.operationBusy || !this.yamlHash || !L.hasViewPermission();
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
		const scope = this.pageScope;
		if (!this.yamlHash || this.operationBusy || !operation.isPageActive(scope))
			return;

		this.setBusy(true);
		const content = String(this.yamlEditor.value ?? '').replace(/\r\n?/g, '\n');
		const operationTicket = operation.start();

		try {
			const accepted = await operation.requestActive(() => callSetYaml(content, this.yamlHash), scope)
				.catch(error => {
					if (operation.isPageInactiveError(error))
						throw error;
					throw uncertainYamlUpdateError();
				});
			if (typeof accepted?.error === 'string' && accepted.error)
				throw new Error(accepted.error);
			if (accepted?.accepted !== true)
				throw new Error(_('The server did not accept the YAML update job.'));
			if (typeof accepted.token !== 'string' || !/^[0-9a-f]{32}$/.test(accepted.token))
				throw uncertainYamlUpdateError();

			const result = await this.waitForYamlUpdate(accepted.token, scope);
			if (result?.indeterminate === true)
				throw uncertainYamlUpdateError(typeof result?.error === 'string' && result.error
					? result.error
					: undefined);
			if (result?.ok === true &&
			    (typeof result.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(result.sha256)))
				throw uncertainYamlUpdateError(_('The YAML update succeeded, but its result could not be verified. Reload the page before editing it again.'));
			if (result?.ok !== true)
				throw new Error(typeof result?.error === 'string' && result.error
					? result.error
					: _('The server rejected the YAML configuration. Check its syntax and protected settings.'));

			this.invalidateYamlEditor();
			try {
				await this.reloadYaml();
			} catch (error) {
				operation.success(
					_('The YAML configuration was saved and applied, but the editor could not reload it: %s. Refresh this page before editing again.').format(errorMessage(error)),
					operationTicket,
				);
				return;
			}
			operation.success(undefined, operationTicket);
		} catch (error) {
			if (operation.isPageInactiveError(error) || !operation.isPageActive(scope))
				return;
			if (error?.yamlUpdateUncertain === true)
				this.invalidateYamlEditor();
			operation.failure(
				_('Unable to save the YAML configuration: %s').format(errorMessage(error)),
				operationTicket,
			);
		} finally {
			if (operation.isPageActive(scope))
				this.setBusy(false);
		}
	},

	handleTemplateResetClick() {
		ui.showModal(_('Restore YAML Template'), [
			E('p', { class: 'alert-message warning' },
				_('This replaces only the text currently shown in the editor with the packaged template.')),
			E('p', {},
				_('The active YAML file, service and data remain unchanged until you choose Validate, Save & Apply. Continue editing after the template is loaded, or reload from disk to discard it.')),
			E('div', { class: 'right' }, [
				E('button', {
					class: 'cbi-button',
					type: 'button',
					click: ui.hideModal,
				}, _('Cancel')),
				' ',
				E('button', {
					class: 'cbi-button cbi-button-negative',
					type: 'button',
					click: ui.createHandlerFn(this, async () => {
						ui.hideModal();
						await this.resetYaml();
					}),
				}, _('Restore Template')),
			]),
		]);
	},

	async resetYaml() {
		const scope = this.pageScope;
		if (!this.yamlHash || this.operationBusy || !operation.isPageActive(scope))
			return;

		this.setBusy(true);
		try {
			const template = await callResetYaml(this.yamlHash);
			if (!operation.isPageActive(scope))
				return;
			if (typeof template?.error === 'string' && template.error)
				throw new Error(template.error);
			if (typeof template?.content !== 'string' || !template.content)
				throw new Error(_('The packaged YAML template is unavailable.'));

			// Keep yamlHash unchanged: it still represents the active file revision
			// that set_yaml must compare when the user later saves this editor text.
			this.yamlEditor.value = template.content;
		} catch (error) {
			if (!operation.isPageActive(scope))
				return;
			operation.failure(
				_('Unable to restore the YAML template: %s').format(errorMessage(error)),
			);
		} finally {
			if (operation.isPageActive(scope))
				this.setBusy(false);
		}
	},

	async waitForYamlUpdate(token, scope) {
		return operation.waitForJob(callGetYamlUpdate, token, scope, {
			unknown: _('The YAML update returned an unknown job state.'),
			unavailable: _('The YAML update is still running, but its status is temporarily unavailable: %s. Do not submit it again; reload this page later.'),
			pending: _('The YAML update is still running. Do not submit it again; reload this page later.'),
		}, uncertainYamlUpdateError);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
});
