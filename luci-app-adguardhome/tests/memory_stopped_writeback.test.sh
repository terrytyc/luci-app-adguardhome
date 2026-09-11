#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
load_body="$(function_body "$init_file" load_settings)"
cleanup_body="$(function_body "$init_file" memory_cleanup_locked_command)"
status_body="$(function_body "$init_file" memory_status)"
stopped_body="$(function_body "$init_file" memory_copy_stopped_data_locked)"
quarantine_body="$(function_body "$init_file" memory_quarantine_stopped_conflicts_locked)"
prune_body="$(function_body "$init_file" memory_prune_stopped_data_locked)"

printf '%s\n' "$load_body" | grep -Fq 'Unsafe or incomplete AdGuard Home memory namespace'
printf '%s\n' "$load_body" | grep -Fq 'return 1'
if printf '%s\n' "$load_body" | grep -Fq 'Disk mode remains available'; then
	exit 1
fi
printf '%s\n' "$cleanup_body" | grep -Fq 'load_settings || return 1'
printf '%s\n' "$status_body" | grep -Fq 'active=invalid'

temporary="$(mktemp -d /tmp/luci-agh-stopped-writeback.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

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

	memory_copy_stopped_data_locked
	[ -f "$MEMORY_BACKING_DATA_MOUNT/to-file" ]
	[ "$(cat "$MEMORY_BACKING_DATA_MOUNT/to-file")" = 'source file' ]
	[ -d "$MEMORY_BACKING_DATA_MOUNT/to-dir" ]
	[ "$(cat "$MEMORY_BACKING_DATA_MOUNT/to-dir/child")" = 'source child' ]
	[ ! -e "$MEMORY_BACKING_DATA_MOUNT/stale" ]
	[ -z "$(find "$MEMORY_BACKING_DATA_MOUNT" -maxdepth 1 -name '.luci-writeback.*' -print)" ]
)

printf 'ok - stopped RAM write-back prunes only after a successful copy\n'
