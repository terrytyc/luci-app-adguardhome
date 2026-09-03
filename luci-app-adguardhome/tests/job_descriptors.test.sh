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

printf 'ok - settings/YAML share authenticated inherited-FD cleanup and retain task locks\n'
