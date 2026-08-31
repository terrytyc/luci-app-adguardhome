// SPDX-License-Identifier: Apache-2.0

'use strict';

'require baseclass';
'require ui';

const APPLY_WAIT_SECONDS = 90;
const DEFAULT_RESULT_DISPLAY_SECONDS = 3;
const ERROR_DISPLAY_SECONDS = 8;
const APPLY_STORAGE_KEY = 'luci.adguardhome.applyPendingUntil';
const APPLY_RETRY_INTERVAL = 1000;

return baseclass.extend({
	_timer: null,
	_generation: 0,
	_scopeGeneration: 0,
	_activeScope: null,
	_applyPendingUntil: 0,
	_applyNavigationGuard: null,

	createPageScope() {
		if (this._activeScope != null) {
			const hadVisibleOperation = this._timer != null;
			this._clearTimer();
			this._generation++;
			if (hadVisibleOperation)
				ui.hideModal();
		}

		const generation = ++this._scopeGeneration;
		let hidden = false;
		let root = null;
		let wasConnected = false;

		const scope = {
			attach(node) {
				root = node;
				return node;
			},

			active: () => {
				if (hidden || generation !== this._scopeGeneration)
					return false;

				if (root == null)
					return true;

				const connected = root.isConnected === true ||
					(document.documentElement?.contains(root) === true);
				if (connected)
					wasConnected = true;
				return !wasConnected || connected;
			},
		};

		window.addEventListener('pagehide', () => {
			hidden = true;
			if (this._activeScope === scope) {
				this._clearTimer();
				this._generation++;
			}
		}, { once: true });

		this._activeScope = scope;
		return scope;
	},

	isPageActive(scope) {
		const target = scope ?? this._activeScope;
		return target == null || target.active();
	},

	pageInactiveError() {
		const error = new Error('AdGuard Home view is no longer active');
		error.pageInactive = true;
		return error;
	},

	isPageInactiveError(error) {
		return error?.pageInactive === true;
	},

	abandonInactiveLoad(error) {
		if (!this.isPageInactiveError(error))
			throw error;

		// LuCI has no view-unload callback. Keeping an obsolete load chain
		// pending prevents its base View continuation from replacing the DOM
		// after a newer view has already been instantiated.
		return new Promise(() => { });
	},

	markApplyPending() {
		const rollback = Number(L.env?.apply_rollback);
		const holdoff = Number(L.env?.apply_holdoff);
		const display = Number(L.env?.apply_display);
		const seconds = Math.max(
			APPLY_WAIT_SECONDS,
			(Number.isFinite(rollback) && rollback > 0 ? rollback : 0) +
			(Number.isFinite(holdoff) && holdoff > 0 ? holdoff : 0) +
			(Number.isFinite(display) && display > 0 ? display : 0) + 15,
		);

		this._applyPendingUntil = Date.now() + seconds * 1000;
		try {
			window.sessionStorage.setItem(
				APPLY_STORAGE_KEY,
				String(this._applyPendingUntil),
			);
		} catch (error) { }
		this._installApplyNavigationGuard();

		const clear = () => this.clearApplyPending();
		document.addEventListener('uci-applied', clear, { once: true });
		document.addEventListener('uci-reverted', clear, { once: true });
	},

	clearApplyPending() {
		this._applyPendingUntil = 0;
		try { window.sessionStorage.removeItem(APPLY_STORAGE_KEY); }
		catch (error) { }
		this._removeApplyNavigationGuard();
	},

	applyPending() {
		let deadline = this._applyPendingUntil;
		try {
			const stored = Number(window.sessionStorage.getItem(APPLY_STORAGE_KEY));
			if (Number.isFinite(stored) && stored > deadline)
				deadline = stored;
		} catch (error) { }
		if (Number.isFinite(deadline) && deadline > Date.now())
			return true;
		this.clearApplyPending();
		return false;
	},

	_installApplyNavigationGuard() {
		if (this._applyNavigationGuard != null)
			return;

		this._applyNavigationGuard = event => {
			const anchor = event.target?.closest?.('a[href]');
			if (anchor == null)
				return;
			if (!this.applyPending())
				return;

			// A checked LuCI apply is confirmed by the JavaScript running in this
			// document.  Some themes expose navigation links above the modal; a
			// full-page switch would destroy that confirmer and force a rollback.
			// Reinforce the standard modal boundary only while it is visibly active.
			if (document.body?.classList?.contains('modal-overlay-active') !== true) {
				this.clearApplyPending();
				return;
			}

			event.preventDefault();
			event.stopPropagation();
			event.stopImmediatePropagation?.();
		};
		document.addEventListener('click', this._applyNavigationGuard, true);
	},

	_removeApplyNavigationGuard() {
		if (this._applyNavigationGuard == null)
			return;
		document.removeEventListener('click', this._applyNavigationGuard, true);
		this._applyNavigationGuard = null;
	},

	isTransientApplyError(error) {
		const name = String(error?.name ?? '');
		const message = String(error?.message ?? error ?? '');
		return name === 'RequestError' || name === 'TimeoutError' ||
			/(?:XHR|network|failed to fetch|load failed|timed?\s*out|HTTP error)/i.test(message);
	},

	async requestDuringApply(requestFn, scope) {
		for (;;) {
			if (!this.isPageActive(scope))
				throw this.pageInactiveError();

			try {
				const result = await requestFn();
				if (!this.isPageActive(scope))
					throw this.pageInactiveError();
				return result;
			} catch (error) {
				if (this.isPageInactiveError(error) || !this.isPageActive(scope))
					throw this.pageInactiveError();
				if (!this.applyPending() || !this.isTransientApplyError(error))
					throw error;
			}

			await new Promise(resolve => window.setTimeout(resolve, APPLY_RETRY_INTERVAL));
		}
	},

	_clearTimer() {
		if (this._timer != null) {
			window.clearTimeout(this._timer);
			this._timer = null;
		}
	},

	_ticketActive(ticket) {
		return ticket == null ||
			(ticket.scope === this._activeScope &&
			 ticket.generation === this._generation &&
			 this.isPageActive(ticket.scope));
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
		const ticket = { generation, scope: this._activeScope };
		const deadline = Date.now() + APPLY_WAIT_SECONDS * 1000;

		const tick = () => {
			if (!this._ticketActive(ticket))
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
		return ticket;
	},

	success(message, ticket) {
		if (!this._ticketActive(ticket))
			return;
		this._clearTimer();
		const generation = ++this._generation;
		if (!this.isPageActive())
			return;
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

	failure(message, ticket) {
		if (!this._ticketActive(ticket))
			return;
		this._clearTimer();
		const generation = ++this._generation;
		if (!this.isPageActive())
			return;
		this._show('error', String(message ?? _('Unknown error')), false);
		this._timer = window.setTimeout(() => {
			if (generation === this._generation) {
				this._timer = null;
				ui.hideModal();
			}
		}, ERROR_DISPLAY_SECONDS * 1000);
	},
});
