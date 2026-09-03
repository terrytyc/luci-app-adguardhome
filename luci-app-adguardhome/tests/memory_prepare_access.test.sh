#!/bin/sh
set -eu

# Exercise real uid permissions, cp and bind mounts without changing the host's
# mount namespace. These are test-host tools, never runtime dependencies.
if [ "${ADGUARDHOME_TEST_PRIVATE_MOUNTS:-0}" != 1 ]; then
	if [ "$(id -u)" != 0 ] || ! command -v unshare >/dev/null 2>&1 ||
	   [ ! -x /usr/bin/setpriv ] ||
	   ! command -v busybox >/dev/null 2>&1 || ! unshare -m -- true 2>/dev/null; then
		printf 'skip - real RAM preparation needs root, unshare, setpriv and BusyBox\n'
		exit 0
	fi
	exec unshare -m -- env ADGUARDHOME_TEST_PRIVATE_MOUNTS=1 busybox ash "$0" "$@"
fi
/bin/mount --make-rprivate /

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
test_tmp="$(mktemp -d /tmp/agh-memory-access.XXXXXX)"
cleanup() {
	local target
	for target in "$test_tmp"/*/AdGuardHome*/data "$test_tmp"/*/ram/backing-data; do
		path_is_exact_mountpoint "$target" && /bin/umount "$target" || true
	done
	# Never recurse through a mount if an assertion or unmount failed.
	tree_is_mount_free "$test_tmp" && rm -rf "$test_tmp"
}
trap cleanup EXIT HUP INT TERM
awk -v helper_dir="$script_dir/../scripts" \
	-f "$script_dir/../scripts/expand-helpers.awk" \
	"$script_dir/../root/etc/init.d/AdGuardHome" >"$test_tmp/init"
# shellcheck disable=SC1090
. "$test_tmp/init"
chmod 0755 "$test_tmp"

# The host may not have an adguardhome passwd entry or ash as /bin/sh. Preserve
# the production command and numeric credentials while adapting just that
# launcher; all scans, copies, chmods and mounts below execute for real.
run_bounded() {
	local executable
	shift 2
	if [ "$1" = /sbin/start-stop-daemon ]; then
		shift
		while [ "$1" != -x ]; do shift; done
		executable="$2"
		shift 3
		[ "$executable" != /bin/cp ] || [ "${TEST_FAIL_COPY:-0}" != 1 ] || return 1
		if [ "$executable" = /bin/sh ]; then
			set -- busybox ash "$@"
		else
			set -- "$executable" "$@"
		fi
		/usr/bin/setpriv --reuid="$ADGUARD_UID" --regid="$ADGUARD_GID" --clear-groups "$@"
	elif [ "$1" = /bin/sh ]; then
		shift
		busybox ash "$@"
	else
		"$@"
	fi
}
validate_managed_work_dir_namespace() {
	case "$1" in "$test_tmp"/*/AdGuardHome|"$test_tmp"/*/AdGuardHome-*) return 0 ;; esac
	return 1
}
official_running() { return 1; }
adguard_uid_process_exists() { return 1; }
memory_capacity_available() { return 0; }
memory_durability_barrier() { return 0; }
clear_recorded_integration_locked() { return 0; }
memory_restore_official_persistent_paths() { return 0; }
sync_official_uci() { return 0; }
log_error() { :; }

set_fixture() {
	local scenario="$1"
	mkdir -m 0755 "$test_tmp/$scenario"
	persistent_work_dir="$test_tmp/$scenario/AdGuardHome"
	persistent_config_file="$persistent_work_dir/AdGuardHome.yaml"
	mkdir -m 0700 "$persistent_work_dir"
	printf 'persistent YAML\n' >"$persistent_config_file"
	MEMORY_RUNTIME_DIR="$test_tmp/$scenario/ram"
	MEMORY_WORK_DIR="$MEMORY_RUNTIME_DIR/work"
	MEMORY_DATA_DIR="$MEMORY_WORK_DIR/data"
	MEMORY_BACKING_DATA_MOUNT="$MEMORY_RUNTIME_DIR/backing-data"
	MEMORY_STATE_FILE="$MEMORY_RUNTIME_DIR/state"
	MEMORY_ACTIVE=0
	MEMORY_BACKING_WORK_DIR=""
	MEMORY_STATE_VALIDATED=0
	MEMORY_MOUNTS_SUSPENDED=0
	memory_requested=1
	TEST_FAIL_COPY=0
}
assert_private_owner() {
	local metadata mode links owner group remainder
	metadata="$(LC_ALL=C ls -ldn "$1")"
	read -r mode links owner group remainder <<-EOF
	$metadata
	EOF
	[ "$mode:$owner:$group" = "drwx------:$2:$3" ]
}
seed_data() {
	mkdir -m 0700 "$persistent_work_dir/data"
	printf 'saved data\n' >"$persistent_work_dir/data/saved"
	chown -R "$ADGUARD_UID:$ADGUARD_GID" "$persistent_work_dir/data"
}
assert_prepared() {
	[ "$MEMORY_ACTIVE:$MEMORY_BACKING_WORK_DIR" = "1:$persistent_work_dir" ]
	[ "$config_file" = "$persistent_config_file" ]
	[ ! -e "$MEMORY_WORK_DIR/AdGuardHome.yaml" ]
	[ "$(cat "$persistent_config_file")" = 'persistent YAML' ]
	memory_bindings_valid "$persistent_work_dir"
	assert_private_owner "$persistent_work_dir" "$1" "$2"
}
remove_prepared() {
	# Simulate only the official init's normal parent ownership handoff. The
	# subsequent stopped direct writeback and bind cleanup are production code.
	chown "$ADGUARD_UID:$ADGUARD_GID" "$persistent_work_dir"
	memory_deactivate_locked 1
	[ "$MEMORY_ACTIVE" = 0 ] && [ ! -e "$MEMORY_RUNTIME_DIR" ]
}

for scenario in empty existing service-owned; do
	set_fixture "$scenario"
	[ "$scenario" = empty ] || seed_data
	owner=0
	group=0
	if [ "$scenario" = service-owned ]; then
		owner="$ADGUARD_UID"
		group="$ADGUARD_GID"
		chown "$owner:$group" "$persistent_work_dir"
	fi
	memory_prepare_runtime_locked
	assert_prepared "$owner" "$group"
	[ "$scenario" = empty ] || [ "$(cat "$MEMORY_DATA_DIR/saved")" = 'saved data' ]
	remove_prepared
done

# Failed copies restore the original parent access and remove only unpublished
# RAM preparation. They leave the persistent data and YAML intact.
set_fixture copy-failure
seed_data
TEST_FAIL_COPY=1
if memory_prepare_runtime_locked; then
	printf 'a failed copy was published as active RAM\n' >&2
	exit 1
fi
assert_private_owner "$persistent_work_dir" 0 0
[ "$MEMORY_ACTIVE" = 0 ] && [ ! -e "$MEMORY_RUNTIME_DIR" ]
[ "$(cat "$persistent_work_dir/data/saved")" = 'saved data' ]

# A foreign runtime parent must not become cleanup-eligible just because the
# permission handoff now covers the complete preparation.
set_fixture foreign-runtime
mkdir -m 0755 "$MEMORY_RUNTIME_DIR"
printf 'keep\n' >"$MEMORY_RUNTIME_DIR/foreign"
if memory_prepare_runtime_locked; then exit 1; fi
assert_private_owner "$persistent_work_dir" 0 0
[ "$(cat "$MEMORY_RUNTIME_DIR/foreign")" = keep ]

# Move an active generation to a new root-private workdir: preserve/write back
# the old RAM data, detach it, then prepare the independent new data tree.
set_fixture transition
seed_data
memory_prepare_runtime_locked
old_work_dir="$persistent_work_dir"
chown "$ADGUARD_UID:$ADGUARD_GID" "$old_work_dir"
/usr/bin/setpriv --reuid="$ADGUARD_UID" --regid="$ADGUARD_GID" --clear-groups \
	busybox ash -c 'printf "RAM update\n" >"$1/saved"' sh "$MEMORY_DATA_DIR"
persistent_work_dir="$test_tmp/transition/AdGuardHome-new"
persistent_config_file="$persistent_work_dir/AdGuardHome.yaml"
mkdir -m 0700 "$persistent_work_dir"
printf 'persistent YAML\n' >"$persistent_config_file"
memory_reconcile_requested_storage_locked
[ "$(cat "$old_work_dir/data/saved")" = 'RAM update' ]
! path_is_exact_mountpoint "$old_work_dir/data"
memory_prepare_runtime_locked
assert_prepared 0 0
[ ! -e "$MEMORY_DATA_DIR/saved" ]
remove_prepared

# Prefer the committed official anchor. Only an old generation not selected
# by that UCI path needs the state fallback, which must remain available.
uci() {
	[ "$1:$2:$3" = "-q:get:adguardhome.config.work_dir" ] || return 1
	printf '%s\n' "$persistent_work_dir"
}
STATE_FALLBACKS=0
memory_state_binds_persistent() {
	STATE_FALLBACKS=$((STATE_FALLBACKS + 1))
	[ "$1" = "$old_work_dir" ]
}
validate_managed_work_dir "$persistent_work_dir"
[ "$STATE_FALLBACKS" = 0 ]
validate_managed_work_dir "$old_work_dir"
[ "$STATE_FALLBACKS" = 1 ]
mkdir -m 0700 "$test_tmp/transition/AdGuardHome-unowned"
if validate_managed_work_dir "$test_tmp/transition/AdGuardHome-unowned"; then exit 1; fi
[ "$STATE_FALLBACKS" = 2 ]

printf 'ok - real RAM preparation access, failure cleanup and workdir transition\n'
