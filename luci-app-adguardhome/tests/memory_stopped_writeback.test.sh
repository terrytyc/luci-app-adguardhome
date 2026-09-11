#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
load_body="$(function_body "$init_file" load_settings)"
cleanup_body="$(function_body "$init_file" memory_cleanup_locked_command)"
checkpoint_body="$(function_body "$init_file" memory_checkpoint_locked_command)"
copy_body="$(function_body "$init_file" memory_copy_live_data_locked)"
deactivate_body="$(function_body "$init_file" memory_deactivate_locked)"
remove_body="$(function_body "$init_file" memory_remove_active_tree)"
status_body="$(function_body "$init_file" memory_status)"
stopped_body="$(function_body "$init_file" memory_copy_stopped_data_locked)"
quarantine_body="$(function_body "$init_file" memory_quarantine_stopped_conflicts_locked)"
prune_body="$(function_body "$init_file" memory_prune_stopped_data_locked)"

printf '%s\n' "$load_body" | grep -Fq 'Unsafe or incomplete AdGuard Home memory namespace'
printf '%s\n' "$load_body" | grep -Fq 'return 1'
if printf '%s\n' "$load_body" | grep -Fq 'Disk mode remains available'; then
	exit 1
fi
printf '%s\n' "$cleanup_body" | grep -Fq 'load_settings light || return 1'
printf '%s\n' "$status_body" | grep -Fq 'active=invalid'

temporary="$(mktemp -d /tmp/luci-agh-stopped-writeback.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# Both stopped CLI commands load only identities at entry. The actual copy
# still performs a full state check and must fail before any write or unmount.
(
	eval "$checkpoint_body"
	eval "$cleanup_body"
	eval "$copy_body"
	eval "$stopped_body"
	eval "$deactivate_body"
	events="$temporary/cli-events"
	MEMORY_ACTIVE=1
	MEMORY_WORK_DIR="$temporary/cli-memory"
	MEMORY_BACKING_WORK_DIR="$temporary/cli-backing"
	MEMORY_BACKING_DATA_MOUNT="$temporary/cli-alias"
	load_settings() { printf 'load:%s\n' "${1:-full}" >>"$events"; }
	official_running() { return 1; }
	memory_state_load() { printf 'state:%s\n' "${1:-full}" >>"$events"; return 1; }
	memory_quarantine_stopped_conflicts_locked() { return 2; }
	memory_prune_stopped_data_locked() { printf 'unexpected prune\n' >>"$events"; }
	memory_suspend_data_bindings() { printf 'unexpected unmount\n' >>"$events"; }
	for action in memory_checkpoint_locked_command memory_cleanup_locked_command; do
		: >"$events"
		if "$action"; then exit 1; fi
		[ "$(cat "$events")" = "$(printf 'load:light\nstate:full')" ]
	done

	# Even after a successful copy and bind suspension, cleanup must validate
	# the full RAM tree again before deletion. A failure preserves that tree.
	eval "$remove_body"
	MEMORY_STATE_FILE="$temporary/cli-state"
	MEMORY_RUNTIME_DIR="$temporary/cli-runtime"
	mkdir -p "$MEMORY_WORK_DIR/data"
	printf 'keep\n' >"$MEMORY_WORK_DIR/data/value"
	memory_copy_stopped_data_locked() { printf 'copy\n' >>"$events"; }
	memory_suspend_data_bindings() { MEMORY_MOUNTS_SUSPENDED=1; }
	memory_restore_official_persistent_paths() { return 0; }
	memory_active_tree_valid() { printf 'full-tree\n' >>"$events"; return 1; }
	: >"$events"
	if memory_cleanup_locked_command; then exit 1; fi
	[ "$(cat "$events")" = "$(printf 'load:light\ncopy\nfull-tree')" ]
	[ "$(cat "$MEMORY_WORK_DIR/data/value")" = keep ]
)

(
	eval "$prune_body"
	MEMORY_WORK_DIR="$temporary/memory"
	MEMORY_BACKING_DATA_MOUNT="$temporary/persistent"
	MEMORY_BACKING_WORK_DIR="$temporary/backing"
	MEMORY_ACTIVE=1
	ADGUARD_UID=853
	ADGUARD_GID=853
	mkdir -p "$MEMORY_WORK_DIR/data/kept dir" \
		"$MEMORY_BACKING_DATA_MOUNT/kept dir" \
		"$MEMORY_BACKING_DATA_MOUNT/stale dir/nested"
	printf 'new\n' >"$MEMORY_WORK_DIR/data/kept dir/value"
	printf 'new\n' >"$MEMORY_BACKING_DATA_MOUNT/kept dir/value"
	printf 'old\n' >"$MEMORY_BACKING_DATA_MOUNT/stale dir/nested/value"
	stale_newline="$(printf 'stale\nname')"
	printf 'old\n' >"$MEMORY_BACKING_DATA_MOUNT/$stale_newline"

	official_running() { return 1; }
	adguard_uid_process_exists() { return 1; }
	memory_state_load() {
		MEMORY_STATE_PERSISTENT_WORK_DIR="$MEMORY_BACKING_WORK_DIR"
		return 0
	}
	memory_bindings_valid() { return 0; }
	uid853_mounted_tree_is_writable() { return 0; }
	log_error() { :; }
	run_bounded() {
		shift 2
		[ "$1" = /sbin/start-stop-daemon ] || return 1
		shift
		executable=""
		while [ "$#" -gt 0 ]; do
			case "$1" in
				-x) executable="$2"; shift 2 ;;
				--) shift; break ;;
				*) shift ;;
			esac
		done
		[ "$executable" = /usr/bin/find ] || return 1
		"$executable" "$@"
	}

	memory_prune_stopped_data_locked
	[ -f "$MEMORY_BACKING_DATA_MOUNT/kept dir/value" ]
	[ ! -e "$MEMORY_BACKING_DATA_MOUNT/stale dir" ]
	[ ! -e "$MEMORY_BACKING_DATA_MOUNT/$stale_newline" ]
)

(
	eval "$stopped_body"
	events="$temporary/events"
	memory_copy_live_data_locked() { printf 'copy\n' >>"$events"; return 1; }
	memory_quarantine_stopped_conflicts_locked() { printf 'quarantine\n' >>"$events"; return 2; }
	memory_prune_stopped_data_locked() { printf 'prune\n' >>"$events"; }
	memory_durability_barrier() { :; }
	if memory_copy_stopped_data_locked; then
		printf 'failed stopped copy unexpectedly pruned data\n' >&2
		exit 1
	fi
	[ "$(cat "$events")" = "$(printf 'copy\nquarantine')" ]
	: >"$events"
	memory_copy_live_data_locked() { printf 'copy\n' >>"$events"; }
	memory_copy_stopped_data_locked
	[ "$(cat "$events")" = "$(printf 'copy\nprune')" ]
)

# BusyBox cp rejects both file-to-directory and directory-to-file changes.
# The stopped path quarantines those old entries, retries, then removes the
# quarantine together with every other stale persistent entry.
(
	eval "$quarantine_body"
	eval "$prune_body"
	eval "$stopped_body"
	MEMORY_WORK_DIR="$temporary/conflict-memory"
	MEMORY_BACKING_DATA_MOUNT="$temporary/conflict-persistent"
	MEMORY_BACKING_WORK_DIR="$temporary/conflict-backing"
	MEMORY_ACTIVE=1
	ADGUARD_UID=853
	ADGUARD_GID=853
	mkdir -p "$MEMORY_WORK_DIR/data/to-dir" \
		"$MEMORY_BACKING_DATA_MOUNT/to-file" \
		"$MEMORY_BACKING_DATA_MOUNT/stale"
	printf 'source file\n' >"$MEMORY_WORK_DIR/data/to-file"
	printf 'source child\n' >"$MEMORY_WORK_DIR/data/to-dir/child"
	printf 'old child\n' >"$MEMORY_BACKING_DATA_MOUNT/to-file/child"
	printf 'old file\n' >"$MEMORY_BACKING_DATA_MOUNT/to-dir"
	printf 'stale\n' >"$MEMORY_BACKING_DATA_MOUNT/stale/value"

	official_running() { return 1; }
	adguard_uid_process_exists() { return 1; }
	memory_state_load() {
		MEMORY_STATE_PERSISTENT_WORK_DIR="$MEMORY_BACKING_WORK_DIR"
		return 0
	}
	memory_bindings_valid() { return 0; }
	uid853_mounted_tree_is_writable() { return 0; }
	log_error() { :; }
	chown() { :; }
	chmod() { :; }
	run_bounded() {
		shift 2
		if [ "$1" != /sbin/start-stop-daemon ]; then
			"$@"
			return
		fi
		shift
		executable=""
		while [ "$#" -gt 0 ]; do
			case "$1" in
				-x) executable="$2"; shift 2 ;;
				--) shift; break ;;
				*) shift ;;
			esac
		done
		"$executable" "$@"
	}
	memory_copy_live_data_locked() {
		busybox cp -pR "$MEMORY_WORK_DIR/data/." "$MEMORY_BACKING_DATA_MOUNT/" 2>/dev/null
	}
	memory_durability_barrier() { :; }

	memory_copy_stopped_data_locked
	[ -f "$MEMORY_BACKING_DATA_MOUNT/to-file" ]
	[ "$(cat "$MEMORY_BACKING_DATA_MOUNT/to-file")" = 'source file' ]
	[ -d "$MEMORY_BACKING_DATA_MOUNT/to-dir" ]
	[ "$(cat "$MEMORY_BACKING_DATA_MOUNT/to-dir/child")" = 'source child' ]
	[ ! -e "$MEMORY_BACKING_DATA_MOUNT/stale" ]
	[ -z "$(find "$MEMORY_BACKING_DATA_MOUNT" -maxdepth 1 -name '.luci-writeback.*' -print)" ]
)

printf 'ok - stopped RAM write-back prunes only after a successful copy\n'
