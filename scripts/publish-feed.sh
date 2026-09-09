#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
apk_verifier=$script_dir/verify-apk.sh

usage() {
	printf 'Usage: APK_SIGNING_KEY_B64=... %s APK_BIN PUBLIC_KEY CURRENT_TAG CURRENT_DIR OUTPUT_DIR [PREVIOUS_TAG PREVIOUS_DIR]\n' "$0" >&2
	exit 2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -ne 5 ] && [ "$#" -ne 7 ]; then
	usage
fi

apk_bin=$1
public_key=$2
current_tag=$3
current_dir=$4
output_dir=$5
previous_tag=${6:-}
previous_dir=${7:-}

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
previous_version=
[ -z "$previous_tag" ] || previous_version=$(tag_version "$previous_tag")
[ -z "$previous_tag" ] || [ "$previous_tag" != "$current_tag" ] ||
	die 'current and previous release tags are identical'

[ -x "$apk_bin" ] || die "APK tool is not executable: $apk_bin"
[ -f "$apk_verifier" ] || die "APK verifier is missing: $apk_verifier"
if [ ! -f "$public_key" ] || [ -L "$public_key" ]; then
	die "public key is missing or unsafe: $public_key"
fi
[ -d "$current_dir" ] || die "current package directory is missing: $current_dir"
[ -z "$previous_tag" ] || [ -n "$previous_dir" ] ||
	die 'previous release directory is empty'
[ -z "$previous_dir" ] || [ -d "$previous_dir" ] ||
	die "previous package directory is missing: $previous_dir"
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

current_main=
current_i18n=

copy_package_set() {
	set_name=$1
	set_dir=$2
	expected_version=$3
	package_count=0

	for package_path in "$set_dir"/*.apk; do
		[ -e "$package_path" ] || [ -L "$package_path" ] || continue
		package_count=$((package_count + 1))
	done
	if [ "$package_count" -ne 2 ]; then
		die "$set_name release must contain exactly one main and one zh-cn APK"
	fi
	main_package=$set_dir/luci-app-adguardhome-$expected_version.apk
	i18n_package=$set_dir/luci-i18n-adguardhome-zh-cn-$expected_version.apk
	if [ ! -f "$main_package" ] || [ -L "$main_package" ] ||
	   [ ! -f "$i18n_package" ] || [ -L "$i18n_package" ]; then
		die "$set_name APK version does not match its release tag"
	fi
	sh "$apk_verifier" "$apk_bin" "$expected_version" \
		"$main_package" "$i18n_package"
	cp -p "$main_package" "$i18n_package" "$stage_dir/"
	if [ "$set_name" = current ]; then
		current_main=$stage_dir/${main_package##*/}
		current_i18n=$stage_dir/${i18n_package##*/}
	fi
}

copy_package_set current "$current_dir" "$current_version"
[ -z "$previous_dir" ] || copy_package_set previous "$previous_dir" "$previous_version"

"$apk_bin" mkndx --allow-untrusted --sign-key "$private_key" \
	--output "$stage_dir/packages.adb" "$current_main" "$current_i18n"

mkdir "$key_dir/trusted"
cp "$public_key" "$key_dir/trusted/public-key.pem"
"$apk_bin" --keys-dir "$key_dir/trusted" verify "$stage_dir/packages.adb" >/dev/null ||
	die 'generated packages.adb failed signature verification'
chmod 0755 "$stage_dir"
chmod 0644 "$stage_dir"/*.apk "$stage_dir/packages.adb"

mv "$stage_dir" "$output_dir"
stage_dir=
printf 'FEED_OK output=%s\n' "$output_dir"
