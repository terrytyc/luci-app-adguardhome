#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)
APK_VERIFIER=$SCRIPT_DIR/verify-apk.sh
PACKAGE_REL=luci-app-adguardhome
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

[[ -d $SDK && -f $SDK/.config ]] || die "initialized SDK is missing: $SDK"
[[ -f $APK_VERIFIER ]] || die "APK verifier is missing: $APK_VERIFIER"
SDK=$(cd -- "$SDK" && pwd -P)
grep -Fqx 'CONFIG_TARGET_ARCH_PACKAGES="x86_64"' "$SDK/.config" ||
	die 'SDK is not configured for x86_64 packages'

source_commit=$(git -C "$REPO" rev-parse --verify "${SOURCE_REF:-HEAD}^{commit}")
stage=$(mktemp -d "${TMPDIR:-/tmp}/luci-app-adguardhome-build.XXXXXX")
stage=$(cd -- "$stage" && pwd -P)
link=$SDK/package/feeds/local/luci-app-adguardhome
old_link=

cleanup() {
	local rc=$?
	trap - EXIT HUP INT TERM
	if [[ -n $old_link ]]; then
		# Only the source directory installed below can replace this SDK link.
		if [[ -d $link && ! -L $link ]]; then
			mv -- "$link" "$stage/source/$PACKAGE_REL" || exit 1
		fi
		ln -sfn "$old_link" "$link"
	fi
	case "$stage" in
		*/luci-app-adguardhome-build.*) rm -rf -- "$stage" ;;
	esac
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -L $link ]] || die "initialized SDK package link is missing: $link"

source_tar=$stage/source.tar.gz
git -C "$REPO" archive --format=tar "$source_commit" "$PACKAGE_REL" | gzip -n -9 >"$source_tar"
mkdir "$stage/source"
tar -xzf "$source_tar" -C "$stage/source"
staged_package=$stage/source/$PACKAGE_REL
[[ -f $staged_package/Makefile ]] || die 'source snapshot omitted the package Makefile'

read_make_value() {
	awk -F':=' -v key="$1" '$1 == key { sub(/^[[:space:]]*/, "", $2); print $2 }' \
		"$staged_package/Makefile"
}

version=$(read_make_value PKG_VERSION)
release=$(read_make_value PKG_RELEASE)
[[ -n $version && $version != *$'\n'* ]] || die 'PKG_VERSION must be one literal value'
[[ -n $release && $release != *$'\n'* ]] || die 'PKG_RELEASE must be one literal value'
case "$version$release" in
	*[!0-9A-Za-z.+_~-]*) die 'package version contains unsafe filename characters' ;;
esac
package_version=$version-r$release
source_name=luci-app-adguardhome-$package_version.tar.gz

# A real directory inside the SDK gives both APKs a stable, SDK-relative
# origin. A symlink to mktemp would embed that random path in the metadata.
old_link=$(readlink "$link")
rm -- "$link"
mv -- "$staged_package" "$link"

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
sh "$APK_VERIFIER" "$apk_host" "$package_version" "$main_apk" "$i18n_apk"

mkdir -p "$OUTPUT_DIR"
cp -p "$source_tar" "$OUTPUT_DIR/$source_name"
cp -p "$main_apk" "$i18n_apk" "$OUTPUT_DIR/"
sha256sum "$OUTPUT_DIR/$source_name" "$OUTPUT_DIR/$main_name" "$OUTPUT_DIR/$i18n_name"
printf 'BUILD_OK version=%s commit=%s output=%s\n' "$package_version" "$source_commit" "$OUTPUT_DIR"
