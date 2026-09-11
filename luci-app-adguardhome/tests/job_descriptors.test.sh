#!/bin/sh

if ! (eval 'exec 199<&0 && exec 199<&-') 2>/dev/null; then
	exec busybox ash "$0" "$@"
fi
set -eu
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="$script_dir/../root/etc/init.d/AdGuardHome"
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
test_tmp="$(mktemp -d /tmp/luci-agh-descriptors.XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
YAML_JOB_RUNTIME_DIR="$test_tmp"
INTEGRATION_LOCK="$test_tmp/integration.lock"
touch "$test_tmp/update.lock"
chmod 0600 "$test_tmp/update.lock"
printf 'staged YAML\n' >"$test_tmp/stage"
awk -v helper_dir="$script_dir/../scripts" \
	-f "$script_dir/../scripts/expand-helpers.awk" "$init_file" >"$test_tmp/init.expanded"
for name in entry_metadata root_private_directory root_private_file run_bounded \
	yaml_job_lock_file_is_private yaml_job_lock_fd_valid \
	prepare_job_descriptors open_integration_lock_descriptor run_locked \
	settings_update; do
	eval "$(function_body "$test_tmp/init.expanded" "$name")"
done

occupy_descriptors() {
	for fd in 187 192 193 194 195 196 197 198 199; do
		eval "exec ${fd}</dev/null"
	done
}

for held_fd in 3 187 197; do
	(
		occupy_descriptors
		if run_locked true; then
			printf 'occupied descriptor range unexpectedly accepted a lock\n' >&2
			exit 1
		fi
		eval "exec ${held_fd}<>\"$test_tmp/update.lock\""
		/usr/bin/flock -n -x "$held_fd"
		exec 1000<"$test_tmp/stage"
		settings_update_job_locked() {
			[ "$#:$1:$9" = 9:1:candidate ]
			[ "$held_fd" = 187 ] || [ ! -e /proc/self/fd/187 ]
			[ -e /proc/self/fd/1000 ]
			yaml_job_lock_fd_valid "" "$held_fd"
			# The child must retain the inherited task lock, not merely leave
			# all serialization to its potentially disappearing RPC parent.
			if /usr/bin/flock -n "$test_tmp/update.lock" true; then
				return 1
			fi
			run_bounded 10 1 /bin/dd of="$test_tmp/held-lock-input" <&1000 2>/dev/null
			cmp -s "$test_tmp/stage" "$test_tmp/held-lock-input"
			yaml_job_lock_fd_valid "" "$held_fd"
			if /usr/bin/flock -n "$test_tmp/update.lock" true; then return 1; fi
			printf 'applied\n' >"$test_tmp/applied"
		}
		settings_update 1 /etc/AdGuardHome 0 none 0 60 revision token candidate "$held_fd"
		[ "$(cat "$test_tmp/applied")" = applied ]
	)
done

# YAML keeps its pinned read-only staging file, even at 187, and the task lock.
for stage_fd in 187 193; do (
	occupy_descriptors
	exec 3<>"$test_tmp/update.lock"
	eval "exec ${stage_fd}<\"$test_tmp/stage\""
	prepare_job_descriptors "$stage_fd" 3
	[ /proc/self/fd/"$stage_fd" -ef "$test_tmp/stage" ]
	[ "$stage_fd" = 187 ] || [ ! -e /proc/self/fd/187 ]
	[ ! -e /proc/self/fd/199 ]
	run_locked true
	run_bounded 10 1 /bin/dd of="$test_tmp/held-stage-input" <&"$stage_fd" 2>/dev/null
	cmp -s "$test_tmp/stage" "$test_tmp/held-stage-input"
	yaml_job_lock_fd_valid "$stage_fd" 3
	if /usr/bin/flock -n "$test_tmp/update.lock" true; then exit 1; fi
); done

# Never clean up arbitrary inherited descriptors or run a settings job before
# authenticating that the supplied descriptor belongs to the private lock.
(
	exec 4</dev/null 187</dev/null
	settings_update_job_locked() { exit 99; }
	if settings_update 1 /etc/AdGuardHome 0 none 0 60 revision token candidate 4; then
		exit 1
	fi
	[ -e /proc/self/fd/187 ]
	if settings_update 1 /etc/AdGuardHome 0 none 0 60 revision token candidate; then
		exit 1
	fi
)

# The new RAM task shares the real private-state and inherited-FD protocol.
# Only settings/process discovery and the data copy are replaced here.
for name in yaml_job_hash_valid yaml_job_token_valid yaml_job_runtime_is_private \
	yaml_job_file_is_private yaml_job_pending_matches write_yaml_job_state \
	memory_writeback_locked_command memory_writeback_job_locked memory_writeback_job; do
	eval "$(function_body "$test_tmp/init.expanded" "$name")"
done
for scenario in bad-lock pending candidate stale hash-failure inactive stopped \
	copy-failure reporting-failure success; do (
	expected=1111111111111111111111111111111111111111111111111111111111111111
	other=3333333333333333333333333333333333333333333333333333333333333333
	token=22222222222222222222222222222222
	candidate="$(printf 'memory_writeback:%s' "$expected" | sha256sum)"
	candidate="${candidate%% *}"
	[ "$scenario" != candidate ] || candidate="$other"
	pending="pending:${expected}:${candidate}"
	[ "$scenario" != pending ] || pending="pending:${other}:${candidate}"
	state_file="$test_tmp/$token"
	events="$test_tmp/writeback-events"
	printf '%s\n' "$pending" >"$state_file"
	chmod 0600 "$state_file"
	: >"$events"
	load_settings() {
		[ "$1:${SETTINGS_CAS_GUARD:-0}" = light:1 ] || return 1
		printf 'settings\n' >>"$events"
		service_enabled=1 memory_requested=1 MEMORY_ACTIVE=1
		persistent_work_dir=/etc/AdGuardHome
		MEMORY_BACKING_WORK_DIR="$persistent_work_dir"
		[ "$scenario" != inactive ] || MEMORY_ACTIVE=0
	}
	settings_current_revision() {
		if [ "$scenario" = stale ]; then printf '%s\n' "$other"; else printf '%s\n' "$expected"; fi
		[ "$scenario" != hash-failure ]
	}
	official_running() { [ "$scenario" != stopped ]; }
	log_error() { printf 'log:%s\n' "$*" >>"$events"; }
	memory_copy_live_data_locked() {
		printf 'copy\n' >>"$events"
		[ "$scenario" != copy-failure ] || return 1
		[ "$scenario" != reporting-failure ] || YAML_JOB_RUNTIME_DIR="$test_tmp/unavailable"
		return 0
	}
	OFFICIAL_SERVICE=unexpected_service
	unexpected_service() { printf 'unexpected-service:%s\n' "$*" >>"$events"; return 1; }
	orchestrate_core_locked() { unexpected_service orchestrate; }
	clear_recorded_integration_locked() { unexpected_service clear-dns; }
	lock_fd=3
	exec 3<>"$test_tmp/update.lock"
	/usr/bin/flock -n -x 3
	if [ "$scenario" = bad-lock ]; then exec 4</dev/null; lock_fd=4; fi
	rc=0
	memory_writeback_job "$expected" "$candidate" "$token" "$lock_fd" || rc=$?
	case "$scenario" in
		bad-lock|pending|candidate)
			[ "$rc" != 0 ] && [ ! -s "$events" ] || exit 1
			[ "$(cat "$state_file")" = "$pending" ]
			;;
		success)
			[ "$rc" = 0 ] && [ "$(grep -c '^copy$' "$events")" = 1 ] || exit 1
			[ "$(cat "$state_file")" = "success:${candidate}:0:${expected}:${candidate}" ]
			;;
		reporting-failure)
			[ "$rc" != 0 ] && [ "$(grep -c '^copy$' "$events")" = 1 ] || exit 1
			grep -Eq "^running:[1-9][0-9]*:${expected}:${candidate}$" "$state_file"
			;;
		*)
			[ "$rc" = 1 ] && [ "$(cat "$state_file")" = "failure:${expected}:${candidate}" ] || exit 1
			if [ "$scenario" = copy-failure ]; then
				[ "$(grep -c '^copy$' "$events")" = 1 ]
			else
				if grep -q '^copy$' "$events"; then exit 1; fi
			fi
			case "$scenario" in
				copy-failure|hash-failure)
					[ "$(grep '^log:' "$events")" = 'log:Requested RAM data write-back failed' ]
					;;
				*)
					[ "$(grep '^log:' "$events")" = 'log:Requested RAM data write-back is stale or RAM data is no longer running' ]
					;;
			esac
			;;
	esac
	! grep -q '^unexpected-service:' "$events" || exit 1
); done

printf 'ok - settings/YAML share authenticated inherited-FD cleanup and retain task locks\n'
