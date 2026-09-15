#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Real APK ownership transfer, isolated from host files and services; full suite only.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
apk=${APK_BIN:-${SDK:-/root/sdk-x86-64}/staging_dir/host/bin/apk}
busybox=${STATIC_BUSYBOX:-$(command -v busybox || true)}
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) == 0 && -x $apk && -x $busybox ]] || die 'root, APK_BIN and static BusyBox are required'
[[ $("$apk" --version) == 'apk-tools 3.'* ]] || die 'APK v3 is required'
temporary=$(mktemp -d /tmp/adguardhome-package-replaces.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT

# Evaluate the production package argument with only the SDK includes stubbed.
# verify-apk.sh separately checks that the real SDK emits it in the final APK.
mkdir -p "$temporary/sdk/feeds/luci"
: >"$temporary/sdk/rules.mk"
: >"$temporary/sdk/feeds/luci/luci.mk"
{
	printf 'include %s/luci-app-adguardhome/Makefile\n' "$repo"
	printf 'metadata:\n\t@printf "%%s\\n" $(APK_SCRIPTS_luci-app-adguardhome)\n'
} >"$temporary/metadata.mk"
make -s -f "$temporary/metadata.mk" TOPDIR="$temporary/sdk" metadata >"$temporary/arguments"
mapfile -t arguments <"$temporary/arguments"
[[ ${arguments[*]} == '--info replaces:luci-app-AdGuardHome' ]] || die 'unexpected replacement metadata'

for payload in old new; do
	mkdir -p "$temporary/$payload/etc/init.d" "$temporary/$payload/etc/AdGuardHome" \
		"$temporary/$payload/usr/share/agh-replacement"
	printf '%s coordinator\n' "$payload" >"$temporary/$payload/etc/init.d/AdGuardHome"
	printf '%s resource\n' "$payload" >"$temporary/$payload/usr/share/agh-replacement/resource"
	printf '%s default YAML\n' "$payload" >"$temporary/$payload/etc/AdGuardHome/AdGuardHome.yaml"
done
printf 'old service\n' >"$temporary/old/etc/init.d/luci-app-AdGuardHome"
cat >"$temporary/old-remove" <<'SH'
#!/bin/sh
printf 'old uninstall ran\n' >>/old-uninstall-ran
SH

"$apk" mkpkg --info name:luci-app-adguardhome --info version:2.0-r0 --info arch:noarch \
	"${arguments[@]}" --files "$temporary/new" --output "$temporary/new.apk" >/dev/null
count=0
for old_name in luci-app-AdGuardHome luci-app-adguardhome; do
	"$apk" mkpkg --info "name:$old_name" --info version:1.0-r0 --info arch:noarch \
		--files "$temporary/old" --script "pre-deinstall:$temporary/old-remove" \
		--script "post-deinstall:$temporary/old-remove" --output "$temporary/old.apk" >/dev/null
	for world in local repository; do
		for predelete in no yes; do
			count=$((count + 1))
			root=$temporary/root-$count
			mkdir -p "$root/bin" "$root/etc/AdGuardHome/data" "$root/etc/ssl/acme"
			cp "$busybox" "$root/bin/busybox"
			ln -s busybox "$root/bin/sh"
			chroot "$root" /bin/sh -c ':' || die 'BusyBox must be static'
			apk_call() {
				"$apk" --root "$root" --arch x86_64 --network=no --repositories-file /dev/null \
					--allow-untrusted --sync=no "$@"
			}
			apk_call add --commit-hooks=no --initdb "$temporary/old.apk" >"$temporary/install.log" 2>&1
			[[ $world != repository ]] || printf '%s\n' "$old_name" >"$root/etc/apk/world"
			printf 'user YAML\n' >"$root/etc/AdGuardHome/AdGuardHome.yaml"
			printf 'user data\n' >"$root/etc/AdGuardHome/data/user-data"
			printf 'user certificate\n' >"$root/etc/ssl/acme/certificate"
			# r5 removed protected program files before APK checked their old owner.
			[[ $predelete != yes ]] || rm "$root/etc/init.d/AdGuardHome"
			apk_call add --commit-hooks=no --upgrade "$temporary/new.apk" >"$temporary/upgrade.log" 2>&1 || {
				cat "$temporary/upgrade.log" >&2
				die "$old_name/$world/predelete=$predelete: replacement failed"
			}
			[[ $(<"$root/etc/init.d/AdGuardHome") == 'new coordinator' ]] || die 'coordinator was not replaced'
			[[ $(<"$root/usr/share/agh-replacement/resource") == 'new resource' ]] || die 'resource was not replaced'
			for path in /etc/init.d/AdGuardHome /usr/share/agh-replacement/resource; do
				[[ $(apk_call info -W "$path") == *'luci-app-adguardhome-2.0-r0'* ]] || die 'new package did not acquire ownership'
			done
			[[ ! -e $root/old-uninstall-ran ]] || die 'replacement executed unknown old removal scripts'
			[[ $(<"$root/etc/AdGuardHome/AdGuardHome.yaml") == 'user YAML' ]] || die 'user YAML changed'
			[[ $(<"$root/etc/AdGuardHome/data/user-data") == 'user data' ]] || die 'user data changed'
			[[ $(<"$root/etc/ssl/acme/certificate") == 'user certificate' ]] || die 'user certificate changed'
			if [[ $old_name == luci-app-AdGuardHome ]]; then
				# Replaces transfers overlapping files, not the old package lifecycle.
				# The installation cleanup handles old services independently.
				[[ -f $root/etc/init.d/luci-app-AdGuardHome ]] || die 'replaces unexpectedly removed old unique files'
				apk_call info -e luci-app-AdGuardHome >/dev/null || die 'replaces unexpectedly uninstalled the alias'
			fi
		done
	done
done
printf 'APK replacement: %s ownership/data/hook cases passed\n' "$count"
