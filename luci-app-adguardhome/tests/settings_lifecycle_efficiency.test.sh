#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="$script_dir/../root/etc/init.d/AdGuardHome"
. "$script_dir/lib/function-body.sh"
eval "$(init_source "$init_file")"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
NORMALIZER_RUNTIME_DIR="$test_tmp/runtime"
work_dir="$test_tmp/work"
config_file="$work_dir/AdGuardHome.yaml"
CORE_BINARY="$test_tmp/core"
OFFICIAL_SERVICE="$test_tmp/service"
mkdir -m 0700 "$work_dir" "$NORMALIZER_RUNTIME_DIR"
mkdir "$work_dir/data"
printf 'core\n' >"$CORE_BINARY"
printf '#!/bin/sh\nexit 0\n' >"$OFFICIAL_SERVICE"
chmod 0700 "$OFFICIAL_SERVICE"
printf 'cert\n' >"$work_dir/certificate"
printf 'key\n' >"$work_dir/key"
printf 'tls:\n  enabled: true\n  certificate_path: %s/certificate\n  private_key_path: %s/key\n' \
	"$work_dir" "$work_dir" >"$config_file"
OFFICIAL_INPUT='config adguardhome config; gc=100'
uci() { [ "$*" = '-q show adguardhome.config' ]; printf '%s\n' "$OFFICIAL_INPUT"; }
official_pid() { printf '%s\n' "$$"; }
snapshot_config_file() {
	cp "$1" "$2"
	SNAPSHOT_CONFIG_HASH="$(yaml_file_hash "$2")"
}
tls_file_hash() { yaml_file_hash "$1"; }

# The real baseline covers YAML, all official options, both TLS files and the
# installed core/service package identity. A valid process PID alone is not enough.
baseline="$(core_runtime_fingerprint)"
remember_core_runtime "$baseline"
core_runtime_matches
for change in yaml official certificate key package data workdir; do
	case "$change" in
		yaml) printf '# external edit\n' >>"$config_file" ;;
		official) OFFICIAL_INPUT='config adguardhome config; gc=200' ;;
		certificate) printf 'renewed cert\n' >"$work_dir/certificate" ;;
		key) printf 'renewed key\n' >"$work_dir/key" ;;
		package) printf 'replacement core\n' >"$CORE_BINARY" ;;
		data) mv "$work_dir/data" "$work_dir/old-data"; mkdir "$work_dir/data" ;;
		workdir) mv "$work_dir" "$test_tmp/old-work"; cp -a "$test_tmp/old-work" "$work_dir" ;;
	esac
	if core_runtime_matches; then
		printf 'runtime baseline concealed %s drift\n' "$change" >&2
		exit 1
	fi
	baseline="$(core_runtime_fingerprint)"
	remember_core_runtime "$baseline"
	core_runtime_matches
done
if remember_core_runtime stale; then exit 1; fi
chmod 0644 "$NORMALIZER_RUNTIME_DIR/applied-runtime"
if core_runtime_matches; then exit 1; fi
chmod 0600 "$NORMALIZER_RUNTIME_DIR/applied-runtime"
saved_identity="$(core_runtime_identity)"
core_runtime_identity() { printf '%s-replaced\n' "$saved_identity"; }
if core_runtime_matches; then exit 1; fi

# Exercise actual settings dispatch. Only the process/IO boundaries are faked;
# changes in startup inputs, readiness or baseline availability take the full path.
events="$test_tmp/events"
record() { printf '%s\n' "$*" >>"$events"; }
counts="$test_tmp/counts"
states="$test_tmp/states"
count() { printf '%s\n' "$1" >>"$counts"; }
call_count() { awk -v name="$1" '$0 == name { count++ } END { print count+0 }' "$counts"; }
assert_count() { [ "$(call_count "$2")" = "$1" ] || {
	printf '%s: expected %s %s calls, got %s\n' "$change" "$1" "$2" "$(call_count "$2")" >&2
	exit 1
}; }
reset_settings_fixture() {
	STORED_ENABLED=1 STORED_WORK=/persistent STORED_VERBOSE=0 STORED_RAM=1
	STORED_MODE=dnsmasq-upstream STORED_INTERVAL=60
	RAW_ENABLED=1 RAW_CONFIG=/persistent/AdGuardHome.yaml RAW_MEMORY=1 RAW_INTERVAL=60
	BASELINE_OK=1 SOCKET_OK=1 INTEGRATION_OK=1 DNS_APPLY_OK=1 RAM_ACTIVE=1 MOUNT_OK=1
	DRIFT_AFTER_COMMIT=0 DRIFT_AFTER_REFRESH=0 DRIFT_AT_MATCH=0 PENDING_AT_CHECK=0
	: >"$events"
	: >"$counts"
	: >"$states"
}
uci() {
	case "$1:$2" in
		-q:export) return 0 ;;
		-q:changes)
			count delta
			if [ "$PENDING_AT_CHECK" -gt 0 ] &&
			   [ "$(call_count delta)" -ge "$PENDING_AT_CHECK" ]; then
				printf "adguardhome.config.enabled='1'\n"
			fi
			return 0 ;;
		-q:get) count raw-get ;;
		*) return 1 ;;
	esac
	case "$3" in
		adguardhome.config.enabled) printf '%s\n' "$RAW_ENABLED" ;;
		adguardhome.config.config_file) printf '%s\n' "$RAW_CONFIG" ;;
		adguardhome.config.work_dir) printf '%s\n' "$STORED_WORK" ;;
		adguardhome.config.verbose) printf '%s\n' "$STORED_VERBOSE" ;;
		adguardhome.luci.redirect) printf '%s\n' "$STORED_MODE" ;;
		adguardhome.luci.run_from_memory) printf '%s\n' "$RAW_MEMORY" ;;
		adguardhome.luci.memory_writeback_interval) printf '%s\n' "$RAW_INTERVAL" ;;
		*) return 1 ;;
	esac
}
load_settings() {
	count "load:${1:-full}"
	uci_guard_no_delta "$OFFICIAL_CONFIG" || return $?
	service_enabled="$STORED_ENABLED" persistent_work_dir="$STORED_WORK"
	work_dir="$STORED_WORK" verbose="$STORED_VERBOSE" memory_requested="$STORED_RAM"
	redirect_mode="$STORED_MODE" memory_writeback_interval="$STORED_INTERVAL"
	MEMORY_ACTIVE="$RAM_ACTIVE" MEMORY_BACKING_WORK_DIR=/persistent
}
settings_commit_persistent() {
	count commit
	STORED_ENABLED="$1" STORED_WORK="$2" STORED_VERBOSE="$3"
	STORED_MODE="$4" STORED_RAM="$5" STORED_INTERVAL="$6"
	RAW_ENABLED="$1" RAW_CONFIG="$2/AdGuardHome.yaml" RAW_MEMORY="$5" RAW_INTERVAL="$6"
	[ "$DRIFT_AFTER_COMMIT" = 0 ] || BASELINE_OK=0
}
memory_run_with_official_path_guard() {
	count write-guard
	uci_guard_no_delta "$OFFICIAL_CONFIG" || return $?
	"$@"
}
refresh_managed_config_snapshot() {
	count snapshot
	[ "$DRIFT_AFTER_REFRESH" = 0 ] || BASELINE_OK=0
}
core_runtime_matches() {
	count fingerprint
	[ "$BASELINE_OK" = 1 ] && [ "$(call_count fingerprint)" != "$DRIFT_AT_MATCH" ]
}
validate_work_dir_mount_dependency() { [ "$MOUNT_OK" = 1 ]; }
load_runtime_dns_port() { dns_port=53335; }
dns_port_listening() { [ "$SOCKET_OK" = 1 ]; }
integration_matches_desired() { [ "$INTEGRATION_OK" = 1 ]; }
integration_status_locked() { integration_matches_desired; }
wait_for_core_ready() { record ready; }
apply_integration_locked() { record dns; [ "$DNS_APPLY_OK" = 1 ]; }
sync_monitor_instance() { record monitor; }
orchestrate_core_locked() { load_settings; record restart; }
official_running() { return 0; }
yaml_job_runtime_is_private() { return 0; }
yaml_job_pending_matches() { [ "$1:$2:$3" = "$token:$revision:$candidate" ]; }
write_yaml_job_state() { printf '%s\n' "$2" >>"$states"; }
log_error() { :; }
token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for change in unchanged disk interval dns core work ram missing-baseline dead-core fallback unmounted \
             normalized-enabled normalized-interval missing-field drift-after-commit drift-after-refresh \
             dns-final-drift dns-repair-failure; do
	reset_settings_fixture
	requested_work=/persistent requested_verbose=0 requested_ram=1
	requested_mode=dnsmasq-upstream requested_interval=60
	case "$change" in
		disk) STORED_RAM=0 RAW_MEMORY=0 RAM_ACTIVE=0 requested_ram=0 ;;
		interval) requested_interval=120 ;;
		dns) requested_mode=redirect; INTEGRATION_OK=0 ;;
		core) requested_verbose=1 ;;
		work) requested_work=/other ;;
		ram) requested_ram=0 ;;
		missing-baseline) BASELINE_OK=0 ;;
		dead-core) SOCKET_OK=0 ;;
		fallback) RAM_ACTIVE=0 ;;
		unmounted) MOUNT_OK=0 ;;
		normalized-enabled) RAW_ENABLED=yes ;;
		normalized-interval) RAW_INTERVAL=060 ;;
		missing-field) STORED_RAM=0 RAW_MEMORY='' RAM_ACTIVE=0 requested_ram=0 ;;
		drift-after-commit) requested_interval=120 DRIFT_AFTER_COMMIT=1 ;;
		drift-after-refresh) DRIFT_AFTER_REFRESH=1 ;;
		dns-final-drift) requested_mode=redirect INTEGRATION_OK=0 DRIFT_AT_MATCH=2 ;;
		dns-repair-failure) requested_mode=redirect INTEGRATION_OK=0 DNS_APPLY_OK=0 ;;
	esac
	revision="$(settings_values_revision "$STORED_ENABLED" "$STORED_WORK" "$STORED_VERBOSE" \
		"$STORED_MODE" "$STORED_RAM" "$STORED_INTERVAL")"
	candidate="$(settings_values_revision 1 "$requested_work" "$requested_verbose" \
		"$requested_mode" "$requested_ram" "$requested_interval")"
	settings_update_job_locked 1 "$requested_work" "$requested_verbose" \
		"$requested_mode" "$requested_ram" "$requested_interval" "$revision" "$token" "$candidate"
	case "$change" in
		unchanged|disk|interval|normalized-*|missing-field)
			[ "$(cat "$events")" = monitor ]; restarted=0 ;;
		dns) [ "$(cat "$events")" = "$(printf 'ready\ndns\nmonitor')" ]; restarted=0 ;;
		dns-final-drift|dns-repair-failure)
			[ "$(cat "$events")" = "$(printf 'ready\ndns\nrestart')" ]; restarted=1 ;;
		*) [ "$(cat "$events")" = restart ]; restarted=1 ;;
	esac
	[ "$(tail -n 1 "$states")" = "success:${candidate}:${restarted}:${revision}:${candidate}" ]
	assert_count 1 snapshot
	assert_count "$restarted" load:full
	case "$change" in
		core|work|ram|fallback|unmounted) assert_count 2 load:light; assert_count 0 fingerprint ;;
		missing-baseline|dead-core|drift-after-commit|drift-after-refresh)
			assert_count 3 load:light; assert_count 1 fingerprint ;;
		dns|dns-final-drift) assert_count 3 load:light; assert_count 2 fingerprint ;;
		*) assert_count 3 load:light; assert_count 1 fingerprint ;;
	esac
	case "$change" in
		interval|dns|dns-final-drift|dns-repair-failure|core|work|ram|normalized-*|missing-field|drift-after-commit)
			assert_count 1 write-guard; assert_count 1 commit ;;
		*) assert_count 0 write-guard; assert_count 0 commit ;;
	esac
done

# A stale revision or pending edit still fails before runtime repair. A pending
# edit appearing after the raw field reads also cannot authorize the no-op.
for change in stale pending-before-load pending-after-raw; do
	reset_settings_fixture
	revision="$(settings_values_revision 1 /persistent 0 dnsmasq-upstream 1 60)"
	case "$change" in
		stale) revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
		pending-before-load) PENDING_AT_CHECK=1 ;;
		pending-after-raw) PENDING_AT_CHECK=3 ;;
	esac
	if settings_update_locked 1 /persistent 0 dnsmasq-upstream 1 60 "$revision"; then
		printf '%s unexpectedly applied settings\n' "$change" >&2
		exit 1
	fi
	[ ! -s "$events" ]
	assert_count 0 commit
	assert_count 0 fingerprint
	assert_count 0 snapshot
done

# The merged UCI view can look correct while an external DNS edit is still
# pending. Such a view cannot authorize the unchanged-settings shortcut.
(
	eval "$(function_body "$init_file" integration_status_locked)"
	reset_settings_fixture
	revision="$(settings_values_revision 1 /persistent 0 dnsmasq-upstream 1 60)"
	uci_guard_no_delta() { [ "$1" != "$pending_package" ]; }
	apply_integration_locked() { return 1; }
	for pending_package in dhcp firewall; do
		: >"$events"
		settings_update_locked 1 /persistent 0 dnsmasq-upstream 1 60 "$revision"
		grep -qx restart "$events"
		! grep -q '^monitor$' "$events"
	done
)

# A real non-boot prepare->service_started must copy fresh RAM in exactly once,
# never copy it back before the writer has run, and synchronize UCI only once.
for name in prepare_wrapper_locked service_started orchestrate_core_locked; do
	eval "$(function_body "$init_file" "$name")"
done
STORED_ENABLED=1 STORED_WORK=/persistent STORED_RAM=1 RAM_ACTIVE=0
START_PREPARED=1 START_DISABLED=0 WRAPPER_BOOT=0
CORE_RUNNING=0
load_settings() {
	count "startup-load:${1:-full}"
	service_enabled=1 persistent_work_dir=/persistent work_dir=/persistent
	persistent_config_file=/persistent/AdGuardHome.yaml config_file="$persistent_config_file"
	previous_work_dir=/persistent memory_requested=1 MEMORY_ACTIVE="$RAM_ACTIVE"
	MEMORY_BACKING_WORK_DIR=/persistent redirect_mode=dnsmasq-upstream
}
run_locked() { "$@"; }
official_running() { [ "$CORE_RUNNING" = 1 ]; }
clear_recorded_integration_locked() { :; }
wait_for_core_stopped() { CORE_RUNNING=0; }
memory_reconcile_requested_storage_locked() { :; }
memory_copy_stopped_data_locked() { record copy-back; }
ensure_config_file() { record ensure; }
validate_work_dir_mount_dependency() { record mount-check; }
check_core_config() { record check-config; }
sync_yaml_managed_fields_checked() { :; }
memory_prepare_or_fallback_locked() { record copy-in; RAM_ACTIVE=1 MEMORY_ACTIVE=1; }
sync_official_uci() { record uci-sync; }
core_runtime_fingerprint() { printf 'fixture\n'; }
remember_core_runtime() { record baseline; }
wait_for_core_ready() { CORE_RUNNING=1; record ready; }
start_official_core() { "$OFFICIAL_SERVICE" start; }
: >"$events"
: >"$counts"
prepare_wrapper_locked
[ ! -s "$events" ]
: >"$counts"
service_started
[ "$(grep -c '^copy-in$' "$events")" = 1 ]
! grep -q '^copy-back$' "$events"
[ "$(grep -c '^uci-sync$' "$events")" = 1 ]
[ "$(grep -c '^check-config$' "$events")" = 1 ]
assert_count 1 startup-load:full
grep -qx baseline "$events"

# Failure to retain this optimization record never turns a ready core into
# a failed activation or cancels its working DNS takeover.
remember_core_runtime() { return 1; }
orchestrate_core_locked
[ "$CORE_RUNNING" = 1 ]

# Bootstrap still checks YAML and restores DNS before its interface-up event,
# without creating a RAM generation or committing the official definition.
WRAPPER_BOOT=1 RAM_ACTIVE=0 CORE_RUNNING=0
clear_recorded_integration_locked() { record cleanup; }
: >"$events"
prepare_wrapper_locked
[ "$(cat "$events")" = "$(printf 'cleanup\nensure\ncheck-config')" ]
printf 'ok - runtime drift guard, selective settings apply and one stopped-core preparation\n'
