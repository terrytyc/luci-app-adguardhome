#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

require() {
	grep -Fq -- "$2" "$1" || {
		printf 'missing v2.4 init contract: %s\n' "$2" >&2
		exit 1
	}
}

function_body() {
	awk -v function_name="$2" '
		$0 == function_name "() {" || $0 == function_name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' "$1"
}

require "$init_file" 'LEGACY_CONFIG="adguardhome"'
require "$init_file" 'OFFICIAL_CONFIG="adguardhome"'
require "$init_file" 'LEGACY_SECTION="luci"'
require "$init_file" 'OFFICIAL_SECTION="config"'
require "$init_file" 'version=4\npersistent_work_dir=%s\nbacking_device=%s\nbacking_inode=%s\npersistent_data_device=%s\npersistent_data_inode=%s\nmemory_data_device=%s\nmemory_data_inode=%s\n'
require "$init_file" 'settings_update <enabled> <workdir> <verbose> <mode> <ram> <minutes> <revision> <token> <candidate>'
require "$init_file" 'settings_values_revision() {'
require "$init_file" 'settings_current_revision() {'
require "$init_file" '[ "$current_revision" != "$expected_revision" ]'
require "$init_file" '[ "$#" = 9 ]'

settings_job_body="$(function_body "$init_file" settings_update_job_locked)"
pending_line="$(printf '%s\n' "$settings_job_body" |
	grep -n 'yaml_job_pending_matches "$token" "$expected_revision"' |
	head -n 1 | cut -d: -f1)"
running_line="$(printf '%s\n' "$settings_job_body" |
	grep -n '"running:$$:${expected_revision}:${candidate_revision}"' |
	head -n 1 | cut -d: -f1)"
apply_line="$(printf '%s\n' "$settings_job_body" |
	grep -n 'settings_update_locked "$requested_enabled"' |
	head -n 1 | cut -d: -f1)"
success_line="$(printf '%s\n' "$settings_job_body" |
	grep -n '"success:${candidate_revision}:${restarted}:${expected_revision}:${candidate_revision}"' |
	head -n 1 | cut -d: -f1)"
[ -n "$pending_line" ] && [ -n "$running_line" ] &&
	[ -n "$apply_line" ] && [ -n "$success_line" ] &&
	[ "$pending_line" -lt "$running_line" ] &&
	[ "$running_line" -lt "$apply_line" ] &&
	[ "$apply_line" -lt "$success_line" ] || {
	printf 'settings job terminal publication is not authenticated and ordered\n' >&2
	exit 1
}

# Exercise a successful terminal publication with only shell/source stubs.  The
# coordinator must first consume the exact one-shot pending credential, publish
# running, complete convergence, recheck the canonical revision, and only then
# atomically publish success.
protocol_tmp="$(mktemp -d)"
trap 'rm -rf "$protocol_tmp"' EXIT
settings_values_body="$(function_body "$init_file" settings_values_revision)"
(
	eval "$settings_values_body"
	eval "$settings_job_body"
	expected_hash=1111111111111111111111111111111111111111111111111111111111111111
	token=22222222222222222222222222222222
	work_dir=/etc/AdGuardHome-next
	candidate_hash="$(settings_values_revision 1 "$work_dir" 0 dnsmasq-upstream 1 60)"
	states="${protocol_tmp}/states"

	yaml_job_hash_valid() {
		[ "${#1}" = 64 ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]'
	}
	yaml_job_token_valid() {
		[ "${#1}" = 32 ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]'
	}
	yaml_job_runtime_is_private() { return 0; }
	yaml_job_pending_matches() {
		[ "$1:$2:$3" = "$token:$expected_hash:$candidate_hash" ]
	}
	write_yaml_job_state() {
		[ "$1" = "$token" ] || return 1
		printf '%s\n' "$2" >>"$states"
	}
	settings_update_locked() { return 0; }
	load_legacy_settings() {
		legacy_enabled=1
		persistent_work_dir="$work_dir"
		verbose=0
		redirect_mode=dnsmasq-upstream
		memory_requested=1
		memory_writeback_interval=60
	}
	settings_current_revision() {
		settings_values_revision "$legacy_enabled" "$persistent_work_dir" \
			"$verbose" "$redirect_mode" "$memory_requested" \
			"$memory_writeback_interval"
	}
	official_running() { return 0; }

	settings_update_job_locked 1 "$work_dir" 0 dnsmasq-upstream 1 60 \
		"$expected_hash" "$token" "$candidate_hash" || exit 1
	grep -Eq "^running:[1-9][0-9]*:${expected_hash}:${candidate_hash}$" "$states" || exit 1
	[ "$(tail -n 1 "$states")" = \
		"success:${candidate_hash}:1:${expected_hash}:${candidate_hash}" ] || exit 1

	: >"$states"
	settings_update_locked() { return 1; }
	if settings_update_job_locked 1 "$work_dir" 0 dnsmasq-upstream 1 60 \
	   "$expected_hash" "$token" "$candidate_hash"; then
		exit 1
	fi
	[ "$(tail -n 1 "$states")" = \
		"failure:${expected_hash}:${candidate_hash}" ] || exit 1

	: >"$states"
	settings_update_locked() { return 2; }
	if settings_update_job_locked 1 "$work_dir" 0 dnsmasq-upstream 1 60 \
	   "$expected_hash" "$token" "$candidate_hash"; then
		exit 1
	fi
	[ "$(tail -n 1 "$states")" = \
		"indeterminate:${expected_hash}:${candidate_hash}" ] || exit 1
) || {
	printf 'normal settings job did not publish an authenticated success terminal\n' >&2
	exit 1
}
rm -rf "$protocol_tmp"
trap - EXIT

activate_body="$(function_body "$init_file" memory_activate_data_bindings)"
first_bind="$(printf '%s\n' "$activate_body" | grep -n 'mount -o bind "$target" "$MEMORY_BACKING_DATA_MOUNT"' | cut -d: -f1)"
second_bind="$(printf '%s\n' "$activate_body" | grep -n 'mount -o bind "$MEMORY_DATA_DIR" "$target"' | cut -d: -f1)"
[ -n "$first_bind" ] && [ -n "$second_bind" ] &&
	[ "$first_bind" -lt "$second_bind" ] || {
	printf 'RAM bind activation order is not backing alias then RAM overlay\n' >&2
	exit 1
}

suspend_body="$(function_body "$init_file" memory_suspend_data_bindings)"
overlay_unmount="$(printf '%s\n' "$suspend_body" | grep -n '/bin/umount "$target"' | head -n 1 | cut -d: -f1)"
alias_unmount="$(printf '%s\n' "$suspend_body" | grep -n '/bin/umount "$MEMORY_BACKING_DATA_MOUNT"' | head -n 1 | cut -d: -f1)"
[ -n "$overlay_unmount" ] && [ -n "$alias_unmount" ] &&
	[ "$overlay_unmount" -lt "$alias_unmount" ] || {
	printf 'RAM bind suspend order is not overlay then backing alias\n' >&2
	exit 1
}

copy_body="$(function_body "$init_file" memory_copy_live_data_locked)"
require_text='target="$MEMORY_BACKING_DATA_MOUNT"'
printf '%s\n' "$copy_body" | grep -Fq -- "$require_text" || {
	printf 'direct copy does not use persistent backing alias\n' >&2
	exit 1
}
for forbidden in AGHDataClear AGHDataMake '/bin/rm' '/bin/mkdir'; do
	if printf '%s\n' "$copy_body" | grep -Fq -- "$forbidden"; then
		printf 'direct copy contains forbidden clear/recreate operation: %s\n' "$forbidden" >&2
		exit 1
	fi
done

deactivate_body="$(function_body "$init_file" memory_deactivate_locked)"
copy_line="$(printf '%s\n' "$deactivate_body" | grep -n 'memory_copy_stopped_data_locked || return 1' | cut -d: -f1)"
suspend_line="$(printf '%s\n' "$deactivate_body" | grep -n 'memory_suspend_data_bindings "$old_backing" || return 1' | cut -d: -f1)"
[ -n "$copy_line" ] && [ -n "$suspend_line" ] && [ "$copy_line" -lt "$suspend_line" ] || {
	printf 'deactivation does not direct-copy before suspending binds\n' >&2
	exit 1
}
if printf '%s\n' "$deactivate_body" | grep -Fq 'memory_checkpoint_full_locked'; then
	printf 'deactivation still performs a root-swapping checkpoint\n' >&2
	exit 1
fi

trigger_body="$(function_body "$init_file" service_triggers)"
if printf '%s\n' "$trigger_body" | grep -Fq 'procd_add_reload_trigger'; then
	printf 'wrapper still registers a duplicate reload trigger\n' >&2
	exit 1
fi

monitor_term_body="$(function_body "$init_file" monitor_terminate)"
if printf '%s\n' "$monitor_term_body" | grep -Fq 'clear_recorded_integration_locked'; then
	printf 'retiring monitor may race and clear replacement DNS integration\n' >&2
	exit 1
fi

start_body="$(function_body "$init_file" start_service)"
require "$init_file" 'upgrade_stopped_marker_is_valid() ('
if grep -Fq 'consume_upgrade_stopped_marker' "$init_file" ||
   ! printf '%s\n' "$start_body" |
	grep -Fq 'upgrade_stopped_marker_is_valid || marker_rc=$?'; then
	printf 'init still consumes the durable cold-upgrade stop barrier\n' >&2
	exit 1
fi
start_tmp="$(mktemp -d)"
trap 'rm -rf "$start_tmp"' EXIT
(
	eval "$start_body"
	UPGRADE_STOPPED_MARKER="${start_tmp}/upgrade-was-stopped"
	MAINTENANCE_UPGRADE_MARKER="${start_tmp}/maintenance-upgrade"
	YAML_MAINTENANCE_MARKER="${start_tmp}/removing"
	PKG_UPGRADE=1
	initscript=/etc/init.d/AdGuardHome
	: >"$UPGRADE_STOPPED_MARKER"
	prepare_yaml_job_runtime() { return 0; }
	upgrade_stopped_marker_is_valid() {
		VALIDATIONS=$((VALIDATIONS + 1))
		return 0
	}
	prepare_wrapper_locked() {
		PREPARE_CALLED=$((PREPARE_CALLED + 1))
		return 0
	}
	run_locked() { "$@"; }
	log_error() { :; }
	procd_open_instance() { PROCD_CALLED=$((PROCD_CALLED + 1)); }
	procd_set_param() { PROCD_CALLED=$((PROCD_CALLED + 1)); }
	procd_close_instance() { PROCD_CALLED=$((PROCD_CALLED + 1)); }
	PREPARE_CALLED=0
	PROCD_CALLED=0
	VALIDATIONS=0
	start_service || exit 1
	start_service || exit 1
	[ "$VALIDATIONS:$PREPARE_CALLED:$PROCD_CALLED" = 2:0:0 ] || exit 1
	[ "$START_PREPARED:$START_DISABLED" = 1:1 ] || exit 1
	[ -e "$UPGRADE_STOPPED_MARKER" ] || exit 1
	PKG_UPGRADE=0
	if start_service; then
		exit 1
	fi
	[ "$VALIDATIONS:$PREPARE_CALLED:$PROCD_CALLED" = 3:0:0 ] || exit 1
	[ "$START_PREPARED:$START_DISABLED" = 1:1 ] || exit 1
	[ -e "$UPGRADE_STOPPED_MARKER" ] || exit 1
) || {
	printf 'cold-upgrade stop barrier did not suppress repeated starts fail-closed\n' >&2
	exit 1
}
rm -rf "$start_tmp"
trap - EXIT

require "$init_file" 'refresh_managed_config_snapshot || return 1'
require "$init_file" 'official_memory_data_mount_visible'
require "$init_file" 'pid_is_supervised_descendant "$pid" "$supervisor"'

printf 'ok - v2.4 single-UCI and RAM bind init contract\n'
