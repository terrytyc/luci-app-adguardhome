#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in path_contains_symlink validate_work_dir validate_managed_work_dir_namespace; do
	eval "$(function_body "$script_dir/../root/etc/init.d/AdGuardHome" "$name")"
done
log_error() { :; }
MAX_WORK_DIR_LENGTH=4040
MAX_WORK_DIR_COMPONENT_LENGTH=255
grep -Fq 'MAX_WORK_DIR_LENGTH=4040' "$script_dir/../root/etc/init.d/AdGuardHome"
grep -Fq 'MAX_WORK_DIR_COMPONENT_LENGTH=255' "$script_dir/../root/etc/init.d/AdGuardHome"

repeat_a() {
	local value=""
	while [ "${#value}" -lt "$1" ]; do value="${value}a"; done
	printf '%s\n' "$value"
}

component255="$(repeat_a 255)"
component256="${component255}a"
validate_work_dir "/opt/${component255}"
! validate_work_dir "/opt/${component256}"

max_work_dir=""
count=0
while [ "$count" -lt 15 ]; do
	max_work_dir="${max_work_dir}/${component255}"
	count=$((count + 1))
done
max_work_dir="${max_work_dir}/$(repeat_a 199)"
[ "${#max_work_dir}" = 4040 ]
validate_work_dir "$max_work_dir"
! validate_work_dir "${max_work_dir}a"

# These existing host mount points exercise the real /proc/mounts parser.
validate_managed_work_dir_namespace /etc/dns-custom
validate_managed_work_dir_namespace /opt/dns-custom
validate_managed_work_dir_namespace /dns-custom
! validate_managed_work_dir_namespace /dev/shm/dns-custom
! validate_managed_work_dir_namespace /proc/dns-custom
! validate_managed_work_dir_namespace /etc
! validate_managed_work_dir_namespace /
! validate_managed_work_dir_namespace /etc/../dns-custom
! validate_managed_work_dir_namespace /etc/passwd/dns-custom

printf 'ok - custom persistent work directories and memory filesystem rejection\n'
