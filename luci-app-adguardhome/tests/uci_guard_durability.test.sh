#!/bin/sh

set -eu

# Production uses high-numbered directory descriptors supported by BusyBox ash.
if ! (eval 'exec 191<&0 && exec 191<&-') 2>/dev/null; then
	if command -v busybox >/dev/null 2>&1; then
		exec busybox ash "$0" "$@"
	fi
	exec bash "$0" "$@"
fi

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

for name in uci_guard_configs_unchanged uci_guard_file_signature \
	memory_run_with_official_path_guard; do
	eval "$(function_body "$init_file" "$name")"
done

OFFICIAL_CONFIG=adguardhome
UCI_CONFIG_DIRECTORY="${test_tmp}/config"
mkdir "$UCI_CONFIG_DIRECTORY"
config_target="${UCI_CONFIG_DIRECTORY}/${OFFICIAL_CONFIG}"
events="${test_tmp}/events"
DELTA_PENDING=0

# File lifecycle is real; only ownership preconditions (so tests run without
# root), UCI delta lookup and the global sync are stubbed.
uci_guard_snapshot_dir_valid() { [ -d "$1" ] && [ ! -L "$1" ]; }
uci_guard_config_file_valid() { [ -f "$1" ] && [ ! -L "$1" ]; }
uci_guard_no_delta() { [ "$DELTA_PENDING" = 0 ]; }
uci_guard_snapshot_configs() {
	local directory
	directory="$(mktemp -d "${test_tmp}/snapshot.XXXXXX")"
	if [ -e "$config_target" ]; then
		cp -p "$config_target" "${directory}/${OFFICIAL_CONFIG}"
	else
		: >"${directory}/.originally-absent"
	fi
	printf '%s\n' "$directory"
}
uci_guard_discard_snapshot() {
	rm -f "$1/$OFFICIAL_CONFIG" "$1/.originally-absent"
	rmdir "$1"
}
memory_durability_barrier() { printf 'sync\n' >>"$events"; }
uci_guard_rollback_configs() {
	printf 'rollback\n' >>"$events"
	if [ -f "$1/$OFFICIAL_CONFIG" ]; then
		cp -p "$1/$OFFICIAL_CONFIG" "$config_target"
	else
		rm -f "$config_target"
	fi
	memory_durability_barrier
}
log_error() { :; }
no_change() { :; }
change_bytes() { printf 'new\n' >"$config_target"; }
change_mode() { chmod 0600 "$config_target"; }
fail_change() { change_bytes; return 1; }
settings_commit_persistent() { "$ACTION"; }
normalize_managed_config_file_persistent() { "$ACTION"; }
sync_tls_access_persistent() { "$ACTION"; }

printf 'old\n' >"$config_target"
chmod 0644 "$config_target"
: >"$events"
ACTION=no_change
memory_run_with_official_path_guard settings_commit_persistent
[ ! -s "$events" ]

# Same-sized but different bytes are a real change and must flush once.
ACTION=change_bytes
memory_run_with_official_path_guard settings_commit_persistent
[ "$(cat "$events")" = sync ]
: >"$events"
ACTION=change_mode
memory_run_with_official_path_guard settings_commit_persistent
[ "$(cat "$events")" = sync ]
: >"$events"
ACTION=no_change
memory_run_with_official_path_guard normalize_managed_config_file_persistent
[ ! -s "$events" ]

# TLS/official actions can repair other files; identical UCI alone is not
# sufficient to suppress their barrier.
memory_run_with_official_path_guard sync_tls_access_persistent
[ "$(cat "$events")" = sync ]
: >"$events"

# Absent -> absent is also a no-op; absent -> newly-created still flushes.
rm "$config_target"
memory_run_with_official_path_guard settings_commit_persistent
[ ! -s "$events" ]
ACTION=change_bytes
memory_run_with_official_path_guard settings_commit_persistent
[ "$(cat "$events")" = sync ]

# Failure still restores the saved file and performs its durability barrier.
printf 'old\n' >"$config_target"
: >"$events"
ACTION=fail_change
if memory_run_with_official_path_guard settings_commit_persistent; then
	printf 'failed transaction was accepted\n' >&2
	exit 1
fi
[ "$(cat "$config_target")" = old ]
[ "$(head -n 1 "$events")" = rollback ]
[ "$(tail -n 1 "$events")" = sync ]

: >"$events"
DELTA_PENDING=1
ACTION=change_bytes
if memory_run_with_official_path_guard settings_commit_persistent; then
	printf 'pending external UCI delta was accepted\n' >&2
	exit 1
fi
[ ! -s "$events" ]
[ "$(cat "$config_target")" = old ]

printf 'ok - unchanged UCI skips sync; content/metadata/create/rollback keep durability\n'
