#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Manual SDK integration check; intentionally excluded from *.test.sh.
# APK_BIN=/path/to/apk STATIC_BUSYBOX=/path/to/static/busybox bash "$0"
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
apk=${APK_BIN:-${SDK:-/root/sdk-x86-64}/staging_dir/host/bin/apk}
hook=${APK_HOOK_FILE:-$repo/luci-app-adguardhome/root/lib/apk/commit_hooks.d/90-luci-app-adguardhome}
init=${APK_INIT_FILE:-$repo/luci-app-adguardhome/root/etc/init.d/AdGuardHome}
busybox=${STATIC_BUSYBOX:-$(command -v busybox || true)}
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || die 'usage: APK_BIN=... STATIC_BUSYBOX=... APK_HOOK_FILE=... APK_INIT_FILE=... APK_HOOK_TEST_TMPDIR=... bash scripts/tests/apk-hook.integration.sh'
[[ $(id -u) == 0 ]] || die 'this isolated chroot integration test requires root'
[[ -x $apk ]] || die "native SDK apk is unavailable: $apk"
[[ -f $hook ]] || die "production commit hook is unavailable: $hook"
[[ -f $init ]] || die "production coordinator is unavailable: $init"
[[ -n $busybox && -x $busybox ]] || die 'a static BusyBox is required; set STATIC_BUSYBOX'
version=$("$apk" --version)
[[ $version == 'apk-tools 3.'* ]] || die "APK v3 is required: $version"

test_parent=$(cd -- "${APK_HOOK_TEST_TMPDIR:-/tmp}" && pwd -P)
temporary=$(mktemp -d "$test_parent/adguardhome-apk-hook.XXXXXX")
cleanup() {
	local rc=$?
	trap - EXIT
	case "$temporary" in
		"$test_parent"/adguardhome-apk-hook.??????) rm -rf -- "$temporary" ;;
		*) printf 'Refusing to remove unexpected test directory: %s\n' "$temporary" >&2; exit 1 ;;
	esac
	exit "$rc"
}
trap cleanup EXIT
root=$temporary/root
mkdir -p "$root/bin" "$root/dev" "$root/etc/init.d" "$root/etc/config" "$root/etc/rc.d" \
	"$root/lib/apk/commit_hooks.d" "$root/var/run"
cp "$busybox" "$root/bin/busybox"
chmod 0755 "$root/bin/busybox"
ln -s busybox "$root/bin/sh"
: >"$root/dev/null"
chroot "$root" /bin/sh -c ':' || die 'STATIC_BUSYBOX must run without libraries inside an empty chroot'
chroot "$root" /bin/busybox --install -s /bin

. "$repo/luci-app-adguardhome/tests/lib/function-body.sh"
helper_dir=$repo/luci-app-adguardhome/scripts
awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" "$init" >"$temporary/init.expanded"

# Package scripts and the unmodified hook run in chroot. Keep production
# fingerprint/snapshot/reconcile decisions; stub only OpenWrt service/UCI calls.
cat >"$root/etc/init.d/AdGuardHome" <<'SH'
#!/bin/sh
set -eu
CORE_BINARY=/usr/bin/AdGuardHome
OFFICIAL_SERVICE=/etc/init.d/adguardhome
OFFICIAL_CONFIG=adguardhome
PLUGIN_CONFIG=adguardhome
OFFICIAL_SECTION=config
NORMALIZER_RUNTIME_DIR=/var/run/luci-app-adguardhome
uci_guard_no_delta() { return 0; }
config_load() { return 0; }
validate_loaded_merged_sections() { return 0; }
config_get_bool() { [ "$1" = service_enabled ] && read -r service_enabled </etc/config/adguardhome; }
official_running() { [ -f /core-running ]; }
run_locked() { printf 'decision:%s:changed=%s\n' "$1" "$2" >>/events; "$@"; }
orchestrate_core_locked() { printf 'orchestrate\n' >>/events; "$OFFICIAL_SERVICE" start; }
stop_wrapper_locked() { [ "$1" = 0 ] && "$OFFICIAL_SERVICE" stop; }
sync_monitor_instance() { printf 'monitor:sync\n' >>/events; }
log_error() { :; }
SH
for name in entry_metadata root_private_directory root_private_file bounded_private_file \
	core_package_fingerprint apk_reconcile_locked apk_commit; do
	function_body "$temporary/init.expanded" "$name" >>"$root/etc/init.d/AdGuardHome"
done
cat >>"$root/etc/init.d/AdGuardHome" <<'SH'
[ "$#" = 2 ] && [ "$1" = apk_commit ] || exit 90
read -r enabled </etc/config/adguardhome
printf 'hook:%s:enabled=%s\n' "$2" "$enabled" >>/events
apk_commit "$2"
SH
chmod 0755 "$root/etc/init.d/AdGuardHome"
cat >"$temporary/post-upgrade" <<'SH'
#!/bin/sh
set -eu
printf 'core:post-upgrade\n' >>/events
/etc/init.d/adguardhome start
SH

for revision in 1 2 3; do
	payload=$temporary/payload-$revision
	mkdir -p "$payload/etc/init.d" "$payload/usr/bin"
	printf '#!/bin/sh\nprintf "dummy core v%s\\n"\n' "$revision" >"$payload/usr/bin/AdGuardHome"
	chmod 0755 "$payload/usr/bin/AdGuardHome"
	{
		printf '#!/bin/sh\nset -eu\nversion=%s\n' "$revision"
		cat <<'SH'
printf 'core:%s:v%s\n' "$1" "$version" >>/events
case "$1" in
	start) : >/core-running ;;
	stop) rm -f /core-running ;;
	enable) ln -sf ../init.d/adguardhome /etc/rc.d/S99adguardhome ;;
	disable) rm -f /etc/rc.d/S99adguardhome ;;
	*) exit 92 ;;
esac
SH
	} >"$payload/etc/init.d/adguardhome"
	chmod 0755 "$payload/etc/init.d/adguardhome"
	"$apk" mkpkg --info name:adguardhome-hook-test --info "version:$revision.0-r0" \
		--info arch:noarch --files "$payload" --script "post-upgrade:$temporary/post-upgrade" \
		--output "$temporary/core-$revision.apk" >"$temporary/mkpkg-$revision.log" 2>&1 || {
		cat "$temporary/mkpkg-$revision.log" >&2; die "could not build dummy core $revision";
	}
done

apk_transaction() {
	"$apk" --root "$root" --arch x86_64 --allow-untrusted --network=no \
		--repositories-file /dev/null --sync=no "$@" >"$temporary/apk.log" 2>&1 || {
		cat "$temporary/apk.log" >&2; die 'native APK transaction failed';
	}
}
apk_transaction add --initdb "$temporary/core-1.apk"
cp "$hook" "$root/lib/apk/commit_hooks.d/90-luci-app-adguardhome"
chmod 0755 "$root/lib/apk/commit_hooks.d/90-luci-app-adguardhome"

for enabled in 0 1; do
	revision=$((enabled + 2))
	printf '%s\n' "$enabled" >"$root/etc/config/adguardhome"
	chroot "$root" /etc/init.d/adguardhome enable
	: >"$root/events"
	apk_transaction add "$temporary/core-$revision.apk"
	expected=$(printf 'hook:pre-commit:enabled=%s\ncore:post-upgrade\ncore:start:v%s\nhook:post-commit:enabled=%s\ndecision:apk_reconcile_locked:changed=1\ncore:disable:v%s\n' \
		"$enabled" "$revision" "$enabled" "$revision"
		if [[ $enabled == 0 ]]; then printf 'core:stop:v%s\nmonitor:sync' "$revision"
		else printf 'orchestrate\ncore:start:v%s' "$revision"; fi)
	[[ $(<"$root/events") == "$expected" ]] || {
		cat "$root/events" >&2; cat "$temporary/apk.log" >&2;
		die "unexpected native commit-hook ordering for enabled=$enabled";
	}
	if [[ $enabled == 0 ]]; then
		[[ ! -e $root/core-running ]] || die 'post-commit did not stop the disabled core started by post-upgrade'
	else
		[[ -f $root/core-running ]] || die 'enabled core did not remain running'
	fi
	[[ ! -e $root/etc/rc.d/S99adguardhome && ! -L $root/etc/rc.d/S99adguardhome ]] || die 'core upgrade left official autostart enabled'
	printf 'ok - native APK pre-commit -> core post-upgrade/start -> post-commit (enabled=%s)\n' "$enabled"
done

# Same-version reinstall preserves contents/mtime/size; inode replacement must
# still trigger the production fingerprint and reconcile the running core.
before_metadata=$(LC_ALL=C ls -ln "$root/usr/bin/AdGuardHome" "$root/etc/init.d/adguardhome")
before_inode=$(ls -i "$root/usr/bin/AdGuardHome" "$root/etc/init.d/adguardhome")
chroot "$root" /etc/init.d/adguardhome enable
: >"$root/events"
apk_transaction add --force-reinstall "$temporary/core-3.apk"
[[ $(<"$root/events") == "$expected" ]] || {
	cat "$root/events" >&2; cat "$temporary/apk.log" >&2;
	die 'same-version reinstall did not detect and reconcile core replacement';
}
[[ $(LC_ALL=C ls -ln "$root/usr/bin/AdGuardHome" "$root/etc/init.d/adguardhome") == "$before_metadata" ]] ||
	die 'same-version reinstall unexpectedly changed non-inode metadata'
[[ $(ls -i "$root/usr/bin/AdGuardHome" "$root/etc/init.d/adguardhome") != "$before_inode" ]] ||
	die 'same-version reinstall did not replace a core inode'
[[ -f $root/core-running ]] || die 'same-version reinstall left enabled core stopped'
[[ ! -e $root/etc/rc.d/S99adguardhome && ! -L $root/etc/rc.d/S99adguardhome ]] || die 'same-version reinstall left official autostart enabled'
printf 'ok - native same-version reinstall detected by inode and reconciled\n'

# An unrelated package transaction must repair accidental official autostart
# without disturbing an already-correct enabled/stopped runtime state.
for enabled in 0 1; do
	payload=$temporary/unrelated-$enabled
	mkdir -p "$payload/usr/share"
	printf '%s\n' "$enabled" >"$payload/usr/share/apk-hook-unrelated-version"
	"$apk" mkpkg --info name:unrelated-hook-test --info "version:$((enabled + 1)).0-r0" \
		--info arch:noarch --files "$payload" --output "$temporary/unrelated-$enabled.apk" \
		>"$temporary/unrelated.log" 2>&1 || {
		cat "$temporary/unrelated.log" >&2; die 'could not build unrelated package';
	}
	printf '%s\n' "$enabled" >"$root/etc/config/adguardhome"
	if [[ $enabled == 0 ]]; then rm -f "$root/core-running"; else : >"$root/core-running"; fi
	chroot "$root" /etc/init.d/adguardhome enable
	[[ -L $root/etc/rc.d/S99adguardhome ]] || die 'fixture did not enable official autostart'
	: >"$root/events"
	apk_transaction add "$temporary/unrelated-$enabled.apk"
	expected=$(printf 'hook:pre-commit:enabled=%s\nhook:post-commit:enabled=%s\ndecision:apk_reconcile_locked:changed=0\ncore:disable:v3' "$enabled" "$enabled")
	[[ $(<"$root/events") == "$expected" ]] || {
		cat "$root/events" >&2; cat "$temporary/apk.log" >&2;
		die "unrelated package disturbed the core for enabled=$enabled";
	}
	[[ $(<"$root/usr/share/apk-hook-unrelated-version") == "$enabled" ]] || die 'unrelated package was not committed'
	[[ ! -e $root/etc/rc.d/S99adguardhome && ! -L $root/etc/rc.d/S99adguardhome ]] || die 'unrelated transaction left official autostart enabled'
	if [[ $enabled == 0 ]]; then
		[[ ! -e $root/core-running ]] || die 'unrelated transaction started the disabled core'
	else
		[[ -f $root/core-running ]] || die 'unrelated transaction stopped the enabled core'
	fi
	printf 'ok - native unrelated package repairs autostart without changing runtime (enabled=%s)\n' "$enabled"
done
printf 'APK_HOOK_INTEGRATION_OK (%s; isolated dummy services)\n' "$version"
