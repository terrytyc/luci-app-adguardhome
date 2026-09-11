#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
. "$script_dir/lib/function-body.sh"
temporary="$(mktemp -d /tmp/luci-agh-install-rollback.XXXXXX)"
mounted_tree=""
cleanup() {
	[ -z "$mounted_tree" ] || /bin/umount "$mounted_tree" 2>/dev/null || true
	rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

# Test real temporary backup/atomic restore, with only platform calls isolated.
for name in bounded_regular_file trim_trailing_slashes resolve_source_work_dir \
	plain_data_tree install_transaction_dir_valid \
	official_delta_is_clean capture_install_config restore_install_config \
	restore_install_files discard_install_transaction cleanup_install; do
	function_body "$defaults" "$name" | sed "s|/etc/config|$temporary/config|g" >>"$temporary/functions"
done
. "$temporary/functions"
install_yaml_body="$(function_body "$defaults" install_selected_yaml)"
restore_files_body="$(function_body "$defaults" restore_install_files)"
discard_body="$(function_body "$defaults" discard_install_transaction)"
printf '%s\n' "$install_yaml_body" | grep -Fq '/bin/cp -p "$TARGET_CONFIG_FILE" "$old_yaml_stage"'
printf '%s\n' "$install_yaml_body" | grep -Fq 'mv "$old_yaml_stage" "$old_yaml"'
printf '%s\n' "$install_yaml_body" | grep -Fq 'mv -f "$target_stage" "$TARGET_CONFIG_FILE"'
if printf '%s\n' "$install_yaml_body" | grep -Fq 'mv "$TARGET_CONFIG_FILE" "$old_yaml"'; then
	printf 'installer still removes the active YAML before publishing its replacement\n' >&2
	exit 1
fi
printf '%s\n' "$restore_files_body" | grep -Fq 'mv -f "$old_yaml" "$TARGET_CONFIG_FILE"'
old_yaml_restore_body="$(printf '%s\n' "$restore_files_body" | awk '
	index($0, "if [ -e \"$old_yaml\"") { copying=1 }
	copying && index($0, "elif [ \"$YAML_ORIGINAL_ABSENT\"") { exit }
	copying { print }
')"
if printf '%s\n' "$old_yaml_restore_body" | grep -Fq 'rm -f "$TARGET_CONFIG_FILE"'; then
	printf 'rollback still removes the active YAML before restoring its replacement\n' >&2
	exit 1
fi
printf '%s\n' "$restore_files_body" | grep -Fq 'rm -f "$TARGET_CONFIG_FILE"'
printf '%s\n' "$discard_body" | grep -Fq 'plain_data_tree "$INSTALL_TRANSACTION_DIR"'
mkdir "$temporary/config"
MAX_FILE_SIZE=524288
UCI_CONFIG=adguardhome
INSTALL_BACKUP=
INSTALL_WAS_RUNNING=0
YAML_STAGE=
INSTALL_TRANSACTION_DIR=
TARGET_WORK_DIR_CREATED=0
YAML_ORIGINAL_ABSENT=0
DATA_ORIGINAL_ABSENT=0
RUNTIME_DIR="$temporary/runtime"
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
[ -f "$backup" ] && grep -Fq 'recovery files were kept' "$temporary/error"

# A failed first-install transaction restores both overwritten targets, while
# a target that was originally absent returns to absent.  Partial staged data
# is private and never becomes authoritative.
root_private_directory() { [ -d "$1" ] && [ ! -L "$1" ]; }

# mountinfo escapes whitespace and backslashes.  Migration paths use the same
# restricted alphabet as managed paths so nested-mount comparisons stay exact.
mkdir "$temporary/source-safe" "$temporary/source data"
[ "$(resolve_source_work_dir "$temporary/source-safe")" = "$temporary/source-safe" ]
if resolve_source_work_dir "$temporary/source data" >/dev/null 2>&1; then
	printf 'unsafe migration source with whitespace was accepted\n' >&2
	exit 1
fi
ln -s "$temporary/source data" "$temporary/source-link"
if resolve_source_work_dir "$temporary/source-link" >/dev/null 2>&1; then
	printf 'migration source resolving to an unsafe path was accepted\n' >&2
	exit 1
fi

# find -xdev alone misses nested bind mounts; recursive rollback/removal must
# reject them before it can touch a mounted external tree.
printf '%s\n' "$(function_body "$defaults" plain_data_tree)" |
	grep -Fq /proc/self/mountinfo
if [ "$(id -u)" = 0 ]; then
	mkdir -p "$temporary/mount-tree/nested" "$temporary/external"
	printf 'keep\n' >"$temporary/external/value"
	if /bin/mount --bind "$temporary/external" "$temporary/mount-tree/nested" \
	   2>/dev/null; then
		mounted_tree="$temporary/mount-tree/nested"
		if plain_data_tree "$temporary/mount-tree"; then
			printf 'nested bind mount was accepted for recursive removal\n' >&2
			exit 1
		fi
		/bin/umount "$mounted_tree"
		mounted_tree=""
		[ "$(cat "$temporary/external/value")" = keep ]
	fi
fi
TARGET_WORK_DIR="$temporary/work"
TARGET_CONFIG_FILE="$TARGET_WORK_DIR/AdGuardHome.yaml"
mkdir -p "$TARGET_WORK_DIR/data"
printf 'new yaml\n' >"$TARGET_CONFIG_FILE"
printf 'new data\n' >"$TARGET_WORK_DIR/data/querylog.json"
YAML_STAGE="$temporary/normalized.yaml"
printf 'new yaml\n' >"$YAML_STAGE"
INSTALL_TRANSACTION_DIR="$TARGET_WORK_DIR/.luci-install.ABC123"
mkdir "$INSTALL_TRANSACTION_DIR" "$INSTALL_TRANSACTION_DIR/data.old"
printf 'old yaml\n' >"$INSTALL_TRANSACTION_DIR/AdGuardHome.yaml.old"
YAML_ORIGINAL_ABSENT=0
DATA_ORIGINAL_ABSENT=0
restore_install_files
[ "$(cat "$TARGET_CONFIG_FILE")" = 'old yaml' ]
[ -d "$TARGET_WORK_DIR/data" ] &&
	[ -z "$(find "$TARGET_WORK_DIR/data" -mindepth 1 -print)" ]
discard_install_transaction

rm -f "$TARGET_CONFIG_FILE"
rmdir "$TARGET_WORK_DIR/data"
printf 'new yaml\n' >"$TARGET_CONFIG_FILE"
mkdir "$TARGET_WORK_DIR/data"
printf 'new data\n' >"$TARGET_WORK_DIR/data/querylog.json"
INSTALL_TRANSACTION_DIR="$TARGET_WORK_DIR/.luci-install.DEF456"
mkdir -p "$INSTALL_TRANSACTION_DIR/data.new"
printf 'partial\n' >"$INSTALL_TRANSACTION_DIR/data.new/partial"
YAML_ORIGINAL_ABSENT=1
DATA_ORIGINAL_ABSENT=1
restore_install_files
[ ! -e "$TARGET_CONFIG_FILE" ] && [ ! -e "$TARGET_WORK_DIR/data" ]
discard_install_transaction

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
begin_yaml_maintenance() { :; }
rollback_yaml_maintenance() { :; }
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
