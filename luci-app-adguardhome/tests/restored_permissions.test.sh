#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
defaults_file="${script_dir}/../root/etc/uci-defaults/40_luci-AdGuardHome"
temporary="$(mktemp -d /tmp/luci-agh-restored-permissions.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in path_contains_symlink secure_active_paths secure_active_config \
	secure_config_inode root_private_config_source trusted_root_file_source \
	capture_root_file_bytes; do
	eval "$(function_body "$init_file" "$name")"
done

work_dir="$temporary/AdGuardHome"
config_file="$work_dir/AdGuardHome.yaml"
ADGUARD_UID=853
ADGUARD_GID=853
mkdir "$work_dir"
printf 'dns:\n  port: 53335\n' >"$config_file"
chmod 0777 "$work_dir"
chmod 0600 "$config_file"

snapshot_config_file() { cp "$1" "$2"; }
run_bounded() { shift 2; "$@"; }
log_error() { :; }
secure_active_paths
(set +u; secure_active_config)
root_private_config_source "$config_file"
if [ "$(id -u)" = 0 ]; then
	trusted_root_file_source "$config_file"
	capture_root_file_bytes "$config_file" "$temporary/captured.yaml" 129
	cmp -s "$config_file" "$temporary/captured.yaml"
fi
[ "$(LC_ALL=C ls -ld "$work_dir" | cut -d' ' -f1)" = drwxrwxrwx ]
[ "$(LC_ALL=C ls -ld "$config_file" | cut -d' ' -f1)" = -rw------- ]

mkdir -m 0777 "$temporary/storage"
work_dir="$temporary/storage/AdGuardHome"
config_file="$work_dir/AdGuardHome.yaml"
mkdir -m 0777 "$work_dir"
printf 'dns:\n  port: 53335\n' >"$config_file"
chmod 0600 "$config_file"
secure_active_paths
root_private_config_source "$config_file"
if [ "$(id -u)" = 0 ]; then
	trusted_root_file_source "$config_file"
	capture_root_file_bytes "$config_file" "$temporary/custom-captured.yaml" 129
	cmp -s "$config_file" "$temporary/custom-captured.yaml"
	chown 65534:65534 "$config_file"
	chmod 0600 "$config_file"
	root_private_config_source "$config_file"
	trusted_root_file_source "$config_file"
	capture_root_file_bytes "$config_file" "$temporary/restored-owner.yaml" 129
	cmp -s "$config_file" "$temporary/restored-owner.yaml"
	chown 65534:853 "$work_dir"
	: >"$work_dir/staged.yaml"
	exec 9<>"$work_dir/staged.yaml"
	secure_config_inode /proc/self/fd/9
	[ "$(LC_ALL=C ls -ldnL /proc/self/fd/9 | awk '{ print $3 ":" $4 ":" $1 }')" = \
		'0:853:-rw-r-----' ]
	exec 9>&-
fi

mv "$config_file" "$temporary/real.yaml"
ln -s "$temporary/real.yaml" "$config_file"
! secure_active_paths || exit 1
rm "$config_file"
mv "$temporary/real.yaml" "$config_file"
ln -s "$temporary" "$work_dir/data"
! secure_active_paths || exit 1

eval "$(function_body "$defaults_file" secure_target_work_dir)"
valid_managed_work_dir() { :; }
TARGET_WORK_DIR="$temporary/existing-workdir"
mkdir -m 0777 "$TARGET_WORK_DIR"
[ "$(id -u)" != 0 ] || chown 65534:65534 "$TARGET_WORK_DIR"
before="$(LC_ALL=C ls -ldn "$TARGET_WORK_DIR" | awk '{ print $3 ":" $4 ":" $1 }')"
secure_target_work_dir
[ "$(LC_ALL=C ls -ldn "$TARGET_WORK_DIR" | awk '{ print $3 ":" $4 ":" $1 }')" = "$before" ]

printf 'ok - restored broad permissions are accepted without weakening path checks\n'
