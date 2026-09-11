#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

if grep -Fq 'MANAGED_DATA_JAIL_OPTION=' "$init_file" ||
   grep -Fq 'set "${PLUGIN_CONFIG}.${PLUGIN_SECTION}.managed_data_jail_mount=' "$init_file"; then
	printf 'RAM jail access still writes a duplicate managed_data_jail_mount marker\n' >&2
	exit 1
fi

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
eval "$(init_source "$init_file")"

TEST_RW=""
TEST_COMMITS=0
TEST_LOADS=0
TEST_DROP_ON_COMMIT=0

config_load() {
	TEST_LOADS=$((TEST_LOADS + 1))
	TEST_LOADED_RW="$TEST_RW"
}
config_list_foreach() {
	local section="$1" option="$2" callback="$3" value
	[ "$section:$option" = "${OFFICIAL_SECTION}:jail_mount_rw" ] || return 1
	while IFS= read -r value; do
		[ -n "$value" ] || continue
		"$callback" "$value"
	done <<-EOF
	${TEST_LOADED_RW}
	EOF
}
validate_managed_work_dir_namespace() {
	case "${1%/}" in
		/etc/AdGuardHome|/mnt/storage/AdGuardHome|/srv/old/AdGuardHome) return 0 ;;
		*) return 1 ;;
	esac
}

uci() {
	[ "${1:-}" != -q ] || shift
	local command="${1:-}" argument="${2:-}" value target rebuilt
	case "$command:$argument" in
		del_list:${OFFICIAL_CONFIG}.${OFFICIAL_SECTION}.jail_mount_rw=*)
			target="${argument#*=}"
			rebuilt=""
			while IFS= read -r value; do
				[ -n "$value" ] || continue
				[ "$value" != "$target" ] || continue
				if [ -n "$rebuilt" ]; then
					rebuilt="${rebuilt}
${value}"
				else
					rebuilt="$value"
				fi
			done <<-EOF
			${TEST_RW}
			EOF
			# libuci's del_list command succeeds even when the option or exact
			# value is absent.  The production code must inspect the list before
			# treating this return status as evidence of a change.
			TEST_RW="$rebuilt"
			;;
		delete:${OFFICIAL_CONFIG}.${OFFICIAL_SECTION}.jail_mount_rw)
			TEST_RW=""
			;;
		add_list:${OFFICIAL_CONFIG}.${OFFICIAL_SECTION}.jail_mount_rw=*)
			value="${argument#*=}"
			if [ -n "$TEST_RW" ]; then
				TEST_RW="${TEST_RW}
${value}"
			else
				TEST_RW="$value"
			fi
			;;
		commit:${OFFICIAL_CONFIG})
			TEST_COMMITS=$((TEST_COMMITS + 1))
			[ "$TEST_DROP_ON_COMMIT" = 0 ] || TEST_RW="$other"
			;;
		*) return 1 ;;
	esac
}

assert_rw() {
	[ "$TEST_RW" = "$1" ] || {
		printf 'unexpected jail_mount_rw list:\n%s\nexpected:\n%s\n' "$TEST_RW" "$1" >&2
		exit 1
	}
}

other='/mnt/user-owned/cache'
path_a='/etc/AdGuardHome/data'
path_b='/mnt/storage/AdGuardHome/data'
path_old='/srv/old/AdGuardHome/data'

# Disk mode removes only the derived child mount.
MEMORY_ACTIVE=0
MEMORY_BACKING_WORK_DIR=""
previous_work_dir=/etc/AdGuardHome
persistent_work_dir=/etc/AdGuardHome
TEST_RW="${other}
${path_a}"
TEST_COMMITS=0
sync_memory_data_jail_access_persistent
assert_rw "$other"
[ "$TEST_COMMITS" = 1 ]

# A second disk-mode synchronization must not infer a change merely because
# libuci del_list would return success while the unrelated RW list still exists.
TEST_COMMITS=0
TEST_LOADS=0
sync_memory_data_jail_access_persistent
assert_rw "$other"
[ "$TEST_COMMITS" = 0 ] || {
	printf 'an unchanged disk-mode RW mount list was committed again\n' >&2
	exit 1
}
[ "$TEST_LOADS" = 1 ] || {
	printf 'unchanged disk mode reloaded the same candidate more than once\n' >&2
	exit 1
}

# RAM mode adds exactly one derived child mount and is idempotent.
MEMORY_ACTIVE=1
MEMORY_BACKING_WORK_DIR=/etc/AdGuardHome
previous_work_dir=/etc/AdGuardHome
persistent_work_dir=/etc/AdGuardHome
TEST_RW="$other"
TEST_COMMITS=0
TEST_LOADS=0
sync_memory_data_jail_access_persistent
assert_rw "${other}
${path_a}"
[ "$TEST_COMMITS" = 1 ]
[ "$TEST_LOADS" = 2 ]
TEST_LOADS=0
sync_memory_data_jail_access_persistent
assert_rw "${other}
${path_a}"
[ "$TEST_COMMITS" = 1 ] || {
	printf 'an unchanged RAM jail mount was committed again\n' >&2
	exit 1
}
[ "$TEST_LOADS" = 1 ] || {
	printf 'unchanged RAM mode reloaded an already validated mount count\n' >&2
	exit 1
}

# An active workdir transition removes A and publishes only B.
MEMORY_ACTIVE=1
MEMORY_BACKING_WORK_DIR=/mnt/storage/AdGuardHome
previous_work_dir=/etc/AdGuardHome
persistent_work_dir=/mnt/storage/AdGuardHome
TEST_RW="${other}
${path_a}"
TEST_COMMITS=0
sync_memory_data_jail_access_persistent
assert_rw "${other}
${path_b}"
[ "$TEST_COMMITS" = 1 ]

# Disabling RAM removes B.  A previous state-bound workdir path is also removed
# without disturbing an unrelated official mount.
MEMORY_ACTIVE=0
MEMORY_BACKING_WORK_DIR=""
previous_work_dir=/mnt/storage/AdGuardHome
persistent_work_dir=/mnt/storage/AdGuardHome
TEST_RW="${path_old}
${other}
${path_b}"
TEST_COMMITS=0
sync_memory_data_jail_access_persistent
assert_rw "${path_old}
${other}"
[ "$TEST_COMMITS" = 1 ]

# Repeated nonadjacent candidates, including a trailing slash, are checked once.
MEMORY_ACTIVE=0
MEMORY_BACKING_WORK_DIR=/etc/AdGuardHome/
previous_work_dir=/etc/AdGuardHome
persistent_work_dir=/mnt/storage/AdGuardHome
TEST_RW="$other"
TEST_COMMITS=0
TEST_LOADS=0
sync_memory_data_jail_access_persistent
assert_rw "$other"
[ "$TEST_COMMITS" = 0 ]
[ "$TEST_LOADS" = 2 ]

# An existing duplicate desired mount still fails before committing any change.
MEMORY_ACTIVE=1
MEMORY_BACKING_WORK_DIR=/etc/AdGuardHome
previous_work_dir=/etc/AdGuardHome
persistent_work_dir=/etc/AdGuardHome
TEST_RW="${other}
${path_a}
${path_a}"
TEST_COMMITS=0
if sync_memory_data_jail_access_persistent; then
	printf 'a duplicated desired RAM jail mount was accepted\n' >&2
	exit 1
fi
[ "$TEST_COMMITS" = 0 ]

# A changed mount list must be reloaded after commit; its pre-commit snapshot
# cannot hide a missing desired mount in the committed configuration.
TEST_RW="$other"
TEST_DROP_ON_COMMIT=1
TEST_LOADS=0
if sync_memory_data_jail_access_persistent; then
	printf 'a missing committed RAM jail mount was accepted\n' >&2
	exit 1
fi
[ "$TEST_COMMITS" = 1 ]
[ "$TEST_LOADS" = 2 ]
TEST_DROP_ON_COMMIT=0

printf 'ok - RAM ujail uses one derived jail_mount_rw state without a duplicate marker\n'
