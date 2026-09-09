#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
init_file="$package_dir/root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d /tmp/luci-agh-apk-commit.XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

# Run the real functions, including snapshot ownership checks, on private
# fixtures. No package manager, router service or system configuration is used.
[ "$(id -u):$(id -g)" = 0:0 ] || {
	printf 'apk_commit.test.sh requires root for private-state checks\n' >&2
	exit 1
}
awk -v helper_dir="$package_dir/scripts" -f "$package_dir/scripts/expand-helpers.awk" \
	"$init_file" >"$test_tmp/init.sh"
. "$script_dir/lib/function-body.sh"
for name in entry_metadata root_private_directory root_private_file bounded_private_file \
	yaml_job_runtime_is_private yaml_job_lock_file_is_private prepare_yaml_job_runtime \
	core_package_fingerprint apk_reconcile_locked apk_commit network_ready service_triggers; do
	eval "$(function_body "$test_tmp/init.sh" "$name")"
done

CORE_BINARY="$test_tmp/core"
OFFICIAL_SERVICE="$test_tmp/official"
YAML_JOB_RUNTIME_DIR="$test_tmp/runtime"
NORMALIZER_RUNTIME_DIR="$test_tmp/normalizer"
PLUGIN_CONFIG=adguardhome OFFICIAL_CONFIG=adguardhome OFFICIAL_SECTION=config
initscript=/etc/init.d/AdGuardHome
snapshot="$NORMALIZER_RUNTIME_DIR/apk-core-before"
events="$test_tmp/events"
logs="$test_tmp/logs"
export APK_TEST_EVENTS="$events" APK_TEST_FAILURE=""
printf 'core version 1\n' >"$CORE_BINARY"
printf '%s\n' '#!/bin/sh' 'printf "official:%s\n" "$1" >>"$APK_TEST_EVENTS"' \
	'[ "$APK_TEST_FAILURE" != "$1" ]' >"$OFFICIAL_SERVICE"
chmod 0755 "$OFFICIAL_SERVICE"

record() { printf '%s\n' "$*" >>"$events"; }
log_error() { printf '%s\n' "$*" >>"$logs"; }
uci_guard_no_delta() { [ "$*" = adguardhome ] && [ "$APK_TEST_FAILURE" != guard ]; }
config_load() { [ "$*" = adguardhome ] && [ "$APK_TEST_FAILURE" != config ]; }
validate_loaded_merged_sections() { [ "$APK_TEST_FAILURE" != sections ]; }
config_get_bool() { [ "$*" = 'service_enabled config enabled 0' ]; service_enabled="$TEST_ENABLED"; }
official_running() { [ "$TEST_RUNNING" = 1 ]; }
# An unrelated APK transaction must not load YAML, inspect RAM or touch DNS.
load_settings() { record unexpected-full-settings-load; return 1; }
orchestrate_core_locked() { record orchestrate; [ "$APK_TEST_FAILURE" != orchestrate ]; }
stop_wrapper_locked() { record "stop-wrapper:$*"; [ "$APK_TEST_FAILURE" != stop ]; }
sync_monitor_instance() { record monitor; [ "$APK_TEST_FAILURE" != monitor ]; }
run_locked() {
	record "locked:$*"
	[ "$APK_TEST_FAILURE" != lock ] || return 1
	"$@"
}
reset_events() { : >"$events"; : >"$logs"; APK_TEST_FAILURE=""; }
replace_file() {
	# Rename a same-content, same-mtime file to model APK's reinstall behavior.
	cp -p "$1" "$1.new"
	mv -f "$1.new" "$1"
}
assert_events() {
	[ "$(cat "$events")" = "$1" ] || {
		printf 'unexpected APK/lifecycle events:\n' >&2
		cat "$events" >&2
		exit 1
	}
}

# Upgrade, same-version reinstall and init-script-only replacement all count
# as core-package changes, regardless of the configured enabled state.
for change in upgrade reinstall script-only; do
	for TEST_ENABLED in 0 1; do
		TEST_RUNNING="$TEST_ENABLED"
		reset_events
		apk_commit pre-commit
		assert_events ''
		root_private_file "$snapshot"
		case "$change" in
			upgrade) printf 'next version\n' >>"$CORE_BINARY" ;;
			reinstall) replace_file "$CORE_BINARY" ;;
			script-only) replace_file "$OFFICIAL_SERVICE" ;;
		esac
		apk_commit post-commit
		[ ! -e "$snapshot" ]
		if [ "$TEST_ENABLED" = 1 ]; then
			assert_events "$(printf 'locked:apk_reconcile_locked 1\nofficial:disable\norchestrate')"
		else
			assert_events "$(printf 'locked:apk_reconcile_locked 1\nofficial:disable\nstop-wrapper:0\nmonitor')"
		fi
		grep -qx "Reconciled AdGuard Home service (enabled $TEST_ENABLED)" "$logs"
	done
done

# Matching enabled/running state repairs independent autostart without loading
# settings or restarting the core. Mismatched state is repaired on first install.
for TEST_ENABLED in 0 1; do
	TEST_RUNNING="$TEST_ENABLED"
	reset_events
	apk_commit pre-commit
	apk_commit post-commit
	assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable')"
	[ ! -s "$logs" ]
	TEST_RUNNING=$((1 - TEST_ENABLED))
	reset_events
	apk_commit post-commit
	if [ "$TEST_ENABLED" = 1 ]; then
		assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable\norchestrate')"
	else
		assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable\nstop-wrapper:0\nmonitor')"
	fi
done

# A new pre-commit replaces interrupted state, without taking the service lock.
TEST_ENABLED=1 TEST_RUNNING=1
reset_events
apk_commit pre-commit
replace_file "$CORE_BINARY"
apk_commit pre-commit
[ "$(cat "$snapshot")" = "$(core_package_fingerprint)" ]
assert_events ''
apk_commit post-commit
assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable')"

# Autostart repair is still mandatory for unchanged packages and a healthy
# core. A failed disable must not be hidden by the no-restart fast path.
for TEST_ENABLED in 0 1; do
	TEST_RUNNING="$TEST_ENABLED"
	reset_events
	apk_commit pre-commit
	APK_TEST_FAILURE=disable
	if apk_commit post-commit; then exit 1; fi
	assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable')"
	root_private_file "$snapshot"
	grep -qx 'Unable to reconcile AdGuard Home after the APK transaction' "$logs"
	! grep -q '^Reconciled ' "$logs"
done

# Each failed reconciliation stays visibly failed and preserves the snapshot
# for diagnosis/retry; neither a success log nor snapshot removal may mask it.
for failure in guard config sections disable orchestrate stop monitor lock; do
	reset_events
	TEST_ENABLED=1 TEST_RUNNING=1
	case "$failure" in stop|monitor) TEST_ENABLED=0 TEST_RUNNING=0 ;; esac
	apk_commit pre-commit
	replace_file "$CORE_BINARY"
	APK_TEST_FAILURE="$failure"
	if apk_commit post-commit; then
		printf 'APK reconciliation ignored %s failure\n' "$failure" >&2
		exit 1
	fi
	root_private_file "$snapshot"
	grep -qx 'Unable to reconcile AdGuard Home after the APK transaction' "$logs"
	! grep -q '^Reconciled ' "$logs"
done

# A stale unsafe snapshot must never be followed or overwritten.
reset_events
rm -f "$snapshot"
printf 'keep me\n' >"$test_tmp/unrelated"
ln -s "$test_tmp/unrelated" "$snapshot"
if apk_commit pre-commit; then exit 1; fi
[ "$(cat "$test_tmp/unrelated")" = 'keep me' ]
assert_events ''
rm -f "$snapshot"
if apk_commit invalid-phase; then exit 1; fi

# A missing package file must not block apk fix: record its absence, then
# recognize the repaired file as a change at post-commit.
for missing_path in "$CORE_BINARY" "$OFFICIAL_SERVICE"; do
	reset_events
	TEST_ENABLED=1 TEST_RUNNING=0
	mv "$missing_path" "$missing_path.missing"
	apk_commit pre-commit
	grep -Fxq "missing $missing_path" "$snapshot"
	assert_events ''
	mv "$missing_path.missing" "$missing_path"
	apk_commit post-commit
	assert_events "$(printf 'locked:apk_reconcile_locked 1\nofficial:disable\norchestrate')"
	[ ! -e "$snapshot" ]
done

# An actual metadata read error is different from absence and must not be
# turned into a successful transaction or replace a known-good snapshot.
reset_events
apk_commit pre-commit
previous_snapshot="$(cat "$snapshot")"
(
	ls() {
		[ "$*" != "-lni $CORE_BINARY" ] || return 1
		command ls "$@"
	}
	for phase in pre-commit post-commit; do
		if apk_commit "$phase"; then exit 1; fi
		[ "$(cat "$snapshot")" = "$previous_snapshot" ]
		assert_events ''
		[ ! -s "$logs" ]
	done
)
rm -f "$snapshot"

# The native interface trigger retries only while the coordinator still has
# a procd object; a queued event after a manual stop cannot resurrect it.
procd_add_raw_trigger() { record "trigger:$*"; }
reset_events
service_triggers
assert_events "trigger:interface.*.up 5000 $initscript network_ready"
ubus() { [ "$*" = '-S call service list {"name":"AdGuardHome"}' ]; printf '%s\n' "$TEST_COORDINATOR"; }
jsonfilter() { [ "$*" = '-e @.AdGuardHome' ]; sed '/^$/d'; }
TEST_ENABLED=1 TEST_RUNNING=0 TEST_COORDINATOR='{}'
reset_events
network_ready
assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable\norchestrate')"
for TEST_ENABLED in 0 1; do
	TEST_RUNNING="$TEST_ENABLED"
	reset_events
	network_ready
	assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable')"
done
TEST_COORDINATOR=''
reset_events
network_ready
assert_events ''

# Boot prepares before netifd, then the native interface event starts the core.
# Manual start orchestrates directly. Disk shutdown stops/waits like RAM mode.
(
	for name in start_service service_started stop_wrapper_locked boot; do
		eval "$(function_body "$init_file" "$name")"
	done
	grep -qx START=18 "$init_file"
	prepare_wrapper_locked() { record prepare; [ "$TEST_ENABLED" = 1 ] || return 2; }
	declare_monitor_instance() { record declare-monitor; }
	fail_safe_locked() { record fail-safe; }
	start() { start_service && service_started; }
	for action in start boot; do
		for TEST_ENABLED in 0 1; do
			reset_events
			WRAPPER_BOOT=0
			"$action"
			if [ "$TEST_ENABLED" = 1 ]; then
				if [ "$action" = boot ]; then
					assert_events "$(printf 'official:disable\nlocked:prepare_wrapper_locked\nprepare\ndeclare-monitor')"
					TEST_COORDINATOR='{}' TEST_RUNNING=0
					reset_events
					network_ready
					assert_events "$(printf 'locked:apk_reconcile_locked 0\nofficial:disable\norchestrate')"
				else
					assert_events "$(printf 'official:disable\nlocked:prepare_wrapper_locked\nprepare\ndeclare-monitor\nlocked:orchestrate_core_locked\norchestrate')"
				fi
			else
				assert_events "$(printf 'official:disable\nlocked:prepare_wrapper_locked\nprepare')"
			fi
		done
	done
	reset_events
	TEST_ENABLED=1 WRAPPER_BOOT=0 APK_TEST_FAILURE=disable
	if start_service; then exit 1; fi
	[ "$START_PREPARED:$START_DISABLED" = 0:0 ]
	assert_events 'official:disable'
	if service_started; then exit 1; fi
	! grep -qx orchestrate "$events"
	! grep -qx 'AdGuard Home coordinator started' "$logs"

	load_settings() { MEMORY_ACTIVE="$TEST_RAM"; }
	clear_recorded_integration_locked() { record cleanup; }
	wait_for_core_stopped() { record wait-stopped; TEST_RUNNING=0; [ "$APK_TEST_FAILURE" != wait ]; }
	memory_deactivate_locked() { record deactivate; }
	for shutdown_mode in 0 1; do
		for TEST_RAM in 0 1; do
			for TEST_RUNNING in 0 1; do
				reset_events
				stop_wrapper_locked "$shutdown_mode"
				[ "$(grep -cx official:stop "$events")" = 1 ]
				grep -qx wait-stopped "$events"
				[ "$TEST_RUNNING" = 0 ]
				[ "$TEST_RAM" = 0 ] || grep -qx deactivate "$events"
			done
		done
	done
	for failure in stop wait; do
		reset_events
		TEST_RUNNING=1 TEST_RAM=1 APK_TEST_FAILURE="$failure"
		if stop_wrapper_locked 1; then exit 1; fi
		! grep -qx deactivate "$events"
	done
)

printf 'ok - APK fingerprints, private snapshots, reconciliation failures, network retries and unified start/stop\n'
