#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

for relative in root/etc/init.d/AdGuardHome root/etc/uci-defaults/40_luci-AdGuardHome; do
	awk -v helper_dir="$package_dir/scripts" -f "$package_dir/scripts/expand-helpers.awk" \
		"$package_dir/$relative" >"$test_tmp/expanded"
	helper="$(function_body "$test_tmp/expanded" keep_active_config)"
	[ -n "$helper" ]
	eval "$helper"
done

KEEP_FILE="$test_tmp/keep.d/luci-app-adguardhome"
snapshot=/root/.luci-app-adguardhome
first=/etc/AdGuardHome/AdGuardHome.yaml
second=/mnt/disk/AdGuardHome/AdGuardHome.yaml
keep_active_config "$first" "$snapshot"
[ "$(cat "$KEEP_FILE")" = "$(printf '%s\n%s/\n' "$first" "$snapshot")" ]
# Matching content must not create a temporary file or rewrite flash.
(
	mktemp() { return 1; }
	keep_active_config "$first" "$snapshot"
)
keep_active_config "$second" "$snapshot"
[ "$(cat "$KEEP_FILE")" = "$(printf '%s\n%s/\n' "$second" "$snapshot")" ]
if grep -Fqx "$first" "$KEEP_FILE"; then exit 1; fi
# Restoring settings restores its keep entry; a failed replace preserves it.
keep_active_config "$first" "$snapshot"
(
	mv() { return 1; }
	if keep_active_config "$second" "$snapshot"; then exit 1; fi
)
[ "$(cat "$KEEP_FILE")" = "$(printf '%s\n%s/\n' "$first" "$snapshot")" ]
[ "$(find "$test_tmp/keep.d" -type f | wc -l)" = 1 ]

printf 'foreign\n' >"$test_tmp/foreign"
rm "$KEEP_FILE"
ln -s "$test_tmp/foreign" "$KEEP_FILE"
if keep_active_config "$second" "$snapshot"; then exit 1; fi
[ "$(cat "$test_tmp/foreign")" = foreign ]
printf 'ok - one shared current-YAML keep list, unchanged no-op and atomic replacement\n'
