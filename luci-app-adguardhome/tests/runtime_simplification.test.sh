#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

# TLS lists keep exact paths and ownership while dropping repeated entries.
for name in line_list_contains append_tls_desired_mount append_tls_old_mount \
	append_tls_new_managed_mount append_tls_original_mount derive_tls_new_managed_mounts; do
	eval "$(function_body "$init_file" "$name")"
done
TLS_DESIRED_MOUNTS='' TLS_OLD_MOUNTS='' TLS_NEW_MANAGED_MOUNTS=''
TLS_ORIGINAL_MOUNTS='' TLS_PRESERVED_MOUNTS=''
append_tls_old_mount /cert/managed
append_tls_old_mount /cert/managed
for path in /cert/managed /cert/user /cert/user; do
	append_tls_original_mount "$path"
done
for path in /cert/managed /cert/user /cert/user /cert/new /cert/new-key; do
	append_tls_desired_mount "$path"
done
derive_tls_new_managed_mounts
append_tls_new_managed_mount /cert/new
[ "$TLS_OLD_MOUNTS" = /cert/managed ]
[ "$TLS_PRESERVED_MOUNTS" = /cert/user ]
[ "$TLS_ORIGINAL_MOUNTS" = '/cert/managed
/cert/user
/cert/user' ]
[ "$TLS_DESIRED_MOUNTS" = '/cert/managed
/cert/user
/cert/new
/cert/new-key' ]
[ "$TLS_NEW_MANAGED_MOUNTS" = '/cert/managed
/cert/new
/cert/new-key' ]

for obsolete in disable_official_autostart sync_yaml_stale_memory_pattern \
	memory_rewrite_workdir_pattern memory_clear_official_path_delta; do
	if grep -Fq "$obsolete" "$init_file"; then
		printf 'obsolete runtime helper remains: %s\n' "$obsolete" >&2
		exit 1
	fi
done

guard_body="$(function_body "$init_file" memory_run_with_official_path_guard)"
# One pre-commit guard and one post-commit guard; no three identical prechecks.
[ "$(printf '%s\n' "$guard_body" | grep -Fc 'uci_guard_no_delta "$OFFICIAL_CONFIG"')" = 2 ] || exit 1
for name in memory_prepare_runtime_locked memory_deactivate_locked; do
	if function_body "$init_file" "$name" | grep -Fq sync_yaml_managed_fields_checked; then
		printf 'data-only RAM transition still rewrites persistent YAML\n' >&2
		exit 1
	fi
done

# With the legacy RAM path rewrite removed, identical workdirs must not even
# create a disposable YAML snapshot.  A real move still uses the checked path.
managed_body="$(function_body "$init_file" sync_yaml_managed_fields_checked)"
(
	eval "$managed_body"
	mktemp() { return 1; }
	validate_work_dir_mount_dependency() { return 0; }
	previous_work_dir=""
	work_dir=/etc/AdGuardHome
	config_file="$work_dir/AdGuardHome.yaml"
	sync_yaml_managed_fields_checked
	previous_work_dir=/etc/AdGuardHome
	sync_yaml_managed_fields_checked
	previous_work_dir=/etc/AdGuardHome-old
	if sync_yaml_managed_fields_checked; then
		printf 'changed workdir skipped the checked YAML path\n' >&2
		exit 1
	fi
)

# Dynamic DNS ports are intentionally read from a fresh snapshot each time.
# There is no monitor-lifetime cache which can conceal an official Web UI edit.
runtime_body="$(function_body "$init_file" load_runtime_dns_port)"
parser_body="$(function_body "$init_file" yaml_runtime_ports)"
port_body="$(function_body "$init_file" is_valid_port)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# A workdir move takes its revision from the actual backup, then retains the
# post-validation compare and failed-install restoration boundaries.
(
	eval "$managed_body"
	for name in sync_yaml_workdir_pattern yaml_replace_section_list_item install_yaml_temp; do
		eval "$(function_body "$init_file" "$name")"
	done
	work_dir="$test_tmp/managed"
	previous_work_dir=/etc/AdGuardHome-old
	config_file="$work_dir/AdGuardHome.yaml"
	mkdir "$work_dir"
	events="$test_tmp/managed-events"
	validate_work_dir_mount_dependency() { :; }
	log_error() { :; }
	yaml_file_hash() { sha256sum "$1" | cut -d ' ' -f 1; }
	snapshot_config_file() {
		printf 'snapshot\n' >>"$events"
		MANAGED_DIRECTORY="${2%/*}"
		cp "$1" "$2" || return 1
		[ "$scenario" != snapshot-failure ] || return 1
		SNAPSHOT_CONFIG_HASH="$(yaml_file_hash "$2")"
	}
	active_config_hash() {
		printf 'active-hash\n' >>"$events"
		yaml_file_hash "$config_file"
	}
	check_core_config_file() {
		printf 'check\n' >>"$events"
		[ "$2" = "$(yaml_file_hash "$1")" ] || return 1
		[ "$scenario" != validation-failure ]
	}
	install_config_candidate() {
		if [ "${1##*/}" = original.yaml ]; then
			printf 'restore\n' >>"$events"
			[ "$scenario" != restore-failure ] || return 1
		else
			printf 'install\n' >>"$events"
			[ "$2" = "$(yaml_file_hash "$config_file")" ] || return 1
			[ "$scenario" != install-before ] || return 1
		fi
		cp "$1" "$config_file" || return 1
		if [ -n "$4" ] && { [ "$scenario" = install-after ] || [ "$scenario" = restore-failure ]; }; then
			: >"$4"
			return 1
		fi
	}
	for scenario in success unchanged snapshot-failure validation-failure install-before install-after restore-failure; do
		printf 'filtering:\n  safe_fs_patterns:\n    - %s/data/userfilters/*\n    - /custom/filters/*\n' \
			"$previous_work_dir" >"$config_file"
		if [ "$scenario" = unchanged ]; then
			printf 'filtering:\n  safe_fs_patterns:\n    - /custom/filters/*\n' >"$config_file"
		fi
		cp "$config_file" "$test_tmp/original.yaml"
		: >"$events"
		rc=0
		sync_yaml_managed_fields_checked || rc=$?
		[ "$(grep -c '^snapshot$' "$events")" = 1 ]
		case "$scenario" in
			success)
				[ "$rc" = 0 ]
				grep -Fqx "    - $work_dir/data/userfilters/*" "$config_file"
				grep -Fqx '    - /custom/filters/*' "$config_file"
				;;
			unchanged) [ "$rc" = 0 ]; cmp -s "$config_file" "$test_tmp/original.yaml" ;;
			restore-failure)
				[ "$rc" != 0 ]
				cmp -s "$MANAGED_DIRECTORY/original.yaml" "$test_tmp/original.yaml"
				[ "$(LC_ALL=C ls -ld "$MANAGED_DIRECTORY" | cut -d ' ' -f 1)" = drwx------ ]
				rm -rf "$MANAGED_DIRECTORY"
				;;
			*) [ "$rc" != 0 ]; cmp -s "$config_file" "$test_tmp/original.yaml" ;;
		esac
		[ ! -e "$MANAGED_DIRECTORY" ]
		case "$scenario" in
			unchanged|snapshot-failure|validation-failure)
				! grep -q '^active-hash$' "$events" || exit 1 ;;
			*) [ "$(grep -c '^active-hash$' "$events")" = 1 ] ;;
		esac
		case "$scenario" in
			install-after|restore-failure) grep -qx restore "$events" ;;
			*) ! grep -q '^restore$' "$events" || exit 1 ;;
		esac
	done
)
(
	eval "$runtime_body"
	eval "$parser_body"
	eval "$port_body"
	config_file="${test_tmp}/AdGuardHome.yaml"
	redirect_mode=none
	SNAPSHOTS=0
	snapshot_config_file() {
		SNAPSHOTS=$((SNAPSHOTS + 1))
		cp "$1" "$2"
	}
	log_error() { :; }
	printf 'http:\n  address: 0.0.0.0:3000\ndns:\n  port: 53335\n' >"$config_file"
	load_runtime_dns_port
	[ "$dns_port" = 53335 ]
	printf 'http:\n  address: 0.0.0.0:3000\ndns:\n  port: 55353\n' >"$config_file"
	load_runtime_dns_port
	[ "$dns_port:$SNAPSHOTS" = 55353:2 ]
	printf 'http:\n  address: 0.0.0.0:3000\ndns:\n  port: 53335\n  port: 55353\n' >"$config_file"
	if load_runtime_dns_port; then
		printf 'ambiguous YAML DNS port was accepted\n' >&2
		exit 1
	fi
)

printf 'ok - empty transactions and obsolete YAML paths removed; DNS stays dynamic\n'
