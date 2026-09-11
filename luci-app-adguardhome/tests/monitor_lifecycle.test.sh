#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

# Execute the real lifecycle entry points without launching a core or monitor.
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in record_ready_core_runtime declare_monitor_instance sync_monitor_instance start_service service_triggers \
	orchestrate_core_locked reconcile_core_locked monitor_interval_locked; do
	eval "$(function_body "$init_file" "$name")"
done

initscript=/etc/init.d/AdGuardHome
OFFICIAL_SERVICE=/bin/true
TEST_ENABLED=0
TEST_RUNNING=0
TEST_RAM=0
TEST_MODE=dnsmasq-upstream
TEST_BACKING=/etc/AdGuardHome
TEST_COMMIT_FAIL=0
PREPARE_CALLS=0
CORE_STARTS=0
MONITOR_STARTS=0
MONITOR_PID=0
LIVE_DEFINITION=""
TX_DEFINITION=""
printf '\n' >"$test_tmp/definition"
printf '0 0\n' >"$test_tmp/monitor-state"

load_settings() {
	service_enabled="$TEST_ENABLED"
	persistent_work_dir=/etc/AdGuardHome
	persistent_config_file="$persistent_work_dir/AdGuardHome.yaml"
	work_dir="$persistent_work_dir"
	config_file="$persistent_config_file"
	previous_work_dir="$persistent_work_dir"
	MEMORY_ACTIVE="$TEST_RAM"
	MEMORY_BACKING_WORK_DIR="$TEST_BACKING"
	memory_requested="$TEST_RAM"
	memory_writeback_interval=60
	redirect_mode="$TEST_MODE"
	MONITOR_SETTINGS_READY=1
}
prepare_yaml_job_runtime() { return 0; }
prepare_wrapper_locked() {
	PREPARE_CALLS=$((PREPARE_CALLS + 1))
	load_settings
	[ "$service_enabled" = 1 ] || return 2
}
run_locked() { "$@"; }
clear_recorded_integration_locked() { return 0; }
official_running() { [ "$TEST_RUNNING" = 1 ]; }
wait_for_core_stopped() { TEST_RUNNING=0; }
wait_for_core_ready() { TEST_RUNNING=1; CORE_STARTS=$((CORE_STARTS + 1)); }
memory_copy_stopped_data_locked() { return 0; }
memory_deactivate_locked() { TEST_RAM=0; MEMORY_ACTIVE=0; }
memory_reconcile_requested_storage_locked() { TEST_BACKING="$persistent_work_dir"; }
ensure_config_file() { return 0; }
start_official_core() { "$OFFICIAL_SERVICE" start; }
validate_work_dir_mount_dependency() { return 0; }
check_core_config() { return 0; }
core_runtime_fingerprint() { printf 'fixture\n'; }
remember_core_runtime() { return 0; }
sync_yaml_managed_fields_checked() { return 0; }
memory_prepare_or_fallback_locked() { MEMORY_BACKING_WORK_DIR="$persistent_work_dir"; }
load_runtime_dns_port() { dns_port=53335; }
official_socket_snapshot() { return 0; }
sync_official_uci() { return 0; }
apply_integration_locked() { return 0; }
dns_port_listening() { return 0; }
integration_matches_desired() { return 0; }
fail_safe_locked() { return 0; }
log_error() { printf '%s\n' "$*" >&2; }

# Model procd's name-keyed set: an identical instance declaration keeps its PID.
procd_open_service() {
	[ "$*" = "AdGuardHome $initscript" ] || return 1
	TX_DEFINITION=""
	TX_TRIGGERS=""
}
procd_open_instance() {
	[ "$*" = monitor ] && [ -z "$TX_DEFINITION" ] || return 1
	TX_DEFINITION=monitor
}
procd_set_param() { TX_DEFINITION="${TX_DEFINITION}|$*"; }
procd_close_instance() { return 0; }
read_monitor_state() {
	IFS= read -r LIVE_DEFINITION <"$test_tmp/definition"
	read -r MONITOR_STARTS MONITOR_PID <"$test_tmp/monitor-state"
}
commit_monitor_definition() {
	[ "$TEST_COMMIT_FAIL" = 0 ] || return 1
	read_monitor_state
	if [ "$TX_DEFINITION" != "$LIVE_DEFINITION" ]; then
		LIVE_DEFINITION="$TX_DEFINITION"
		MONITOR_PID=0
		if [ -n "$LIVE_DEFINITION" ]; then
			MONITOR_STARTS=$((MONITOR_STARTS + 1))
			MONITOR_PID="$MONITOR_STARTS"
		fi
	fi
	printf '%s\n' "$LIVE_DEFINITION" >"$test_tmp/definition"
	printf '%s %s\n' "$MONITOR_STARTS" "$MONITOR_PID" >"$test_tmp/monitor-state"
}
# The platform helper masks ubus failure during JSON cleanup. Apply must use
# its direct checked submission rather than inherit this return-status loss.
procd_close_service() { commit_monitor_definition || true; }
json_set_namespace() { [ "$*" = procd ]; }
json_close_object() { return 0; }
json_add_array() { [ "$*" = triggers ]; }
json_close_array() { return 0; }
procd_add_raw_trigger() { TX_TRIGGERS="$*"; }
json_dump() {
	[ "$TX_TRIGGERS" = "interface.*.up 5000 $initscript network_ready" ] || return 1
	printf '%s\n' "$TX_DEFINITION"
}
ubus() {
	[ "$1 $2 $3" = 'call service set' ] || return 1
	TX_DEFINITION="$4"
	commit_monitor_definition
}

# rc.common opens/closes the service transaction around start_service().
procd_open_service AdGuardHome "$initscript"
start_service
procd_close_service
[ "$START_PREPARED:$START_DISABLED:$MONITOR_PID:$PREPARE_CALLS" = 1:1:0:1 ]

TEST_ENABLED=1
orchestrate_core_locked
read_monitor_state
expected="monitor|command $initscript monitor|stdout 1|stderr 1|respawn 3600 5 0|term_timeout 5"
[ "$LIVE_DEFINITION" = "$expected" ]
[ "$MONITOR_STARTS:$MONITOR_PID:$CORE_STARTS" = 1:1:1 ]
orchestrate_core_locked
read_monitor_state
[ "$MONITOR_STARTS:$MONITOR_PID:$CORE_STARTS" = 1:1:2 ]

# Enabled start and monitor-initiated RAM/workdir reconciliation must submit
# exactly the same definition, without a second instance or self-restart.
procd_open_service AdGuardHome "$initscript"
start_service
procd_close_service
[ "$LIVE_DEFINITION" = "$expected" ]
[ "$START_PREPARED:$START_DISABLED:$MONITOR_STARTS:$MONITOR_PID" = 1:0:1:1 ]
TEST_RAM=1
TEST_BACKING=/etc/AdGuardHome-old
monitor_interval_locked >"$test_tmp/interval"
read_monitor_state
[ "$(cat "$test_tmp/interval")" = 60 ]
[ "$LIVE_DEFINITION" = "$expected" ]
[ "$MONITOR_STARTS:$MONITOR_PID:$CORE_STARTS" = 1:1:3 ]

TEST_ENABLED=0
orchestrate_core_locked
read_monitor_state
[ "$TEST_RUNNING:$MONITOR_PID:$MONITOR_STARTS" = 0:0:1 ]
[ -z "$LIVE_DEFINITION" ]
TEST_ENABLED=1
orchestrate_core_locked
read_monitor_state
[ "$MONITOR_STARTS:$MONITOR_PID" = 2:2 ]
TEST_ENABLED=0
reconcile_core_locked
read_monitor_state
[ "$TEST_RUNNING:$MONITOR_PID:$MONITOR_STARTS" = 0:0:2 ]
[ -z "$LIVE_DEFINITION" ]

# A failed monitor submission must fail both direct apply paths and disabled
# reconciliation. The existing active declaration must not be changed on failure.
TEST_ENABLED=1
orchestrate_core_locked
TEST_COMMIT_FAIL=1
for action in enabled-apply disabled-apply disabled-reconcile; do
	case "$action" in enabled-apply) TEST_ENABLED=1 ;; *) TEST_ENABLED=0 ;; esac
	rc=0
	case "$action" in
		disabled-reconcile) reconcile_core_locked || rc=$? ;;
		*) orchestrate_core_locked || rc=$? ;;
	esac
	[ "$rc" = 1 ] || { printf 'monitor commit failure was ignored: %s\n' "$action" >&2; exit 1; }
	read_monitor_state
	[ "$LIVE_DEFINITION" = "$expected" ] && [ "$MONITOR_STARTS:$MONITOR_PID" = 3:3 ]
done

# Exercise the real preparation result across a subshell, as run_locked does.
# No parent settings variables may be needed to select the monitor definition.
(
	for name in prepare_wrapper_locked service_started stop_wrapper_locked; do
		eval "$(function_body "$init_file" "$name")"
	done
	run_locked() ( "$@"; )
	check_core_config() { return 0; }
	memory_discard_incomplete_runtime_locked() { return 0; }
	events="$test_tmp/idle-monitor-events"
	clear_recorded_integration_locked() { printf 'cleanup\n' >>"$events"; }
	wait_for_core_ready() { printf 'start\n' >>"$events"; }
	wait_for_core_stopped() { TEST_RUNNING=0; printf 'stop\n' >>"$events"; }
	TEST_COMMIT_FAIL=0
	TEST_ENABLED=1
	TEST_RUNNING=0
	TEST_BACKING=/etc/AdGuardHome
	for TEST_MODE in dnsmasq-upstream redirect none; do
		for TEST_RAM in 0 1; do
			unset service_enabled redirect_mode memory_requested
			: >"$events"
			procd_open_service AdGuardHome "$initscript"
			start_service
			[ "$START_PREPARED:$START_DISABLED" = 1:0 ]
			if [ "$TEST_MODE:$TEST_RAM" = none:0 ]; then
				[ -z "$TX_DEFINITION" ]
				# Withdraw old DNS takeover before removing its monitor.
				grep -qx cleanup "$events"
			else
				[ "$TX_DEFINITION" = "$expected" ]
			fi
			procd_close_service
			service_started
			read_monitor_state
			grep -qx start "$events"
			grep -qx cleanup "$events"
			if [ "$TEST_MODE:$TEST_RAM" = none:0 ]; then
				[ -z "$LIVE_DEFINITION" ] && [ "$MONITOR_PID" = 0 ]
			else
				[ "$LIVE_DEFINITION" = "$expected" ] && [ "$MONITOR_PID" -gt 0 ]
			fi
		done
	done
	# A service without a monitor still runs its normal core-stop/cleanup hook.
	TEST_MODE=none TEST_RAM=0 TEST_RUNNING=1
	: >"$events"
	run_locked stop_wrapper_locked 0
	[ "$(cat "$events")" = "$(printf 'cleanup\nstop')" ]
)

# Apply/reload also repairs independent official autostart. Failure must leave
# the running core untouched rather than continue to cleanup/stop/start.
(
	eval "$(function_body "$init_file" reload_service)"
	OFFICIAL_SERVICE="$test_tmp/official"
	export MONITOR_TEST_OFFICIAL_LOG="$test_tmp/official-events" MONITOR_TEST_FAILURE=""
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$1" >>"$MONITOR_TEST_OFFICIAL_LOG"' \
		'[ "$MONITOR_TEST_FAILURE" != "$1" ]' >"$OFFICIAL_SERVICE"
	chmod 0755 "$OFFICIAL_SERVICE"
	clear_recorded_integration_locked() { printf 'cleanup\n' >>"$MONITOR_TEST_OFFICIAL_LOG"; }
	TEST_ENABLED=1 TEST_RUNNING=1 TEST_RAM=0 TEST_MODE=dnsmasq-upstream TEST_COMMIT_FAIL=0
	for action in orchestrate_core_locked reload_service; do
		: >"$MONITOR_TEST_OFFICIAL_LOG"
		MONITOR_TEST_FAILURE=""
		"$action"
		[ "$(cat "$MONITOR_TEST_OFFICIAL_LOG")" = "$(printf 'disable\ncleanup\nstop\nstart')" ]
		: >"$MONITOR_TEST_OFFICIAL_LOG"
		MONITOR_TEST_FAILURE=disable
		previous_starts="$CORE_STARTS"
		if "$action"; then exit 1; fi
		[ "$(cat "$MONITOR_TEST_OFFICIAL_LOG")" = disable ]
		[ "$TEST_RUNNING:$CORE_STARTS" = "1:$previous_starts" ]
	done
)

printf 'ok - monitor duty selection, core start/stop, identical declarations and failed submission propagation\n'
