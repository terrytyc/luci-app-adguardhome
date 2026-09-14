#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Full-only: execute production trigger JSON using native procd/libjson_script.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
runtime=${TARGET_ROOT:-${ADGUARDHOME_TEST_UCI_ROOT:-${SDK:-/root/sdk-x86-64}/staging_dir/target-x86_64_musl/root-x86}}
[[ $(id -u) == 0 && -x $runtime/sbin/procd && -x $runtime/bin/busybox ]] || {
	printf 'Native interface integration requires root and TARGET_ROOT\n' >&2
	exit 1
}
temporary=$(mktemp -d /tmp/adguardhome-interface-trigger.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
mkdir -p "$root"/{bin,sbin,dev,proc,tmp,var/run,var/lock,lib/functions,usr/bin,usr/lib,usr/share/libubox,etc/init.d}
cp -P "$runtime/lib"/*.so* "$root/lib/"
cp -P "$runtime/usr/lib"/*.so* "$root/usr/lib/"
cp "$runtime/sbin/"{procd,ubusd} "$root/sbin/"
cp "$runtime/bin/ubus" "$root/bin/"
cp "$runtime/usr/bin/jshn" "$root/usr/bin/"
cp "$runtime/usr/share/libubox/jshn.sh" "$root/usr/share/libubox/"
cp "$runtime/lib/functions/procd.sh" "$root/lib/functions/"
cp "$runtime/bin/busybox" "$root/bin/busybox"
chmod 0755 "$root/bin/busybox"
for applet in sh cat grep sleep readlink basename flock logger; do
	ln -s busybox "$root/bin/$applet"
done
mknod "$root/dev/null" c 1 3
mknod "$root/dev/urandom" c 1 9
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\n' > "$root/etc/group"
. "$repo/luci-app-adguardhome/tests/lib/function-body.sh"
function_body "${INTERFACE_INIT_FILE:-$repo/luci-app-adguardhome/root/etc/init.d/AdGuardHome}" \
	service_triggers > "$root/tmp/triggers.sh"
# Substitute only the callback; matching, JSON construction and the five-second
# debounce all use the platform implementation and the production declaration.
cat > "$root/etc/init.d/AdGuardHome" <<'SH'
#!/bin/sh
[ "$*" = network_ready ] || exit 1
printf 'ready\n' >> /tmp/callbacks
SH
chmod 0755 "$root/etc/init.d/AdGuardHome"
cat > "$root/tmp/probe.sh" <<'SH'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin
initscript=/etc/init.d/AdGuardHome
# procd.sh establishes its shell helpers and service lock before errexit.
. /lib/functions/procd.sh
. /tmp/triggers.sh
set -e
trap 'cat /tmp/procd.log /tmp/ubusd.log >&2' EXIT
/sbin/ubusd -s /tmp/test-ubus.sock > /tmp/ubusd.log 2>&1 &
/sbin/procd -s /tmp/test-ubus.sock -S > /tmp/procd.log 2>&1 &
procd_pid=$!
ubus() { /bin/ubus -s /tmp/test-ubus.sock "$@"; }
attempts=10
until ubus list service 2>/dev/null | grep -qx service; do
	[ "$attempts" -gt 0 ] || { echo 'native procd did not connect' >&2; exit 1; }
	kill -0 "$procd_pid"
	attempts=$((attempts - 1))
	sleep 1
done
json_set_namespace procd
json_init
json_add_string name AdGuardHome
json_add_array triggers
service_triggers
json_close_array
json_dump > /tmp/definition.json
ubus call service set "$(cat /tmp/definition.json)"
: > /tmp/callbacks
# netifd sends interface.down on teardown. An update before IFS_UP omits
# l3_device; a ready interface.update includes it (netifd/ubus.c).
ubus call service event '{"type":"interface.down","data":{"interface":"wan","up":false}}'
ubus call service event '{"type":"interface.update","data":{"interface":"wan","up":false,"pending":true}}'
sleep 6
[ ! -s /tmp/callbacks ] || { echo 'down or unready update launched network_ready' >&2; exit 1; }
ubus call service event '{"type":"interface.update","data":{"interface":"wan","up":true,"l3_device":"eth0"}}'
sleep 6
[ "$(cat /tmp/callbacks)" = ready ] || { echo 'ready update did not launch exactly one callback' >&2; exit 1; }
kill -0 "$procd_pid"
trap - EXIT
printf 'INTERFACE_TRIGGER_OK down=0 unready_update=0 ready_update=1\n'
SH
# The driver is PID 1; native procd is a child and therefore skips boot/init.
# Namespace teardown kills both daemons, including when an assertion fails.
unshare --mount --pid --fork --kill-child bash -c '
	set -eu
	root=$1
	mount --make-rprivate /
	mount -t proc proc "$root/proc"
	exec chroot "$root" /bin/sh /tmp/probe.sh
' interface-trigger "$root"
