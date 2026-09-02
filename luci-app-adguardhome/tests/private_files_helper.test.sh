#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
helper_dir="$package_dir/scripts"
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
temporary="$(mktemp -d /tmp/luci-agh-private-helper.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# Make expands the same canonical source used by all four package hooks.
printf 'include %s/private-files.mk\n$(info $(AdGuardHome/PrivateFiles))\nall:; @:\n' \
	"$helper_dir" >"$temporary/helper.make"
make --no-print-directory -s -f "$temporary/helper.make" >"$temporary/helper.sh"
busybox ash -n "$temporary/helper.sh"
awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$defaults" >"$temporary/defaults.sh"
busybox ash -n "$temporary/defaults.sh"
awk '
	/^entry_metadata\(\) \{/ { copying=1 }
	copying { print }
	/^root_private_file\(\) \{/ { last=1 }
	copying && last && /^}/ { exit }
' "$temporary/defaults.sh" >"$temporary/defaults.helper"
cmp "$temporary/helper.sh" "$temporary/defaults.helper"
[ "$(grep -Fc '$(AdGuardHome/PrivateFiles)' "$makefile")" = 4 ]
! grep -Eq '^entry_metadata\(\)|^root_private_(directory|file)\(\)' "$makefile" "$defaults"
! grep -Fq '# @include ' "$temporary/defaults.sh"

# Missing, unknown or duplicated source markers must fail the build.
for marker in '# @include missing' '# @include private-files'; do
	printf '%s\n' "$marker" >"$temporary/invalid"
	if awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
		"$temporary/invalid" >"$temporary/invalid.out"; then
		printf 'invalid helper input unexpectedly expanded\n' >&2
		exit 1
	fi
done
printf '# @include run-bounded\n# @include run-bounded\n' >"$temporary/invalid"
if awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$temporary/invalid" >"$temporary/invalid.out"; then
	printf 'duplicate helper marker unexpectedly expanded\n' >&2
	exit 1
fi

# Verify the preserved metadata policy without changing any system file.
# shellcheck disable=SC1090
. "$temporary/helper.sh"
mkdir -m 0700 "$temporary/private"
: >"$temporary/private/file"
chmod 0600 "$temporary/private/file"
if [ "$(id -u)" = 0 ] && [ "$(id -g)" = 0 ]; then
	root_private_directory "$temporary/private"
	root_private_file "$temporary/private/file"
fi
ln -s "$temporary/private/file" "$temporary/link"
! root_private_file "$temporary/link"
ln "$temporary/private/file" "$temporary/hardlink"
! root_private_file "$temporary/private/file"
chmod 0755 "$temporary/private"
! root_private_directory "$temporary/private"
! root_private_file "$temporary/missing"
printf 'ok - single-source private-file checks and helper expansion\n'
