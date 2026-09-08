#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
temporary=$(mktemp -d /tmp/adguardhome-release-test.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

workflow=$repo/.github/workflows/publish-feed.yml
selection=$(awk '
 /name: Select current/ { selected=1 }
 selected && /run: \|/ { active=1; next }
 active && /      - name:/ { exit }
 active { sub(/^          /, ""); print }
' "$workflow")
check_selection() {
	local requested=$1 tags=$2 expected=$3
	: >"$temporary/output"
	REQUESTED_TAG=$requested TEST_TAGS=$tags GITHUB_REPOSITORY=test/project \
		GITHUB_OUTPUT=$temporary/output SELECTION="$selection" bash -c '
		gh() { printf "%s\n" "$TEST_TAGS"; }
		eval "$SELECTION"
	'
	[[ $(<"$temporary/output") == "$expected" ]] || die "release selection: $requested"
}
check_selection v3.0.0-r1 $'v3.0.0-r2\nv3.0.0-r1' ''
check_selection v3.0.0-r2 $'v3.0.0-r2\nv3.0.0-r1' $'current=v3.0.0-r2\nprevious=v3.0.0-r1'
check_selection '' $'v3.0.0-r2\nv3.0.0-r1' $'current=v3.0.0-r2\nprevious=v3.0.0-r1'
check_selection '' v3.0.0-r1 $'current=v3.0.0-r1\nprevious='
check_selection v3.0.0-r10 $'v3.0.0-r9\nv3.0.0-r2\nv3.0.0-r10' $'current=v3.0.0-r10\nprevious=v3.0.0-r9'
check_selection '' $'v3.0.0-r9\nv3.0.0-r10\nv3.1.0-r1' $'current=v3.1.0-r1\nprevious=v3.0.0-r10'
check_selection v3.0.0-r9 $'v3.0.0-r9\nv3.0.0-r10' ''
[[ $(grep -Fc "if: steps.releases.outputs.current != ''" "$workflow") == 4 ]] || die 'build steps must skip old releases'
grep -Fq "if: needs.build.outputs.current != ''" "$workflow" || die 'deploy must skip old releases'
! grep -Fq 'inputs.tag' "$workflow" || die 'manual publication must use the latest release'

fixture=$temporary/repo
sdk=$temporary/sdk
bin=$temporary/bin
package_dir=$fixture/luci-app-adguardhome
package_link=$sdk/package/feeds/local/luci-app-adguardhome
mkdir -p "$fixture/scripts" "$package_dir/root" "$bin" \
	"$sdk/feeds/base/feeds/local" "$sdk/staging_dir/host/bin"
ln -s feeds/base "$sdk/package"
cp "$repo/scripts/build-apk.sh" "$fixture/scripts/"
printf 'PKG_VERSION:=3.0.0\nPKG_RELEASE:=1\n' >"$package_dir/Makefile"
printf 'committed\n' >"$package_dir/root/marker"
git -C "$fixture" init -q
git -C "$fixture" config user.name Test
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" add .
git -C "$fixture" commit -qm r1
git -C "$fixture" tag v3.0.0-r1
printf 'PKG_VERSION:=3.0.0\nPKG_RELEASE:=2\n' >"$package_dir/Makefile"
git -C "$fixture" commit -qam r2
printf 'PKG_VERSION:=99.0.0\nPKG_RELEASE:=9\n' >"$package_dir/Makefile"
printf 'uncommitted\n' >"$package_dir/root/marker"
printf 'must not ship\n' >"$package_dir/root/untracked"
printf 'CONFIG_TARGET_ARCH_PACKAGES="x86_64"\n' >"$sdk/.config"
ln -s "$package_dir" "$package_link"

cat >"$bin/make" <<'SH'
#!/usr/bin/env bash
set -eu
sdk=$2
pkg=$sdk/package/feeds/local/luci-app-adguardhome
[[ -d $pkg && ! -L $pkg ]]
[[ $(<"$pkg/root/marker") == committed ]]
[[ ! -e $pkg/root/untracked ]]
[[ -z ${FAIL_BUILD:-} ]] || exit 7
[[ -z ${HANGUP_BUILD:-} ]] || { kill -HUP "$PPID"; exit 0; }
[[ " $* " == *' package/luci-app-adguardhome/compile '* ]] || exit 0
version=3.0.0-r$(sed -n 's/^PKG_RELEASE:=//p' "$pkg/Makefile")
out=$sdk/bin/packages/x86_64/local
mkdir -p "$out"
origin=$(readlink -f "$pkg")
origin=${origin#"$sdk/"}
for name in luci-app-adguardhome luci-i18n-adguardhome-zh-cn; do
	printf '  version: %s\n  arch: noarch\n  origin: %s\n' "$version" "$origin" >"$out/$name-$version.apk"
done
SH
cat >"$sdk/staging_dir/host/bin/apk" <<'SH'
#!/bin/sh
[ "$1" != adbdump ] || cat "$2"
SH
chmod +x "$bin/make" "$sdk/staging_dir/host/bin/apk"
export SDK=$sdk JOBS=1 PATH="$bin:$PATH" SOURCE_REF=HEAD
script=$fixture/scripts/build-apk.sh
for destination in first second; do
	OUTPUT_DIR=$temporary/$destination bash "$script"
	[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after success'
done
for artifact in "$temporary/first/"*; do
	cmp "$artifact" "$temporary/second/${artifact##*/}"
done
archive=$temporary/first/luci-app-adguardhome-3.0.0-r2.tar.gz
[[ $(tar -xOf "$archive" luci-app-adguardhome/root/marker) == committed ]] || die 'dirty file shipped'
! tar -tzf "$archive" | grep -q untracked || die 'untracked file shipped'
SOURCE_REF=v3.0.0-r1 OUTPUT_DIR=$temporary/tag bash "$script"
[[ -f $temporary/tag/luci-app-adguardhome-3.0.0-r1.apk ]] || die 'tag build used working-tree version'
if FAIL_BUILD=1 bash "$script"; then die 'build failure was ignored'; fi
[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after failure'
hangup_rc=0
HANGUP_BUILD=1 bash "$script" || hangup_rc=$?
[[ $hangup_rc == 129 ]] || die 'HUP did not stop the build with its signal status'
[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after HUP'
printf 'release selection, committed build snapshot and SDK cleanup tests passed\n'
