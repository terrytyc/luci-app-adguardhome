#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
events="$test_tmp/events"
revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
record() { printf '%s\n' "$*" >>"$events"; }
load_settings() {
	service_enabled="$STORED_ENABLED" MEMORY_ACTIVE="$RAM_ACTIVE"
	persistent_work_dir="${STORED_WORK_DIR:-/etc/AdGuardHome}"
	persistent_config_file="$persistent_work_dir/AdGuardHome.yaml"
	work_dir="$persistent_work_dir" config_file="$persistent_config_file"
	previous_work_dir="$work_dir" MEMORY_BACKING_WORK_DIR="${ACTIVE_BACKING:-$work_dir}"
	if [ "$MEMORY_ACTIVE" = 1 ]; then
		previous_work_dir="$MEMORY_BACKING_WORK_DIR"
		config_file="$MEMORY_BACKING_WORK_DIR/AdGuardHome.yaml"
	fi
	verbose=0 redirect_mode=none memory_requested="$RAM_REQUESTED" memory_writeback_interval=60
}
settings_current_revision() { printf '%s\n' "$revision"; }
settings_commit_persistent() { STORED_ENABLED="$1" STORED_WORK_DIR="$2"; record "enabled:$1"; }
memory_run_with_official_path_guard() { "$@"; }
refresh_managed_config_snapshot() { :; }
uci_set_if_changed() { :; }
uci_delete_if_present() { :; }
uci() {
	[ "$1:$2" = -q:get ] || return 1
	case "$3" in
		adguardhome.config) printf 'adguardhome\n' ;;
		adguardhome.luci) printf 'luci\n' ;;
		adguardhome.config.enabled) printf '%s\n' "$STORED_ENABLED" ;;
		adguardhome.config.config_file) printf '%s\n' "$persistent_config_file" ;;
		adguardhome.config.work_dir) printf '%s\n' "$persistent_work_dir" ;;
		adguardhome.config.verbose) printf '0\n' ;;
		adguardhome.luci.redirect) printf 'none\n' ;;
		adguardhome.luci.run_from_memory) printf '%s\n' "$RAM_REQUESTED" ;;
		adguardhome.luci.memory_writeback_interval) printf '60\n' ;;
		adguardhome.config.config|adguardhome.config.workdir) ;;
		*) return 1 ;;
	esac
}
sync_memory_data_jail_access_persistent() { record jail-sync; }
sync_monitor_instance() { record monitor-sync; }
sync_tls_access_persistent() { record unexpected-tls; return 1; }
sync_yaml_managed_fields_checked() { record unexpected-yaml; return 1; }
load_runtime_dns_port() { record unexpected-dns; return 1; }
ensure_config_file() { record unexpected-yaml; return 1; }
clear_recorded_integration_locked() { record cleanup; [ "$FAILURE" != cleanup ]; }
fake_service() {
	record "$1"
	[ "$FAILURE" != "$1" ] || return 1
	[ "$1" != stop ] || CORE_RUNNING=0
}
OFFICIAL_SERVICE=fake_service
wait_for_core_stopped() { [ "$CORE_RUNNING" = 0 ] && [ "$FAILURE" != wait ]; }
memory_reconcile_requested_storage_locked() { :; }
memory_deactivate_locked() {
	record writeback
	[ "$FAILURE" != writeback ] || return 1
	RAM_ACTIVE=0 MEMORY_ACTIVE=0
}
log_error() { record "$*"; }

# Exercise the settings transaction and actual persistent UCI sync together.
# A YAML/DNS/TLS validation would fail, but a successful stop must remain saved.
FAILURE=''
for RAM_REQUESTED in 0 1; do
	STORED_ENABLED=1 CORE_RUNNING=1 RAM_ACTIVE="$RAM_REQUESTED"
	: >"$events"
	settings_update_locked 0 /etc/AdGuardHome 0 none "$RAM_REQUESTED" 60 "$revision"
	[ "$STORED_ENABLED:$CORE_RUNNING:$RAM_ACTIVE" = 0:0:0 ]
	! grep -q '^unexpected-' "$events"
	grep -qx jail-sync "$events"
	grep -qx monitor-sync "$events"
	[ "$(grep -c '^writeback$' "$events" || true)" = "$RAM_REQUESTED" ]
done

# Disabling still refuses cleanup, stop, shutdown confirmation or RAM writeback
# failures. It must not remove the active RAM generation after such an error.
for FAILURE in cleanup stop wait writeback; do
	STORED_ENABLED=0 CORE_RUNNING=1 RAM_ACTIVE=1 RAM_REQUESTED=1
	: >"$events"
	if orchestrate_core_locked; then exit 1; fi
	[ "$RAM_ACTIVE" = 1 ]
	! grep -Eq '^(unexpected-|jail-sync|monitor-sync)' "$events"
done

# Exercise the real RAM deactivation and checked pattern migration during a
# combined A -> B workdir change and disable. Only mount/UCI/core boundaries are
# mocked; YAML rewriting, hashes and temporary state removal run on fixtures.
(
	. "$script_dir/lib/function-body.sh"
	for name in memory_deactivate_locked sync_yaml_managed_fields_checked; do
		eval "$(function_body "$script_dir/../root/etc/init.d/AdGuardHome" "$name")"
	done
	old_work="$test_tmp/old"
	new_work="$test_tmp/new"
	mkdir "$old_work" "$new_work"
	official_running() { [ "$CORE_RUNNING" = 1 ]; }
	memory_copy_stopped_data_locked() { record writeback; [ "$FAILURE" != writeback ]; }
	memory_suspend_data_bindings() { record unmount; [ "$FAILURE" != unmount ]; }
	memory_restore_official_persistent_paths() { record restore-paths; [ "$FAILURE" != restore-paths ]; }
	memory_reactivate_after_deactivation_failure() { record reactivate; }
	memory_remove_active_tree() { record remove-tree; [ "$FAILURE" != remove-tree ]; }
	memory_private_state_file() { record state-identity; [ "$FAILURE" != state-identity ]; }
	memory_runtime_dir_valid() { record directory-identity; [ "$FAILURE" != directory-identity ]; }
	memory_discard_incomplete_runtime_locked() { :; }
	sync_memory_data_jail_access_persistent() { record jail-sync; [ "$FAILURE" != jail-sync ]; }
	snapshot_config_file() {
		cp "$1" "$2" || return 1
		SNAPSHOT_CONFIG_HASH="$(yaml_file_hash "$2")"
	}
	active_config_hash() { yaml_file_hash "$config_file"; }
	check_core_config_file() { ! grep -Fqx 'broken: [' "$1"; }
	install_config_candidate() { cp "$1" "$config_file"; }
	prepare_ram_case() {
		FAILURE='' STORED_ENABLED=1 CORE_RUNNING=1 RAM_ACTIVE=1 RAM_REQUESTED=1
		STORED_WORK_DIR="$old_work" ACTIVE_BACKING="$old_work"
		MEMORY_RUNTIME_DIR="$(mktemp -d "$test_tmp/ram.XXXXXX")"
		MEMORY_STATE_FILE="$MEMORY_RUNTIME_DIR/state"
		: >"$MEMORY_STATE_FILE"
		: >"$events"
	}
	for yaml_kind in valid broken missing; do
		prepare_ram_case
		printf 'filtering:\n  safe_fs_patterns:\n    - %s/data/userfilters/*\n    - /custom/filters/*\n' \
			"$old_work" >"$new_work/AdGuardHome.yaml"
		case "$yaml_kind" in
			broken) printf 'broken: [\n' >>"$new_work/AdGuardHome.yaml" ;;
			missing) rm "$new_work/AdGuardHome.yaml" ;;
		esac
		settings_update_locked 0 "$new_work" 0 none 1 60 "$revision"
		[ "$STORED_ENABLED:$CORE_RUNNING:$MEMORY_ACTIVE" = 0:0:0 ]
		[ "$STORED_WORK_DIR" = "$new_work" ] && [ ! -e "$MEMORY_RUNTIME_DIR" ]
		! grep -q '^unexpected-' "$events"
		case "$yaml_kind" in
			valid)
				grep -Fqx "    - $new_work/data/userfilters/*" "$new_work/AdGuardHome.yaml"
				grep -Fqx '    - /custom/filters/*' "$new_work/AdGuardHome.yaml"
				! grep -Fq "$old_work/data/userfilters/*" "$new_work/AdGuardHome.yaml"
				;;
			broken)
				grep -Fqx "    - $old_work/data/userfilters/*" "$new_work/AdGuardHome.yaml"
				grep -Fq 'Service remains stopped' "$events"
				;;
			missing) [ ! -e "$new_work/AdGuardHome.yaml" ] ;;
		esac
	done
	# Neither disabled boot/start nor apply initializes a missing YAML.
	RAM_ACTIVE=0
	result=0
	prepare_wrapper_locked || result=$?
	[ "$result" = 2 ] && [ ! -e "$new_work/AdGuardHome.yaml" ]
	! grep -q '^unexpected-' "$events"
	for boundary in writeback unmount restore-paths remove-tree state-identity directory-identity jail-sync; do
		prepare_ram_case
		STORED_ENABLED=0 STORED_WORK_DIR="$new_work" FAILURE="$boundary"
		if orchestrate_core_locked; then exit 1; fi
		grep -qx "$boundary" "$events"
		! grep -q '^monitor-sync$' "$events"
	done
)
printf 'ok - disabling broken activation config stays saved and preserves stop/writeback failures\n'
