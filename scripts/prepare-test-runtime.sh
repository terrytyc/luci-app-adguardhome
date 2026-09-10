#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fetch only the pinned x86_64 test runtime; no SDK or host package installation.
set -Eeuo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && $1 == /* && ! -e $1 && ! -L $1 ]] ||
	die 'usage: scripts/prepare-test-runtime.sh /absolute/new-directory'
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Linux x86_64 is required'
runtime=$1
umask 077
mkdir -- "$runtime"
mkdir -- "$runtime/root" "$runtime/apk"

fetch() {
	local name=$1 checksum=$2 url=$3
	wget -q --https-only --timeout=30 --tries=3 -O "$runtime/$name" "$url"
	printf '%s  %s\n' "$checksum" "$runtime/$name" | sha256sum --check --status ||
		die "checksum mismatch: $name"
}

# Rootfs checksum: https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/
fetch rootfs.tar.gz 11c2f26b9d48c02cbdb3b63d499e1f6413ed62bcdbbea78937b12279b95acb1e \
	https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-25.12.0-x86-64-rootfs.tar.gz
fetch apk-tools-static.apk 2edccd3267ce540f8d2371a0f394e84b40d8348ecc28425309e6d07079ed1259 \
	https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/apk-tools-static-3.0.8-r0.apk
fetch digest.apk 3fe11155a01a4e2cff9d871fa7f80e9a173867ca623ccea7972e3c6c91421f4f \
	https://downloads.openwrt.org/releases/25.12.0/packages/x86_64/base/ucode-mod-digest-2026.01.16~85922056-r1.apk

tar -xzf "$runtime/rootfs.tar.gz" -C "$runtime/root" \
	./lib ./usr/lib ./usr/bin/ucode ./sbin/uci
tar --warning=no-unknown-keyword -xzf "$runtime/apk-tools-static.apk" -C "$runtime/apk" sbin/apk.static
# The exact downloaded bytes were checked above; extraction executes no package scripts.
"$runtime/apk/sbin/apk.static" extract --allow-untrusted \
	--destination "$runtime/root" "$runtime/digest.apk"
"$runtime/apk/sbin/apk.static" --version
"$runtime/root/lib/ld-musl-x86_64.so.1" \
	--library-path "$runtime/root/lib:$runtime/root/usr/lib" \
	"$runtime/root/usr/bin/ucode" -L "$runtime/root/usr/lib/ucode" \
	-e 'import { sha256 } from "digest"; import * as fs from "fs"; import * as uloop from "uloop"; if (sha256("test") != "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08") exit(1);'
printf 'TEST_RUNTIME_OK root=%s/root apk=%s/apk/sbin/apk.static\n' "$runtime" "$runtime"
