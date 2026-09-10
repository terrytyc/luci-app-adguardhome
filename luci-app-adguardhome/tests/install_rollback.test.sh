#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
. "$script_dir/lib/function-body.sh"
temporary="$(mktemp -d /tmp/luci-agh-install-rollback.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# Test real temporary backup/atomic restore, with only platform calls isolated.
for name in bounded_regular_file official_delta_is_clean capture_install_config \
	restore_install_config cleanup_install; do
	function_body "$defaults" "$name" | sed "s|/etc/config|$temporary/config|g" >>"$temporary/functions"
done
. "$temporary/functions"
mkdir "$temporary/config"
MAX_FILE_SIZE=524288
UCI_CONFIG=adguardhome
INSTALL_BACKUP=
INSTALL_WAS_RUNNING=0
YAML_STAGE=
events="$temporary/events"
uci() { [ "$2" = changes ] || [ "$2" = revert ]; }
bounded_private_file() { bounded_regular_file "$1"; }
chown() { :; }
run_bounded() {
	shift 2
	if [ "$1" = /etc/init.d/adguardhome ]; then
		case "$2" in
			running) return "$fixture_running_rc" ;;
			start) printf 'start\n' >>"$events" ;;
			*) return 1 ;;
		esac
	else
		"$@"
	fi
}
for fixture_running_rc in 0 1; do
	printf 'original\n' >"$temporary/config/adguardhome"
	: >"$events"
	capture_install_config
	backup="$INSTALL_BACKUP"
	printf 'changed\n' >"$temporary/config/adguardhome"
	(
		INSTALL_STARTED=1
		INSTALL_COMMITTED=0
		cleanup_install
	)
	[ "$(cat "$temporary/config/adguardhome")" = original ]
	[ ! -e "$backup" ]
	if [ "$fixture_running_rc" = 0 ]; then [ "$(cat "$events")" = start ]; else [ ! -s "$events" ]; fi
done

# Success keeps current settings; a failed recovery retains its private backup.
capture_install_config
backup="$INSTALL_BACKUP"
printf 'current\n' >"$temporary/config/adguardhome"
(INSTALL_STARTED=1; INSTALL_COMMITTED=1; cleanup_install)
[ "$(cat "$temporary/config/adguardhome")" = current ] && [ ! -e "$backup" ]
capture_install_config
backup="$INSTALL_BACKUP"
if (INSTALL_STARTED=1; INSTALL_COMMITTED=0; restore_install_config() { return 1; }; cleanup_install) 2>"$temporary/error"; then
	exit 1
fi
[ -f "$backup" ] && grep -Fq "$backup" "$temporary/error"

# Neither install preflight nor uninstall may depend on a historic snapshot.
! grep -Eq 'OriginalSnapshot|validate_original_snapshot|official-adguardhome.config' "$package_dir/Makefile"
! grep -Fq '# @include original-snapshot' "$defaults"

# Run the actual removal body against isolated service scripts. There is no
# original snapshot; current UCI/YAML/data must survive enabled and disabled cases.
fixture_root="$temporary/router"
mkdir -p "$fixture_root/etc/init.d" "$fixture_root/etc/config" \
	"$fixture_root/etc/AdGuardHome/data" "$fixture_root/var/run"
export events
printf '#!/bin/sh\nprintf "coordinator:%%s\\n" "$*" >>"$events"\nexit "${fixture_fail:-0}"\n' \
	>"$fixture_root/etc/init.d/AdGuardHome"
printf '#!/bin/sh\nprintf "core:%%s\\n" "$1" >>"$events"\n' \
	>"$fixture_root/etc/init.d/adguardhome"
chmod 0700 "$fixture_root/etc/init.d/AdGuardHome" "$fixture_root/etc/init.d/adguardhome"
awk '
	$0 == "define Package/$(PKG_NAME)/prerm" { copying=1; next }
	copying && /^endef$/ { exit }
	copying && !/^\$\(AdGuardHome\// { gsub(/\$\$/, "$"); print }
' "$package_dir/Makefile" | sed "s|/etc/|$fixture_root/etc/|g;s|/var/run/|$fixture_root/var/run/|g" \
	>"$temporary/prerm"
root_private_directory() { [ -d "$1" ] && [ ! -L "$1" ]; }
for enabled in 0 1; do
	printf 'enabled=%s\n' "$enabled" >"$fixture_root/etc/config/adguardhome"
	printf 'current YAML\n' >"$fixture_root/etc/AdGuardHome/AdGuardHome.yaml"
	printf 'current data\n' >"$fixture_root/etc/AdGuardHome/data/querylog.json"
	before="$(cksum "$fixture_root/etc/config/adguardhome" "$fixture_root/etc/AdGuardHome/AdGuardHome.yaml" \
		"$fixture_root/etc/AdGuardHome/data/querylog.json")"
	: >"$events"
	(IPKG_INSTROOT=; PKG_UPGRADE=0; set -- remove; . "$temporary/prerm")
	[ "$(cat "$events")" = "$(printf 'coordinator:do_redirect 0\ncoordinator:memory_cleanup\ncore:stop\ncore:disable')" ]
	[ "$(cat "$fixture_root/var/run/luci-app-adguardhome/remove-ok")" = 1 ]
	[ "$(cksum "$fixture_root/etc/config/adguardhome" "$fixture_root/etc/AdGuardHome/AdGuardHome.yaml" \
		"$fixture_root/etc/AdGuardHome/data/querylog.json")" = "$before" ]
done
rm "$fixture_root/var/run/luci-app-adguardhome/remove-ok"
if (export fixture_fail=1; IPKG_INSTROOT=; PKG_UPGRADE=0; set -- remove; . "$temporary/prerm"); then
	exit 1
fi
[ ! -e "$fixture_root/var/run/luci-app-adguardhome/remove-ok" ]
printf 'ok - first-install rollback and history-free uninstall preserve current UCI/YAML/data\n'
