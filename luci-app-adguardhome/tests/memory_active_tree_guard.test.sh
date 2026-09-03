#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

[ -f "$init_file" ] || {
	printf 'init script not found: %s\n' "$init_file" >&2
	exit 1
}

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
tree_body="$(function_body "$init_file" memory_active_tree_valid)"
layout_body="$(function_body "$init_file" memory_active_layout_valid)"
state_body="$(function_body "$init_file" memory_state_load)"
binds_body="$(function_body "$init_file" memory_state_binds_persistent)"
load_body="$(function_body "$init_file" load_settings)"
copy_body="$(function_body "$init_file" memory_copy_live_data_locked)"

# The single-quoted pattern intentionally matches the literal production
# variable reference.
# shellcheck disable=SC2016
[ "$(printf '%s\n' "$tree_body" |
	grep -Fc 'uid853_tree_is_plain "$MEMORY_WORK_DIR"')" -eq 1 ] || {
	printf 'active RAM validation is not guarded by the plain-tree mount scan\n' >&2
	exit 1
}

printf '%s\n' "$tree_body" | grep -Fq 'memory_active_layout_valid' || exit 1
printf '%s\n' "$layout_body" | grep -Fq '[ "$found" = 1 ] || return 1' || exit 1
printf '%s\n' "$layout_body" | grep -Fq 'tree_is_mount_free "$MEMORY_WORK_DIR"' || exit 1
printf '%s\n' "$layout_body" | grep -Fq 'memory_bindings_valid "$backing"' || exit 1
if printf '%s\n' "$layout_body" | grep -Eq 'uid853_tree|find '; then
	printf 'light RAM layout validation still traverses the data tree\n' >&2
	exit 1
fi

# Monitor/status and live-copy setup are lightweight.  The actual copy retains
# a full default state load, then scans the persistent destination once.
for name in reconcile_core_locked memory_status memory_writeback_locked_command; do
	function_body "$init_file" "$name" | grep -Fq 'load_settings light' || exit 1
done
printf '%s\n' "$load_body" | grep -Fq 'local MEMORY_STATE_CHECK="${1:-full}"' || exit 1
printf '%s\n' "$binds_body" | grep -Fq 'memory_state_load "${MEMORY_STATE_CHECK:-full}"' || exit 1
[ "$(printf '%s\n' "$copy_body" | grep -Fc 'memory_state_load || exit 1')" = 1 ] || exit 1
[ "$(printf '%s\n' "$copy_body" | grep -Fc 'uid853_mounted_tree_is_writable "$target"')" = 1 ] || exit 1
if printf '%s\n' "$copy_body" | grep -Eq 'uid853_tree_is_plain|memory_active_tree_valid'; then
	printf 'live RAM source is redundantly scanned outside its full state load\n' >&2
	exit 1
fi

# The record is parsed once without shell evaluation, sed/grep subprocesses,
# or loss of duplicate-key/version/numeric/inode checks.
if printf '%s\n' "$state_body" | grep -Eq '(sed |grep |wc |eval )'; then
	printf 'RAM state loading still contains repeated text subprocesses\n' >&2
	exit 1
fi
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
(
	eval "$state_body"
	MEMORY_RUNTIME_DIR="$test_tmp"
	MEMORY_STATE_FILE="${test_tmp}/state"
	SCAN_COUNT=0
	LAYOUT_COUNT=0
	IDENTITY_OK=1
	MEMORY_MOUNTS_SUSPENDED=0
	memory_runtime_dir_valid() { return 0; }
	memory_private_state_file() { [ -f "$1" ]; }
	validate_managed_work_dir_namespace() { [ "$1" = /etc/AdGuardHome ]; }
	memory_backing_identity() {
		MEMORY_IDENTITY_DEVICE=10
		MEMORY_IDENTITY_INODE=20
	}
	memory_active_tree_valid() { SCAN_COUNT=$((SCAN_COUNT + 1)); }
	memory_active_layout_valid() { LAYOUT_COUNT=$((LAYOUT_COUNT + 1)); }
	memory_binding_identities_match() {
		[ "$*" = '/etc/AdGuardHome 11 21 12 22' ] && [ "$IDENTITY_OK" = 1 ]
	}
	memory_suspended_identities_match() { memory_binding_identities_match "$@"; }
	valid_record() {
		printf '%s\n' version=4 persistent_work_dir=/etc/AdGuardHome \
			backing_device=10 backing_inode=20 persistent_data_device=11 \
			persistent_data_inode=21 memory_data_device=12 memory_data_inode=22
	}
	expect_invalid() {
		local rc=0
		memory_state_load light || rc=$?
		[ "$rc" = 2 ] && [ "$MEMORY_STATE_VALIDATED" = 0 ] || {
			printf 'malformed RAM state was accepted\n' >&2
			exit 1
		}
	}
	valid_record >"$MEMORY_STATE_FILE"
	memory_state_load light
	[ "$SCAN_COUNT:$LAYOUT_COUNT:$MEMORY_STATE_VALIDATED" = 0:1:1 ]
	[ "$MEMORY_STATE_PERSISTENT_WORK_DIR:$MEMORY_STATE_BACKING_DEVICE:$MEMORY_STATE_BACKING_INODE" = \
		/etc/AdGuardHome:10:20 ]
	memory_state_load
	[ "$SCAN_COUNT:$LAYOUT_COUNT" = 1:1 ]
	MEMORY_MOUNTS_SUSPENDED=1
	memory_state_load light
	IDENTITY_OK=0
	expect_invalid
	IDENTITY_OK=1
	MEMORY_MOUNTS_SUSPENDED=0
	for extra in version=4 memory_data_inode=22 unknown=1; do
		valid_record >"$MEMORY_STATE_FILE"
		printf '%s\n' "$extra" >>"$MEMORY_STATE_FILE"
		expect_invalid
	done
	# Unknown unterminated tails cannot bypass the key allowlist.
	valid_record >"$MEMORY_STATE_FILE"
	printf unknown=1 >>"$MEMORY_STATE_FILE"
	expect_invalid
	for pattern in 's/version=4/version=3/' 's/backing_device=10/backing_device=bad/' \
		's/backing_inode=20/backing_inode=99/' '/persistent_work_dir=/d' \
		'/memory_data_inode=/d' 's/persistent_work_dir=.*/persistent_work_dir=\/tmp\/foreign/'; do
		valid_record | sed "$pattern" >"$MEMORY_STATE_FILE"
		expect_invalid
	done
) || {
	printf 'single-read RAM state validation or scan selection failed\n' >&2
	exit 1
}

printf 'ok - lightweight RAM monitoring, single-read state and guarded copy\n'
