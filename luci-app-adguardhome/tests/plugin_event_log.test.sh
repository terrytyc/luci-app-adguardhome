#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in service_started stop_service wait_for_core_stopped settings_update_locked; do
	eval "$(function_body "$init_file" "$name")"
done

log_file="$test_tmp/events"
log_error() { printf '%s\n' "$*" >>"$log_file"; }
run_locked() { "$@"; }
fail_safe_locked() { return 0; }
orchestrate_core_locked() { return "${ORCHESTRATE_RC:-0}"; }
reconcile_core_locked() { return "${RECONCILE_RC:-0}"; }
stop_wrapper_locked() { return "${STOP_RC:-0}"; }

expect_log() {
	local expected="$1"
	[ "$(cat "$log_file")" = "$expected" ] || {
		printf 'unexpected plugin event log:\n%s\n' "$(cat "$log_file")" >&2
		exit 1
	}
}

: >"$log_file"
START_PREPARED=1 START_DISABLED=0 WRAPPER_BOOT=0 ORCHESTRATE_RC=0
service_started
expect_log 'AdGuard Home coordinator started'

: >"$log_file"
START_PREPARED=0
rc=0
service_started || rc=$?
[ "$rc" = 1 ]
[ ! -s "$log_file" ]
START_PREPARED=1

: >"$log_file"
ORCHESTRATE_RC=7
rc=0
service_started || rc=$?
[ "$rc" = 7 ]
expect_log 'AdGuard Home coordinator start failed'

: >"$log_file"
START_DISABLED=1
service_started
[ ! -s "$log_file" ]

: >"$log_file"
STOP_RC=0
stop_service
expect_log 'AdGuard Home coordinator stopped'

: >"$log_file"
STOP_RC=6
rc=0
stop_service || rc=$?
[ "$rc" = 6 ]
expect_log 'AdGuard Home coordinator stop failed'

sleep() { :; }
official_running() { return 0; }
adguard_uid_process_exists() { return 0; }
: >"$log_file"
rc=0
wait_for_core_stopped || rc=$?
[ "$rc" = 1 ]
expect_log 'AdGuard Home core did not stop within 10 seconds'

revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
load_settings() {
	service_enabled=1
	persistent_work_dir=/etc/AdGuardHome
	verbose=0
	redirect_mode=none
	memory_requested=0
	memory_writeback_interval=60
}
settings_current_revision() { printf '%s\n' "$revision"; }
memory_run_with_official_path_guard() {
	COMMIT_CALLS=$((COMMIT_CALLS + 1))
	[ "$COMMIT_FAIL_FIRST" != 1 ] || [ "$COMMIT_CALLS" -gt 1 ]
}
refresh_managed_config_snapshot() { return 0; }

: >"$log_file"
START_DISABLED=0 ORCHESTRATE_RC=0 COMMIT_CALLS=0 COMMIT_FAIL_FIRST=0
settings_update_locked 1 /etc/AdGuardHome 1 dnsmasq-upstream 1 120 "$revision"
expect_log 'Applied AdGuard Home settings (enabled 1->1, DNS none->dnsmasq-upstream, memory 0->1)'

: >"$log_file"
COMMIT_CALLS=0 COMMIT_FAIL_FIRST=1
rc=0
settings_update_locked 1 /etc/AdGuardHome 1 dnsmasq-upstream 1 120 "$revision" || rc=$?
[ "$rc" = 1 ]
expect_log 'Unable to save the new AdGuard Home settings; previous settings were restored'

copy_body="$(function_body "$init_file" memory_copy_live_data_locked)"
prepare_body="$(function_body "$init_file" memory_prepare_runtime_locked)"
writeback_body="$(function_body "$init_file" memory_writeback_locked_command)"
monitor_body="$(function_body "$init_file" monitor)"
monitor_interval_body="$(function_body "$init_file" monitor_interval_locked)"
orchestrate_body="$(function_body "$init_file" orchestrate_core_locked)"
yaml_update_body="$(function_body "$init_file" yaml_update_locked)"

# shellcheck disable=SC2016
[ "$(printf '%s\n' "$copy_body" | grep -Fc \
	'log_error "Wrote AdGuard Home RAM data back to ${MEMORY_BACKING_WORK_DIR}/data"')" = 1 ]
# shellcheck disable=SC2016
[ "$(printf '%s\n' "$prepare_body" | grep -Fc \
	'log_error "AdGuard Home data directory prepared in memory from ${persistent_work_dir}/data"')" = 1 ]
if printf '%s\n' "$writeback_body" | grep -Fq 'log_error'; then
	printf 'live write-back wrapper still duplicates the shared event\n' >&2
	exit 1
fi
if grep -Fq 'Completed the live AdGuard Home memory write-back' "$init_file"; then
	printf 'obsolete duplicate RAM write-back event remains\n' >&2
	exit 1
fi
[ "$(printf '%s\n' "$monitor_body" | grep -Fc 'log_error')" = 1 ]
printf '%s\n' "$monitor_body" | grep -Fq \
	'Scheduled AdGuard Home memory write-back failed; retrying in 60 seconds'
printf '%s\n' "$monitor_interval_body" | grep -Fq \
	'ADGUARDHOME_LOG_SILENT=1 reconcile_core_locked >/dev/null || true'
printf '%s\n' "$orchestrate_body" | grep -Fq \
	'Official AdGuard Home service start command failed'
[ "$(printf '%s\n' "$yaml_update_body" | grep -Fc \
	'log_error "Applied AdGuard Home YAML configuration"')" = 1 ]
if grep -Fq 'Removed the AdGuard Home memory workdir after a successful direct write-back' "$init_file"; then
	printf 'internal RAM cleanup still emits a redundant lifecycle event\n' >&2
	exit 1
fi

eval "$(function_body "$init_file" log_error)"
logger() { printf '%s\n' "$*" >>"$log_file"; }
: >"$log_file"
ADGUARDHOME_LOG_SILENT=1 log_error 'hidden monitor detail'
[ ! -s "$log_file" ]
ADGUARDHOME_LOG_SILENT=0 log_error 'visible event'
expect_log '-t AdGuardHome visible event'

printf 'ok - sparse plugin lifecycle events and shared RAM write-back logging\n'
