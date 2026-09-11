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

reject() {
	if grep -Fq -- "$2" "$1"; then
		printf 'obsolete v2.4 init mechanism remains: %s\n' "$2" >&2
		exit 1
	fi
}

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

require "$init_file" 'PLUGIN_CONFIG="adguardhome"'
require "$init_file" 'OFFICIAL_CONFIG="adguardhome"'
require "$init_file" 'PLUGIN_SECTION="luci"'
require "$init_file" 'OFFICIAL_SECTION="config"'
require "$init_file" 'version=4\npersistent_work_dir=%s\nbacking_device=%s\nbacking_inode=%s\npersistent_data_device=%s\npersistent_data_inode=%s\nmemory_data_device=%s\nmemory_data_inode=%s\n'
require "$init_file" 'settings_update <enabled> <workdir> <verbose> <mode> <ram> <minutes> <revision> <token> <candidate>'
require "$init_file" 'settings_values_revision() {'
require "$init_file" 'settings_current_revision() {'
require "$init_file" '[ "$current_revision" != "$expected_revision" ]'
require "$init_file" '[ "$#" = 10 ]'

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
	load_settings() {
		service_enabled=1
		persistent_work_dir="$work_dir"
		verbose=0
		redirect_mode=dnsmasq-upstream
		memory_requested=1
		memory_writeback_interval=60
	}
	settings_current_revision() {
		settings_values_revision "$service_enabled" "$persistent_work_dir" \
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

# Exercise the actual YAML transaction through its first runtime boundary.
# Preflight rejection is definitive; load/cleanup failures remain uncertain.
(
	eval "$(function_body "$init_file" yaml_update_locked)"
	eval "$(function_body "$init_file" yaml_update_job_locked)"
	expected_hash=1111111111111111111111111111111111111111111111111111111111111111
	candidate_hash=3333333333333333333333333333333333333333333333333333333333333333
	token=22222222222222222222222222222222
	states="${protocol_tmp}/yaml-states"
	load_settings() { [ "$scenario" != settings ]; }
	config_file=/etc/AdGuardHome/AdGuardHome.yaml
	validate_work_dir_mount_dependency() { [ "$scenario" != mount ]; }
	validate_yaml_stage() { [ "$scenario" != stage ]; }
	active_config_hash() {
		[ "$scenario" != hash-read ] || return 1
		if [ "$scenario" = hash-conflict ]; then
			printf '%s\n' "$candidate_hash"
		else
			printf '%s\n' "$expected_hash"
		fi
	}
	check_core_config_file() { [ "$scenario" != validation ]; }
	official_running() { return 0; }
	clear_recorded_integration_locked() { touched=1; return 1; }
	resume_paused_yaml_runtime() { return 1; }
	log_error() { :; }
	cleanup_yaml_update() { :; }
	cleanup_yaml_job_stage() { :; }
	yaml_job_pending_matches() { return 0; }
	write_yaml_job_state() {
		[ "$1" = "$token" ] || return 1
		printf '%s\n' "$2" >>"$states"
	}
	for scenario in validation settings mount stage hash-read hash-conflict cleanup; do
		: >"$states"
		touched=0
		# Values from an earlier call must not affect this job's classification.
		update_rc=2 terminal=failure
		if yaml_update_job_locked "$expected_hash" "$candidate_hash" \
		   /unused/AdGuardHome.yaml.luci-test 9 "$token"; then
			exit 1
		fi
		case "$scenario" in
			settings|cleanup) expected=indeterminate ;;
			*) expected=failure ;;
		esac
		[ "$(tail -n 1 "$states")" = \
			"${expected}:${expected_hash}:${candidate_hash}" ] || exit 1
		case "$scenario" in cleanup) [ "$touched" = 1 ] ;; *) [ "$touched" = 0 ] ;; esac
	done
) || {
	printf 'YAML preflight failure was confused with an uncertain runtime result\n' >&2
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
if printf '%s\n' "$deactivate_body" | grep -Eq 'checkpoint|\$\{?1'; then
	printf 'RAM deactivation must always write back, without a bypass parameter\n' >&2
	exit 1
fi
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

for obsolete in \
	'LEGACY_CONFIG=' \
	'LEGACY_SECTION=' \
	'load_legacy_settings()' \
	'MEMORY_JOURNAL' \
	'memory_recover_journal' \
	'memory_restore_live_checkpoint' \
	'memory_live_marker_load' \
	'MAINTENANCE_UPGRADE' \
	'UPGRADE_STOPPED'; do
	reject "$init_file" "$obsolete"
done
require "$init_file" 'memory_discard_incomplete_runtime_locked() {'
function_body "$init_file" load_settings |
	grep -Fq 'memory_discard_incomplete_runtime_locked "$configured_work_dir" || return 1'

require "$init_file" 'refresh_managed_config_snapshot || return 1'
require "$init_file" 'official_memory_data_mount_visible'
require "$init_file" 'pid_is_supervised_descendant "$pid" "$supervisor"'

printf 'ok - v2.4 single-UCI and RAM bind init contract\n'
