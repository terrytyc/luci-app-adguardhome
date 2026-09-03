#!/bin/sh

if ! (eval 'exec 189<&0 && exec 189<&-') 2>/dev/null; then
	exec busybox ash "$0" "$@"
fi
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in memory_backing_identity run_locked open_integration_lock_descriptor; do
	eval "$(function_body "$init_file" "$name")"
done

# Keep the real high-FD boundary and test one actual procfs lookup before
# substituting deterministic fdinfo/mountinfo content for parser rejection tests.
tree="${test_tmp}/tree"
command mkdir "$tree"
memory_backing_identity "$tree"
[ "$MEMORY_IDENTITY_DEVICE $MEMORY_IDENTITY_INODE" = "$(stat -Lc '%d %i' "$tree")" ]
exec 188<"$tree"
memory_backing_identity /proc/self/fd/188
[ "$MEMORY_IDENTITY_DEVICE $MEMORY_IDENTITY_INODE" = "$(stat -Lc '%d %i' "$tree")" ]
exec 188<&-
exec 189<"$tree"
if memory_backing_identity "$tree"; then
	printf 'identity reader clobbered an inherited descriptor\n' >&2
	exit 1
fi
exec 189<&-
ln -s "$tree" "${test_tmp}/symlink"
if memory_backing_identity "${test_tmp}/symlink"; then
	printf 'identity reader accepted a symlink\n' >&2
	exit 1
fi
printf 'not a directory\n' >"${test_tmp}/file"
if memory_backing_identity "${test_tmp}/file"; then
	printf 'identity reader accepted a regular file\n' >&2
	exit 1
fi

fd_fixture="${test_tmp}/fdinfo"
mount_fixture="${test_tmp}/mountinfo"
calls="${test_tmp}/calls"
: >"$calls"
awk() {
	if [ "$#" = 3 ] && [ "$2" = /proc/self/fdinfo/189 ] &&
	   [ "$3" = /proc/self/mountinfo ]; then
		printf 'awk\n' >>"$calls"
		command awk "$1" "$fd_fixture" "$mount_fixture"
	else
		command awk "$@"
	fi
}
valid_fixtures() {
	printf 'pos:\t0\nflags:\t0100000\nmnt_id:\t42\nino:\t456\n' >"$fd_fixture"
	printf '42 1 8:1 / /fixture rw - ext4 /dev/fixture rw\n' >"$mount_fixture"
}
expect_identity() {
	local expected="$1" before
	before="$(wc -l <"$calls")"
	memory_backing_identity "$tree"
	[ "$MEMORY_IDENTITY_DEVICE:$MEMORY_IDENTITY_INODE" = "$expected" ]
	[ "$(wc -l <"$calls")" -eq "$((before + 1))" ]
}
reject_identity() {
	local reason="$1" before
	before="$(wc -l <"$calls")"
	if memory_backing_identity "$tree"; then
		printf 'invalid identity fixture accepted: %s\n' "$reason" >&2
		exit 1
	fi
	[ "$(wc -l <"$calls")" -eq "$((before + 1))" ]
}
valid_fixtures
expect_identity 2049:456
printf '42 1 4096:256 / /fixture rw - ext4 /dev/fixture rw\n' >"$mount_fixture"
expect_identity 17592187092992:456

for record in \
	'mnt_id: 42\nino: 456\nmnt_id: 42\n' \
	'mnt_id: 42\nino: 456\nino: 456\n' \
	'mnt_id: 42\n' \
	'ino: 456\n' \
	'mnt_id: invalid\nino: 456\n' \
	'mnt_id: 42\nino: invalid\n' \
	''; do
	valid_fixtures
	printf '%b' "$record" >"$fd_fixture"
	reject_identity fdinfo
done
valid_fixtures
printf '43 1 8:1 / /fixture rw - ext4 /dev/fixture rw\n' >"$mount_fixture"
reject_identity missing-mount
valid_fixtures
printf '42 1 8:1 / /duplicate rw - ext4 /dev/fixture rw\n' >>"$mount_fixture"
reject_identity duplicate-mount
for device in 8 invalid 8:invalid invalid:1 8::1 :1 8:; do
	valid_fixtures
	printf '42 1 %s / /fixture rw - ext4 /dev/fixture rw\n' "$device" >"$mount_fixture"
	reject_identity malformed-device
done
valid_fixtures
: >"$mount_fixture"
reject_identity empty-mountinfo

# Existing lock directories use no mkdir process.  Missing directories still
# get created, while creation/open failures must prevent the protected action.
: >"$calls"
command mkdir "${test_tmp}/existing-lock"
mkdir() {
	printf 'mkdir\n' >>"$calls"
	command mkdir "$@"
}
locked_action() { printf 'action\n' >>"$calls"; }
INTEGRATION_LOCK="${test_tmp}/existing-lock/integration.lock"
run_locked locked_action
[ "$(cat "$calls")" = action ]
INTEGRATION_LOCK="${test_tmp}/new-lock/integration.lock"
run_locked locked_action
run_locked locked_action
[ "$(grep -c '^mkdir$' "$calls")" = 1 ]
[ "$(grep -c '^action$' "$calls")" = 3 ]
INTEGRATION_LOCK="${test_tmp}/file/integration.lock"
if run_locked locked_action >/dev/null 2>&1; then
	printf 'failed lock-directory creation still ran the action\n' >&2
	exit 1
fi
[ "$(grep -c '^action$' "$calls")" = 3 ]
command mkdir "${test_tmp}/lock-is-directory"
INTEGRATION_LOCK="${test_tmp}/lock-is-directory"
if run_locked locked_action >/dev/null 2>&1; then
	printf 'failed lock descriptor open still ran the action\n' >&2
	exit 1
fi
[ "$(grep -c '^action$' "$calls")" = 3 ]

printf 'ok - one-pass mount identity parsing and existing lock-directory fast path\n'
