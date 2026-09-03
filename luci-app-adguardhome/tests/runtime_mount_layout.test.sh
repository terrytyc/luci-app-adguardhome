#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in memory_binding_mounts_valid memory_bindings_valid \
	path_is_exact_mountpoint tree_has_no_nested_mounts; do
	eval "$(function_body "$init_file" "$name")"
done

test_backing="${test_tmp}/AdGuardHome"
test_target="${test_backing}/data"
test_alias="${test_tmp}/backing-data"
mount_fixture="${test_tmp}/mountinfo"
calls="${test_tmp}/calls"
mkdir -p "$test_target" "$test_alias" "${test_tmp}/other-data"
awk() {
	case "$#" in
		6)
			[ "$6" = /proc/self/mountinfo ] || return 1
			printf 'awk\n' >>"$calls"
			command awk "$1" "$2" "$3" "$4" "$5" "$mount_fixture"
			;;
		4)
			[ "$4" = /proc/self/mountinfo ] || return 1
			printf 'awk\n' >>"$calls"
			command awk "$1" "$2" "$3" "$mount_fixture"
			;;
		*) return 1 ;;
	esac
}
mount_record() {
	printf '%s 1 8:1 / %s rw - ext4 /dev/fixture rw\n' "$1" "$2"
}
valid_mounts() {
	mount_record 2 "$test_alias" >"$mount_fixture"
	mount_record 3 "$test_target" >>"$mount_fixture"
}
legacy_binding_mounts_valid() {
	path_is_exact_mountpoint "$1" && path_is_exact_mountpoint "$2" &&
		tree_has_no_nested_mounts "$1" && tree_has_no_nested_mounts "$2"
}
expect_layout() {
	local expected="$1" actual=0 old=0
	: >"$calls"
	memory_binding_mounts_valid "$test_alias" "$test_target" || actual=$?
	[ "$actual" = "$expected" ]
	[ "$(grep -c '^awk$' "$calls")" = 1 ]
	: >"$calls"
	legacy_binding_mounts_valid "$test_alias" "$test_target" || old=$?
	[ "$old" = "$actual" ]
	if [ "$expected" = 0 ]; then
		[ "$(grep -c '^awk$' "$calls")" = 4 ]
	fi
}
valid_mounts
expect_layout 0
# Similar prefixes and escaped characters on unrelated mounts are not children.
mount_record 4 "${test_alias}-sibling" >>"$mount_fixture"
mount_record 5 "${test_target}-sibling" >>"$mount_fixture"
mount_record 6 '/unrelated\040directory' >>"$mount_fixture"
expect_layout 0
for root in "$test_alias" "$test_target"; do
	valid_mounts
	mount_record 4 "$root" >>"$mount_fixture"
	expect_layout 1
	valid_mounts
	mount_record 4 "${root}/child" >>"$mount_fixture"
	expect_layout 1
	valid_mounts
	mount_record 4 "${root}/escaped\040child" >>"$mount_fixture"
	expect_layout 1
done
mount_record 2 "$test_alias" >"$mount_fixture"
expect_layout 1
mount_record 3 "$test_target" >"$mount_fixture"
expect_layout 1
: >"$mount_fixture"
expect_layout 1
if memory_binding_mounts_valid relative "$test_target" ||
   memory_binding_mounts_valid "$test_alias" relative; then
	printf 'mount layout accepted a relative path\n' >&2
	exit 1
fi

# Exercise the real binding validator around the combined mount predicate.
# Only procfs and the independent device/inode helper are fixtures; the actual
# directory, symlink and -ef checks still run.
MEMORY_BACKING_DATA_MOUNT="$test_alias"
MEMORY_DATA_DIR="$test_target"
MEMORY_STATE_VALIDATED=1
MEMORY_STATE_PERSISTENT_DATA_DEVICE=11
MEMORY_STATE_PERSISTENT_DATA_INODE=21
MEMORY_STATE_MEMORY_DATA_DEVICE=12
MEMORY_STATE_MEMORY_DATA_INODE=22
IDENTITY_OK=1
validate_managed_work_dir_namespace() { [ "$1" = "$test_backing" ]; }
memory_binding_identities_match() {
	printf 'identity\n' >>"$calls"
	[ "$*" = "$test_backing 11 21 12 22" ] && [ "$IDENTITY_OK" = 1 ]
}
valid_mounts
: >"$calls"
memory_bindings_valid "$test_backing"
[ "$(cat "$calls")" = "$(printf 'awk\nidentity')" ]
# A new mount introduced between operation-boundary calls must be seen anew.
mount_record 4 "${test_target}/late-mount" >>"$mount_fixture"
if memory_bindings_valid "$test_backing"; then
	printf 'binding validation reused a stale mount layout\n' >&2
	exit 1
fi
[ "$(grep -c '^awk$' "$calls")" = 2 ]
[ "$(grep -c '^identity$' "$calls")" = 1 ]
valid_mounts
IDENTITY_OK=0
if memory_bindings_valid "$test_backing"; then
	printf 'combined mount check bypassed device/inode validation\n' >&2
	exit 1
fi
IDENTITY_OK=1
MEMORY_DATA_DIR="${test_tmp}/other-data"
if memory_bindings_valid "$test_backing"; then
	printf 'combined mount check bypassed the live data -ef guard\n' >&2
	exit 1
fi
MEMORY_DATA_DIR="$test_target"
MEMORY_BACKING_DATA_MOUNT="$test_target"
if memory_bindings_valid "$test_backing"; then
	printf 'binding validator accepted its RAM source as persistent backing\n' >&2
	exit 1
fi
ln -s "$test_alias" "${test_tmp}/alias-link"
MEMORY_BACKING_DATA_MOUNT="${test_tmp}/alias-link"
if memory_bindings_valid "$test_backing"; then
	printf 'binding validator accepted a symlink alias\n' >&2
	exit 1
fi

printf 'ok - one-pass dual mount layout, fresh boundaries and unchanged identity guards\n'
