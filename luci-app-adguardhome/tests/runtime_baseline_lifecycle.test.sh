#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="$script_dir/../root/etc/init.d/AdGuardHome"
. "$script_dir/lib/function-body.sh"
eval "$(init_source "$init_file")"
temporary="$(mktemp -d /tmp/agh-baseline-lifecycle.XXXXXX)"
work_dir="$temporary/work"
config_file="$work_dir/AdGuardHome.yaml"
NORMALIZER_RUNTIME_DIR="$temporary/runtime"
CORE_BINARY="$temporary/core"
OFFICIAL_SERVICE="$temporary/service"
mkdir -m 0700 "$work_dir" "$NORMALIZER_RUNTIME_DIR"
mkdir "$work_dir/data"
printf 'core\n' >"$CORE_BINARY"
printf '#!/bin/sh\nexit 0\n' >"$OFFICIAL_SERVICE"
chmod 0700 "$OFFICIAL_SERVICE"
printf 'dns:\n  port: 53335\ntls:\n  enabled: false\n' >"$config_file"
events="$temporary/events"
: >"$events"
pids=''
cleanup() {
	for test_pid in $pids; do kill "$test_pid" 2>/dev/null || true; done
	rm -rf "$temporary"
}
trap cleanup EXIT

STORED_INTERVAL=60 STORED_MODE=none CORE_RUNNING=0
load_settings() {
	service_enabled=1 persistent_work_dir="$temporary/work" work_dir="$temporary/work"
	config_file="$work_dir/AdGuardHome.yaml" verbose=0 memory_requested=0 MEMORY_ACTIVE=0
	redirect_mode="$STORED_MODE" memory_writeback_interval="$STORED_INTERVAL"
}
load_settings
uci() {
	case "$*" in
		'-q show adguardhome.config') printf 'config adguardhome config; gc=100\n' ;;
		'-q get adguardhome.luci.managed_tls_fingerprint') printf '%s\n' "$TLS_STORED" ;;
		*) return 1 ;;
	esac
}
official_pid() { printf '%s\n' "$current_pid"; }
official_running() { [ "$CORE_RUNNING" = 1 ]; }
wait_for_core_stopped() { CORE_RUNNING=0; }
start_official_core() {
	sleep 300 >/dev/null 2>&1 & current_pid=$!
	pids="$pids $current_pid"
	CORE_RUNNING=1
	printf 'start\n' >>"$events"
	# Canonical serialization replaces the inode, preserving the staged FD.
	if [ "${CANONICALIZE:-0}" = 1 ]; then
		cp "$config_file" "$work_dir/canonical"
		printf '# canonical\n' >>"$work_dir/canonical"
		mv "$work_dir/canonical" "$config_file"
	fi
}
snapshot_config_file() {
	cp "$1" "$2"
	SNAPSHOT_CONFIG_HASH="$(yaml_file_hash "$2")"
	[ -z "${3:-}" ] || [ "$SNAPSHOT_CONFIG_HASH" = "$3" ]
}
active_config_hash() { yaml_file_hash "$config_file"; }
held_config_hash() {
	local digest
	digest="$(sha256sum "/proc/self/fd/$2")" || return 1
	printf '%s\n' "${digest%% *}"
}
validate_work_dir_mount_dependency() { :; }
validate_yaml_stage() { :; }
check_core_config_file() {
	[ "$1" != "${stage:-}" ] || printf 'check-stage\n' >>"$events"
	TLS_DESIRED_MOUNTS=''
}
secure_config_inode() { :; }
secure_active_paths() { :; }
load_runtime_dns_port() { dns_port=53335; }
sync_official_uci() { :; }
clear_recorded_integration_locked() { return "${CLEAR_RC:-0}"; }
wait_for_core_ready() { return "${READY_RC:-0}"; }
apply_integration_locked() { return "${APPLY_RC:-0}"; }
runtime_settings_match() { :; }
dns_port_listening() { :; }
log_error() { :; }

# Keep the real baseline methods, PID identity, filesystem and Apply decision.
settings_current_revision() {
	settings_values_revision 1 "$work_dir" 0 "$STORED_MODE" 0 "$STORED_INTERVAL"
}
settings_persistent_matches() { [ "$4:$6" = "$STORED_MODE:$STORED_INTERVAL" ]; }
memory_run_with_official_path_guard() { "$@"; }
settings_commit_persistent() { STORED_MODE="$4"; STORED_INTERVAL="$6"; }
refresh_managed_config_snapshot() { :; }
integration_status_locked() { :; }
sync_monitor_instance() { printf 'monitor\n' >>"$events"; }
orchestrate_core_locked() { printf 'restart\n' >>"$events"; }
assert_light_apply() {
	local operation requested_interval requested_mode revision
	for operation in unchanged interval dns; do
		STORED_INTERVAL=60 STORED_MODE=none
		requested_interval=60 requested_mode=none
		case "$operation" in interval) requested_interval=120 ;; dns) requested_mode=redirect ;; esac
		revision="$(settings_current_revision)"
		: >"$events"
		settings_update_locked 1 "$work_dir" 0 "$requested_mode" 0 "$requested_interval" "$revision"
		[ "$(cat "$events")" = monitor ] && [ "$SETTINGS_CORE_RESTARTED" = 0 ]
	done
}

start_official_core
baseline="$(core_runtime_fingerprint)"
remember_core_runtime "$baseline"
initial_pid="$current_pid"
record_before="$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")"
expected_hash="$(yaml_file_hash "$config_file")"
stage="$work_dir/.AdGuardHome.yaml-stage"
printf 'dns:\n  port: 53335\ntls:\n  enabled: false\nusers: []\n' >"$stage"
candidate_hash="$(yaml_file_hash "$stage")"
exec 9<"$stage"
CANONICALIZE=1
yaml_update_locked "$expected_hash" "$candidate_hash" "$stage" 9
trap cleanup EXIT
exec 9<&-
[ "$current_pid" != "$initial_pid" ]
[ "$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")" != "$record_before" ]
[ "$(grep -c '^check-stage$' "$events")" = 1 ]
core_runtime_matches
assert_light_apply

# The resumed core reads unchanged, already validated inputs. An already-live
# core must retain its old baseline if the current files have not been loaded.
CANONICALIZE=0
CORE_RUNNING=0
resume_core_and_dns
core_runtime_matches
assert_light_apply
record_before="$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")"
printf '# not loaded by the live core\n' >>"$config_file"
resume_core_and_dns
[ "$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")" = "$record_before" ]
! core_runtime_matches

# Failures before readiness or DNS completion cannot publish a new baseline.
for failure in ready dns; do
	CORE_RUNNING=0 READY_RC=0 APPLY_RC=0
	case "$failure" in ready) READY_RC=1 ;; dns) APPLY_RC=1 ;; esac
	if resume_core_and_dns; then exit 1; fi
	[ "$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")" = "$record_before" ]
done
READY_RC=0 APPLY_RC=0

# ACME renewals use the same successful-start record boundary.
TLS_STORED=old
load_active_tls_access() { TLS_USES_ACME=1; }
check_core_config() { :; }
sync_tls_access() { TLS_STORED=new; }
coordinator_present() { return 0; }
tls_refresh_locked
core_runtime_matches
assert_light_apply

# A baseline write failure is nonfatal and does not accept unrecorded inputs.
remember_core_runtime() { return 1; }
record_before="$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")"
CORE_RUNNING=0
resume_core_and_dns
[ "$CORE_RUNNING" = 1 ]
[ "$(cat "$NORMALIZER_RUNTIME_DIR/applied-runtime")" = "$record_before" ]
! core_runtime_matches
printf 'ok - YAML canonical save, recovery and ACME preserve lightweight subsequent Apply\n'
