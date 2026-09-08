#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)
PACKAGE_REL=luci-app-adguardhome
PACKAGE_DIR=$REPO/$PACKAGE_REL
SDK=${SDK:-/root/sdk-x86-64}
OUTPUT_DIR=${OUTPUT_DIR:-$REPO/dist}
JOBS=${JOBS:-$(nproc)}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

for command_name in awk cp git gzip make mktemp nproc readlink sha256sum tar; do
	command -v "$command_name" >/dev/null 2>&1 ||
		die "required command is unavailable: $command_name"
done

[[ -f $PACKAGE_DIR/Makefile ]] || die "package Makefile is missing: $PACKAGE_DIR/Makefile"
[[ -d $SDK && -f $SDK/.config ]] || die "initialized SDK is missing: $SDK"
grep -Fqx 'CONFIG_TARGET_ARCH_PACKAGES="x86_64"' "$SDK/.config" ||
	die 'SDK is not configured for x86_64 packages'

read_make_value() {
	awk -F':=' -v key="$1" '$1 == key { sub(/^[[:space:]]*/, "", $2); print $2 }' \
		"$PACKAGE_DIR/Makefile"
}

version=$(read_make_value PKG_VERSION)
release=$(read_make_value PKG_RELEASE)
[[ -n $version && $version != *$'\n'* ]] || die 'PKG_VERSION must be one literal value'
[[ -n $release && $release != *$'\n'* ]] || die 'PKG_RELEASE must be one literal value'
case "$version" in
	*[!0-9A-Za-z.+_~-]*) die 'PKG_VERSION contains unsafe filename characters' ;;
esac
case "$release" in
	*[!0-9A-Za-z.+_~-]*) die 'PKG_RELEASE contains unsafe filename characters' ;;
esac
package_version=$version-r$release

stage=$(mktemp -d /root/luci-app-adguardhome-build.XXXXXX)
link=$SDK/package/feeds/local/luci-app-adguardhome
old_link=

cleanup() {
	local rc=$?
	trap - EXIT INT TERM
	[[ -z $old_link ]] || ln -sfn "$old_link" "$link"
	case "$stage" in
		/root/luci-app-adguardhome-build.*) rm -rf -- "$stage" ;;
	esac
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -L $link ]] || die "initialized SDK package link is missing: $link"
old_link=$(readlink "$link")

file_list=$stage/source-files
git -C "$REPO" ls-files --cached --others --exclude-standard -z -- "$PACKAGE_REL" |
	while IFS= read -r -d '' path; do
		[[ -f $REPO/$path || -L $REPO/$path ]] && printf '%s\0' "$path"
	done >"$file_list"
[[ -s $file_list ]] || die 'package source file list is empty'

source_name=luci-app-adguardhome-$package_version.tar.gz
source_tar=$stage/$source_name
source_epoch=${SOURCE_DATE_EPOCH:-$(git -C "$REPO" log -1 --format=%ct)}
tar -C "$REPO" --null --files-from="$file_list" --sort=name \
	--mtime="@$source_epoch" --owner=0 --group=0 --numeric-owner -cf - |
	gzip -n -9 >"$source_tar"
mkdir "$stage/source"
tar -xzf "$source_tar" -C "$stage/source"
staged_package=$stage/source/$PACKAGE_REL
[[ -f $staged_package/Makefile ]] || die 'source snapshot omitted the package Makefile'

ln -sfn "$staged_package" "$link"
[[ $(readlink -f "$link") == "$staged_package" ]] || die 'failed to select staged SDK package'

make_args=(V=s PKG_PO_VERSION="$package_version")
[[ ${NO_DEPS:-0} != 1 ]] || make_args+=(NO_DEPS=1)
make -C "$SDK" package/luci-app-adguardhome/clean "${make_args[@]}"
make -C "$SDK" -j"$JOBS" package/luci-app-adguardhome/compile "${make_args[@]}"

package_output=$SDK/bin/packages/x86_64/local
main_name=luci-app-adguardhome-$package_version.apk
i18n_name=luci-i18n-adguardhome-zh-cn-$package_version.apk
main_apk=$package_output/$main_name
i18n_apk=$package_output/$i18n_name
[[ -f $main_apk ]] || die "main APK was not built: $main_apk"
[[ -f $i18n_apk ]] || die "Chinese APK was not built with the main version: $i18n_apk"

apk_host=$SDK/staging_dir/host/bin/apk
[[ -x $apk_host ]] || die "SDK APK verifier is missing: $apk_host"
for artifact in "$main_apk" "$i18n_apk"; do
	"$apk_host" verify --allow-untrusted "$artifact"
	metadata=$("$apk_host" adbdump "$artifact")
	grep -Fqx "  version: $package_version" <<<"$metadata" ||
		die "APK version mismatch: $artifact"
	grep -Fqx '  arch: noarch' <<<"$metadata" || die "APK is not noarch: $artifact"
done

mkdir -p "$OUTPUT_DIR"
cp -p "$source_tar" "$main_apk" "$i18n_apk" "$OUTPUT_DIR/"
sha256sum "$OUTPUT_DIR/$source_name" "$OUTPUT_DIR/$main_name" "$OUTPUT_DIR/$i18n_name"
printf 'BUILD_OK version=%s output=%s\n' "$package_version" "$OUTPUT_DIR"
