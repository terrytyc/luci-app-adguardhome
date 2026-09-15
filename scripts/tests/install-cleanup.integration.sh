#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Real APK pre-install/upgrade, with all process cleanup confined to a PID namespace.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
package=$repo/luci-app-adguardhome
runtime=${TARGET_ROOT:-${ADGUARDHOME_TEST_UCI_ROOT:-${SDK:-/root/sdk-x86-64}/staging_dir/target-x86_64_musl/root-x86}}
apk=${APK_BIN:-${SDK:-/root/sdk-x86-64}/staging_dir/host/bin/apk}
busybox=${STATIC_BUSYBOX:-$(command -v busybox)}
[[ $(id -u) == 0 && -x $apk && -x $runtime/usr/bin/ucode && -x $runtime/sbin/procd ]] || {
	printf 'Install cleanup integration requires root, APK_BIN and TARGET_ROOT\n' >&2; exit 1;
}
temporary=$(mktemp -d /tmp/adguardhome-install-cleanup.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
mkdir -p "$root"/{bin,sbin,usr/bin,usr/lib/ucode,usr/share/libubox,lib,dev,proc,tmp,var/run,etc/config,etc/init.d,etc/rc.d,etc/AdGuardHome/data,etc/ssl/acme,root/.luci-app-adguardhome,opt/normal,opt/stubborn,opt/deleted,opt/unrelated,opt/variant,opt/managed,opt/renamed,opt/wrapper}
cp -P "$runtime/lib"/*.so* "$root/lib/"
cp -P "$runtime/usr/lib"/*.so* "$root/usr/lib/"
cp "$runtime/usr/lib/ucode/"{fs,uloop}.so "$root/usr/lib/ucode/"
cp "$runtime/sbin/"{uci,procd,ubusd} "$root/sbin/"
if [[ -f ${apk%/*}/.apk.bin ]]; then
	# The SDK host entry is a runas wrapper; its native APK needs only glibc.
	mkdir -p "$root/opt/apk-test/lib"
	cp "${apk%/*}/.apk.bin" "$root/opt/apk-test/apk"
	cp -L "${apk%/*}/../lib/"{ld-linux-x86-64.so.2,libc.so.6,libpthread.so.0} "$root/opt/apk-test/lib/"
	printf '#!/bin/sh\nexec /opt/apk-test/lib/ld-linux-x86-64.so.2 --library-path /opt/apk-test/lib /opt/apk-test/apk "$@"\n' > "$root/sbin/apk"
	chmod 0755 "$root/sbin/apk"
else
	cp "$apk" "$root/sbin/apk"
fi
cp "$runtime/bin/ubus" "$root/bin/ubus-native"
cp "$runtime/usr/bin/"{ucode,jshn} "$root/usr/bin/"
cp "$runtime/usr/share/libubox/jshn.sh" "$root/usr/share/libubox/"
cp "$busybox" "$root/bin/busybox-static"
chroot "$root" /bin/busybox-static --install -s /bin
# Run package hooks with the same ash as the target, retaining static applets.
rm -f "$root/bin/busybox"
cp "$runtime/bin/busybox" "$root/bin/busybox"
ln -sf busybox "$root/bin/sh"
# The real util-linux flock supports the production -w timeout option.
flock=$(command -v flock)
cp "$flock" "$root/usr/bin/flock"
while IFS= read -r library; do
	cp -L --parents "$library" "$root"
done < <(ldd "$flock" | awk '$2 == "=>" && $3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }')
ln -s /bin/busybox-static "$root/usr/bin/setsid"
mknod "$root/dev/null" c 1 3
mknod "$root/dev/urandom" c 1 9
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\n' > "$root/etc/group"
for path in opt/normal/AdGuardHome opt/stubborn/adguardhome opt/deleted/AdGuardHome opt/unrelated/sleep opt/variant/ADGUARDHOME opt/managed/AdGuardHome opt/renamed/AdGuardHome; do
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
cat > "$root/opt/wrapper/AdGuardHome" <<'SH'
#!/bin/sh
trap 'echo received > /tmp/shell.term; exit 0' TERM
echo ready > /tmp/shell.ready
while :; do sleep 1; done
SH
chmod 0755 "$root/opt/wrapper/AdGuardHome"
cat > "$root/usr/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> /tmp/service-events
case "$*" in
	*'call service delete {"name":"delayed-filter"}') [ ! -e /tmp/fail-delete ] || exit 1 ;;
esac
exec /bin/ubus-native -s /tmp/install-ubus.sock "$@"
SH
chmod 0755 "$root/usr/bin/ubus"
ln -s ../usr/bin/ubus "$root/bin/ubus"

# GNU make expands the actual hook and its canonical shared helpers.
{
	printf 'PKG_NAME:=luci-app-adguardhome\ninclude %s/scripts/*.mk\n' "$package"
	awk '/^define / { copying=1 } copying { print } /^endef$/ { copying=0 }' \
		"${INSTALL_MAKEFILE:-$package/Makefile}"
	printf '$(file >%s/preinst,$(Package/$(PKG_NAME)/preinst))\nall:; @:\n' "$temporary"
	printf '$(file >%s/postinst,$(Package/$(PKG_NAME)/postinst))\n' "$temporary"
} > "$temporary/hooks.make"
make --no-print-directory -s -f "$temporary/hooks.make"

cp "$temporary/"{preinst,postinst} "$root/tmp/"
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
foreign=$temporary/foreign/etc/hotplug.d/acme
mkdir -p "$foreign"
printf 'foreign package file\n' > "$foreign/95-AdGuardHome.apk-new"
"$apk" mkpkg --info name:foreign-app --info version:1-r0 --info arch:noarch \
	--files "$temporary/foreign" --output "$temporary/foreign.apk" >/dev/null

cat > "$temporary/driver.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root=$1 apk=$2 temporary=$3
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$temporary/"*.log >&2; exit 1; }
ubus() { chroot "$root" /bin/ubus-native -s /tmp/install-ubus.sock "$@"; }
run_apk() {
	"$apk" --root "$root" --arch x86_64 --allow-untrusted --network=no \
		--repositories-file /dev/null --sync=no "$@" > "$temporary/apk.log" 2>&1
}
run_apk add --initdb "$temporary/package-1.apk"
# Real procd owns an arbitrarily named core service and a non-core shell wrapper.
chroot "$root" /sbin/ubusd -s /tmp/install-ubus.sock > "$temporary/ubusd.log" 2>&1 &
chroot "$root" /sbin/procd -s /tmp/install-ubus.sock -S > "$temporary/procd.log" 2>&1 &
for attempt in {1..100}; do
	ubus list service 2>/dev/null | grep -qx service && break
	sleep .02
done
ubus list service | grep -qx service || fail 'native procd did not connect'
ubus call service set '{"name":"dns-filter","instances":{"main":{"command":["/opt/managed/AdGuardHome","/tmp/process.uc","managed"],"respawn":["3600","1","0"]}}}' >/dev/null
ubus call service set '{"name":"shell-filter","instances":{"main":{"command":["/bin/sh","-c","/opt/managed/AdGuardHome /tmp/process.uc wrapped_core & wait"],"respawn":["3600","1","0"]}}}' >/dev/null
ubus call service set '{"name":"backup","instances":{"main":{"command":["/bin/sh","-c","exec /opt/unrelated/sleep /tmp/process.uc wrapped AdGuardHome"],"respawn":["3600","1","0"]}}}' >/dev/null
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
services=(AdGuardHome adguardhome luci-app-adguardhome luci-app-AdGuardHome ADGUARD-HOME dns-filter shell-filter)
for service in "${services[@]:1}" AdGuardHomeExporter backup; do
	cp "$root/etc/init.d/AdGuardHome" "$root/etc/init.d/$service"
done
for service in "${services[@]}" AdGuardHomeExporter backup; do
	ln -s "../init.d/$service" "$root/etc/rc.d/S99$service"
done
ln -s ../init.d/ADGUARD-HOME "$root/etc/rc.d/S88imported-alias"
ln -s ../init.d/dns-filter "$root/etc/rc.d/S81custom-dns"
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
chroot "$root" /opt/variant/ADGUARDHOME /tmp/process.uc variant & variant=$!
chroot "$root" /opt/renamed/AdGuardHome /tmp/process.uc renamed & renamed=$!
chroot "$root" /opt/wrapper/AdGuardHome & shell=$!
# Executable basename is sleep, while argv contains AdGuardHome: leave it alone.
chroot "$root" /opt/unrelated/sleep /tmp/process.uc unrelated AdGuardHome & unrelated=$!
for attempt in {1..100}; do
	[[ -f $root/tmp/normal.ready && -f $root/tmp/stubborn.ready && -f $root/tmp/deleted.ready && -f $root/tmp/unrelated.ready && -f $root/tmp/variant.ready && -f $root/tmp/managed.ready && -f $root/tmp/wrapped.ready && -f $root/tmp/renamed.ready && -f $root/tmp/shell.ready && -f $root/tmp/wrapped_core.ready ]] && break
	sleep .02
done
[[ -f $root/tmp/normal.ready && -f $root/tmp/stubborn.ready && -f $root/tmp/deleted.ready && -f $root/tmp/unrelated.ready && -f $root/tmp/variant.ready && -f $root/tmp/managed.ready && -f $root/tmp/wrapped.ready && -f $root/tmp/renamed.ready && -f $root/tmp/shell.ready && -f $root/tmp/wrapped_core.ready ]] || fail 'process fixtures did not start'
rm "$root/opt/deleted/AdGuardHome"
mv "$root/opt/renamed/AdGuardHome" "$root/opt/renamed/agh-backup"
[[ $(cat "$root/proc/$renamed/comm") == AdGuardHome && $(readlink "$root/proc/$renamed/exe") == */agh-backup ]] || fail 'renamed core fixture lost its original comm'
[[ $(cat "$root/proc/$shell/comm") == AdGuardHome && $(readlink "$root/proc/$shell/exe") == */bin/busybox ]] || fail 'shell fixture does not exercise the same-name interpreter boundary'
# An unknown service sharing core and unrelated instances must be rejected
# before either instance or the old coordinator is stopped.
ubus call service set '{"name":"mixed","instances":{"core":{"command":["/opt/managed/AdGuardHome","/tmp/process.uc","mixed_core"]},"other":{"command":["/opt/unrelated/sleep","/tmp/process.uc","mixed_other"]}}}' >/dev/null
cp "$root/etc/init.d/AdGuardHome" "$root/etc/init.d/mixed"
ln -s ../init.d/mixed "$root/etc/rc.d/S89mixed-alias"
for attempt in {1..100}; do
	[[ -f $root/tmp/mixed_core.ready && -f $root/tmp/mixed_other.ready ]] && break
	sleep .02
done
[[ -f $root/tmp/mixed_core.ready && -f $root/tmp/mixed_other.ready ]] || fail 'mixed service did not start'
if chroot "$root" /bin/sh /tmp/preinst > "$temporary/mixed.log" 2>&1; then
	fail 'mixed service was not rejected'
fi
grep -q mixed "$temporary/mixed.log" || fail 'mixed preflight failed for a different reason'
[[ ! -e $root/tmp/mixed_core.term && ! -e $root/tmp/mixed_other.term && -L $root/etc/rc.d/S89mixed-alias ]] || fail 'mixed service was partially stopped'
! grep -q '^old:stop' "$root/tmp/service-events" || fail 'mixed preflight stopped the coordinator'
[[ $(ubus call service list '{"name":"mixed"}' | grep -c '"running": true') == 2 ]] || fail 'mixed service lost an instance'
ubus call service delete '{"name":"mixed"}' >/dev/null
rm "$root/etc/init.d/mixed" "$root/etc/rc.d/S89mixed-alias"
started=$SECONDS
run_apk add "$temporary/package-2.apk" || fail 'upgrade transaction failed'
[[ $((SECONDS - started)) -ge 10 ]] || fail 'KILL fallback did not wait for TERM cleanup'
for pid in "$normal" "$stubborn" "$deleted" "$variant" "$renamed"; do
	! kill -0 "$pid" 2>/dev/null || fail 'an AdGuard Home executable survived cleanup'
done
wait "$normal" || fail 'normal core did not exit through TERM'
wait "$deleted" || fail 'deleted executable did not exit through TERM'
wait "$variant" || fail 'uppercase core did not exit through TERM'
wait "$renamed" || fail 'renamed running core did not exit through TERM'
rc=0; wait "$stubborn" || rc=$?
[[ $rc == 137 && -f $root/tmp/stubborn.term ]] || fail 'TERM-to-KILL fallback was not exercised'
kill -0 "$unrelated" && [[ ! -e $root/tmp/unrelated.term ]] || fail 'unrelated process was signaled'
kill -0 "$shell" && [[ ! -e $root/tmp/shell.term ]] || fail 'same-name shell wrapper was signaled'
[[ ! -e $root/var/run/luci-app-adguardhome-yaml/install-incomplete ]] || fail 'successful cleanup retained its gate'
for path in etc/init.d/AdGuardHome etc/uci-defaults/40_luci-AdGuardHome etc/hotplug.d/acme/95-AdGuardHome; do
	cmp "$root/$path" "$temporary/payload-2/$path" || fail "old executable was retained: $path"
	[[ ! -e $root/$path.apk-new ]] || fail "stale APK candidate survived: $path"
done
for service in "${services[@]}"; do
	grep -Fq "{\"name\":\"$service\"}" "$root/tmp/service-events" || fail "service was not deleted: $service"
	[[ ! -L $root/etc/rc.d/S99$service ]] || fail "autostart link survived: $service"
done
[[ ! -L $root/etc/rc.d/S88imported-alias && ! -L $root/etc/rc.d/S81custom-dns ]] || fail 'alternate autostart link names survived'
[[ -L $root/etc/rc.d/S99AdGuardHomeExporter && -L $root/etc/rc.d/S99backup ]] || fail 'unrelated autostart links were removed'
[[ -f $root/tmp/managed.term && -f $root/tmp/wrapped_core.term && ! -e $root/tmp/wrapped.term ]] || fail 'managed core or unrelated wrapper was handled incorrectly'
ubus call service list '{"name":"dns-filter"}' | grep -q 'dns-filter' && fail 'managed core service can still respawn'
ubus call service list '{"name":"shell-filter"}' | grep -q 'shell-filter' && fail 'core shell service can still respawn'
ubus call service list '{"name":"backup"}' | grep -q '"running": true' || fail 'unrelated shell service did not survive'
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

# Failed service deletion leaves a pending respawn even while no core PID
# exists. The final native service query must reject that incomplete cleanup.
# Keep the respawn gap longer than the bounded shutdown wait.
ubus call service set '{"name":"delayed-filter","instances":{"main":{"command":["/opt/managed/AdGuardHome","/tmp/process.uc","delayed"],"respawn":["3600","30","0"]}}}' >/dev/null
for attempt in {1..100}; do [[ -f $root/tmp/delayed.ready ]] && break; sleep .02; done
[[ -f $root/tmp/delayed.ready ]] || fail 'delayed core did not start'
ubus call service list '{"name":"delayed-filter","verbose":true}' | grep -q '"timeout": 30,' || fail 'native procd did not accept the thirty-second respawn timeout'
: > "$root/tmp/fail-delete"
sha256sum "$root/etc/init.d/AdGuardHome" "$root/etc/hotplug.d/acme/95-AdGuardHome" > "$temporary/programs.sha256"
if chroot "$root" /bin/sh /tmp/preinst > "$temporary/delete.log" 2>&1; then
	fail 'failed service deletion was accepted'
fi
grep -q 'still registered' "$temporary/delete.log" || fail 'delete failure took a different path'
ubus call service list '{"name":"delayed-filter"}' > "$temporary/delayed-state.json"
[[ -f $root/tmp/delayed.term ]] && grep -q '"running": false' "$temporary/delayed-state.json" || fail 'delayed respawn did not leave a gap without a core PID'
sha256sum --check --status "$temporary/programs.sha256" || fail 'failed service deletion removed plugin programs'
[[ -f $root/var/run/luci-app-adguardhome-yaml/install-incomplete ]] || fail 'failed service deletion discarded its gate'
rm "$root/tmp/fail-delete"
ubus call service delete '{"name":"delayed-filter"}' >/dev/null

# A different package owning an executable candidate must not lose that file
# or any current plugin programs during the attempted cleanup.
run_apk add "$temporary/foreign.apk" || fail 'foreign owner fixture did not install'
sha256sum "$root/etc/init.d/AdGuardHome" "$root/etc/hotplug.d/acme/95-AdGuardHome" \
	"$root/etc/hotplug.d/acme/95-AdGuardHome.apk-new" > "$temporary/owned.sha256"
if chroot "$root" /bin/sh /tmp/preinst > "$temporary/owner.log" 2>&1; then
	fail 'foreign package owner was not rejected'
fi
grep -q foreign-app "$temporary/owner.log" || fail 'owner preflight failed for a different reason'
sha256sum --check --status "$temporary/owned.sha256" || fail 'foreign owner preflight removed or changed a program'
run_apk del foreign-app || fail 'foreign owner fixture could not be removed'

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
printf 'INSTALL_CLEANUP_OK term=4 kill=1 unrelated=3 procd=deleted mixed=blocked owner=blocked delete_failure=blocked service_names=7 aliases=removed programs=replaced user_files=preserved upgrade=enabled retry=recovered failed_stop=blocked\n'
SH
# No core-like process exists until this private PID namespace is active.
timeout --kill-after=2s 90s unshare --mount --pid --fork --kill-child bash -c '
	set -eu
	mount --make-rprivate /
	mount -t proc proc "$1/proc"
	exec bash "$3/driver.sh" "$1" "$2" "$3"
' install-cleanup "$root" "$apk" "$temporary"
