// SPDX-License-Identifier: Apache-2.0

'use strict';

'require adguardhome.operation as operation';
'require rpc';
'require ui';
'require view';

const DEFAULT_LINES = 100;
const VALID_LINE_COUNTS = [ 100, 300, 500 ];

const callGetLog = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_log',
	params: [ 'lines' ],
	expect: { '': { log: '', lines: 0 } },
	reject: true,
});

function normalizeLineCount(value) {
	const lines = Number(value);
	return VALID_LINE_COUNTS.includes(lines) ? lines : DEFAULT_LINES;
}

function normalizeLog(result) {
	return {
		log: typeof result?.log === 'string' ? result.log : '',
		lines: Number.isInteger(Number(result?.lines)) && Number(result.lines) >= 0
			? Number(result.lines)
			: 0,
	};
}

function errorMessage(error) {
	return String(error?.message ?? error ?? _('Unknown error'));
}

return view.extend({
	async load() {
		try {
			return normalizeLog(await callGetLog(DEFAULT_LINES));
		} catch (error) {
			return { log: '', lines: 0, error };
		}
	},

	render(result) {
		this.logLines = DEFAULT_LINES;
		this.logOutput = E('textarea', {
			class: 'cbi-input-textarea',
			readonly: 'readonly',
			rows: 28,
			spellcheck: 'false',
			wrap: 'off',
			style: 'box-sizing: border-box; width: 100%; padding: .75em; font-family: monospace; resize: vertical;',
		}, [ result.log || _('No log output.') ]);
		this.logSummary = E('span', {},
			_('Showing up to %d lines (%d returned).').format(DEFAULT_LINES, result.lines));
		this.lineSelect = E('select', {
			class: 'cbi-input-select',
			change: (event) => {
				this.logLines = normalizeLineCount(event.target.value);
			},
		}, VALID_LINE_COUNTS.map((lines) => E('option', {
			value: String(lines),
			selected: lines === DEFAULT_LINES ? 'selected' : null,
		}, _('%d lines').format(lines))));
		this.refreshButton = E('button', {
			class: 'cbi-button cbi-button-action',
			type: 'button',
			click: ui.createHandlerFn(this, 'handleRefresh'),
		}, _('Refresh'));

		if (result.error) {
			ui.addNotification(null, E('p', {},
				_('Unable to read the runtime log: %s').format(errorMessage(result.error))), 'error');
		}

		return E('div', {}, [
			E('h2', {}, _('AdGuard Home')),
			E('div', { class: 'cbi-map-descr' },
				_('View recent service messages from the system log. This page is read-only.')),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('Runtime Log')),
				E('div', {
					style: 'display: flex; align-items: center; flex-wrap: wrap; gap: .5em; margin-bottom: .75em;',
				}, [
					E('label', {}, [ _('Lines:'), ' ', this.lineSelect ]),
					this.refreshButton,
					this.logSummary,
				]),
				this.logOutput,
			]),
		]);
	},

	async handleRefresh() {
		const lines = normalizeLineCount(this.lineSelect?.value ?? this.logLines);
		this.logLines = lines;
		this.refreshButton.disabled = true;
		operation.start();

		try {
			const result = normalizeLog(await callGetLog(lines));
			this.logOutput.value = result.log || _('No log output.');
			this.logSummary.textContent =
				_('Showing up to %d lines (%d returned).').format(lines, result.lines);
			operation.success();
		} catch (error) {
			operation.failure(
				_('Unable to read the runtime log: %s').format(errorMessage(error)),
			);
		} finally {
			this.refreshButton.disabled = false;
		}
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
});
