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
revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STORED_ENABLED=1 STORED_WORK=/persistent STORED_VERBOSE=0 STORED_RAM=1
STORED_MODE=dnsmasq-upstream STORED_INTERVAL=60
BASELINE_OK=1 SOCKET_OK=1 INTEGRATION_OK=1 RAM_ACTIVE=1
load_settings() {
	service_enabled="$STORED_ENABLED" persistent_work_dir="$STORED_WORK"
	work_dir="$STORED_WORK" verbose="$STORED_VERBOSE" memory_requested="$STORED_RAM"
	redirect_mode="$STORED_MODE" memory_writeback_interval="$STORED_INTERVAL"
	MEMORY_ACTIVE="$RAM_ACTIVE" MEMORY_BACKING_WORK_DIR=/persistent
}
settings_current_revision() { printf '%s\n' "$revision"; }
settings_commit_persistent() {
	STORED_ENABLED="$1" STORED_WORK="$2" STORED_VERBOSE="$3"
	STORED_MODE="$4" STORED_RAM="$5" STORED_INTERVAL="$6"
}
memory_run_with_official_path_guard() { "$@"; }
refresh_managed_config_snapshot() { :; }
core_runtime_matches() { [ "$BASELINE_OK" = 1 ]; }
validate_work_dir_mount_dependency() { [ "$MOUNT_OK" = 1 ]; }
load_runtime_dns_port() { dns_port=53335; }
dns_port_listening() { [ "$SOCKET_OK" = 1 ]; }
integration_matches_desired() { [ "$INTEGRATION_OK" = 1 ]; }
integration_status_locked() { integration_matches_desired; }
wait_for_core_ready() { record ready; }
apply_integration_locked() { record dns; }
sync_monitor_instance() { record monitor; }
orchestrate_core_locked() { record restart; }
log_error() { :; }
for change in unchanged disk interval dns core work ram missing-baseline dead-core fallback unmounted; do
	STORED_ENABLED=1 STORED_WORK=/persistent STORED_VERBOSE=0 STORED_RAM=1
	STORED_MODE=dnsmasq-upstream STORED_INTERVAL=60
	BASELINE_OK=1 SOCKET_OK=1 INTEGRATION_OK=1 RAM_ACTIVE=1 MOUNT_OK=1
	requested_work=/persistent requested_verbose=0 requested_ram=1
	requested_mode=dnsmasq-upstream requested_interval=60
	case "$change" in
		disk) STORED_RAM=0 RAM_ACTIVE=0 requested_ram=0 ;;
		interval) requested_interval=120 ;;
		dns) requested_mode=redirect; INTEGRATION_OK=0 ;;
		core) requested_verbose=1 ;;
		work) requested_work=/other ;;
		ram) requested_ram=0 ;;
		missing-baseline) BASELINE_OK=0 ;;
		dead-core) SOCKET_OK=0 ;;
		fallback) RAM_ACTIVE=0 ;;
		unmounted) MOUNT_OK=0 ;;
	esac
	: >"$events"
	settings_update_locked 1 "$requested_work" "$requested_verbose" \
		"$requested_mode" "$requested_ram" "$requested_interval" "$revision"
	case "$change" in
		unchanged|disk|interval) [ "$(cat "$events")" = monitor ] && [ "$SETTINGS_CORE_RESTARTED" = 0 ] ;;
		dns) [ "$(cat "$events")" = "$(printf 'ready\ndns\nmonitor')" ] && [ "$SETTINGS_CORE_RESTARTED" = 0 ] ;;
		*) [ "$(cat "$events")" = restart ] && [ "$SETTINGS_CORE_RESTARTED" = 1 ] ;;
	esac
done

# The merged UCI view can look correct while an external DNS edit is still
# pending. Such a view cannot authorize the unchanged-settings shortcut.
(
	eval "$(function_body "$init_file" integration_status_locked)"
	STORED_ENABLED=1 STORED_WORK=/persistent STORED_VERBOSE=0 STORED_RAM=1
	STORED_MODE=dnsmasq-upstream STORED_INTERVAL=60
	BASELINE_OK=1 SOCKET_OK=1 INTEGRATION_OK=1 RAM_ACTIVE=1 MOUNT_OK=1
	uci() {
		case "$1:$2" in
			-q:export) return 0 ;;
			-q:get) printf '%s\n' "$STORED_MODE" ;;
			*) return 1 ;;
		esac
	}
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
prepare_wrapper_locked
[ ! -s "$events" ]
service_started
[ "$(grep -c '^copy-in$' "$events")" = 1 ]
! grep -q '^copy-back$' "$events"
[ "$(grep -c '^uci-sync$' "$events")" = 1 ]
[ "$(grep -c '^check-config$' "$events")" = 1 ]
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
