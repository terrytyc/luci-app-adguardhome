#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
init_file="$package_dir/root/etc/init.d/AdGuardHome"
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

hook_body() {
	awk -v hook="$2" '
		BEGIN { start = "define Package/$(PKG_NAME)/" hook }
		$0 == start { copying = 1; next }
		copying && /^endef$/ { exit }
		copying { print }
	' "$1"
}

preinst="$(hook_body "$makefile" preinst)"
postinst="$(hook_body "$makefile" postinst)"
prerm="$(hook_body "$makefile" prerm)"
postrm="$(hook_body "$makefile" postrm)"
for body in "$preinst" "$postinst" "$prerm" "$postrm"; do
	[ -n "$body" ] || {
		printf 'missing package lifecycle hook\n' >&2
		exit 1
	}
done

overwrite_block="$(printf '%s\n' "$preinst" |
	sed -n '/^if \[ -e \/etc\/init.d\/AdGuardHome \]/,/^fi$/p')"
for required in \
	'[ -f /etc/init.d/AdGuardHome ]' \
	'[ ! -L /etc/init.d/AdGuardHome ]' \
	'[ -x /etc/init.d/AdGuardHome ]' \
	'run_bounded 180 5 /etc/init.d/AdGuardHome stop'; do
	printf '%s\n' "$overwrite_block" | grep -Fq "$required" || {
		printf 'overwrite preflight missing: %s\n' "$required" >&2
		exit 1
	}
done
if printf '%s\n' "$overwrite_block" |
	grep -Eq 'source_version|upgrade[_-]state|was_running|original_snapshot'; then
	printf 'overwrite preflight still carries versioned upgrade state\n' >&2
	exit 1
fi

test_tmp="$(mktemp -d /tmp/luci-agh-overwrite.XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
coordinator="$test_tmp/AdGuardHome"
stop_marker="$test_tmp/stopped"
export stop_marker
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >"$stop_marker"\n' >"$coordinator"
chmod 0700 "$coordinator"
runtime_overwrite="$(printf '%s\n' "$overwrite_block" |
	sed 's|/etc/init.d/AdGuardHome|"$coordinator"|g')"
(
	run_bounded() {
		[ "$1:$2" = 180:5 ] || exit 1
		shift 2
		"$@"
	}
	eval "$runtime_overwrite"
	exit 0
) || {
	printf 'overwrite preflight did not stop and exit cleanly\n' >&2
	exit 1
}
[ "$(cat "$stop_marker")" = stop ]

managed_block="$(sed -n \
	'/^if \[ "$(uci -q get "$UCI_CONFIG.$LUCI_SECTION")" = luci \]; then$/,/^fi$/p' \
	"$defaults")"
for required in managed_config_is_valid keep_active_config \
	refresh_managed_config_snapshot 'exit 0'; do
	printf '%s\n' "$managed_block" | grep -Fq "$required" || {
		printf 'managed overwrite selection missing: %s\n' "$required" >&2
		exit 1
	}
done
if printf '%s\n' "$managed_block" |
	grep -Eq 'uci[[:space:]]+-q[[:space:]]+(set|delete|commit)|select_clean_install_source|initialize_clean_options|normalize_config'; then
	printf 'managed overwrite mutates or migrates the installed configuration\n' >&2
	exit 1
fi

managed_log="$test_tmp/managed"
export managed_log
(
	UCI_CONFIG=adguardhome
	LUCI_SECTION=luci
	OFFICIAL_SECTION=config
	SNAPSHOT_DIR=/root/.luci-app-adguardhome
	INSTALL_COMMITTED=0
	uci() {
		[ "$1:$2" = -q:get ] || return 1
		case "$3" in
			adguardhome.luci) printf 'luci\n' ;;
			adguardhome.config.work_dir) printf '/etc/AdGuardHome\n' ;;
			*) return 1 ;;
		esac
	}
	managed_config_is_valid() { printf 'validated\n' >>"$managed_log"; }
	keep_active_config() {
		[ "$1:$2" = "/etc/AdGuardHome/AdGuardHome.yaml:$SNAPSHOT_DIR" ] || return 1
		printf 'kept\n' >>"$managed_log"
	}
	refresh_managed_config_snapshot() { printf 'refreshed\n' >>"$managed_log"; }
	eval "$managed_block"
	exit 97
) || {
	printf 'managed overwrite branch did not preserve and exit cleanly\n' >&2
	exit 1
}
[ "$(cat "$managed_log")" = "$(printf 'validated\nkept\nrefreshed')" ]

eval "$(function_body "$init_file" install_check)"
eval "$(function_body "$init_file" log_error)"
logger() { printf '%s\n' "$*" >>"$test_tmp/check-log"; }
open_integration_read_lock() { [ "$lock_ready" = 1 ]; }
read_settings() { [ "$settings_ready" = 1 ]; }
official_running() { [ "$core_running" = 1 ]; }
load_runtime_dns_port() { dns_port=53335; [ "$yaml_ready" = 1 ]; }
official_socket_snapshot() { [ "$core_running" = 1 ]; }
official_memory_data_mount_visible() { [ "$memory_visible" = 1 ]; }
dns_port_listening() { [ "$dns_ready:$memory_visible" = 1:1 ]; }
integration_status_locked() { [ "$1:$2" = 53335:none ]; return "$integration_rc"; }
redirect_mode=none
for scenario in disabled disabled_running ready lock settings yaml no_core no_memory no_listener no_integration invalid_integration; do
	service_enabled=1 core_running=1 dns_ready=1 integration_rc=0 expected=0
	lock_ready=1 settings_ready=1 yaml_ready=1 memory_visible=1 reason=''
	case "$scenario" in
		disabled) service_enabled=0 core_running=0 ;;
		disabled_running) service_enabled=0 reason='the disabled core is still running' ;;
		lock) lock_ready=0 reason='unable to acquire the integration lock within 30 seconds' ;;
		settings) settings_ready=0 reason='unable to read valid service settings and runtime paths' ;;
		yaml) yaml_ready=0 reason='unable to read a valid DNS port from the active YAML' ;;
		no_core) core_running=0 reason='the supervised core has no owned sockets' ;;
		no_memory) memory_visible=0 reason='the supervised core cannot see the active RAM data mount' ;;
		no_listener) dns_ready=0 reason='the supervised core is not listening on DNS port 53335 for none' ;;
		no_integration) integration_rc=1 reason='DNS integration does not match none on port 53335' ;;
		invalid_integration) integration_rc=2 reason='DNS integration configuration is unavailable or has pending changes' ;;
	esac
	[ -z "$reason" ] || expected=1
	: >"$test_tmp/check-log"
	rc=0
	install_check 2>"$test_tmp/check-error" || rc=$?
	[ "$rc" = "$expected" ] || {
		printf 'installation verification failed: %s\n' "$scenario" >&2
		exit 1
	}
	if [ "$expected" = 1 ]; then
		[ "$(cat "$test_tmp/check-error")" = "Installation verification failed: $reason" ]
		[ "$(cat "$test_tmp/check-log")" = "-t AdGuardHome Installation verification failed: $reason" ]
	else
		[ ! -s "$test_tmp/check-error" ] && [ ! -s "$test_tmp/check-log" ]
	fi
done

# A healthy monitor can briefly own the real integration lock after startup.
# UI snapshots stay nonblocking; installation waits before reading settings.
(
	eval "$(function_body "$init_file" open_integration_read_lock)"
	eval "$(function_body "$init_file" integration_status)"
	INTEGRATION_LOCK="$test_tmp/integration.lock"
	: >"$INTEGRATION_LOCK"
	service_enabled=1 dns_ready=1 integration_rc=0
	read_settings() {
		[ -e "$test_tmp/lock-released" ] || return 1
		printf 'read\n' >>"$test_tmp/settings-read"
	}
	(
		exec 9>"$INTEGRATION_LOCK"
		/usr/bin/flock -x 9
		: >"$test_tmp/lock-acquired"
		sleep 1
		: >"$test_tmp/lock-released"
	) &
	lock_owner=$!
	while [ ! -e "$test_tmp/lock-acquired" ]; do
		kill -0 "$lock_owner" || exit 1
		sleep .01
	done
	rc=0; integration_status 53335 none || rc=$?
	[ "$rc" = 2 ] && [ ! -e "$test_tmp/lock-released" ]
	rc=0; (open_integration_read_lock -w 0) || rc=$?
	[ "$rc" = 2 ] && [ ! -e "$test_tmp/settings-read" ]
	install_check
	wait "$lock_owner"
	[ "$(cat "$test_tmp/settings-read")" = read ]
	dns_ready=0
	rc=0; install_check 2>"$test_tmp/check-error" || rc=$?
	[ "$rc" = 1 ]
)

start_body="$(function_body "$init_file" start_service)"
printf '%s\n' "$start_body" |
	grep -Fq '/etc/uci-defaults/40_luci-AdGuardHome' || {
	printf 'start no longer blocks incomplete first-install initialization\n' >&2
	exit 1
}

for removed in ADGUARDHOME_UPGRADE_SOURCES UpgradePolicy upgrade-policy \
	upgrade_state UPGRADE_STATE BASELINE_UPGRADE_STATE \
	ADGUARDHOME_BASELINE_RESUME source_version official-adguardhome.uci; do
	if grep -Fq "$removed" "$makefile" "$defaults" "$init_file" \
	   "$package_dir/scripts/expand-helpers.awk"; then
		printf 'removed upgrade compatibility remains: %s\n' "$removed" >&2
		exit 1
	fi
done
[ ! -e "$package_dir/scripts/upgrade-policy.mk" ]

if printf '%s\n' "$postinst" | grep -Eq '/etc/init.d/AdGuardHome (start|stop|restart)'; then
	printf 'package postinst duplicates the generated init-script convergence\n' >&2
	exit 1
fi
rpcd_reload='[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || exit 1'
[ "$(printf '%s\n' "$postinst" | grep -Fc "$rpcd_reload")" = 1 ]
printf '%s\n' "$prerm" | grep -Fq '1:*|*:upgrade) exit 0'
printf '%s\n' "$postrm" | grep -Fq '1:*|*:upgrade) exit 0'
printf '%s\n' "$postrm" | grep -Fq 'rmdir "$$snapshot_dir" 2>/dev/null || true'

cleanup_body="$(function_body "$defaults" cleanup_install)"
for required in \
	'INSTALL_BACKUP' \
	'[ "$INSTALL_STARTED" = 1 ]' \
	'[ "$INSTALL_COMMITTED" != 1 ]' \
	'restore_install_config'; do
	printf '%s\n' "$cleanup_body" | grep -Fq "$required" || {
		printf 'first-install rollback contract missing: %s\n' "$required" >&2
		exit 1
	}
done
[ "$(grep -Fc 'INSTALL_STARTED=1' "$defaults")" = 1 ]
[ "$(grep -n '^INSTALL_STARTED=1' "$defaults" | cut -d: -f1)" -lt \
	"$(grep -n '^run_bounded 20 2 /etc/init.d/adguardhome stop' "$defaults" | cut -d: -f1)" ]

rm -rf "$test_tmp"
trap - EXIT HUP INT TERM
printf 'ok - native overwrite preserves configuration without versioned upgrade state\n'
