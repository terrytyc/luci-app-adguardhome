#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/lib/function-body.sh"
init_file="$script_dir/../root/etc/init.d/AdGuardHome"
temporary="$(mktemp -d /tmp/agh-mount-dependency.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
printf '/dev/root / overlay rw 0 0\n' >"$temporary/mounts"

# Only the host mount table and block executable are adapted. The production
# selection, target boundary, writable mount and device checks execute here.
body="$(function_body "$init_file" check_work_dir_fstab_mount |
	sed -e "s@/proc/mounts@$temporary/mounts@g" -e 's@/sbin/block info@test_block_info@g')"
eval "$body"
log_error() { :; }
config_get() {
	case "$3" in
		target) value="$target_option" ;;
		device) value="$device_option" ;;
		uuid) value="$uuid_option" ;;
		label) value="$label_option" ;;
		*) return 1 ;;
	esac
	export "$1=$value"
}
test_block_info() {
	[ "$1" = /dev/sda1 ] || return 1
	printf '%s\n' '/dev/sda1: UUID="A1-B2" LABEL="dns disk" TYPE="ext4"'
}
WORK_DIR_MOUNT_CHECK_PATH=/mnt/usb/AdGuardHome
target_option=/mnt/usb
device_option=/dev/sda1
uuid_option=""
label_option=""
check() {
	WORK_DIR_MOUNT_CHECK_RC=0
	check_work_dir_fstab_mount disk
	[ "$WORK_DIR_MOUNT_CHECK_RC" = "$1" ]
}
check 1 # No external mount: the root overlay must never satisfy the dependency.
printf '/dev/sda1 /mnt/usb ext4 ro 0 0\n' >>"$temporary/mounts"
check 1
printf '/dev/sdb1 /mnt/usb ext4 rw 0 0\n' >>"$temporary/mounts"
check 1
printf '/dev/sda1 /mnt/usb ext4 rw 0 0\n' >>"$temporary/mounts"
check 0
uuid_option=a1-b2
check 0
uuid_option=wrong
check 1
uuid_option=""
label_option='dns disk'
check 0
label_option=wrong
check 1
WORK_DIR_MOUNT_CHECK_PATH=/mnt/usb-other/AdGuardHome
check 0 # A sibling path is not a child dependency.
WORK_DIR_MOUNT_CHECK_PATH=/etc/AdGuardHome
check 0 # Ordinary persistent directories remain supported.

# Reading fstab in the helper must not replace the caller's settings snapshot.
body="$(function_body "$init_file" validate_work_dir_mount_dependency |
	sed "s@/etc/config/fstab@$temporary/fstab@g")"
eval "$body"
: >"$temporary/fstab"
loaded_package=adguardhome
config_load() { loaded_package="$1"; }
config_foreach() { "$1" disk; }
WORK_DIR_MOUNT_CHECK_PATH=/mnt/usb/AdGuardHome
label_option=""
validate_work_dir_mount_dependency /mnt/usb/AdGuardHome
[ "$loaded_package" = adguardhome ]
printf '/dev/root / overlay rw 0 0\n' >"$temporary/mounts"
if validate_work_dir_mount_dependency /mnt/usb/AdGuardHome; then exit 1; fi

# Fallback is permitted only after unpublished state and both mount names are
# gone. A published generation is always retained even if preparation failed.
eval "$(function_body "$init_file" memory_prepare_or_fallback_locked)"
service_enabled=1
memory_requested=1
MEMORY_ACTIVE=0
MEMORY_BACKING_WORK_DIR=""
persistent_work_dir="$temporary/persistent"
persistent_config_file="$persistent_work_dir/AdGuardHome.yaml"
MEMORY_RUNTIME_DIR="$temporary/ram"
MEMORY_STATE_FILE="$MEMORY_RUNTIME_DIR/state"
validate_work_dir_mount_dependency() { return 0; }
memory_prepare_runtime_locked() { return 1; }
memory_discard_incomplete_runtime_locked() { return "$cleanup_failure"; }
tree_is_mount_free() { [ "$mount_leftover" = 0 ]; }
cleanup_failure=0
mount_leftover=0
memory_prepare_or_fallback_locked
[ "$work_dir" = "$persistent_work_dir" ]
cleanup_failure=1
if memory_prepare_or_fallback_locked; then exit 1; fi
cleanup_failure=0
mount_leftover=1
if memory_prepare_or_fallback_locked; then exit 1; fi
mount_leftover=0
mkdir "$MEMORY_RUNTIME_DIR"
if memory_prepare_or_fallback_locked; then exit 1; fi
printf 'published\n' >"$MEMORY_STATE_FILE"
if memory_prepare_or_fallback_locked; then exit 1; fi
[ "$(cat "$MEMORY_STATE_FILE")" = published ]

# Mount preflight must reject YAML/TLS jobs before their first runtime or
# permission change. Check the actual YAML parent even during an A-to-B move.
(
	for name in yaml_update_locked tls_refresh_locked install_config_candidate \
		sync_yaml_managed_fields_checked restore_yaml_backup rollback_yaml_update \
		attempt_yaml_rollback; do
		eval "$(function_body "$init_file" "$name")"
	done
	actual="$temporary/old-workdir"
	mkdir "$actual"
	config_file="$actual/AdGuardHome.yaml"
	printf 'unchanged YAML\n' >"$config_file"
	backup="$temporary/backup.yaml"
	printf 'retained backup\n' >"$backup"
	events="$temporary/preflight-events"
	: >"$events"
	load_settings() { work_dir="$temporary/new-workdir"; }
	validate_work_dir_mount_dependency() {
		[ "$1" = "$actual" ] || exit 99
		printf 'mount\n' >>"$events"
		return 1
	}
	validate_yaml_stage() { printf 'unexpected-stage\n' >>"$events"; }
	load_active_tls_access() { printf 'unexpected-permissions\n' >>"$events"; }
	rc=0
	yaml_update_locked hash candidate stage 9 || rc=$?
	[ "$rc" = 2 ]
	if tls_refresh_locked; then exit 1; fi
	if install_config_candidate "$backup" '' '' ''; then exit 1; fi
	previous_work_dir="$actual"
	if sync_yaml_managed_fields_checked; then exit 1; fi
	[ "$(cat "$events")" = "$(printf 'mount\nmount\nmount\nmount')" ]
	[ "$(cat "$config_file")" = 'unchanged YAML' ]

	# A mount disappearing during rollback cannot publish the previous YAML
	# onto overlay and cannot cause cleanup to delete the sole backup.
	clear_recorded_integration_locked() { :; }
	official_running() { return 1; }
	YAML_BACKUP_CLEANUP="$backup"
	# rc.common permits optional arguments omitted by the real restore helper.
	set +u
	if attempt_yaml_rollback "$backup" 1; then exit 1; fi
	[ -z "$YAML_BACKUP_CLEANUP" ]
	[ "$(cat "$backup")" = 'retained backup' ]
	[ "$(cat "$config_file")" = 'unchanged YAML' ]
)

printf 'ok - workdir mount dependencies, clean RAM fallback and YAML write preflight\n'
