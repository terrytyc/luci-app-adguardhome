#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
makefile="$package_dir/Makefile"
temporary="$(mktemp -d /tmp/luci-agh-maintenance.XXXXXX)"
holder=""
waiter=""
cleanup() {
	trap - EXIT HUP INT TERM
	[ -z "$waiter" ] || kill "$waiter" 2>/dev/null || true
	[ -z "$holder" ] || kill "$holder" 2>/dev/null || true
	[ -z "$waiter" ] || wait "$waiter" 2>/dev/null || true
	[ -z "$holder" ] || wait "$holder" 2>/dev/null || true
	rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

extract_define() {
	awk -v name="$2" '
		$0 == "define AdGuardHome/" name { copying = 1; next }
		copying && /^endef$/ { exit }
		copying { gsub(/\$\$/, "$"); print }
	' "$1"
}

extract_define "$package_dir/scripts/private-files.mk" PrivateFiles >"$temporary/private"
extract_define "$makefile" YamlMaintenance >"$temporary/maintenance"
# shellcheck disable=SC1090
. "$temporary/private"
# shellcheck disable=SC1090
. "$temporary/maintenance"

set_paths() {
	yaml_job_runtime="$temporary/jobs"
	yaml_job_lock="$yaml_job_runtime/update.lock"
	yaml_maintenance_marker="$yaml_job_runtime/removing"
	yaml_maintenance_created=0
}

# A newly created gate is rolled back on a failed pre-hook.
(
	set_paths
	begin_yaml_maintenance
	[ "$yaml_maintenance_created" = 1 ]
	root_private_directory "$yaml_job_runtime"
	root_private_empty_file "$yaml_job_lock"
	root_private_empty_file "$yaml_maintenance_marker"
	rollback_yaml_maintenance
	[ ! -e "$yaml_maintenance_marker" ] && [ ! -L "$yaml_maintenance_marker" ]
)

# A valid inherited gate belongs to the package transaction, not a failed retry.
rm -rf "$temporary/jobs"
mkdir -m 0700 "$temporary/jobs"
: >"$temporary/jobs/update.lock"
: >"$temporary/jobs/removing"
chmod 0600 "$temporary/jobs/update.lock" "$temporary/jobs/removing"
(
	set_paths
	begin_yaml_maintenance
	[ "$yaml_maintenance_created" = 0 ]
	rollback_yaml_maintenance
	root_private_empty_file "$yaml_maintenance_marker"
	finish_yaml_maintenance
	[ ! -e "$yaml_maintenance_marker" ] && [ ! -L "$yaml_maintenance_marker" ]
)

# Never repair or unlink an unsafe pre-existing marker.
: >"$temporary/jobs/removing"
chmod 0644 "$temporary/jobs/removing"
if (set_paths; begin_yaml_maintenance); then
	printf 'unsafe maintenance marker was accepted\n' >&2
	exit 1
fi
[ -f "$temporary/jobs/removing" ]
[ "$(LC_ALL=C ls -ld "$temporary/jobs/removing" | cut -c 1-10)" = -rw-r--r-- ]

# The marker must not appear until the currently active job releases update.lock.
rm -rf "$temporary/jobs"
mkdir -m 0700 "$temporary/jobs"
: >"$temporary/jobs/update.lock"
chmod 0600 "$temporary/jobs/update.lock"
(
	exec 9>>"$temporary/jobs/update.lock"
	/usr/bin/flock -x 9
	: >"$temporary/holder-ready"
	while [ ! -e "$temporary/release-holder" ]; do sleep 1; done
) &
holder=$!
remaining=10
while [ ! -e "$temporary/holder-ready" ] && [ "$remaining" -gt 0 ]; do
	sleep 1
	remaining=$((remaining - 1))
done
[ -e "$temporary/holder-ready" ]
(
	set_paths
	begin_yaml_maintenance
	: >"$temporary/gate-ready"
) &
waiter=$!
sleep 1
[ ! -e "$temporary/jobs/removing" ]
[ ! -e "$temporary/gate-ready" ]
: >"$temporary/release-holder"
wait "$holder"
wait "$waiter"
holder=""
waiter=""
root_private_empty_file "$temporary/jobs/removing"

hook_body() {
	awk -v hook="$2" '
		BEGIN { start = "define Package/$(PKG_NAME)/" hook }
		$0 == start { copying = 1; next }
		copying && /^endef$/ { exit }
		copying { print }
	' "$1"
}

before() {
	left="$(printf '%s\n' "$1" | grep -nF "$2" | head -1 | cut -d: -f1)"
	right="$(printf '%s\n' "$1" | grep -nF "$3" | head -1 | cut -d: -f1)"
	[ -n "$left" ] && [ -n "$right" ] && [ "$left" -lt "$right" ]
}

preinst="$(hook_body "$makefile" preinst)"
postinst="$(hook_body "$makefile" postinst)"
prerm="$(hook_body "$makefile" prerm)"
postrm="$(hook_body "$makefile" postrm)"
before "$preinst" begin_yaml_maintenance '/etc/init.d/AdGuardHome stop'
before "$postinst" begin_yaml_maintenance '/etc/init.d/rpcd reload'
before "$postinst" '/etc/init.d/rpcd reload' finish_yaml_maintenance
before "$prerm" begin_yaml_maintenance '/etc/init.d/AdGuardHome stop'
before "$postrm" begin_yaml_maintenance '/etc/init.d/rpcd reload'
before "$postrm" '/etc/init.d/rpcd reload' finish_yaml_maintenance
printf '%s\n' "$preinst" | grep -Fq "trap 'rollback_yaml_maintenance' 0"
printf '%s\n' "$prerm" | grep -Fq "trap 'recover_failed_removal' 0"
printf '%s\n' "$prerm" | grep -Fq 'for recovery_config in adguardhome dhcp firewall; do'
if printf '%s\n' "$prerm" |
	grep -Fq 'Commit or revert pending adguardhome changes before uninstalling.'; then
	printf 'pre-deinstall retained its ineffective late UCI guard\n' >&2
	exit 1
fi
before "$prerm" 'rollback_yaml_maintenance >/dev/null' '/etc/init.d/AdGuardHome enable'
before "$prerm" '/etc/init.d/AdGuardHome enable' 'for recovery_config in adguardhome dhcp firewall'
before "$prerm" 'for recovery_config in adguardhome dhcp firewall' '/etc/init.d/AdGuardHome start'
before "$prerm" "trap 'recover_failed_removal' 0" begin_yaml_maintenance
before "$prerm" '/etc/init.d/AdGuardHome stop' 'trap - 0 HUP INT TERM'
printf '%s\n' "$postinst$postrm" |
	grep -Fq '[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || exit 1'

printf 'ok - package maintenance serializes and gates asynchronous YAML jobs\n'
