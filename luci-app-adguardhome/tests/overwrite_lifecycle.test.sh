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
	'run_bounded 180 5 /etc/init.d/AdGuardHome stop' \
	'exit 0'; do
	printf '%s\n' "$overwrite_block" | grep -Fq "$required" || {
		printf 'overwrite preflight missing: %s\n' "$required" >&2
		exit 1
	}
done
if printf '%s\n' "$overwrite_block" |
	grep -Eq 'source_version|upgrade[_-]state|was_running|snapshot'; then
	printf 'overwrite preflight still carries versioned upgrade state\n' >&2
	exit 1
fi

stop_line="$(printf '%s\n' "$preinst" |
	grep -n 'run_bounded 180 5 /etc/init.d/AdGuardHome stop' | cut -d: -f1)"
snapshot_line="$(printf '%s\n' "$preinst" |
	grep -n '^SNAPSHOT_DIR=' | cut -d: -f1)"
[ "$stop_line" -lt "$snapshot_line" ] || {
	printf 'overwrite is not selected before first-install snapshot creation\n' >&2
	exit 1
}

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
	exit 97
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
	'cleanup_snapshot_stage' \
	'[ "$INSTALL_STARTED" = 1 ]' \
	'[ "$INSTALL_COMMITTED" != 1 ]' \
	'restore_original_config'; do
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
