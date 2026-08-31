// SPDX-License-Identifier: Apache-2.0

'use strict';

'require baseclass';
'require ui';

const APPLY_WAIT_SECONDS = 90;
const DEFAULT_RESULT_DISPLAY_SECONDS = 3;
const ERROR_DISPLAY_SECONDS = 8;

return baseclass.extend({
	_timer: null,
	_generation: 0,

	_clearTimer() {
		if (this._timer != null) {
			window.clearTimeout(this._timer);
			this._timer = null;
		}
	},

	_show(type, message, spinning) {
		const classes = [ 'alert-message', type ];
		if (spinning)
			classes.push('spinning');

		ui.showModal('', E('p', {}, message), ...classes);
	},

	start() {
		this._clearTimer();
		const generation = ++this._generation;
		const deadline = Date.now() + APPLY_WAIT_SECONDS * 1000;

		const tick = () => {
			if (generation !== this._generation)
				return;

			const remaining = Math.max(Math.ceil((deadline - Date.now()) / 1000), 0);
			this._show(
				'notice',
				_('Applying configuration changes… %ds').format(remaining),
				true,
			);

			if (remaining > 0)
				this._timer = window.setTimeout(tick, 1000);
		};

		tick();
	},

	success(message) {
		this._clearTimer();
		const generation = ++this._generation;
		this._show(
			'notice',
			String(message ?? _('Configuration changes applied.')),
			false,
		);

		const configured = Number(L.env?.apply_display);
		const seconds = Number.isFinite(configured) && configured > 0
			? configured
			: DEFAULT_RESULT_DISPLAY_SECONDS;
		this._timer = window.setTimeout(() => {
			if (generation === this._generation) {
				this._timer = null;
				ui.hideModal();
			}
		}, seconds * 1000);
	},

	failure(message) {
		this._clearTimer();
		const generation = ++this._generation;
		this._show('error', String(message ?? _('Unknown error')), false);
		this._timer = window.setTimeout(() => {
			if (generation === this._generation) {
				this._timer = null;
				ui.hideModal();
			}
		}, ERROR_DISPLAY_SECONDS * 1000);
	},
});
