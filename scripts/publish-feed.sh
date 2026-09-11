#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
apk_verifier=$script_dir/verify-apk.sh

usage() {
	printf 'Usage: APK_SIGNING_KEY_B64=... %s APK_BIN PUBLIC_KEY CURRENT_TAG CURRENT_DIR OUTPUT_DIR\n' "$0" >&2
	exit 2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -ne 5 ]; then
	usage
fi

apk_bin=$1
public_key=$2
current_tag=$3
current_dir=$4
output_dir=$5

tag_version() {
	case "$1" in
		v3.?*) version=${1#v} ;;
		*) die "not a stable v3 release tag: $1" ;;
	esac
	case "$version" in
		*[!0-9A-Za-z.+_~-]*) die "unsafe release tag: $1" ;;
	esac
	printf '%s\n' "$version"
}

current_version=$(tag_version "$current_tag")

[ -x "$apk_bin" ] || die "APK tool is not executable: $apk_bin"
[ -f "$apk_verifier" ] || die "APK verifier is missing: $apk_verifier"
if [ ! -f "$public_key" ] || [ -L "$public_key" ]; then
	die "public key is missing or unsafe: $public_key"
fi
[ -d "$current_dir" ] || die "current package directory is missing: $current_dir"
[ -n "${APK_SIGNING_KEY_B64:-}" ] || die 'APK_SIGNING_KEY_B64 is empty'

for command_name in base64 cmp mktemp openssl; do
	command -v "$command_name" >/dev/null 2>&1 ||
		die "required command is unavailable: $command_name"
done

case "$output_dir" in
	''|.|..|/) die "unsafe output directory: $output_dir" ;;
esac
if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
	die "output directory already exists: $output_dir"
fi

umask 077
key_dir=$(mktemp -d "${TMPDIR:-/tmp}/publish-feed-key.XXXXXX")
stage_dir=

cleanup() {
	rc=$?
	trap - EXIT HUP INT TERM
	case "$stage_dir" in
		*/.publish-feed.*) rm -rf -- "$stage_dir" ;;
	esac
	case "$key_dir" in
		*/publish-feed-key.*) rm -rf -- "$key_dir" ;;
	esac
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

private_key=$key_dir/private-key.pem
derived_key=$key_dir/public-key.pem
printf '%s' "$APK_SIGNING_KEY_B64" | base64 -d >"$private_key" ||
	die 'APK_SIGNING_KEY_B64 is not valid base64'
chmod 0600 "$private_key"
openssl pkey -in "$private_key" -check -noout >/dev/null 2>&1 ||
	die 'APK_SIGNING_KEY_B64 does not contain a valid private key'
openssl pkey -in "$private_key" -pubout -out "$derived_key" >/dev/null 2>&1 ||
	die 'unable to derive the signing public key'
cmp -s "$derived_key" "$public_key" ||
	die 'signing key does not match keys/public-key.pem'

umask 022
output_parent=$(dirname "$output_dir")
mkdir -p "$output_parent"
stage_dir=$(mktemp -d "$output_parent/.publish-feed.XXXXXX")

package_count=0
for package_path in "$current_dir"/*.apk; do
	[ -e "$package_path" ] || [ -L "$package_path" ] || continue
	package_count=$((package_count + 1))
done
[ "$package_count" -eq 2 ] ||
	die 'current release must contain exactly one main and one zh-cn APK'
main_package=$current_dir/luci-app-adguardhome-$current_version.apk
i18n_package=$current_dir/luci-i18n-adguardhome-zh-cn-$current_version.apk
if [ ! -f "$main_package" ] || [ -L "$main_package" ] ||
   [ ! -f "$i18n_package" ] || [ -L "$i18n_package" ]; then
	die 'current APK version does not match its release tag'
fi
sh "$apk_verifier" "$apk_bin" "$current_version" \
	"$main_package" "$i18n_package"
cp -p "$main_package" "$i18n_package" "$stage_dir/"

"$apk_bin" mkndx --allow-untrusted --sign-key "$private_key" \
	--output "$stage_dir/packages.adb" \
	"$stage_dir/${main_package##*/}" "$stage_dir/${i18n_package##*/}"

mkdir "$key_dir/trusted"
cp "$public_key" "$key_dir/trusted/public-key.pem"
"$apk_bin" --keys-dir "$key_dir/trusted" verify "$stage_dir/packages.adb" >/dev/null ||
	die 'generated packages.adb failed signature verification'
chmod 0755 "$stage_dir"
chmod 0644 "$stage_dir"/*.apk "$stage_dir/packages.adb"

mv "$stage_dir" "$output_dir"
stage_dir=
printf 'FEED_OK output=%s\n' "$output_dir"
