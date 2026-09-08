#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

usage() {
	printf 'Usage: APK_SIGNING_KEY_B64=... %s APK_BIN PUBLIC_KEY CURRENT_DIR OUTPUT_DIR [PREVIOUS_DIR]\n' "$0" >&2
	exit 2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
	usage
fi

apk_bin=$1
public_key=$2
current_dir=$3
output_dir=$4
previous_dir=${5:-}

[ -x "$apk_bin" ] || die "APK tool is not executable: $apk_bin"
if [ ! -f "$public_key" ] || [ -L "$public_key" ]; then
	die "public key is missing or unsafe: $public_key"
fi
[ -d "$current_dir" ] || die "current package directory is missing: $current_dir"
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
	allow_empty=$3
	package_count=0
	main_count=0
	i18n_count=0
	main_version=
	i18n_version=

	for package_path in "$set_dir"/*.apk; do
		[ -e "$package_path" ] || continue
		if [ ! -f "$package_path" ] || [ -L "$package_path" ]; then
			die "unsafe APK asset: $package_path"
		fi
		package_count=$((package_count + 1))
		metadata=$key_dir/metadata-$set_name-$package_count.json
		"$apk_bin" verify --allow-untrusted "$package_path" >/dev/null ||
			die "invalid APK asset: $package_path"
		"$apk_bin" adbdump --format json "$package_path" >"$metadata" ||
			die "unable to read APK metadata: $package_path"
		package_name=$(sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)",[[:space:]]*$/\1/p' "$metadata" | sed -n '1p')
		package_version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)",[[:space:]]*$/\1/p' "$metadata" | sed -n '1p')
		package_arch=$(sed -n 's/^[[:space:]]*"arch":[[:space:]]*"\([^"]*\)",[[:space:]]*$/\1/p' "$metadata" | sed -n '1p')
		[ "$package_arch" = noarch ] || die "APK is not noarch: $package_path"

		case "$package_name" in
			luci-app-adguardhome)
				main_count=$((main_count + 1))
				main_version=$package_version
				case "$package_version" in
					3.*) ;;
					*) die "main APK is not a 3.x release: $package_path" ;;
				esac
				;;
			luci-i18n-adguardhome-zh-cn)
				i18n_count=$((i18n_count + 1))
				i18n_version=$package_version
				;;
			*) die "unexpected APK package: $package_name" ;;
		esac

		case "$package_version" in
			''|*[!0-9A-Za-z.+_~-]*) die "unsafe APK version: $package_version" ;;
		esac
		expected_name=$package_name-$package_version.apk
		[ "$(basename "$package_path")" = "$expected_name" ] ||
			die "APK filename does not match metadata: $package_path"
		target=$stage_dir/$expected_name
		if [ -e "$target" ]; then
			cmp -s "$package_path" "$target" ||
				die "conflicting APK assets named $expected_name"
		else
			cp -p "$package_path" "$target"
		fi

		if [ "$set_name" = current ]; then
			case "$package_name" in
				luci-app-adguardhome) current_main=$target ;;
				luci-i18n-adguardhome-zh-cn) current_i18n=$target ;;
			esac
		fi
	done

	if [ "$package_count" -eq 0 ] && [ "$allow_empty" = yes ]; then
		return 0
	fi
	if [ "$package_count" -ne 2 ] || [ "$main_count" -ne 1 ] ||
		[ "$i18n_count" -ne 1 ]; then
		die "$set_name release must contain exactly one main and one zh-cn APK"
	fi
	[ "$main_version" = "$i18n_version" ] ||
		die "$set_name main and zh-cn APK versions differ"
}

copy_package_set current "$current_dir" no
[ -z "$previous_dir" ] || copy_package_set previous "$previous_dir" yes

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
