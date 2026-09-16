#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Native APK -> platform defaults -> real coordinator/procd/core -> verification.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
package=$repo/luci-app-adguardhome
runtime=${TARGET_ROOT:-${ADGUARDHOME_TEST_UCI_ROOT:-${SDK:-/root/sdk-x86-64}/staging_dir/target-x86_64_musl/root-x86}}
apk=${APK_BIN:-${SDK:-/root/sdk-x86-64}/staging_dir/host/bin/apk}
busybox=${STATIC_BUSYBOX:-$(command -v busybox)}
[[ $(id -u) == 0 && -x $apk && -x $runtime/usr/bin/AdGuardHome && -f $runtime/etc/rc.common ]] || {
	printf 'Package lifecycle integration requires root and the pinned full test runtime\n' >&2; exit 1;
}
temporary=$(mktemp -d /tmp/adguardhome-package-lifecycle.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
mkdir -p "$root"/{bin,sbin,lib,usr/bin,usr/lib,usr/share/libubox,etc/init.d,etc/config,etc/rc.d,dev,proc,tmp,root}
ln -s tmp "$root/var"
cp -P "$runtime/lib"/*.so* "$root/lib/"
cp -a "$runtime/lib/functions.sh" "$runtime/lib/functions" "$runtime/lib/config" "$root/lib/"
cp -a "$runtime/usr/lib/ucode" "$root/usr/lib/"
cp -P "$runtime/usr/lib"/*.so* "$root/usr/lib/"
cp "$runtime/sbin/"{uci,procd,ubusd,ujail,validate_data} "$root/sbin/"
cp "$runtime/usr/bin/"{ucode,AdGuardHome,jshn,jsonfilter} "$root/usr/bin/"
cp "$runtime/usr/bin/util-linux-flock" "$root/usr/bin/flock"
cp "$runtime/bin/ubus" "$root/bin/"
if [[ -f ${apk%/*}/.apk.bin ]]; then
	mkdir -p "$root/opt/apk-test/lib"
	cp "${apk%/*}/.apk.bin" "$root/opt/apk-test/apk"
	cp -L "${apk%/*}/../lib/"{ld-linux-x86-64.so.2,libc.so.6,libpthread.so.0} "$root/opt/apk-test/lib/"
	printf '#!/bin/sh\nexec /opt/apk-test/lib/ld-linux-x86-64.so.2 --library-path /opt/apk-test/lib /opt/apk-test/apk "$@"\n' > "$root/sbin/apk"
	chmod 0755 "$root/sbin/apk"
else
	cp "$apk" "$root/sbin/apk"
fi
cp "$runtime/usr/share/libubox/jshn.sh" "$root/usr/share/libubox/"
cp "$runtime/etc/"{rc.common,hosts} "$root/etc/"
cp -a "$runtime/etc/capabilities" "$root/etc/"
cp "$runtime/etc/init.d/adguardhome" "$root/etc/init.d/"
cp "$runtime/etc/config/"{adguardhome,firewall,dhcp} "$root/etc/config/"
cp "$busybox" "$root/bin/busybox-static"
chroot "$root" /bin/busybox-static --install -s /bin
# Never write through applet links: replace the link itself before copying.
rm -f "$root/bin/busybox" "$root/bin/sh" "$root/bin/bash"
cp "$runtime/bin/busybox" "$root/bin/busybox"
ln -s busybox "$root/bin/sh"
# Only the test driver uses host bash; supervised helpers use the target libc.
cp /bin/bash "$root/bin/bash"
while IFS= read -r library; do
	cp -L --parents "$library" "$root"
done < <(ldd /bin/bash | awk '$2 == "=>" && $3 ~ /^\// { print $3 } $1 ~ /^\// { print $1 }')
for applet in setsid sha256sum du find head; do ln -s /bin/busybox-static "$root/usr/bin/$applet"; done
ln -s /bin/busybox "$root/sbin/start-stop-daemon"
mknod "$root/dev/null" c 1 3
mknod "$root/dev/urandom" c 1 9
chmod 0666 "$root/dev/null" "$root/dev/urandom"
printf 'root:x:0:0:root:/root:/bin/sh\nadguardhome:x:853:853:AdGuard Home:/var/lib/adguardhome:/bin/false\n' > "$root/etc/passwd"
printf 'root:x:0:\nadguardhome:x:853:\n' > "$root/etc/group"
# RPC module reload is outside this service lifecycle; no auth daemon is started.
printf '#!/bin/sh\n[ "$1" = reload ]\n' > "$root/etc/init.d/rpcd"
chmod 0755 "$root/etc/init.d/rpcd"

{
	printf 'PKG_NAME:=luci-app-adguardhome\ninclude %s/scripts/*.mk\n' "$package"
	awk '/^define / { copying=1 } copying { print } /^endef$/ { copying=0 }' "$package/Makefile"
	for phase in preinst postinst prerm postrm; do
		printf '$(file >%s/%s,$(Package/$(PKG_NAME)/%s))\n' "$temporary" "$phase" "$phase"
	done
	printf 'all:; @:\n'
} > "$temporary/hooks.make"
make --no-print-directory -s -f "$temporary/hooks.make"
for phase in postinst prerm; do
	{
		printf '#!/bin/sh\nexport root="" pkgname=luci-app-adguardhome\n. /lib/functions.sh\n'
		[[ $phase != postinst ]] || printf 'add_group_and_user\n'
		printf 'default_%s\n' "$phase"
		cat "$temporary/$phase"
	} > "$temporary/$phase-platform"
done
{ printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'; cat "$temporary/postinst-platform"; } > "$temporary/post-upgrade"
{ printf '#!/bin/sh\nexport PKG_UPGRADE=1\n'; cat "$temporary/preinst"; } > "$temporary/pre-upgrade"
for revision in 1 2 3; do
	payload=$temporary/payload-$revision
	mkdir -p "$payload/lib/apk/packages"
	cp -a "$package/root/." "$payload/"
	for path in etc/init.d/AdGuardHome etc/uci-defaults/40_luci-AdGuardHome; do
		awk -v helper_dir="$package/scripts" -f "$package/scripts/expand-helpers.awk" \
			"$package/root/$path" > "$payload/$path"
	done
	printf '/etc/init.d/AdGuardHome\n/etc/uci-defaults/40_luci-AdGuardHome\n' > "$payload/lib/apk/packages/luci-app-adguardhome.list"
	# Keep package networking out of the fixture; all DNS and HTTP checks use
	# actual listening sockets in a private network namespace.
	python3 - "$payload/usr/share/luci-app-adguardhome/default.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as stream:
    config = yaml.safe_load(stream)
config['filters'] = []
with open(path, 'w') as stream:
    yaml.safe_dump(config, stream, sort_keys=False)
PY
	mkdir -p "$payload/etc/AdGuardHome"
	cp "$payload/usr/share/luci-app-adguardhome/default.yaml" "$payload/etc/AdGuardHome/AdGuardHome.yaml"
	printf '/etc/AdGuardHome/AdGuardHome.yaml\n/root/.luci-app-adguardhome/\n' > "$payload/lib/apk/packages/luci-app-adguardhome.conffiles"
	printf '/etc/AdGuardHome/AdGuardHome.yaml %s\n' "$(sha256sum "$payload/etc/AdGuardHome/AdGuardHome.yaml" | cut -d ' ' -f 1)" > "$payload/lib/apk/packages/luci-app-adguardhome.conffiles_static"
	find "$payload" -type d -exec chmod 0755 {} +
	find "$payload" -type f -exec chmod 0644 {} +
	chmod 0755 "$payload/etc/init.d/AdGuardHome" "$payload/etc/uci-defaults/40_luci-AdGuardHome" \
		"$payload/etc/hotplug.d/acme/95-AdGuardHome" "$payload/lib/apk/commit_hooks.d/90-luci-app-adguardhome"
	chmod 0700 "$payload/etc/AdGuardHome"
	chmod 0600 "$payload/etc/AdGuardHome/AdGuardHome.yaml"
	"$apk" mkpkg --info name:luci-app-adguardhome --info "version:$revision-r0" --info arch:noarch \
		--files "$payload" --script "pre-install:$temporary/preinst" --script "pre-upgrade:$temporary/pre-upgrade" \
		--script "post-install:$temporary/postinst-platform" --script "post-upgrade:$temporary/post-upgrade" \
		--script "pre-deinstall:$temporary/prerm-platform" --script "post-deinstall:$temporary/postrm" \
		--output "$temporary/package-$revision.apk" >/dev/null
done

cat > "$temporary/apply.uc" <<'UC'
import * as uloop from 'uloop';
let methods = loadfile('/usr/share/rpcd/ucode/luci.adguardhome', { raw_mode: true })()['luci.adguardhome'];
uloop.init();
let settings = methods.get_settings.call();
settings.force_restart = ARGV[0] == '1';
let job = methods.set_settings.call({ args: settings });
if (!job.accepted) die(sprintf('Settings submission failed: %J', job));
let complete = false;
for (let attempt = 0; attempt < 300; attempt++) {
	let timer = uloop.timer(100, function() { uloop.end(); });
	uloop.run();
	let result = methods.get_settings_update.call({ args: { token: job.token } });
	if (result.error) die(sprintf('Settings polling failed: %J', result));
	if (result.state == 'done') {
		if (!result.ok || result.restarted != (ARGV[1] == '1'))
			die(sprintf('Unexpected settings result: %J', result));
		complete = true;
		break;
	}
}
if (!complete) die('Settings worker did not finish');
UC

cat > "$temporary/driver.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root=$1 apk=$2 temporary=$3
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	run /bin/ubus call service list > "$temporary/failed-services.log" || true
	run /bin/ps w > "$temporary/failed-processes.log" || true
	cat "$temporary/"*.log "$root/tmp/system.log" >&2; exit 1
}
run() { chroot "$root" "$@"; }
run_apk() {
	"$apk" --root "$root" --arch x86_64 --allow-untrusted --network=no \
		--repositories-file /dev/null --sync=no "$@" > "$temporary/apk.log" 2>&1 || fail 'APK transaction failed'
	! grep -q 'exited with error' "$temporary/apk.log" || fail 'APK package script failed'
}
apply_settings() {
	run /usr/bin/ucode /test/apply.uc "$@" > "$temporary/apply.log" 2>&1 || fail 'native settings apply failed'
}
core_pid() {
	local executable
	for executable in /proc/[0-9]*/exe; do
		[[ $(readlink "$executable" 2>/dev/null) == /usr/bin/AdGuardHome ]] || continue
		executable=${executable%/exe}
		printf '%s\n' "${executable##*/}"
	done
}
monitor_pid() {
	run /bin/ubus call service list '{"name":"AdGuardHome"}' |
		run /usr/bin/jsonfilter -e '@.AdGuardHome.instances.monitor.pid'
}
run /bin/busybox-static syslogd -n -O /tmp/system.log > "$temporary/syslogd.log" 2>&1 &
run /sbin/ubusd > "$temporary/ubusd.log" 2>&1 &
run /sbin/procd -S > "$temporary/procd.log" 2>&1 &
for attempt in {1..100}; do run /bin/ubus list service 2>/dev/null | grep -qx service && break; sleep .02; done
run /bin/ubus list service | grep -qx service || fail 'native procd did not connect'
run /sbin/uci set adguardhome.config.enabled=0
run /sbin/uci commit adguardhome
run_apk add --initdb "$temporary/package-1.apk"
[[ ! -e $root/etc/uci-defaults/40_luci-AdGuardHome ]] || fail 'platform did not consume defaults'
[[ -L $root/etc/rc.d/S18AdGuardHome ]] || fail 'fresh install did not enable coordinator'
run /etc/init.d/AdGuardHome install_check || fail 'disabled fresh install failed verification'
! run /etc/init.d/adguardhome running || fail 'disabled fresh install started the core'
printf 'ok - native fresh disabled install executes defaults and real installation verification\n'

# Enable the existing installation, then upgrade with actual pre/post scripts.
# The old core is stopped, replaced by the real coordinator and verified once.
run /sbin/uci set adguardhome.config.enabled=1
run /sbin/uci set adguardhome.luci.redirect=none
run /sbin/uci set adguardhome.luci.run_from_memory=1
run /sbin/uci set adguardhome.luci.memory_writeback_interval=60
run /sbin/uci commit adguardhome
run /etc/init.d/AdGuardHome start > "$temporary/start.log" 2>&1 || fail 'enabled fixture did not start'
run /etc/init.d/AdGuardHome install_check || fail 'enabled fixture failed verification'
[[ -f $root/tmp/luci-app-adguardhome-memory/state ]] || fail 'enabled fixture fell back from RAM'
sha256sum "$root/etc/AdGuardHome/AdGuardHome.yaml" > "$temporary/upgrade-yaml.sha256"
run_apk add "$temporary/package-2.apk"
run /etc/init.d/AdGuardHome install_check || fail 'enabled upgrade failed verification'
run /etc/init.d/adguardhome running || fail 'enabled upgrade lost the core'
[[ -L $root/etc/rc.d/S18AdGuardHome && ! -L $root/etc/rc.d/S19adguardhome ]] || fail 'enabled upgrade boot links are wrong'
[[ ! -e $root/etc/uci-defaults/40_luci-AdGuardHome ]] || fail 'enabled upgrade retained defaults'
[[ -f $root/tmp/luci-app-adguardhome-memory/state ]] || fail 'enabled upgrade fell back from RAM'
[[ $(run /bin/ubus call service list '{"name":"AdGuardHome"}' | run /usr/bin/jsonfilter -e '@.AdGuardHome.instances.monitor.running') == true ]] || fail 'enabled upgrade lost the real monitor'
sha256sum -c "$temporary/upgrade-yaml.sha256" >/dev/null || fail 'enabled upgrade changed user YAML'
printf 'ok - native enabled upgrade executes defaults, real RAM core/monitor startup and service verification\n'

# Exercise the installed RPC, its authenticated worker and both real processes.
core_before=$(core_pid)
monitor_before=$(monitor_pid)
[[ $core_before =~ ^[0-9]+$ && $monitor_before =~ ^[0-9]+$ ]] || fail 'apply fixture lacks unique core and monitor PIDs'
apply_settings 0 0
[[ $(core_pid) == "$core_before" && $(monitor_pid) == "$monitor_before" ]] || fail 'unchanged apply restarted core or monitor'
sha256sum -c "$temporary/upgrade-yaml.sha256" >/dev/null || fail 'unchanged apply changed user YAML'
printf 'ok - native unchanged RPC apply preserves core and monitor PIDs\n'

printf 'write-back-on-force\n' > "$root/etc/AdGuardHome/data/force-sentinel"
chown 853:853 "$root/etc/AdGuardHome/data/force-sentinel"
chmod 0600 "$root/etc/AdGuardHome/data/force-sentinel"
[[ ! -e $root/tmp/luci-app-adguardhome-memory/backing-data/force-sentinel ]] || fail 'force sentinel was not written to RAM'
apply_settings 1 1
core_after=$(core_pid)
monitor_after=$(monitor_pid)
[[ $core_after =~ ^[0-9]+$ && $monitor_after =~ ^[0-9]+$ &&
   $core_after != "$core_before" && $monitor_after != "$monitor_before" ]] || fail 'force apply did not replace core and monitor PIDs'
[[ ! -e /proc/$core_before && ! -e /proc/$monitor_before ]] || fail 'force apply left an old core or monitor process'
[[ -f $root/tmp/luci-app-adguardhome-memory/state ]] || fail 'force apply fell back from RAM'
[[ $(cat "$root/tmp/luci-app-adguardhome-memory/backing-data/force-sentinel") == write-back-on-force ]] || fail 'force apply lost RAM write-back'
sha256sum -c "$temporary/upgrade-yaml.sha256" >/dev/null || fail 'force apply changed user YAML'
run /etc/init.d/AdGuardHome install_check || fail 'force apply failed service verification'
printf 'ok - native forced RPC apply replaces core and monitor, writes RAM data back and preserves YAML\n'

run /etc/init.d/AdGuardHome stop > "$temporary/stop.log" 2>&1 || fail 'fixture did not stop'
run /sbin/uci set adguardhome.config.enabled=0
run /sbin/uci commit adguardhome
run_apk add "$temporary/package-3.apk"
run /etc/init.d/AdGuardHome install_check || fail 'disabled upgrade failed verification'
! run /etc/init.d/adguardhome running || fail 'disabled upgrade started the core'
[[ -L $root/etc/rc.d/S18AdGuardHome ]] || fail 'disabled upgrade lost coordinator boot links'
sha256sum -c "$temporary/upgrade-yaml.sha256" >/dev/null || fail 'disabled upgrade changed user YAML'
printf 'ok - native disabled upgrade keeps core stopped and coordinator enabled\n'
apply_settings 1 0
[[ -z $(core_pid) && -z $(monitor_pid) ]] || fail 'disabled force apply started core or monitor'
sha256sum -c "$temporary/upgrade-yaml.sha256" >/dev/null || fail 'disabled force apply changed user YAML'
printf 'ok - native disabled force apply keeps core and monitor stopped\n'

# A successful uninstall must stop the real RAM core, write back its data, and
# remove only plugin state. The YAML, user UCI, data and adjacent files remain.
run /sbin/uci set adguardhome.config.enabled=1
run /sbin/uci set adguardhome.luci.run_from_memory=1
run /sbin/uci set adguardhome.luci.memory_writeback_interval=0
run /sbin/uci commit adguardhome
run /etc/init.d/AdGuardHome start > "$temporary/ram-start.log" 2>&1 || fail 'RAM fixture did not start'
run /etc/init.d/AdGuardHome install_check || fail 'RAM core failed verification'
[[ -f $root/tmp/luci-app-adguardhome-memory/state ]] || fail 'RAM fixture has no authenticated state'
printf 'write-back-on-uninstall\n' > "$root/etc/AdGuardHome/data/lifecycle-sentinel"
chown 853:853 "$root/etc/AdGuardHome/data/lifecycle-sentinel"
chmod 0600 "$root/etc/AdGuardHome/data/lifecycle-sentinel"
[[ ! -e $root/tmp/luci-app-adguardhome-memory/backing-data/lifecycle-sentinel ]] || fail 'sentinel was not written to RAM'
printf 'keep-adjacent\n' > "$root/etc/AdGuardHome/adjacent"
sha256sum "$root/etc/AdGuardHome/AdGuardHome.yaml" "$root/etc/AdGuardHome/adjacent" > "$temporary/user.sha256"
run /sbin/uci export adguardhome | sed '/option managed_/d; \|list jail_mount_rw.*/etc/AdGuardHome/data|d' > "$temporary/user-uci"
run_apk del luci-app-adguardhome
! run /etc/init.d/adguardhome running || fail 'successful uninstall left core running'
[[ $(cat "$root/etc/AdGuardHome/data/lifecycle-sentinel") == write-back-on-uninstall ]] || fail 'successful uninstall lost RAM writes'
sha256sum -c "$temporary/user.sha256" >/dev/null || fail 'successful uninstall changed YAML or adjacent user files'
run /sbin/uci export adguardhome | sed '/option managed_/d; \|list jail_mount_rw.*/etc/AdGuardHome/data|d' > "$temporary/removed-uci"
cmp "$temporary/user-uci" "$temporary/removed-uci" || fail 'successful uninstall changed user UCI fields'
for path in etc/init.d/AdGuardHome lib/apk/commit_hooks.d/90-luci-app-adguardhome \
	tmp/luci-app-adguardhome-memory var/run/luci-app-adguardhome/apk-core-before \
	var/run/luci-app-adguardhome/remove-ok var/run/luci-app-adguardhome/applied-runtime \
	root/.luci-app-adguardhome/managed-adguardhome.config; do
	[[ ! -e $root/$path && ! -L $root/$path ]] || fail "successful uninstall retained $path"
done
printf 'ok - native successful uninstall stops real core, writes RAM data back and removes temporary snapshot\n'
printf 'PACKAGE_LIFECYCLE_OK fresh=disabled upgrade=ram-monitor,disabled apply=unchanged,forced,disabled removal=ram-writeback\n'
SH
mkdir "$root/test" "$root/.oldroot"
cp "$temporary/driver.sh" "$temporary/apply.uc" "$temporary/"package-*.apk "$root/test/"
timeout --kill-after=2s 180s unshare --mount --pid --net --fork --kill-child bash -c '
	set -eu
	mount --make-rprivate /
	mount --bind "$1" "$1"
	mount -t proc proc "$1/proc"
	mount -t tmpfs tmpfs "$1/tmp"
	mkdir -p "$1/tmp/run" "$1/tmp/lock"
	# A chroot alone leaks host path prefixes through jailed /proc/PID/exe.
	# Use an actual root mount so production PID ownership checks run unchanged.
	cd "$1"
	pivot_root . .oldroot
	cd /
	umount -l /.oldroot
	rmdir /.oldroot
	/bin/ifconfig lo up
	exec /bin/bash /test/driver.sh / /sbin/apk /test
' package-lifecycle "$root" "$apk" "$temporary"
