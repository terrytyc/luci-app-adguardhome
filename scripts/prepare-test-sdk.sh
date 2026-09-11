#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 && $1 == /* && ! -e $1 && ! -L $1 && $2 == /* && -d $2 ]] ||
	die 'usage: scripts/prepare-test-sdk.sh /absolute/new-sdk-directory /absolute/repository'
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Linux x86_64 is required'
[[ $2 != *[[:space:]]* && -f $2/luci-app-adguardhome/Makefile ]] ||
	die 'repository path is missing or unsafe'

sdk=$1
repo=$2
archive=$(mktemp "${TMPDIR:-/tmp}/openwrt-sdk.XXXXXX")
trap 'rm -f -- "$archive"' EXIT HUP INT TERM

wget -q --https-only --timeout=30 --tries=3 -O "$archive" \
	https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
printf '%s  %s\n' 9f371906ce6d2f95418f69fac06df58bf9df0ffc4abed6206c30f1b547fcfc12 "$archive" |
	sha256sum --check --status || die 'OpenWrt SDK checksum mismatch'

mkdir -- "$sdk"
tar --zstd -xf "$archive" --strip-components=1 -C "$sdk"
cp "$sdk/feeds.conf.default" "$sdk/feeds.conf"
printf 'src-link local %s\n' "$repo" >>"$sdk/feeds.conf"

(
	cd -- "$sdk"
	./scripts/feeds update base packages luci local
	./scripts/feeds install -p packages adguardhome
	./scripts/feeds install -p luci luci-base csstidy
	./scripts/feeds install -p local luci-app-adguardhome
	make defconfig
	make package/feeds/luci/luci-base/host/compile \
		package/feeds/luci/csstidy/host/compile
)

grep -Fqx 'CONFIG_TARGET_ARCH_PACKAGES="x86_64"' "$sdk/.config" ||
	die 'SDK is not configured for x86_64 packages'
[[ -L $sdk/package/feeds/local/luci-app-adguardhome ]] ||
	die 'local package feed was not installed'
printf 'TEST_SDK_OK sdk=%s\n' "$sdk"
