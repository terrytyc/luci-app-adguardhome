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
		content: typeof result?.content === 'string' ? result.content.replace(/\r\n?/g, '\n') : '',
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

function escapeHtml(value) {
	return String(value).replace(/[&<>"']/g, character => ({
		'&': '&amp;',
		'<': '&lt;',
		'>': '&gt;',
		'"': '&quot;',
		"'": '&#39;',
	})[character]);
}

function yamlCommentOffset(line) {
	let quote = '';
	for (let i = 0; i < line.length; i++) {
		const character = line[i];
		if (quote === '"' && character === '\\') {
			i++;
			continue;
		}
		if (character === '"' || character === "'") {
			quote = quote === character ? '' : quote || character;
			continue;
		}
		if (!quote && character === '#' && (i === 0 || /\s/.test(line[i - 1])))
			return i;
	}
	return -1;
}

function yamlToken(type, value) {
	return `<span class="adguardhome-yaml-${type}">${escapeHtml(value)}</span>`;
}

// ponytail: presentation-only common scalars; the backend remains the YAML parser.
function highlightYamlScalar(value) {
	const match = String(value).match(/^(\s*)(.*?)(\s*)$/);
	const scalar = match[2];
	let type = '';

	if (/^(?:true|false|null|~)$/i.test(scalar))
		type = 'literal';
	else if (/^[-+]?(?:0|[1-9]\d*)(?:\.\d+)?(?:e[-+]?\d+)?$/i.test(scalar))
		type = 'number';
	else if (/^(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s,[\]{}]+)$/.test(scalar))
		type = 'scalar';

	return escapeHtml(match[1]) + (type ? yamlToken(type, scalar) : escapeHtml(scalar)) + escapeHtml(match[3]);
}

function highlightYamlLine(line) {
	const commentOffset = yamlCommentOffset(line);
	const content = commentOffset < 0 ? line : line.slice(0, commentOffset);
	const comment = commentOffset < 0 ? '' : line.slice(commentOffset);
	const mapping = content.match(/^(\s*(?:-\s+)?)([^:#][^:]*?)(\s*:\s*)(.*)$/);
	const sequence = mapping ? null : content.match(/^(\s*-\s+)(.*)$/);
	let highlighted;

	if (mapping) {
		highlighted = escapeHtml(mapping[1]) + yamlToken('key', mapping[2]) +
			escapeHtml(mapping[3]) + highlightYamlScalar(mapping[4]);
	} else if (sequence) {
		highlighted = escapeHtml(sequence[1]) + highlightYamlScalar(sequence[2]);
	} else {
		highlighted = highlightYamlScalar(content);
	}

	return highlighted + (comment ? yamlToken('comment', comment) : '');
}

function highlightYaml(content, activeLine) {
	return String(content).split('\n').map((line, index) =>
		`<span class="adguardhome-yaml-line${index === activeLine ? ' active' : ''}">${highlightYamlLine(line) || '&#8203;'}</span>`
	).join('');
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
		this.loadedYaml = result.content;
		this.editorNotice = E('p', { class: 'alert-message error', role: 'status', hidden: true });
		this.draftStatus = E('span', { class: 'adguardhome-yaml-draft', role: 'status', hidden: true }, _('Unsaved changes'));
		this.yamlLineNumbers = E('pre', {
			class: 'adguardhome-yaml-lines',
			'aria-hidden': 'true',
		});
		this.yamlHighlight = E('pre', {
			class: 'adguardhome-yaml-highlight',
			'aria-hidden': 'true',
		});
		this.yamlEditor = E('textarea', {
			class: 'adguardhome-editor',
			'aria-label': _('YAML Configuration'),
			rows: 32,
			spellcheck: 'false',
			wrap: 'off',
			readonly: result.error || !result.sha256 || !L.hasViewPermission() ? 'readonly' : null,
			input: () => this.refreshYamlEditor(),
			scroll: () => this.syncYamlEditorScroll(),
			click: () => this.updateActiveYamlLine(),
			keyup: () => this.updateActiveYamlLine(),
			select: () => this.updateActiveYamlLine(),
		}, [ result.content ]);
		this.yamlEditorFrame = E('div', { class: 'adguardhome-yaml-editor' }, [
			this.yamlLineNumbers,
			this.yamlHighlight,
			this.yamlEditor,
		]);
		this.refreshYamlEditor();
		this.pathValue = E('span', {}, result.path || _('Unavailable'));
		this.saveButton = E('button', {
			class: 'cbi-button cbi-button-positive',
			type: 'button',
			disabled: result.error || !result.sha256 || !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'handleSaveClick'),
		}, _('Validate, Save & Apply'));
		this.resetButton = E('button', {
			class: 'cbi-button',
			type: 'button',
			disabled: result.error || !result.sha256 || !L.hasViewPermission() ? 'disabled' : null,
			click: ui.createHandlerFn(this, 'resetYaml'),
		}, _('Load Template'));
		this.reloadButton = E('button', {
			class: 'cbi-button',
			type: 'button',
			click: ui.createHandlerFn(this, 'handleReload'),
		}, _('Reload from disk'));

		if (result.error && operation.isPageActive(pageScope)) {
			ui.addNotification(null, E('p', {},
				_('Unable to read the YAML configuration: %s').format(errorMessage(result.error))), 'error');
		}
		if (result.error || !result.sha256)
			this.invalidateYamlEditor(result.error
				? _('Unable to read the YAML configuration: %s').format(errorMessage(result.error))
				: _('The YAML configuration is unavailable.'));

		const root = E('div', { class: 'adguardhome-view' }, [
			E('link', { rel: 'stylesheet', href: L.resource('adguardhome/style.css') }),
			E('h2', {}, _('AdGuard Home')),
			E('div', { class: 'cbi-map-descr' }, [
				_('Edit the active AdGuard Home configuration file directly.'),
				' ',
				_('Saving validates and atomically applies the YAML. A running service is restarted; a disabled service remains stopped.'),
			]),
			E('div', { class: 'cbi-section' }, [
				E('div', { class: 'adguardhome-yaml-heading' }, [
					E('h3', {}, _('YAML Configuration')),
					this.draftStatus,
				]),
				E('p', { class: 'adguardhome-yaml-path' }, this.pathValue),
				this.editorNotice,
				this.yamlEditorFrame,
				E('p', { class: 'adguardhome-help' },
					_('Load Template changes only the editor. The active configuration stays unchanged until Validate, Save & Apply.')),
				E('div', { class: 'cbi-page-actions adguardhome-actions' }, [
					E('div', { class: 'adguardhome-actions-secondary' }, [
						this.reloadButton,
						this.resetButton,
					]),
					this.saveButton,
				]),
			]),
		]);
		return pageScope.attach(root);
	},

	async handleReload(discardDraft = false) {
		const scope = this.pageScope;
		if (this.operationBusy || !operation.isPageActive(scope))
			return;
		if (discardDraft !== true && this.hasDraft()) {
			ui.showModal(_('Discard unsaved changes?'), [
				E('p', {}, _('Reloading from disk will replace your unsaved editor text.')),
				E('div', { class: 'right' }, [
					E('button', { class: 'cbi-button', type: 'button', click: ui.hideModal }, _('Cancel')),
					' ',
					E('button', {
						class: 'cbi-button cbi-button-action', type: 'button',
						click: () => { ui.hideModal(); return this.handleReload(true); },
					}, _('Reload from disk')),
				]),
			]);
			return;
		}
		this.setBusy(true);
		try {
			await this.reloadYaml();
		} catch (error) {
			if (operation.isPageInactiveError(error))
				return;
			this.invalidateYamlEditor(_('Unable to read the YAML configuration: %s').format(errorMessage(error)));
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
		this.loadedYaml = result.content;
		this.yamlHash = result.sha256;
		this.pathValue.textContent = result.path || _('Unavailable');
		this.editorNotice.hidden = true;
		this.editorNotice.textContent = '';
		this.refreshYamlEditor();
		this.yamlEditor.readOnly = this.operationBusy || !this.yamlHash || !L.hasViewPermission();
	},

	hasDraft() {
		return this.yamlEditor.value !== this.loadedYaml;
	},

	updateDraftStatus() {
		this.draftStatus.hidden = !this.hasDraft();
	},

	refreshYamlEditor() {
		const content = String(this.yamlEditor.value ?? '');
		const cursor = Number.isInteger(this.yamlEditor.selectionStart)
			? this.yamlEditor.selectionStart
			: 0;
		const activeLine = content.slice(0, cursor).split('\n').length - 1;
		const lineCount = content.split('\n').length;

		this.yamlLineNumbers.textContent = Array.from({ length: lineCount }, (_, index) => index + 1).join('\n');
		this.yamlHighlight.innerHTML = highlightYaml(content, activeLine);
		this.activeYamlLine = activeLine;
		this.syncYamlEditorScroll();
		this.updateDraftStatus();
	},

	updateActiveYamlLine() {
		const content = String(this.yamlEditor.value ?? '');
		const cursor = Number.isInteger(this.yamlEditor.selectionStart)
			? this.yamlEditor.selectionStart
			: 0;
		const activeLine = content.slice(0, cursor).split('\n').length - 1;

		if (activeLine === this.activeYamlLine)
			return;
		this.yamlHighlight.children[this.activeYamlLine]?.classList.remove('active');
		this.yamlHighlight.children[activeLine]?.classList.add('active');
		this.activeYamlLine = activeLine;
	},

	syncYamlEditorScroll() {
		const left = Number(this.yamlEditor.scrollLeft) || 0;
		const top = Number(this.yamlEditor.scrollTop) || 0;

		this.yamlLineNumbers.style.transform = `translateY(${-top}px)`;
		this.yamlHighlight.style.transform = `translate(${-left}px, ${-top}px)`;
	},

	invalidateYamlEditor(reason = _('The YAML configuration is unavailable.')) {
		this.yamlHash = '';
		this.yamlEditor.readOnly = true;
		this.editorNotice.textContent = `${reason} ${_('Use Reload from disk before editing again.')}`;
		this.editorNotice.hidden = false;
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
				if (operation.isPageInactiveError(error) || !operation.isPageActive(scope))
					return;
				this.invalidateYamlEditor(_('Unable to read the YAML configuration: %s').format(errorMessage(error)));
				operation.failure(
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
				this.invalidateYamlEditor(errorMessage(error));
			operation.failure(
				_('Unable to save the YAML configuration: %s').format(errorMessage(error)),
				operationTicket,
			);
		} finally {
			if (operation.isPageActive(scope))
				this.setBusy(false);
		}
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
			this.refreshYamlEditor();
		} catch (error) {
			if (!operation.isPageActive(scope))
				return;
			operation.failure(
				_('Unable to load the YAML template: %s').format(errorMessage(error)),
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
