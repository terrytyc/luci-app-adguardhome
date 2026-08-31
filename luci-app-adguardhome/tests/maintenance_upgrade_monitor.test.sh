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

printf 'ok - fail-closed maintenance monitor replacement contract\n'
