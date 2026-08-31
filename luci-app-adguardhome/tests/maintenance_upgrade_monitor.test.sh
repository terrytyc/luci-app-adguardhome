#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
makefile="${package_dir}/Makefile"
init_file="${package_dir}/root/etc/init.d/AdGuardHome"

for file in "$makefile" "$init_file"; do
	[ -f "$file" ] || {
		printf 'required maintenance source not found: %s\n' "$file" >&2
		exit 1
	}
done

wrapper_bodies="$(awk '
	$0 == "maintenance_wrapper_registered() {" { copying = 1; count++ }
	copying { print }
	copying && $0 == "}" { copying = 0 }
	END { if (count != 2) exit 1 }
' "$makefile")" || {
	printf 'expected both preinst and postinst coordinator-state readers\n' >&2
	exit 1
}

# A command mismatch is an unexpected service object (status 2), never the
# stopped/absent status 1.  Both lifecycle copies must encode that distinction.
# The doubled dollars are literal Make recipe text, not shell variables.
# shellcheck disable=SC2016
exact_returns="$(printf '%s\n' "$wrapper_bodies" |
	grep -c '\[ "\$\$command1" = monitor \] && return 0')"
unexpected_returns="$(printf '%s\n' "$wrapper_bodies" | awk '
	previous ~ /\[ "\$\$command1" = monitor \] && return 0/ &&
		$0 ~ /^[[:space:]]*return 2$/ { count++ }
	{ previous = $0 }
	END { print count + 0 }
')"
if [ "$exact_returns" != 2 ] || [ "$unexpected_returns" != 2 ]; then
	printf 'maintenance coordinator command mismatches are not fail-closed\n' >&2
	exit 1
fi

contained_body="$(awk '
	$0 == "maintenance_monitor_pid_is_contained() {" { copying = 1 }
	copying { print }
	copying && $0 == "}" { exit }
' "$makefile")"
[ -n "$contained_body" ] || {
	printf 'maintenance cgroup containment check is missing\n' >&2
	exit 1
}

# The doubled dollars in one pattern are literal Make recipe text.
# shellcheck disable=SC2016
for required in \
	"instances.monitor.running" \
	'true|1)' \
	'false|0)' \
	'grep -qx "$$pid" "$$directory/cgroup.procs"' \
	'! printf'; do
	printf '%s\n' "$contained_body" | grep -Fq -- "$required" || {
		printf 'maintenance cgroup containment contract is missing: %s\n' "$required" >&2
		exit 1
	}
done

if printf '%s\n' "$contained_body" |
	grep -Fq 'maintenance_monitor_pid)" || return 0'; then
	printf 'maintenance PID lookup still treats query errors as respawn delay\n' >&2
	exit 1
fi

# The installed monitor must remain inert while postinst holds an authenticated
# maintenance bundle.  This protects the official lowercase core on every
# postinst failure path after the old generation has been retired.
monitor_guard="$(awk '
	$0 == "monitor() {" { copying = 1 }
	copying { print }
	copying && $0 == "}" { exit }
' "$init_file")"
case "$monitor_guard" in
	*'maintenance_upgrade_marker_is_valid'*'yaml_maintenance_marker_is_private'*'continue'*'run_locked reconcile_core_locked'*) ;;
	*)
		printf 'installed monitor does not stay passive through maintenance upgrade\n' >&2
		exit 1
		;;
esac

# Cold upgrades are handled by default_postinst, whose init-loop return value
# does not reflect a failed service start.  A private handoff record must carry
# the source running state into the custom postinst, and that hook must verify
# the exact running/stopped outcome before retiring the record.
for required in \
	'cold_postinst_dir=/var/run/luci-app-adguardhome-postinst' \
	'cold_postinst_state="$${cold_postinst_dir}/cold-upgrade"' \
	'write_cold_postinst_state() {' \
	'load_cold_postinst_state() {' \
	'verify_cold_upgrade_completion() {' \
	'retire_cold_postinst_state() {' \
	"printf 'format=1\\n'" \
	"printf 'source_version=%s\\n' \"\$\$upgrade_source_version\"" \
	"printf 'was_running=%s\\n' \"\$\$upgrade_was_running\"" \
	'run_bounded 180 5 /etc/init.d/AdGuardHome do_redirect 1' \
	'if [ "$$active" = 1 ]; then' \
	"case \"\$\$old_enabled\" in ''|0) ;; *) return 1 ;; esac" \
	'root_private_bounded_job_file "$$cold_postinst_state"'; do
	grep -Fq -- "$required" "$makefile" || {
		printf 'cold-upgrade completion contract is missing: %s\n' "$required" >&2
		exit 1
	}
done

cold_verify_body="$(awk '
	$0 == "verify_cold_upgrade_completion() {" { copying = 1; depth = 0 }
	copying {
		print
		opens = gsub(/\{/, "{")
		closes = gsub(/\}/, "}")
		depth += opens - closes
		if (depth == 0) exit
	}
' "$makefile")"
[ -n "$cold_verify_body" ] || {
	printf 'cold-upgrade completion verifier is missing\n' >&2
	exit 1
}
case "$cold_verify_body" in
	*'case "$$cold_was_running" in'*'maintenance_wrapper_registered'*'maintenance_core_identity'*'verify_cold_storage_state 1'*'verify_cold_storage_state 0'*) ;;
	*)
		printf 'cold-upgrade running/stopped verifier is incomplete\n' >&2
		exit 1
		;;
esac
if printf '%s\n' "$cold_verify_body" | grep -Eq '(^|[[:space:]])sleep([[:space:]]|$)'; then
	printf 'cold-upgrade completion uses a fixed sleep instead of bounded state checks\n' >&2
	exit 1
fi

snapshot_line="$(grep -n '^cold_snapshot_upgrade_yaml "\$\$upgrade_workdir"' "$makefile" |
	cut -d: -f1)"
publish_line="$(grep -n '^write_cold_postinst_state ||' "$makefile" | cut -d: -f1)"
commit_line="$(grep -n '^cold_postinst_committed=1$' "$makefile" | cut -d: -f1)"
verify_line="$(grep -n '^[[:space:]]*verify_cold_upgrade_completion ||' "$makefile" |
	cut -d: -f1)"
retire_line="$(grep -n '^retire_cold_postinst_state ||' "$makefile" | cut -d: -f1)"
case "$snapshot_line:$publish_line:$commit_line:$verify_line:$retire_line" in
	*[!0-9:]*|:*|*:|*::*)
		printf 'cold-upgrade lifecycle ordering markers are ambiguous\n' >&2
		exit 1
		;;
esac
if [ "$snapshot_line" -ge "$publish_line" ] ||
   [ "$publish_line" -ge "$commit_line" ] ||
   [ "$verify_line" -ge "$retire_line" ]; then
	printf 'cold-upgrade completion state is published, verified, or retired out of order\n' >&2
	exit 1
fi

printf 'ok - fail-closed maintenance monitor replacement contract\n'
