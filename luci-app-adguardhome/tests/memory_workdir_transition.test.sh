#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

apply_body="$(function_body "$init_file" memory_apply_official_path_delta)"
normalize_persistent_body="$(function_body "$init_file" normalize_managed_config_file_persistent)"
normalize_body="$(function_body "$init_file" normalize_managed_config_file)"
load_body="$(function_body "$init_file" load_settings)"
suspend_body="$(function_body "$init_file" memory_suspend_data_bindings)"
restore_body="$(function_body "$init_file" memory_restore_data_bindings_after_suspend_failure)"
deactivate_body="$(function_body "$init_file" memory_deactivate_locked)"
reconcile_body="$(function_body "$init_file" memory_reconcile_requested_storage_locked)"
settings_body="$(function_body "$init_file" settings_update_locked)"
values_revision_body="$(function_body "$init_file" settings_values_revision)"
revision_body="$(function_body "$init_file" settings_current_revision)"
orchestrate_body="$(function_body "$init_file" orchestrate_core_locked)"

for body in "$apply_body" "$normalize_persistent_body" "$normalize_body" \
	"$load_body" "$suspend_body" "$restore_body" \
	"$deactivate_body" "$reconcile_body" "$settings_body" \
	"$values_revision_body" "$revision_body" \
	"$orchestrate_body"; do
	[ -n "$body" ] || {
		printf 'unable to extract RAM workdir transition function\n' >&2
		exit 1
	}
done

normalize_line="$(printf '%s\n' "$load_body" |
	grep -n 'normalize_managed_config_file "$configured_work_dir" "$official_config"' |
	cut -d: -f1)"
derived_line="$(printf '%s\n' "$load_body" |
	grep -n 'persistent_config_file="${persistent_work_dir}/AdGuardHome.yaml"' |
	cut -d: -f1)"
[ -n "$normalize_line" ] && [ -n "$derived_line" ] &&
	[ "$normalize_line" -lt "$derived_line" ] || {
	printf 'committed config_file is not normalized before runtime YAML selection\n' >&2
	exit 1
}

# Static ordering: an active generation keeps using the state-authenticated old
# YAML until reconciliation writes it back and removes its data bindings.
old_yaml_line="$(printf '%s\n' "$load_body" |
	grep -n 'config_file="${MEMORY_BACKING_WORK_DIR}/AdGuardHome.yaml"' |
	cut -d: -f1)"
path_guard_line="$(printf '%s\n' "$load_body" |
	grep -n 'memory_apply_official_path_delta || return 1' | cut -d: -f1)"
[ -n "$old_yaml_line" ] && [ -n "$path_guard_line" ] &&
	[ "$old_yaml_line" -lt "$path_guard_line" ] || {
	printf 'active RAM load does not retain the old state-bound YAML\n' >&2
	exit 1
}
printf '%s\n' "$apply_body" |
	grep -Fq '[ "$effective_config" = "$persistent_config_file" ]' || {
	printf 'active RAM path guard does not accept a validated next workdir pair\n' >&2
	exit 1
}
printf '%s\n' "$reconcile_body" |
	grep -Fq '[ "$MEMORY_BACKING_WORK_DIR" != "$persistent_work_dir" ]' || {
	printf 'active RAM reconciliation does not detect a workdir change\n' >&2
	exit 1
}
printf '%s\n' "$reconcile_body" |
	grep -Fq 'memory_deactivate_locked || return 1' || {
	printf 'active RAM reconciliation does not write back and deactivate the old tree\n' >&2
	exit 1
}
copy_line="$(printf '%s\n' "$deactivate_body" |
	grep -n 'memory_copy_stopped_data_locked || return 1' | cut -d: -f1)"
suspend_line="$(printf '%s\n' "$deactivate_body" |
	grep -n 'memory_suspend_data_bindings "$old_backing" || return 1' | cut -d: -f1)"
[ -n "$copy_line" ] && [ -n "$suspend_line" ] &&
	[ "$copy_line" -lt "$suspend_line" ] || {
	printf 'old RAM data is not directly written back before bind removal\n' >&2
	exit 1
}

# Every failure after the first ordered unmount attempt must use the same
# identity-authenticated compensation path.  That helper restores the backing
# alias before exposing the RAM overlay again.
[ "$(printf '%s\n' "$suspend_body" |
	grep -c 'memory_restore_data_bindings_after_suspend_failure "$backing"')" = 3 ] || {
	printf 'not every bind-suspend failure path invokes compensation\n' >&2
	exit 1
}
alias_bind_line="$(printf '%s\n' "$restore_body" |
	grep -n 'mount -o bind "$target" "$MEMORY_BACKING_DATA_MOUNT"' | cut -d: -f1)"
overlay_bind_line="$(printf '%s\n' "$restore_body" |
	grep -n 'mount -o bind "$MEMORY_DATA_DIR" "$target"' | cut -d: -f1)"
[ -n "$alias_bind_line" ] && [ -n "$overlay_bind_line" ] &&
	[ "$alias_bind_line" -lt "$overlay_bind_line" ] || {
	printf 'bind-suspend compensation does not restore alias before overlay\n' >&2
	exit 1
}

# Dynamic path-pair test: both the old state backing and the newly committed,
# already-validated authoritative pair are accepted, but mixed pairs are not.
(
	eval "$apply_body"
	OFFICIAL_CONFIG=adguardhome
	OFFICIAL_SECTION=config
	MEMORY_ACTIVE=1
	MEMORY_BACKING_WORK_DIR=/etc/AdGuardHome-old
	persistent_work_dir=/etc/AdGuardHome-new
	persistent_config_file=/etc/AdGuardHome-new/AdGuardHome.yaml
	UCI_WORK=""
	UCI_CONFIG=""
	UCI_DELTA=0
	memory_state_binds_persistent() {
		[ "$1" = /etc/AdGuardHome-old ]
	}
	uci_guard_no_delta() { [ "$UCI_DELTA" = 0 ]; }
	uci() {
		case "$3" in
			adguardhome.config.work_dir) printf '%s\n' "$UCI_WORK" ;;
			adguardhome.config.config_file) printf '%s\n' "$UCI_CONFIG" ;;
			*) return 1 ;;
		esac
	}

	UCI_WORK=/etc/AdGuardHome-old
	UCI_CONFIG=/etc/AdGuardHome-old/AdGuardHome.yaml
	memory_apply_official_path_delta || exit 1
	UCI_WORK=/etc/AdGuardHome-new
	UCI_CONFIG=/etc/AdGuardHome-new/AdGuardHome.yaml
	memory_apply_official_path_delta || exit 1
	UCI_CONFIG=/etc/AdGuardHome-old/AdGuardHome.yaml
	if memory_apply_official_path_delta; then
		printf 'mixed old/new workdir pair was accepted\n' >&2
		exit 1
	fi
	UCI_CONFIG=/etc/AdGuardHome-new/AdGuardHome.yaml
	UCI_DELTA=1
	if memory_apply_official_path_delta; then
		printf 'pending official UCI delta was accepted\n' >&2
		exit 1
	fi
)

# Dynamic derived-field test: a hand-edited config_file is normalized for both
# the default and a custom authoritative workdir.  A pending UCI delta blocks
# the repair and leaves the committed value untouched.
(
	eval "$normalize_persistent_body"
	eval "$normalize_body"
	OFFICIAL_CONFIG=adguardhome
	OFFICIAL_SECTION=config
	UCI_WORK=""
	UCI_CONFIG=""
	UCI_DELTA=0
	COMMIT_COUNT=0
	REFRESH_COUNT=0
	LOGGED=""
	validate_managed_work_dir_namespace() {
		case "${1%/}" in
			/etc/AdGuardHome|/mnt/storage/AdGuardHome) return 0 ;;
			*) return 1 ;;
		esac
	}
	uci_guard_no_delta() { [ "$UCI_DELTA" = 0 ]; }
	uci() {
		case "$2:$3" in
			get:adguardhome.config) printf 'adguardhome\n' ;;
			get:adguardhome.config.work_dir) printf '%s\n' "$UCI_WORK" ;;
			get:adguardhome.config.config_file) printf '%s\n' "$UCI_CONFIG" ;;
			set:adguardhome.config.config_file=*)
				UCI_CONFIG="${3#*=}"
				;;
			commit:adguardhome)
				COMMIT_COUNT=$((COMMIT_COUNT + 1))
				;;
			revert:adguardhome) ;;
			*) return 1 ;;
		esac
	}
	memory_run_with_official_path_guard() { "$@"; }
	refresh_managed_config_snapshot() { REFRESH_COUNT=$((REFRESH_COUNT + 1)); }
	log_error() { LOGGED="$*"; }

	UCI_WORK=/etc/AdGuardHome
	UCI_CONFIG=/etc/other.yaml
	normalize_managed_config_file "$UCI_WORK" "$UCI_CONFIG" || exit 1
	[ "$UCI_CONFIG" = /etc/AdGuardHome/AdGuardHome.yaml ] &&
		[ "$COMMIT_COUNT" = 1 ] && [ "$REFRESH_COUNT" = 1 ] || {
		printf 'default workdir config_file was not normalized\n' >&2
		exit 1
	}
	case "$LOGGED" in *'config_file is derived from work_dir'*) ;; *)
		printf 'config_file normalization was not logged\n' >&2
		exit 1
		;;
	esac

	UCI_WORK=/mnt/storage/AdGuardHome
	UCI_CONFIG=/tmp/custom.yaml
	COMMIT_COUNT=0
	REFRESH_COUNT=0
	normalize_managed_config_file "$UCI_WORK" "$UCI_CONFIG" || exit 1
	[ "$UCI_CONFIG" = /mnt/storage/AdGuardHome/AdGuardHome.yaml ] &&
		[ "$COMMIT_COUNT" = 1 ] && [ "$REFRESH_COUNT" = 1 ] || {
		printf 'custom workdir config_file was not normalized\n' >&2
		exit 1
	}

	UCI_WORK=/etc/AdGuardHome
	UCI_CONFIG=/tmp/pending.yaml
	UCI_DELTA=1
	COMMIT_COUNT=0
	REFRESH_COUNT=0
	if normalize_managed_config_file "$UCI_WORK" "$UCI_CONFIG"; then
		printf 'config_file normalization ignored a pending UCI delta\n' >&2
		exit 1
	fi
	[ "$UCI_CONFIG" = /tmp/pending.yaml ] && [ "$COMMIT_COUNT" = 0 ] &&
		[ "$REFRESH_COUNT" = 0 ] || {
		printf 'failed config_file normalization changed committed state\n' >&2
		exit 1
	}
)

# Dynamic transaction test: applying B while RAM-backed A is active retains A's
# YAML through stop/writeback/deactivation.  A simulated B initialization
# failure must commit A again and fully restore its requested RAM service state.
(
	test_root="$(mktemp -d /tmp/agh-workdir-transition.XXXXXX)"
	events="${test_root}/events"
	service_state="${test_root}/service-state"
	service="${test_root}/adguardhome"
	trap 'rm -rf "$test_root"' EXIT HUP INT TERM
	: >"$events"
	printf 'running\n' >"$service_state"
	cat >"$service" <<-'MOCK_SERVICE'
	#!/bin/sh
	printf 'service:%s\n' "$1" >>"$TEST_EVENTS"
	case "$1" in
		stop) printf 'stopped\n' >"$TEST_SERVICE_STATE" ;;
		start) printf 'running\n' >"$TEST_SERVICE_STATE" ;;
		*) exit 1 ;;
	esac
	MOCK_SERVICE
	chmod 0700 "$service"
	export TEST_EVENTS="$events" TEST_SERVICE_STATE="$service_state"

	eval "$apply_body"
	eval "$reconcile_body"
	eval "$orchestrate_body"
	eval "$values_revision_body"
	eval "$revision_body"
	eval "$settings_body"

	OFFICIAL_CONFIG=adguardhome
	OFFICIAL_SECTION=config
	OFFICIAL_SERVICE="$service"
	OLD=/etc/AdGuardHome-old
	NEW=/etc/AdGuardHome-new
	COMMITTED_ENABLED=1
	COMMITTED_WORK="$OLD"
	COMMITTED_VERBOSE=0
	COMMITTED_REDIRECT=dnsmasq-upstream
	COMMITTED_MEMORY=1
	COMMITTED_INTERVAL=60
	RUNTIME_ACTIVE=1
	RUNTIME_BACKING="$OLD"
	FAIL_NEW=1
	uci() {
		case "$3" in
			adguardhome.config.work_dir) printf '%s\n' "$COMMITTED_WORK" ;;
			adguardhome.config.config_file) printf '%s/AdGuardHome.yaml\n' "$COMMITTED_WORK" ;;
			*) return 1 ;;
		esac
	}
	uci_guard_no_delta() { return 0; }
	memory_state_binds_persistent() { [ "$1" = "$RUNTIME_BACKING" ]; }
	load_settings() {
		service_enabled="$COMMITTED_ENABLED"
		persistent_work_dir="$COMMITTED_WORK"
		persistent_config_file="${COMMITTED_WORK}/AdGuardHome.yaml"
		verbose="$COMMITTED_VERBOSE"
		redirect_mode="$COMMITTED_REDIRECT"
		memory_requested="$COMMITTED_MEMORY"
		memory_writeback_interval="$COMMITTED_INTERVAL"
		MEMORY_ACTIVE="$RUNTIME_ACTIVE"
		MEMORY_BACKING_WORK_DIR="$RUNTIME_BACKING"
		previous_work_dir="$RUNTIME_BACKING"
		work_dir="$persistent_work_dir"
		config_file="$persistent_config_file"
		if [ "$MEMORY_ACTIVE" = 1 ]; then
			config_file="${MEMORY_BACKING_WORK_DIR}/AdGuardHome.yaml"
			memory_apply_official_path_delta || return 1
		fi
	}
	settings_commit_persistent() {
		COMMITTED_ENABLED="$1"
		COMMITTED_WORK="${2%/}"
		COMMITTED_VERBOSE="$3"
		COMMITTED_REDIRECT="$4"
		COMMITTED_MEMORY="$5"
		COMMITTED_INTERVAL="$6"
		printf 'commit:%s:%s\n' "$COMMITTED_WORK" "$COMMITTED_MEMORY" >>"$events"
	}
	memory_run_with_official_path_guard() { "$@"; }
	refresh_managed_config_snapshot() { return 0; }
	log_error() { :; }
	clear_recorded_integration_locked() {
		printf 'clear:%s\n' "$COMMITTED_WORK" >>"$events"
	}
	official_running() { grep -qx running "$service_state"; }
	wait_for_core_stopped() { ! official_running; }
	memory_copy_stopped_data_locked() {
		printf 'unexpected-restart-copy\n' >>"$events"
		return 1
	}
	memory_deactivate_locked() {
		[ "$#" = 0 ] && ! official_running || return 1
		[ "$config_file" = "${OLD}/AdGuardHome.yaml" ] || return 1
		printf 'deactivate:%s:%s:%s\n' \
			"$MEMORY_BACKING_WORK_DIR" "$config_file" "$persistent_work_dir" >>"$events"
		RUNTIME_ACTIVE=0
		RUNTIME_BACKING=""
		MEMORY_ACTIVE=0
		MEMORY_BACKING_WORK_DIR=""
		work_dir="$persistent_work_dir"
		config_file="$persistent_config_file"
	}
	memory_discard_incomplete_runtime_locked() { return 0; }
	ensure_config_file() {
		printf 'ensure:%s\n' "$work_dir" >>"$events"
		if [ "$work_dir" = "$NEW" ] && [ "$FAIL_NEW" = 1 ]; then
			FAIL_NEW=0
			return 1
		fi
	}
	fail_safe_locked() {
		"$OFFICIAL_SERVICE" stop >/dev/null 2>&1 || true
		return 0
	}
	sync_yaml_managed_fields_checked() { return 0; }
	memory_prepare_or_fallback_locked() {
		printf 'prepare:%s:%s\n' "$work_dir" "$memory_requested" >>"$events"
		if [ "$memory_requested" = 1 ]; then
			RUNTIME_ACTIVE=1
			RUNTIME_BACKING="$persistent_work_dir"
			MEMORY_ACTIVE=1
			MEMORY_BACKING_WORK_DIR="$persistent_work_dir"
		fi
	}
	load_runtime_dns_port() { dns_port=53335; }
	sync_official_uci() { return 0; }
	sync_monitor_instance() { printf 'monitor:%s:%s\n' "$COMMITTED_WORK" "$COMMITTED_ENABLED" >>"$events"; }
	wait_for_core_ready() {
		printf 'ready:%s:%s\n' "$3" "$config_file" >>"$events"
		official_running
	}
	apply_integration_locked() {
		printf 'integrated:%s\n' "$3" >>"$events"
	}

	load_settings || exit 1
	expected_revision="$(settings_current_revision)" || exit 1
	stale_revision=0000000000000000000000000000000000000000000000000000000000000000
	if settings_update_locked 1 "$NEW" 0 dnsmasq-upstream 1 60 "$stale_revision"; then
		printf 'stale settings revision was accepted\n' >&2
		exit 1
	fi
	[ ! -s "$events" ] && [ "$COMMITTED_WORK" = "$OLD" ] && official_running || {
		printf 'stale settings revision changed UCI or service state\n' >&2
		exit 1
	}
	result=0
	settings_update_locked 1 "$NEW" 0 dnsmasq-upstream 1 60 "$expected_revision" || result=$?
	if [ "$result" != 1 ]; then
		printf 'new-workdir failure did not report a fully restored rollback: %s\n' "$result" >&2
		exit 1
	fi
	[ "$(grep -Fxc "monitor:${OLD}:1" "$events")" = 1 ] || {
		printf 'rollback did not restore the enabled monitor exactly once\n' >&2
		exit 1
	}
	[ "$COMMITTED_WORK" = "$OLD" ] && [ "$COMMITTED_MEMORY" = 1 ] || {
		printf 'failed apply did not restore old authoritative settings\n' >&2
		exit 1
	}
	[ "$RUNTIME_ACTIVE" = 1 ] && [ "$RUNTIME_BACKING" = "$OLD" ] || {
		printf 'failed apply did not restore old RAM request\n' >&2
		exit 1
	}
	official_running || {
		printf 'failed apply did not restart the old service state\n' >&2
		exit 1
	}
	grep -Fqx "deactivate:${OLD}:${OLD}/AdGuardHome.yaml:${NEW}" "$events" || {
		printf 'active old YAML was not retained through new-workdir deactivation\n' >&2
		exit 1
	}
	new_commit="$(grep -n -F "commit:${NEW}:1" "$events" | head -n 1 | cut -d: -f1)"
	deactivate="$(grep -n -F "deactivate:${OLD}:${OLD}/AdGuardHome.yaml:${NEW}" "$events" |
		head -n 1 | cut -d: -f1)"
	old_commit="$(grep -n -F "commit:${OLD}:1" "$events" | tail -n 1 | cut -d: -f1)"
	restored="$(grep -n -F "integrated:${OLD}" "$events" | tail -n 1 | cut -d: -f1)"
	[ "$new_commit" -lt "$deactivate" ] && [ "$deactivate" -lt "$old_commit" ] &&
		[ "$old_commit" -lt "$restored" ] || {
		printf 'new-workdir failure rollback ordering is incorrect\n' >&2
		exit 1
	}
)

printf 'ok - active RAM workdir transition and rollback\n'
