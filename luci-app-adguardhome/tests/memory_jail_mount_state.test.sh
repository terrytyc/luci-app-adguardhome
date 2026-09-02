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
. "$init_file"

TEST_RW=""
TEST_COMMITS=0

config_load() { return 0; }
config_list_foreach() {
	local section="$1" option="$2" callback="$3" value
	[ "$section:$option" = "${OFFICIAL_SECTION}:jail_mount_rw" ] || return 1
	while IFS= read -r value; do
		[ -n "$value" ] || continue
		"$callback" "$value"
	done <<-EOF
	${TEST_RW}
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
	local command="${1:-}" argument="${2:-}" value target found rebuilt
	case "$command:$argument" in
		del_list:${OFFICIAL_CONFIG}.${OFFICIAL_SECTION}.jail_mount_rw=*)
			target="${argument#*=}"
			found=0
			rebuilt=""
			while IFS= read -r value; do
				[ -n "$value" ] || continue
				if [ "$found" = 0 ] && [ "$value" = "$target" ]; then
					found=1
					continue
				fi
				if [ -n "$rebuilt" ]; then
					rebuilt="${rebuilt}
${value}"
				else
					rebuilt="$value"
				fi
			done <<-EOF
			${TEST_RW}
			EOF
			[ "$found" = 1 ] || return 1
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

# RAM mode adds exactly one derived child mount and is idempotent.
MEMORY_ACTIVE=1
MEMORY_BACKING_WORK_DIR=/etc/AdGuardHome
previous_work_dir=/etc/AdGuardHome
persistent_work_dir=/etc/AdGuardHome
TEST_RW="$other"
TEST_COMMITS=0
sync_memory_data_jail_access_persistent
assert_rw "${other}
${path_a}"
[ "$TEST_COMMITS" = 1 ]
sync_memory_data_jail_access_persistent
assert_rw "${other}
${path_a}"
[ "$TEST_COMMITS" = 1 ] || {
	printf 'an unchanged RAM jail mount was committed again\n' >&2
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

printf 'ok - RAM ujail uses one derived jail_mount_rw state without a duplicate marker\n'
