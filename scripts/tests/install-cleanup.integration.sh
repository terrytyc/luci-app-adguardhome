#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Real APK pre-install/upgrade, with all process cleanup confined to a PID namespace.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
package=$repo/luci-app-adguardhome
runtime=${TARGET_ROOT:-${ADGUARDHOME_TEST_UCI_ROOT:-${SDK:-/root/sdk-x86-64}/staging_dir/target-x86_64_musl/root-x86}}
apk=${APK_BIN:-${SDK:-/root/sdk-x86-64}/staging_dir/host/bin/apk}
busybox=${STATIC_BUSYBOX:-$(command -v busybox)}
[[ $(id -u) == 0 && -x $apk && -x $runtime/usr/bin/ucode ]] || {
	printf 'Install cleanup integration requires root, APK_BIN and TARGET_ROOT\n' >&2; exit 1;
}
temporary=$(mktemp -d /tmp/adguardhome-install-cleanup.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
mkdir -p "$root"/{bin,sbin,usr/bin,usr/lib/ucode,lib,dev,proc,tmp,var/run,etc/config,etc/init.d,etc/rc.d,etc/AdGuardHome/data,etc/ssl/acme,root/.luci-app-adguardhome,opt/normal,opt/stubborn,opt/deleted,opt/unrelated}
cp -P "$runtime/lib"/*.so* "$root/lib/"
cp -P "$runtime/usr/lib"/*.so* "$root/usr/lib/"
cp "$runtime/usr/lib/ucode/"{fs,uloop}.so "$root/usr/lib/ucode/"
cp "$runtime/sbin/uci" "$root/sbin/uci"
cp "$busybox" "$root/bin/busybox"
chroot "$root" /bin/busybox --install -s /bin
# Run package hooks with the same ash as the target, retaining static applets.
cp "$runtime/bin/busybox" "$root/bin/openwrt-busybox"
ln -sf openwrt-busybox "$root/bin/sh"
# The real util-linux flock supports the production -w timeout option.
flock=$(command -v flock)
cp "$flock" "$root/usr/bin/flock"
while IFS= read -r library; do
	cp -L --parents "$library" "$root"
done < <(ldd "$flock" | awk '$2 == "=>" && $3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }')
ln -s /bin/busybox "$root/usr/bin/setsid"
mknod "$root/dev/null" c 1 3
mknod "$root/dev/urandom" c 1 9
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\n' > "$root/etc/group"
for path in opt/normal/AdGuardHome opt/stubborn/adguardhome opt/deleted/AdGuardHome opt/unrelated/sleep; do
	cp "$runtime/usr/bin/ucode" "$root/$path"
done
cat > "$root/tmp/process.uc" <<'UC'
import * as uloop from 'uloop';
import { writefile } from 'fs';
let mode = ARGV[0];
uloop.init();
let handler = uloop.signal('SIGTERM', function() {
	writefile(`/tmp/${mode}.term`, 'received');
	if (mode != 'stubborn') uloop.end();
});
assert(handler, 'Native signal handler unavailable');
writefile(`/tmp/${mode}.ready`, 'ready');
uloop.run();
UC
cat > "$root/usr/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> /tmp/service-events
SH
chmod 0755 "$root/usr/bin/ubus"

# GNU make expands the actual hook and its canonical shared helpers.
{
	printf 'PKG_NAME:=luci-app-adguardhome\ninclude %s/scripts/*.mk\n' "$package"
	awk '/^define / { copying=1 } copying { print } /^endef$/ { copying=0 }' \
		"${INSTALL_MAKEFILE:-$package/Makefile}"
	printf '$(file >%s/preinst,$(Package/$(PKG_NAME)/preinst))\nall:; @:\n' "$temporary"
	printf '$(file >%s/postinst,$(Package/$(PKG_NAME)/postinst))\n' "$temporary"
} > "$temporary/hooks.make"
make --no-print-directory -s -f "$temporary/hooks.make"

cp "$temporary/postinst" "$root/tmp/postinst"
for version in 1 2 3 4; do
	payload=$temporary/payload-$version
	mkdir -p "$payload/etc/"{init.d,uci-defaults,hotplug.d/acme,AdGuardHome}
	for path in etc/init.d/AdGuardHome etc/uci-defaults/40_luci-AdGuardHome; do
		awk -v helper_dir="$package/scripts" -f "$package/scripts/expand-helpers.awk" \
			"$package/root/$path" > "$payload/$path"
	done
	cp "$package/root/etc/hotplug.d/acme/95-AdGuardHome" "$payload/etc/hotplug.d/acme/"
	cp "$package/root/usr/share/luci-app-adguardhome/default.yaml" "$payload/etc/AdGuardHome/AdGuardHome.yaml"
	chmod 0755 "$payload/etc/init.d/AdGuardHome" "$payload/etc/uci-defaults/40_luci-AdGuardHome" "$payload/etc/hotplug.d/acme/95-AdGuardHome"
	hooks=()
	[[ $version == 1 ]] || hooks=(--script "pre-install:$temporary/preinst" --script "pre-upgrade:$temporary/preinst")
	"$apk" mkpkg --info name:luci-app-adguardhome --info "version:$version-r0" --info arch:noarch \
		--files "$payload" "${hooks[@]}" --output "$temporary/package-$version.apk" >/dev/null
done

cat > "$temporary/driver.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root=$1 apk=$2 temporary=$3
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$temporary/apk.log" >&2; exit 1; }
run_apk() {
	"$apk" --root "$root" --arch x86_64 --allow-untrusted --network=no \
		--repositories-file /dev/null --sync=no "$@" > "$temporary/apk.log" 2>&1
}
run_apk add --initdb "$temporary/package-1.apk"
# Imported service stop is broken; its programs and stale candidates must still
# be replaced. All user-owned paths sit beside files from the actual payload.
cat > "$root/etc/init.d/AdGuardHome" <<'OLD'
#!/bin/sh
printf 'old:%s\n' "$1" >> /tmp/service-events
[ "$1" != stop ]
OLD
chmod 0755 "$root/etc/init.d/AdGuardHome"
for path in etc/init.d/AdGuardHome etc/uci-defaults/40_luci-AdGuardHome etc/hotplug.d/acme/95-AdGuardHome; do
	printf '\n# modified locally\n' >> "$root/$path"
	printf 'stale candidate\n' > "$root/$path.apk-new"
done
for service in adguardhome luci-app-adguardhome; do
	cp "$root/etc/init.d/AdGuardHome" "$root/etc/init.d/$service"
done
for service in AdGuardHome adguardhome luci-app-adguardhome; do
	ln -s "../init.d/$service" "$root/etc/rc.d/S99$service"
done
printf '\n# user YAML\n' >> "$root/etc/AdGuardHome/AdGuardHome.yaml"
printf 'filter and query data\n' > "$root/etc/AdGuardHome/data/keep"
printf 'private certificate\n' > "$root/etc/ssl/acme/keep.pem"
printf 'unrelated\n' > "$root/etc/AdGuardHome/unrelated"
printf 'config adguardhome config\n' > "$root/etc/config/adguardhome"
sha256sum "$root/etc/AdGuardHome/AdGuardHome.yaml" "$root/etc/AdGuardHome/data/keep" \
	"$root/etc/ssl/acme/keep.pem" "$root/etc/AdGuardHome/unrelated" "$root/etc/config/adguardhome" > "$temporary/user.sha256"
chroot "$root" /opt/normal/AdGuardHome /tmp/process.uc normal & normal=$!
chroot "$root" /opt/stubborn/adguardhome /tmp/process.uc stubborn & stubborn=$!
chroot "$root" /opt/deleted/AdGuardHome /tmp/process.uc deleted & deleted=$!
# Executable basename is sleep, while argv contains AdGuardHome: leave it alone.
chroot "$root" /opt/unrelated/sleep /tmp/process.uc unrelated AdGuardHome & unrelated=$!
for attempt in {1..100}; do
	[[ -f $root/tmp/normal.ready && -f $root/tmp/stubborn.ready && -f $root/tmp/deleted.ready && -f $root/tmp/unrelated.ready ]] && break
	sleep .02
done
[[ -f $root/tmp/normal.ready && -f $root/tmp/stubborn.ready && -f $root/tmp/deleted.ready && -f $root/tmp/unrelated.ready ]] || fail 'process fixtures did not start'
rm "$root/opt/deleted/AdGuardHome"
started=$SECONDS
run_apk add "$temporary/package-2.apk" || fail 'upgrade transaction failed'
[[ $((SECONDS - started)) -ge 10 ]] || fail 'KILL fallback did not wait for TERM cleanup'
for pid in "$normal" "$stubborn" "$deleted"; do
	! kill -0 "$pid" 2>/dev/null || fail 'an AdGuard Home executable survived cleanup'
done
wait "$normal" || fail 'normal core did not exit through TERM'
wait "$deleted" || fail 'deleted executable did not exit through TERM'
rc=0; wait "$stubborn" || rc=$?
[[ $rc == 137 && -f $root/tmp/stubborn.term ]] || fail 'TERM-to-KILL fallback was not exercised'
kill -0 "$unrelated" && [[ ! -e $root/tmp/unrelated.term ]] || fail 'unrelated process was signaled'
[[ ! -e $root/var/run/luci-app-adguardhome-yaml/install-incomplete ]] || fail 'successful cleanup retained its gate'
for path in etc/init.d/AdGuardHome etc/uci-defaults/40_luci-AdGuardHome etc/hotplug.d/acme/95-AdGuardHome; do
	cmp "$root/$path" "$temporary/payload-2/$path" || fail "old executable was retained: $path"
	[[ ! -e $root/$path.apk-new ]] || fail "stale APK candidate survived: $path"
done
for service in AdGuardHome adguardhome luci-app-adguardhome; do
	grep -Fq "{\"name\":\"$service\"}" "$root/tmp/service-events" || fail "service was not deleted: $service"
	[[ ! -L $root/etc/rc.d/S99$service ]] || fail "autostart link survived: $service"
done
sha256sum --check --status "$temporary/user.sha256" || fail 'user configuration, data or certificate changed'

# Execute the real package postinst after the platform consumed uci-defaults.
# Only service actions are stubbed; verify its explicit upgrade enable call.
rm "$root/etc/uci-defaults/40_luci-AdGuardHome"
cat > "$root/etc/init.d/AdGuardHome" <<'NEW'
#!/bin/sh
case "$1" in
	enable) ln -sf ../init.d/AdGuardHome /etc/rc.d/S99AdGuardHome ;;
	install_check) [ ! -e /tmp/fail-install-check ] ;;
	*) exit 1 ;;
esac
NEW
printf '#!/bin/sh\n[ "$1" = reload ]\n' > "$root/etc/init.d/rpcd"
chmod 0755 "$root/etc/init.d/rpcd"
chroot "$root" /bin/sh /tmp/postinst || fail 'package postinst failed'
[[ -L $root/etc/rc.d/S99AdGuardHome ]] || fail 'upgrade did not enable the new coordinator'
: > "$root/tmp/fail-install-check"
if chroot "$root" /bin/sh /tmp/postinst > "$temporary/postinst.log" 2>&1; then
	fail 'postinst hid failed service verification'
fi
grep -q 'service verification failed' "$temporary/postinst.log" || fail 'postinst failed for a different reason'
[[ ! -e $root/var/run/luci-app-adguardhome-yaml/removing ]] || fail 'failed service verification left edits blocked'

# A foreign core may prevent the old coordinator from stopping. It must be
# stopped before retrying the same coordinator, allowing recovery to complete.
cat > "$root/etc/init.d/AdGuardHome" <<'OLD'
#!/bin/sh
stop_wrapper_locked() { [ -f /tmp/retry.term ]; }
[ "$1" = stop ] || exit 0
printf 'stop\n' >> /tmp/retry-stops
stop_wrapper_locked
OLD
chroot "$root" /opt/normal/AdGuardHome /tmp/process.uc retry & retry=$!
for attempt in {1..100}; do [[ -f $root/tmp/retry.ready ]] && break; sleep .02; done
[[ -f $root/tmp/retry.ready ]] || fail 'retry process did not start'
run_apk add "$temporary/package-3.apk" || fail 'coordinator stop retry did not recover'
! kill -0 "$retry" 2>/dev/null || fail 'retry left the foreign core alive'
wait "$retry" || fail 'retry core did not exit through TERM'
[[ $(cat "$root/tmp/retry-stops") == $'stop\nstop' ]] || fail 'coordinator was not retried exactly once'
[[ ! -e $root/var/run/luci-app-adguardhome-yaml/install-incomplete ]] || fail 'successful retry retained its gate'

# A plugin stop/write-back failure blocks destructive cleanup. APK may still
# extract its payload, but the real defaults entry point must obey the gate.
cat > "$root/etc/init.d/AdGuardHome" <<'OLD'
#!/bin/sh
stop_wrapper_locked() { return 1; }
stop_wrapper_locked
OLD
mkdir -p "$root/tmp/luci-app-adguardhome-memory"
printf 'unsaved RAM data\n' > "$root/tmp/luci-app-adguardhome-memory/state"
run_apk add "$temporary/package-4.apk" || true
grep -q 'Unable to finish coordinator cleanup' "$temporary/apk.log" || fail 'stop failure was not reached'
[[ -f $root/var/run/luci-app-adguardhome-yaml/install-incomplete ]] || fail 'stop failure did not retain the install gate'
[[ $(cat "$root/tmp/luci-app-adguardhome-memory/state") == 'unsaved RAM data' ]] || fail 'failed stop discarded RAM data'
if chroot "$root" /bin/sh /etc/uci-defaults/40_luci-AdGuardHome > "$temporary/defaults.log" 2>&1; then
	fail 'initialization ignored the failed cleanup gate'
fi
grep -q 'installation cleanup is incomplete' "$temporary/defaults.log" || fail 'defaults failed for a different reason'
sha256sum --check --status "$temporary/user.sha256" || fail 'failed installation changed user files'
kill -0 "$unrelated" || fail 'failure path killed the unrelated process'
printf 'INSTALL_CLEANUP_OK term=2 kill=1 unrelated=1 programs=replaced user_files=preserved upgrade=enabled retry=recovered failed_stop=blocked\n'
SH
# No core-like process exists until this private PID namespace is active.
timeout --kill-after=2s 90s unshare --mount --pid --fork --kill-child bash -c '
	set -eu
	mount --make-rprivate /
	mount -t proc proc "$1/proc"
	exec bash "$3/driver.sh" "$1" "$2" "$3"
' install-cleanup "$root" "$apk" "$temporary"
