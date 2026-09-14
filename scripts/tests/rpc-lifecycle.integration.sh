#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Full-only native RPC check. No installed services or previous fixture required.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
runtime=${TARGET_ROOT:-${ADGUARDHOME_TEST_UCI_ROOT:-${SDK:-/root/sdk-x86-64}/staging_dir/target-x86_64_musl/root-x86}}
busybox=${STATIC_BUSYBOX:-$(command -v busybox || true)}
[[ $(id -u) == 0 && -x $runtime/usr/bin/ucode && -x $busybox ]] || {
	printf 'Native RPC integration requires root, TARGET_ROOT and STATIC_BUSYBOX\n' >&2
	exit 1
}
temporary=$(mktemp -d /tmp/adguardhome-rpc-lifecycle.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
root=$temporary/root
mkdir -p "$root"/{bin,dev,proc,tmp/.uci,var/run,lib,usr/bin,usr/lib/ucode,etc/config,etc/init.d,mnt/adguardhome}
# Copy shared libraries, not the SDK's kernel modules or other rootfs contents.
cp -P "$runtime/lib"/*.so* "$root/lib/"
cp -P "$runtime/usr/lib"/*.so* "$root/usr/lib/"
for module in fs digest ubus uci uloop; do
	cp "$runtime/usr/lib/ucode/$module.so" "$root/usr/lib/ucode/"
done
cp "$runtime/usr/bin/ucode" "$root/usr/bin/ucode"
cp "$busybox" "$root/bin/busybox"
chmod 0755 "$root/bin/busybox"
chroot "$root" /bin/busybox --install -s /bin
mknod "$root/dev/null" c 1 3
mknod "$root/dev/urandom" c 1 9
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\n' > "$root/etc/group"
cp "$repo/luci-app-adguardhome/root/usr/share/rpcd/ucode/luci.adguardhome" "$root/tmp/rpc.uc"
cp "$repo/scripts/tests/rpc-lifecycle.uc" "$root/tmp/probe.uc"
cp "$repo/luci-app-adguardhome/root/usr/share/luci-app-adguardhome/default.yaml" "$root/mnt/adguardhome/AdGuardHome.yaml"
cat > "$root/etc/config/adguardhome" <<'UCI'
config adguardhome 'config'
	option enabled '0'
	option work_dir '/mnt/adguardhome'
	option config_file '/mnt/adguardhome/AdGuardHome.yaml'
	option verbose '0'
config adguardhome 'luci'
	option redirect 'none'
	option run_from_memory '0'
	option memory_writeback_interval '0'
UCI
# Only the service worker is substituted. The complete RPC module owns real
# UCI reads, native child callbacks, staging, lock descriptors and job records.
cat > "$root/etc/init.d/AdGuardHome" <<'SH'
#!/bin/sh
set -eu
mode=$(cat /tmp/worker-mode)
stage=
case "$1" in
	settings_update) expected=$8; token=$9; shift 9; candidate=$1; lock=$2 ;;
	yaml_update_job) expected=$2; candidate=$3; stage=$4; descriptor=$5; lock=$6; token=$7
		test -r "/proc/self/fd/$descriptor" ;;
	*) exit 1 ;;
esac
test -r "/proc/self/fd/$lock"
[ "$mode" != exit ] || exit 0
if [ "$mode" = failure ]; then
	result="failure:$expected:$candidate"
else
	[ -z "$stage" ] || cp "/proc/self/fd/$descriptor" /mnt/adguardhome/AdGuardHome.yaml
	result="success:$candidate:0:$expected:$candidate"
fi
umask 077
temporary="/var/run/luci-app-adguardhome-yaml/.$token.Work01"
printf '%s\n' "$result" > "$temporary"
mv "$temporary" "/var/run/luci-app-adguardhome-yaml/$token"
if [ "$mode" = handoff ]; then
	remaining=500
	while [ ! -e /tmp/release-worker ] && [ "$remaining" -gt 0 ]; do
		sleep 0.01
		remaining=$((remaining - 1))
	done
	test -e /tmp/release-worker
fi
SH
chmod 0755 "$root/etc/init.d/AdGuardHome"
# A private PID namespace also terminates the worker if a test assertion fails.
# The root bind makes its actual filesystem visible to RPC mount validation.
unshare --mount --pid --fork --kill-child bash -c '
	set -eu
	root=$1
	mount --make-rprivate /
	mount --bind "$root" "$root"
	mount -t proc proc "$root/proc"
	exec chroot "$root" /usr/bin/ucode /tmp/probe.uc
' rpc-lifecycle "$root"
