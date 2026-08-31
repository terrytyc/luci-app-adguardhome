// SPDX-License-Identifier: Apache-2.0

'use strict';

'require adguardhome.operation as operation';
'require rpc';
'require ui';
'require view';

const DEFAULT_LINES = 100;
const VALID_LINE_COUNTS = [ 100, 300, 500 ];
const LOG_SOURCES = [ 'core', 'plugin' ];

const callGetLog = rpc.declare({
	object: 'luci.adguardhome',
	method: 'get_log',
	params: [ 'source', 'lines' ],
	expect: { '': { log: '', lines: 0, source: 'core' } },
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
		source: result?.source === 'plugin' ? 'plugin' : 'core',
	};
}

function errorMessage(error) {
	return String(error?.message ?? error ?? _('Unknown error'));
}

function sourceErrorMessage(source, error) {
	return source === 'plugin'
		? _('Unable to read the plugin runtime log: %s').format(errorMessage(error))
		: _('Unable to read the AdGuard Home core log: %s').format(errorMessage(error));
}

async function fetchLog(source, lines) {
	try {
		const result = normalizeLog(await callGetLog(source, lines));
		if (result.source !== source)
			throw new Error(_('The log source response was invalid.'));
		return result;
	} catch (error) {
		return { log: '', lines: 0, source, error };
	}
}

function logOutput(result) {
	return E('textarea', {
		class: 'cbi-input-textarea',
		readonly: 'readonly',
		rows: 20,
		spellcheck: 'false',
		wrap: 'off',
		style: 'box-sizing: border-box; width: 100%; padding: .75em; font-family: monospace; resize: vertical;',
	}, [ result.log || _('No log output.') ]);
}

function logSummary(lines, result) {
	return E('span', {},
		_('Showing up to %d lines (%d returned).').format(lines, result.lines));
}

return view.extend({
	async load() {
		const [ core, plugin ] = await Promise.all([
			fetchLog('core', DEFAULT_LINES),
			fetchLog('plugin', DEFAULT_LINES),
		]);
		return { core, plugin };
	},

	render(result) {
		this.logLines = DEFAULT_LINES;
		this.logOutputs = {
			core: logOutput(result.core),
			plugin: logOutput(result.plugin),
		};
		this.logSummaries = {
			core: logSummary(DEFAULT_LINES, result.core),
			plugin: logSummary(DEFAULT_LINES, result.plugin),
		};
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

		for (const source of LOG_SOURCES)
			if (result[source].error)
				ui.addNotification(null, E('p', {},
					sourceErrorMessage(source, result[source].error)), 'error');

		return E('div', {}, [
			E('h2', {}, _('AdGuard Home')),
			E('div', { class: 'cbi-map-descr' },
				_('View recent core and plugin messages from the system log. The newest entries are shown first, and this page is read-only.')),
			E('div', { class: 'cbi-section' }, [
				E('div', {
					style: 'display: flex; align-items: center; flex-wrap: wrap; gap: .5em;',
				}, [
					E('label', {}, [ _('Lines:'), ' ', this.lineSelect ]),
					this.refreshButton,
				]),
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('AdGuard Home Core Log')),
				E('div', { style: 'margin-bottom: .75em;' }, [ this.logSummaries.core ]),
				this.logOutputs.core,
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('Plugin Runtime Log')),
				E('div', { style: 'margin-bottom: .75em;' }, [ this.logSummaries.plugin ]),
				this.logOutputs.plugin,
			]),
		]);
	},

	async handleRefresh() {
		const lines = normalizeLineCount(this.lineSelect?.value ?? this.logLines);
		this.logLines = lines;
		this.refreshButton.disabled = true;
		operation.start();

		try {
			const [ core, plugin ] = await Promise.all([
				fetchLog('core', lines),
				fetchLog('plugin', lines),
			]);
			const results = { core, plugin };
			const failures = [];

			for (const source of LOG_SOURCES) {
				const result = results[source];
				if (result.error) {
					failures.push(sourceErrorMessage(source, result.error));
					continue;
				}

				this.logOutputs[source].value = result.log || _('No log output.');
				this.logOutputs[source].scrollTop = 0;
				this.logSummaries[source].textContent =
					_('Showing up to %d lines (%d returned).').format(lines, result.lines);
			}

			if (failures.length)
				operation.failure(failures.join(' '));
			else
				operation.success(_('Logs refreshed.'));
		} catch (error) {
			operation.failure(errorMessage(error));
		} finally {
			this.refreshButton.disabled = false;
		}
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
});
