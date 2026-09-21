#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Exercise the production publisher with real SDK APKs and a disposable key.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
apk=${1:?APK tool required}
packages=${2:?Built APK directory required}
temporary=$(mktemp -d /tmp/adguardhome-signing.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
main=("$packages"/luci-app-adguardhome-*.apk)
[[ ${#main[@]} == 1 && -f ${main[0]} ]]
version=${main[0]##*/luci-app-adguardhome-}
version=${version%.apk}
sha256sum "$packages/"*.apk >"$temporary/input.sha256"
mkdir "$temporary/keys" "$temporary/empty-keys" "$temporary/download"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
	-out "$temporary/private.pem" 2>/dev/null
openssl pkey -in "$temporary/private.pem" -pubout \
	-out "$temporary/keys/public-key.pem" 2>/dev/null
export APK_SIGNING_KEY_B64
APK_SIGNING_KEY_B64=$(base64 <"$temporary/private.pem" | tr -d '\n')
sh "$repo/scripts/publish-feed.sh" "$apk" "$temporary/keys/public-key.pem" \
	"v$version" "$packages" "$temporary/feed"
unset APK_SIGNING_KEY_B64
sha256sum --check "$temporary/input.sha256"

for name in luci-app-adguardhome luci-i18n-adguardhome-zh-cn; do
	package=$name-$version.apk
	"$apk" --keys-dir "$temporary/keys" verify "$temporary/feed/$package"
	if "$apk" --keys-dir "$temporary/empty-keys" verify "$temporary/feed/$package" \
		>"$temporary/untrusted.log" 2>&1; then
		printf 'FAIL: APK trusted without the signing key\n' >&2; exit 1
	fi
	grep -q 'UNTRUSTED signature' "$temporary/untrusted.log"
	head -c 128 "$temporary/feed/$package" >"$temporary/truncated.apk"
	if "$apk" --keys-dir "$temporary/keys" verify "$temporary/truncated.apk" >/dev/null 2>&1; then
		printf 'FAIL: truncated APK accepted\n' >&2; exit 1
	fi
	mkdir "$temporary/original-$name" "$temporary/signed-$name"
	"$apk" extract --allow-untrusted --destination "$temporary/original-$name" "$packages/$package"
	"$apk" --keys-dir "$temporary/keys" extract --destination "$temporary/signed-$name" "$temporary/feed/$package"
	diff -r "$temporary/original-$name" "$temporary/signed-$name"
done

"$apk" --keys-dir "$temporary/keys" --repositories-file /dev/null \
	--repository "$temporary/feed/packages.adb" --arch x86_64 \
	fetch --output "$temporary/download" luci-app-adguardhome luci-i18n-adguardhome-zh-cn
for package in "$temporary/download/"*.apk; do
	cmp "$package" "$temporary/feed/${package##*/}"
done
[[ $(find "$temporary/download" -name '*.apk' | wc -l) == 2 ]]
printf 'PACKAGE_SIGNING_OK: standalone trust, missing-key/corruption rejection, unchanged payload and signed-feed download\n'
