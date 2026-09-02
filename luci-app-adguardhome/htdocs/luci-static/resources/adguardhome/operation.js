// SPDX-License-Identifier: Apache-2.0

'use strict';

'require baseclass';
'require ui';

const DEFAULT_RESULT_DISPLAY_SECONDS = 3;
const ERROR_DISPLAY_SECONDS = 8;
const JOB_POLL_INTERVAL = 2000;
const JOB_POLL_LIMIT = 180;

return baseclass.extend({
	_timer: null,
	_modalVisible: false,
	_generation: 0,
	_scopeGeneration: 0,
	_activeScope: null,
	_pageShowGuard: null,
	_bfcacheReloading: false,

	_installPageShowGuard() {
		if (this._pageShowGuard != null)
			return;

		this._pageShowGuard = event => {
			if (event?.persisted !== true || this._bfcacheReloading)
				return;

			// A page restored from the back-forward cache retains its old
			// promises, timers and form snapshot.  Rebuild the LuCI view instead
			// of reactivating an obsolete scope and allowing stale XHR results to
			// update it.
			this._bfcacheReloading = true;
			window.location.reload();
		};
		window.addEventListener('pageshow', this._pageShowGuard);
	},

	createPageScope() {
		this._installPageShowGuard();

		if (this._activeScope != null) {
			this._clearTimer();
			this._generation++;
			if (this._modalVisible)
				this._hide();
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

	async requestActive(requestFn, scope) {
		if (!this.isPageActive(scope))
			throw this.pageInactiveError();

		try {
			const result = await requestFn();
			if (!this.isPageActive(scope))
				throw this.pageInactiveError();
			return result;
		} catch (error) {
			if (!this.isPageActive(scope))
				throw this.pageInactiveError();
			throw error;
		}
	},

	async waitForJob(statusFn, token, scope, messages, makeError = message => new Error(message)) {
		let consecutiveErrors = 0;
		let lastError = null;

		for (let attempt = 0; attempt < JOB_POLL_LIMIT; attempt++) {
			let result = null;
			try {
				result = await this.requestActive(() => statusFn(token, false), scope);
				consecutiveErrors = 0;
				lastError = null;
			} catch (error) {
				if (this.isPageInactiveError(error))
					throw error;
				lastError = error;
				if (++consecutiveErrors >= 6)
					break;
			}

			if (result != null) {
				if (result.state === 'done') {
					try { await this.requestActive(() => statusFn(token, true), scope); }
					catch (error) {
						// The terminal result is known; only page invalidation matters here.
						if (this.isPageInactiveError(error))
							throw error;
					}
					return result;
				}
				if (typeof result.error === 'string' && result.error)
					throw makeError(result.error);
				if (result.state !== 'pending' && result.state !== 'running')
					throw makeError(messages.unknown);
			} else if (lastError == null) {
				throw makeError(messages.unknown);
			}

			await new Promise(resolve => window.setTimeout(resolve, JOB_POLL_INTERVAL));
		}

		throw makeError(lastError
			? messages.unavailable.format(String(lastError?.message ?? lastError))
			: messages.pending);
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
		this._modalVisible = true;
	},

	_hide() {
		this._modalVisible = false;
		ui.hideModal();
	},

	start() {
		this._clearTimer();
		const generation = ++this._generation;
		const ticket = { generation, scope: this._activeScope };
		if (this._ticketActive(ticket))
			this._show('notice', _('Applying configuration changes…'), true);
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
				this._hide();
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
				this._hide();
			}
		}, ERROR_DISPLAY_SECONDS * 1000);
	},
});
