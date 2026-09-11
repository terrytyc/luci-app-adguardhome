#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/lib/function-body.sh"
eval "$(init_source "$script_dir/../root/etc/init.d/AdGuardHome")"
temporary="$(mktemp -d /tmp/luci-agh-readonly.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
UCI_CONFIG_DIRECTORY="$temporary"
INTEGRATION_LOCK="$temporary/integration.lock"
: >"$temporary/adguardhome"
: >"$INTEGRATION_LOCK"
events="$temporary/events"
: >"$events"
TEST_CONFIG=/persistent/AdGuardHome.yaml
TEST_WORK=/persistent
DEFAULT_WORK_DIR=/persistent
WORK_READS=0
TEST_STATE=1
TEST_DELTA=0
GUARD_CALLS=0
uci_calls="$temporary/uci-calls"
: >"$uci_calls"

uci_guard_config_file_valid() { [ -f "$1" ]; }
uci_guard_no_delta() {
	GUARD_CALLS=$((GUARD_CALLS + 1))
	[ "$TEST_DELTA" = 0 ] || return 2
}
uci() { printf '%s\n' "$*" >>"$uci_calls"; return 1; }
config_load() { [ -f "$temporary/adguardhome" ]; }
validate_loaded_merged_sections() { return 0; }
config_get_bool() {
	case "$3" in
		enabled) service_enabled=1 ;;
		verbose) verbose=0 ;;
		run_from_memory) memory_requested=0 ;;
	esac
}
config_get() {
	case "$1" in
		official_work) official_work="$TEST_WORK"; WORK_READS=$((WORK_READS + 1)) ;;
		official_config) official_config="$TEST_CONFIG" ;;
		redirect_mode) redirect_mode=none ;;
		memory_writeback_interval) memory_writeback_interval=60 ;;
	esac
}
validate_managed_work_dir_namespace() {
	case "${1%/}" in /persistent|/active-old) return 0 ;; *) return 1 ;; esac
}
memory_state_load() {
	MEMORY_STATE_VALIDATED=1
	MEMORY_STATE_PERSISTENT_WORK_DIR=/active-old
	return "$TEST_STATE"
}
log_error() { :; }
restore_managed_config_snapshot() {
	printf 'restore\n' >>"$events"
	: >"$temporary/adguardhome"
}
normalize_managed_config_file() { printf 'normalize\n' >>"$events"; }
memory_discard_incomplete_runtime_locked() { printf 'cleanup\n' >>"$events"; }

read_settings
[ "$WORK_READS" = 1 ]
[ "$GUARD_CALLS" = 1 ]
[ "$service_enabled:$MEMORY_ACTIVE:$work_dir" = 1:0:/persistent ]
[ ! -s "$events" ]
result="$(memory_status)"
[ "$result" = "$(printf 'requested=0\nactive=0\npersistent_work_dir=/persistent\nactive_work_dir=/persistent\nactive_config_file=/persistent/AdGuardHome.yaml')" ]

# An active generation accepts this already-loaded next workdir pair while
# keeping the old YAML, with no second UCI field read or pending-edit check.
TEST_STATE=0
GUARD_CALLS=0
read_settings
[ "$GUARD_CALLS" = 1 ]
[ "$MEMORY_ACTIVE:$work_dir:$config_file" = 1:/persistent:/active-old/AdGuardHome.yaml ]
[ ! -s "$uci_calls" ]
TEST_WORK=/active-old/
TEST_CONFIG=/active-old/AdGuardHome.yaml
read_settings
[ "$work_dir:$config_file" = /active-old:/active-old/AdGuardHome.yaml ]
TEST_WORK=/persistent
if read_settings; then
	printf 'a mixed old/new path pair was accepted\n' >&2
	exit 1
fi
TEST_CONFIG=/persistent/AdGuardHome.yaml
TEST_WORK=""
if read_settings; then
	printf 'active RAM accepted a missing authoritative work_dir\n' >&2
	exit 1
fi
TEST_STATE=1
read_settings
[ "$work_dir" = /persistent ]
TEST_WORK=/persistent
# A pending edit is rejected at either entry before loading any fields, whether
# disk or RAM is requested. Management operations remain serialized thereafter.
TEST_DELTA=1
for TEST_STATE in 1 0; do
	for action in read_settings load_settings; do
		GUARD_CALLS=0
		WORK_READS=0
		rc=0
		"$action" light || rc=$?
		[ "$rc:$MONITOR_SETTINGS_READY:$GUARD_CALLS:$WORK_READS" = 2:0:1:0 ]
	done
done
[ ! -s "$events" ]
TEST_DELTA=0
TEST_STATE=1

# Invalid/missing settings and interrupted RAM state are reported, never repaired.
TEST_CONFIG=/wrong.yaml
! read_settings || exit 1
TEST_CONFIG=/persistent/AdGuardHome.yaml
TEST_STATE=2
! memory_status >"$temporary/status" || exit 1
grep -qx 'active=invalid' "$temporary/status"
TEST_STATE=1
mv "$temporary/adguardhome" "$temporary/saved"
! read_settings || exit 1
mv "$temporary/saved" "$temporary/adguardhome"
[ ! -s "$events" ]

# The shared lock is nonblocking and is not created by a query.
exec 199<"$INTEGRATION_LOCK"
/usr/bin/flock -x 199
rc=0
memory_status >"$temporary/status" || rc=$?
[ "$rc" = 2 ]
grep -qx 'active=busy' "$temporary/status"
/usr/bin/flock -u 199
exec 199<&-
rm "$INTEGRATION_LOCK"
rc=0
memory_status >/dev/null || rc=$?
[ "$rc" = 2 ] && [ ! -e "$INTEGRATION_LOCK" ]
[ ! -s "$events" ]

# Disk and RAM lifecycle loads each check pending edits once at entry.
for TEST_STATE in 1 0; do
	: >"$events"
	GUARD_CALLS=0
	load_settings light
	[ "$GUARD_CALLS" = 1 ]
	[ "$(cat "$events")" = "$(printf 'normalize\ncleanup')" ]
done

# The missing-file recovery entry retains its own pending-edit guard. A busy
# configuration must never be restored underneath that already-pending edit.
TEST_STATE=1
mv "$temporary/adguardhome" "$temporary/saved"
: >"$events"
TEST_DELTA=1
GUARD_CALLS=0
rc=0
load_settings light || rc=$?
[ "$rc:$GUARD_CALLS" = 2:1 ]
[ ! -e "$temporary/adguardhome" ] && [ ! -s "$events" ]
TEST_DELTA=0
GUARD_CALLS=0
load_settings light
[ "$GUARD_CALLS" = 1 ]
[ "$(cat "$events")" = "$(printf 'restore\nnormalize\ncleanup')" ]
printf 'ok - shared settings reader is read-only and status observes the integration lock\n'
