#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in path_contains_symlink validate_work_dir validate_managed_work_dir_namespace; do
	eval "$(function_body "$script_dir/../root/etc/init.d/AdGuardHome" "$name")"
done
log_error() { :; }

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
