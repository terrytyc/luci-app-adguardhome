#!/bin/sh
# rc.common does not enable nounset; real YAML helpers accept omitted arguments.
set -e

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
	"$script_dir/../root/etc/init.d/AdGuardHome" |
	sed 's@/bin/mount -o bind@test_mount -o bind@g' >"$test_tmp/init"
# shellcheck disable=SC1090
. "$test_tmp/init"
chmod 0755 "$test_tmp"

# Only the bind syscall boundary is intercepted for failure injection; normal
# calls still create real mounts inside this test's private namespace.
test_mount() {
	printf '%s\n' "$4" >>"$test_tmp/mounts"
	[ "${TEST_FAIL_MOUNT:-}" != "$4" ] || return 1
	/bin/mount "$@"
}

# The host may not have an adguardhome passwd entry or ash as /bin/sh. Preserve
# the production command and numeric credentials while adapting just that
# launcher; all scans, copies, chmods and mounts below execute for real.
run_bounded() {
	local executable operation=""
	shift 2
	if [ "$1" = /sbin/start-stop-daemon ]; then
		shift
		while [ "$1" != -x ]; do
			[ "$1" != -n ] || operation="$2"
			shift
		done
		executable="$2"
		shift 3
		if [ "$operation" = AGHDataScan ]; then
			printf '%s\n' "$4" >>"$test_tmp/scans"
			[ "${TEST_FAIL_SCAN:-0}" != 1 ] || [ "$4" != "$MEMORY_DATA_DIR" ] || return 1
		fi
		[ "$executable" != /bin/cp ] || [ "${TEST_FAIL_COPY:-0}" != 1 ] || return 1
		[ "$operation" != AGHDataPrune ] || [ "${TEST_FAIL_PRUNE:-0}" != 1 ] || return 1
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
sync_official_uci() { load_active_tls_access; }
log_error() { :; }

set_fixture() {
	local scenario="$1"
	mkdir -m 0755 "$test_tmp/$scenario"
	persistent_work_dir="$test_tmp/$scenario/AdGuardHome"
	persistent_config_file="$persistent_work_dir/AdGuardHome.yaml"
	mkdir -m 0700 "$persistent_work_dir"
	printf 'dns: { port: 53335 }\n' >"$persistent_config_file"
	chmod 0600 "$persistent_config_file"
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
	TEST_FAIL_PRUNE=0
	TEST_FAIL_SCAN=0
	TEST_FAIL_MOUNT=""
	: >"$test_tmp/scans"
	: >"$test_tmp/mounts"
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
	[ "$(cat "$persistent_config_file")" = 'dns: { port: 53335 }' ]
	memory_bindings_valid "$persistent_work_dir"
	assert_private_owner "$persistent_work_dir" "$1" "$2"
}
remove_prepared() {
	# Simulate only the official init's normal directory/YAML ownership handoff. The
	# subsequent stopped direct writeback and bind cleanup are production code.
	chown "$ADGUARD_UID:$ADGUARD_GID" "$persistent_work_dir" "$persistent_config_file"
	memory_deactivate_locked
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
	expected_scans=3
	[ "$scenario" != empty ] || expected_scans=2
	[ "$(wc -l <"$test_tmp/scans")" -eq "$expected_scans" ]
	[ "$(grep -Fxc "$MEMORY_DATA_DIR" "$test_tmp/scans")" = 1 ]
	[ "$scenario" = empty ] || [ "$(cat "$MEMORY_DATA_DIR/saved")" = 'saved data' ]
	remove_prepared
done

# The complete stopped copy/prune chain scans the unchanged RAM source once.
# Mount/state checks still bracket deletion, and failed writes retain active RAM.
(
	. "$script_dir/lib/function-body.sh"
	for name in memory_state_load memory_bindings_valid memory_backing_identity; do
		eval "$(function_body "$test_tmp/init" "$name" | sed "1s/^$name/original_$name/")"
	done
	memory_state_load() {
		printf '%s\n' "${1:-full}" >>"$test_tmp/state-calls"
		original_memory_state_load "$@"
	}
	memory_bindings_valid() {
		printf '%s\n' "$1" >>"$test_tmp/binding-calls"
		original_memory_bindings_valid "$@"
	}
	memory_backing_identity() {
		printf '%s\n' "$1" >>"$test_tmp/identity-calls"
		original_memory_backing_identity "$@"
	}
	set_fixture stopped-writeback
	seed_data
	memory_prepare_runtime_locked
	chown "$ADGUARD_UID:$ADGUARD_GID" "$persistent_work_dir"
	printf 'RAM update\n' >"$MEMORY_DATA_DIR/saved"
	printf 'stale data\n' >"$MEMORY_BACKING_DATA_MOUNT/stale"
	chown "$ADGUARD_UID:$ADGUARD_GID" "$MEMORY_BACKING_DATA_MOUNT/stale"
	: >"$test_tmp/scans"
	: >"$test_tmp/state-calls"
	: >"$test_tmp/binding-calls"
	: >"$test_tmp/identity-calls"
	memory_copy_stopped_data_locked
	[ "$(cat "$MEMORY_BACKING_DATA_MOUNT/saved")" = 'RAM update' ]
	[ ! -e "$MEMORY_BACKING_DATA_MOUNT/stale" ]
	[ "$(wc -l <"$test_tmp/scans")" = 1 ]
	[ "$(cat "$test_tmp/state-calls")" = "$(printf 'full\nlight\nlight')" ]
	[ "$(wc -l <"$test_tmp/binding-calls")" = 5 ]
	[ "$(wc -l <"$test_tmp/identity-calls")" = 14 ]
	remove_prepared

	for failure in copy prune; do
		set_fixture "writeback-$failure-failure"
		seed_data
		memory_prepare_runtime_locked
		chown "$ADGUARD_UID:$ADGUARD_GID" "$persistent_work_dir"
		printf 'RAM update\n' >"$MEMORY_DATA_DIR/saved"
		printf 'keep on failure\n' >"$MEMORY_BACKING_DATA_MOUNT/stale"
		chown "$ADGUARD_UID:$ADGUARD_GID" "$MEMORY_BACKING_DATA_MOUNT/stale"
		case "$failure" in
			copy) TEST_FAIL_COPY=1 ;;
			prune) TEST_FAIL_PRUNE=1 ;;
		esac
		if memory_deactivate_locked; then
			printf 'RAM was removed after a failed %s\n' "$failure" >&2
			exit 1
		fi
		[ "$MEMORY_ACTIVE" = 1 ] && [ -f "$MEMORY_STATE_FILE" ]
		[ "$persistent_work_dir/data" -ef "$MEMORY_DATA_DIR" ]
		[ "$(cat "$MEMORY_DATA_DIR/saved")" = 'RAM update' ]
		[ "$(cat "$MEMORY_BACKING_DATA_MOUNT/stale")" = 'keep on failure' ]
		TEST_FAIL_COPY=0 TEST_FAIL_PRUNE=0
		remove_prepared
		[ "$(cat "$persistent_work_dir/data/saved")" = 'RAM update' ]
	done
)

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

# The final activation scan remains mandatory. Copy/scan/mount failures must
# leave the source intact, restore its parent permissions and remove partial RAM.
for failure in scan backing-mount overlay-mount; do
	set_fixture "$failure-failure"
	seed_data
	case "$failure" in
		scan) TEST_FAIL_SCAN=1 ;;
		backing-mount) TEST_FAIL_MOUNT="$MEMORY_BACKING_DATA_MOUNT" ;;
		overlay-mount) TEST_FAIL_MOUNT="$persistent_work_dir/data" ;;
	esac
	if memory_prepare_runtime_locked; then
		printf 'RAM preparation accepted a failed %s\n' "$failure" >&2
		exit 1
	fi
	assert_private_owner "$persistent_work_dir" 0 0
	[ "$MEMORY_ACTIVE" = 0 ] && [ ! -e "$MEMORY_RUNTIME_DIR" ]
	[ "$(cat "$persistent_work_dir/data/saved")" = 'saved data' ]
	! path_is_exact_mountpoint "$persistent_work_dir/data" || exit 1
	[ "$failure" != scan ] || [ ! -s "$test_tmp/mounts" ]
done

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
printf 'dns: { port: 53335 }\n' >"$persistent_config_file"
chmod 0600 "$persistent_config_file"
chown "$ADGUARD_UID:$ADGUARD_GID" "$persistent_config_file"
memory_reconcile_requested_storage_locked
# Preparing the new YAML must precede the real TLS snapshot during deactivation
# without rewriting restored metadata.
[ "$(stat -c '%a:%u:%g' "$persistent_config_file")" = '600:853:853' ]
[ "$(cat "$old_work_dir/data/saved")" = 'RAM update' ]
! path_is_exact_mountpoint "$old_work_dir/data" || exit 1
memory_prepare_runtime_locked
assert_prepared 0 0
[ ! -e "$MEMORY_DATA_DIR/saved" ]
remove_prepared

# A safe persistent directory does not need a prior UCI or RAM-state anchor.
validate_managed_work_dir_namespace "$persistent_work_dir"
validate_managed_work_dir_namespace "$old_work_dir"
mkdir -m 0700 "$test_tmp/transition/AdGuardHome-unowned"
validate_managed_work_dir_namespace "$test_tmp/transition/AdGuardHome-unowned"

printf 'ok - real RAM preparation access, failure cleanup and workdir transition\n'
