#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

function_body() {
	awk -v name="$1" '
		$0 == name "() {" || $0 == name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' "$init_file"
}

for obsolete in disable_official_autostart sync_yaml_stale_memory_pattern \
	memory_rewrite_workdir_pattern memory_clear_official_path_delta; do
	if grep -Fq "$obsolete" "$init_file"; then
		printf 'obsolete runtime helper remains: %s\n' "$obsolete" >&2
		exit 1
	fi
done

guard_body="$(function_body memory_run_with_official_path_guard)"
# One pre-commit guard and one post-commit guard; no three identical prechecks.
[ "$(printf '%s\n' "$guard_body" | grep -Fc 'uci_guard_no_delta "$OFFICIAL_CONFIG"')" = 2 ] || exit 1
for name in memory_prepare_runtime_locked memory_deactivate_locked; do
	if function_body "$name" | grep -Fq sync_yaml_managed_fields_checked; then
		printf 'data-only RAM transition still rewrites persistent YAML\n' >&2
		exit 1
	fi
done

# With the legacy RAM path rewrite removed, identical workdirs must not even
# create a disposable YAML snapshot.  A real move still uses the checked path.
managed_body="$(function_body sync_yaml_managed_fields_checked)"
(
	eval "$managed_body"
	mktemp() { return 1; }
	previous_work_dir=""
	work_dir=/etc/AdGuardHome
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
runtime_body="$(function_body load_runtime_dns_port)"
parser_body="$(function_body yaml_runtime_ports)"
port_body="$(function_body is_valid_port)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
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
