#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in record_ready_core_runtime service_started stop_service wait_for_core_stopped settings_update_locked \
	tls_refresh_locked start_official_core; do
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

# Target rc.common's stop action deliberately continues after the hook. Test
# this complete dispatch, not merely the return value of stop_service().
stop() {
	procd_lock
	stop_service "$@"
	procd_kill "$(basename ${basescript:-$initscript})" "$1"
	if eval "type service_stopped" 2>/dev/null >/dev/null; then
		service_stopped
	fi
}
initscript=/etc/init.d/AdGuardHome
procd_lock() { :; }
procd_kill() { printf '%s\n' "$1" >>"$test_tmp/monitor-deletions"; }
for STOP_RC in 0 6; do
	: >"$log_file"
	: >"$test_tmp/monitor-deletions"
	rc=0
	( stop '' ) || rc=$?
	[ "$rc" = "$STOP_RC" ]
	if [ "$STOP_RC" = 0 ]; then
		expect_log 'AdGuard Home coordinator stopped'
		[ "$(cat "$test_tmp/monitor-deletions")" = AdGuardHome ]
	else
		expect_log 'AdGuard Home coordinator stop failed'
		[ ! -s "$test_tmp/monitor-deletions" ]
	fi
done

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

hotplug_file="${script_dir}/../root/etc/hotplug.d/acme/95-AdGuardHome"
hotplug_log="$test_tmp/hotplug-events"
sed "s#/etc/init.d/AdGuardHome#$test_tmp/AdGuardHome#g" \
	"$hotplug_file" >"$test_tmp/acme-hotplug"
cat >"$test_tmp/AdGuardHome" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$HOTPLUG_LOG"
EOF
chmod 0755 "$test_tmp/AdGuardHome" "$test_tmp/acme-hotplug"
export HOTPLUG_LOG="$hotplug_log"
: >"$hotplug_log"
ACTION=renewed CERT_FULLCHAIN_PATH=/etc/acme/example/fullchain.cer \
	"$test_tmp/acme-hotplug"
[ ! -s "$hotplug_log" ]
ACTION=renewed CERT_FULLCHAIN_PATH='' "$test_tmp/acme-hotplug"
ACTION=issued CERT_FULLCHAIN_PATH=/etc/acme/example/fullchain.cer \
	"$test_tmp/acme-hotplug"
[ "$(wc -l <"$hotplug_log")" = 2 ]
[ "$(grep -cx tls_refresh "$hotplug_log")" = 2 ]

PLUGIN_CONFIG=adguardhome
PLUGIN_SECTION=luci
MANAGED_TLS_FINGERPRINT=managed_tls_fingerprint
config_file="$test_tmp/AdGuardHome.yaml"
printf 'dns:\n  port: 53335\n' >"$config_file"
OFFICIAL_SERVICE="$test_tmp/official-service"
official_log="$test_tmp/official-events"
cat >"$OFFICIAL_SERVICE" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$OFFICIAL_LOG"
EOF
chmod 0755 "$OFFICIAL_SERVICE"
export OFFICIAL_LOG="$official_log"
uci() {
	[ "$1" = -q ] && shift
	[ "$1" = get ] && printf '%s\n' "$UCI_FINGERPRINT"
}
load_settings() { service_enabled=1; work_dir=/etc/AdGuardHome; redirect_mode=none; }
validate_work_dir_mount_dependency() { return 0; }
load_active_tls_access() { TLS_USES_ACME=1; TLS_FINGERPRINT=loaded; }
check_core_config() { TLS_FINGERPRINT=; }
sync_tls_access() { UCI_FINGERPRINT="$SYNC_FINGERPRINT"; }
CORE_RUNNING=0
official_running() { [ "$CORE_RUNNING" = 1 ]; }
coordinator_present() { [ "${TEST_COORDINATOR_PRESENT:-0}" = 1 ]; }
DNS_CHANGES=0
clear_recorded_integration_locked() { DNS_CHANGES=$((DNS_CHANGES + 1)); }
load_runtime_dns_port() { dns_port=53335; }
wait_for_core_ready() { :; }
apply_integration_locked() { DNS_CHANGES=$((DNS_CHANGES + 1)); }
restore_tls_fingerprint() { :; }
resume_yaml_runtime() { :; }
core_runtime_fingerprint() { printf 'fixture\n'; }
remember_core_runtime() { return 0; }

: >"$official_log"
UCI_FINGERPRINT=same SYNC_FINGERPRINT=same tls_refresh_locked
[ ! -s "$official_log" ]
# A renewed certificate may refresh access while stopped, but must not undo
# a manual coordinator stop (which also removed its DNS monitor).
for CORE_RUNNING in 0 1; do
	UCI_FINGERPRINT=old SYNC_FINGERPRINT=new tls_refresh_locked
	[ ! -s "$official_log" ] && [ "$DNS_CHANGES" = 0 ]
done

# Keep the actual recovery chain: resume_yaml_runtime syncs TLS access, which
# republishes the new fingerprint even when it cannot restart the old core.
# Every failure branch must restore the retry marker after that attempt.
(
	TEST_COORDINATOR_PRESENT=1
	eval "$(function_body "$init_file" resume_core_and_dns)"
	eval "$(function_body "$init_file" resume_yaml_runtime)"
	eval "$(function_body "$init_file" restore_tls_fingerprint)"
	uci() {
		[ "$1" = -q ] && shift
		case "$1" in
			get) printf '%s\n' "$UCI_FINGERPRINT" ;;
			set) UCI_FINGERPRINT="${2#*=}" ;;
			delete) UCI_FINGERPRINT='' ;;
			commit) return 0 ;;
			*) return 1 ;;
		esac
	}
	sync_official_uci() { sync_tls_access; }
	official_running() { [ "$CORE_RUNNING" = 1 ]; }
	clear_recorded_integration_locked() { [ "$TLS_FAILURE" != cleanup ]; }
	wait_for_core_stopped() { [ "$CORE_RUNNING" = 0 ]; }
	OFFICIAL_SERVICE=acme_test_service
	acme_test_service() {
		printf '%s\n' "$1" >>"$official_log"
		[ "$1" != "$TLS_FAILURE" ] || return 1
		case "$1" in stop) CORE_RUNNING=0 ;; start) CORE_RUNNING=1 ;; esac
	}
	for TLS_FAILURE in cleanup stop start; do
		CORE_RUNNING=1 UCI_FINGERPRINT=old SYNC_FINGERPRINT=new
		: >"$official_log"
		rc=0
		tls_refresh_locked || rc=$?
		[ "$rc" = 1 ] && [ "$UCI_FINGERPRINT" = old ]
		if [ "$TLS_FAILURE" = start ]; then
			expected_retry=start
		else
			expected_retry="$(printf 'stop\nstart')"
		fi
		TLS_FAILURE=''
		: >"$official_log"
		tls_refresh_locked
		[ "$UCI_FINGERPRINT" = new ] && [ "$CORE_RUNNING" = 1 ]
		[ "$(cat "$official_log")" = "$expected_retry" ]
	done
)

printf 'ok - sparse plugin events, ACME refresh ordering and shared RAM write-back logging\n'
