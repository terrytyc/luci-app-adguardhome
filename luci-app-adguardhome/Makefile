# This is free software, licensed under the Apache License, Version 2.0 .
#

ADGUARDHOME_SOURCE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(TOPDIR)/rules.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/run-bounded.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/private-files.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=3.3.0
PKG_RELEASE:=3
PKG_LICENSE:=Apache-2.0 BSD-3-Clause

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-digest +ucode-mod-uloop +flock +procd-ujail +dnsmasq +firewall4 +adguardhome
LUCI_EXTRA_DEPENDS:=adguardhome (>=0.107.76-r1)
LUCI_DESCRIPTION:=LuCI integration for the packaged AdGuard Home service
LUCI_MAINTAINER:=terrytyc
LUCI_URL:=https://github.com/terrytyc/luci-app-adguardhome

define AdGuardHome/UciPendingGuard
# This reports first-install preflight failure; only an already-installed
# pre-commit hook can abort APK before extraction and default_postinst.
pending_uci_changes="$$(uci -q changes 2>/dev/null)" || {
	echo "Unable to inspect pending UCI changes; APK may still install files." >&2
	exit 1
}
[ -z "$$pending_uci_changes" ] || {
	echo "Commit or revert pending UCI changes before installing this package." >&2
	echo "APK may still install files after this package script fails." >&2
	exit 1
}
endef

define AdGuardHome/YamlMaintenance
yaml_job_runtime=/var/run/luci-app-adguardhome-yaml
yaml_job_lock="$${yaml_job_runtime}/update.lock"
yaml_maintenance_marker="$${yaml_job_runtime}/removing"
yaml_maintenance_created=0

root_private_empty_file() {
	root_private_file "$$1" || return 1
	[ "$$(wc -c <"$$1" 2>/dev/null)" = 0 ]
}

begin_yaml_maintenance() {
	if [ -e "$$yaml_job_runtime" ] || [ -L "$$yaml_job_runtime" ]; then
		root_private_directory "$$yaml_job_runtime" || return 1
	else
		mkdir -m 0700 "$$yaml_job_runtime" || return 1
		chown 0:0 "$$yaml_job_runtime" && chmod 0700 "$$yaml_job_runtime" || return 1
	fi
	if [ -e "$$yaml_job_lock" ] || [ -L "$$yaml_job_lock" ]; then
		root_private_empty_file "$$yaml_job_lock" || return 1
	else
		(umask 077; set -C; : >"$$yaml_job_lock") 2>/dev/null || return 1
		chown 0:0 "$$yaml_job_lock" && chmod 0600 "$$yaml_job_lock" || return 1
	fi
	[ ! -e /proc/self/fd/191 ] || return 1
	exec 191>>"$$yaml_job_lock" || return 1
	[ /proc/self/fd/191 -ef "$$yaml_job_lock" ] || return 1
	/usr/bin/flock -x -w 300 191 || return 1
	[ /proc/self/fd/191 -ef "$$yaml_job_lock" ] &&
		root_private_empty_file "$$yaml_job_lock" || return 1
	if [ -e "$$yaml_maintenance_marker" ] || [ -L "$$yaml_maintenance_marker" ]; then
		root_private_empty_file "$$yaml_maintenance_marker" || return 1
	else
		(umask 077; set -C; : >"$$yaml_maintenance_marker") 2>/dev/null || return 1
		yaml_maintenance_created=1
		chown 0:0 "$$yaml_maintenance_marker" &&
			chmod 0600 "$$yaml_maintenance_marker" || return 1
		root_private_empty_file "$$yaml_maintenance_marker" || return 1
	fi
}

rollback_yaml_maintenance() {
	[ "$$yaml_maintenance_created" = 1 ] || return 0
	[ -e /proc/self/fd/191 ] && [ /proc/self/fd/191 -ef "$$yaml_job_lock" ] &&
		root_private_empty_file "$$yaml_maintenance_marker" || return 0
	rm -f "$$yaml_maintenance_marker" 2>/dev/null || true
}

finish_yaml_maintenance() {
	[ -e /proc/self/fd/191 ] && [ /proc/self/fd/191 -ef "$$yaml_job_lock" ] &&
		root_private_directory "$$yaml_job_runtime" &&
		root_private_empty_file "$$yaml_job_lock" &&
		root_private_empty_file "$$yaml_maintenance_marker" || return 1
	rm -f "$$yaml_maintenance_marker" || return 1
	[ ! -e "$$yaml_maintenance_marker" ] && [ ! -L "$$yaml_maintenance_marker" ]
}
endef

define Build/Prepare/luci-app-adguardhome
	printf '%s\n' '$(PKG_VERSION)-r$(PKG_RELEASE)' >$(PKG_BUILD_DIR)/root/usr/share/luci-app-adguardhome/version
	mkdir -p $(PKG_BUILD_DIR)/root/etc/AdGuardHome
	cp -p $(PKG_BUILD_DIR)/root/usr/share/luci-app-adguardhome/default.yaml \
		$(PKG_BUILD_DIR)/root/etc/AdGuardHome/AdGuardHome.yaml
	for file in etc/init.d/AdGuardHome etc/uci-defaults/40_luci-AdGuardHome; do \
		awk -v helper_dir="$(ADGUARDHOME_SOURCE_DIR)scripts" \
			-f $(ADGUARDHOME_SOURCE_DIR)scripts/expand-helpers.awk \
			$(PKG_BUILD_DIR)/root/$$$$file >$(PKG_BUILD_DIR)/root/$$$$file.expanded && \
			touch -r $(PKG_BUILD_DIR)/root/$$$$file $(PKG_BUILD_DIR)/root/$$$$file.expanded && \
			mv $(PKG_BUILD_DIR)/root/$$$$file.expanded $(PKG_BUILD_DIR)/root/$$$$file || exit 1; \
	done
	find $(PKG_BUILD_DIR)/root $(PKG_BUILD_DIR)/htdocs -type d -exec chmod 0755 {} +
	find $(PKG_BUILD_DIR)/root $(PKG_BUILD_DIR)/htdocs -type f -exec chmod 0644 {} +
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/AdGuardHome
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/uci-defaults/40_luci-AdGuardHome
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/hotplug.d/acme/95-AdGuardHome
	chmod 0755 $(PKG_BUILD_DIR)/root/lib/apk/commit_hooks.d/90-luci-app-adguardhome
	chmod 0700 $(PKG_BUILD_DIR)/root/etc/AdGuardHome
	chmod 0600 $(PKG_BUILD_DIR)/root/etc/AdGuardHome/AdGuardHome.yaml
	chmod 0644 $(PKG_BUILD_DIR)/root/usr/share/luci-app-adguardhome/default.yaml
	cmp -s $(PKG_BUILD_DIR)/root/etc/AdGuardHome/AdGuardHome.yaml \
		$(PKG_BUILD_DIR)/root/usr/share/luci-app-adguardhome/default.yaml
endef

define Package/$(PKG_NAME)/conffiles
/etc/AdGuardHome/AdGuardHome.yaml
/root/.luci-app-adguardhome/
endef

# Stop old services and cores before replacing plugin code; retain user data.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/PrivateFiles)

$(AdGuardHome/YamlMaintenance)

trap 'rollback_yaml_maintenance' 0
trap 'exit 1' HUP INT TERM
begin_yaml_maintenance || {
	echo "Unable to quiesce LuCI YAML updates; APK may still install files." >&2
	exit 1
}

# APK continues after a failed preinst. Keep initialization blocked until
# cleanup succeeds, including when an old coordinator cannot write back RAM.
install_marker="$$yaml_job_runtime/install-incomplete"
if [ -e "$$install_marker" ] || [ -L "$$install_marker" ]; then
	root_private_empty_file "$$install_marker" || exit 1
else
	(umask 077; set -C; : >"$$install_marker") || exit 1
fi
trap - 0

$(AdGuardHome/UciPendingGuard)

$(AdGuardHome/RunBounded)

adguardhome_inventory() {
	/usr/bin/ucode -e '
		import * as fs from "fs";
		function normalized(name) { return replace(lc(name), /[-_]/g, ""); }
		function basename(path) { return replace(path, /^.*\//, ""); }
		function core(name) { return normalized(name) == "adguardhome"; }
		function known(name) { return core(name) || normalized(name) == "luciappadguardhome"; }
		let pids = {}, ancestors = {}, services = {};
		for (let pid in fs.lsdir("/proc")) {
			if (!match(pid, /^[0-9]+$$/) || +pid <= 1) continue;
			let exe = fs.readlink(`/proc/$${pid}/exe`);
			if (!exe) continue;
			exe = basename(replace(exe, / \(deleted\)$$/, ""));
			let comm = trim(fs.readfile(`/proc/$${pid}/comm`) || "");
			if (core(exe) || (core(comm) && !match(exe, /^(busybox|sh|ash|bash|dash|ucode|lua|python3?|node)$$/)))
				pids[pid] = true;
		}
		if (ARGV[0] == "pids") { print(join(" ", keys(pids))); exit(0); }
		for (let pid in pids) {
			for (let depth = 0; +pid > 1 && !ancestors[pid] && depth < 64; depth++) {
				ancestors[pid] = true;
				let parent = match(fs.readfile(`/proc/$${pid}/status`) || "", /\nPPid:\s+([0-9]+)/);
				pid = parent ? parent[1] : "0";
			}
		}
		for (let name in fs.lsdir("/etc/init.d") || [])
			if (known(name)) services[name] = true;
		let registered = json(fs.stdin.read("all"));
		if (type(registered) != "object") exit(1);
		for (let name, service in registered) {
			if (known(name)) { services[name] = true; continue; }
			let matched = 0, instances = service.instances || {};
			for (let id, instance in instances)
				if (core(basename(instance.command?.[0] || "")) || ancestors["" + instance.pid]) matched++;
			if (!matched) continue;
			if (matched != length(instances)) {
				warn(`AdGuard Home shares service $${name} with unrelated instances; separate it before installing.\n`);
				exit(1);
			}
			services[name] = true;
		}
		for (let name in services) {
			if (!match(name, /^[A-Za-z0-9_.-]+$$/)) {
				warn(`Unsupported AdGuard Home service name: $${name}\n`);
				exit(1);
			}
		}
		print(join(" ", keys(services)));
	' "$$1"
}

stop_adguardhome_processes() {
	local signal pids remaining
	for signal in TERM KILL; do
		pids="$$(adguardhome_inventory pids)" || return 1
		[ -n "$$pids" ] || return 0
		kill "-$$signal" $$pids 2>/dev/null || true
		remaining=10
		[ "$$signal" != KILL ] || remaining=2
		while [ "$$remaining" -gt 0 ]; do
			sleep 1
			pids="$$(adguardhome_inventory pids)" || return 1
			[ -n "$$pids" ] || return 0
			remaining=$$((remaining - 1))
		done
	done
	echo "AdGuard Home processes are still running; installation cleanup is incomplete." >&2
	return 1
}

program_files="/etc/init.d/AdGuardHome /etc/uci-defaults/40_luci-AdGuardHome /etc/hotplug.d/acme/95-AdGuardHome"
for file in $$program_files; do
	for target in "$$file" "$$file.apk-new"; do
		owner="$$(apk info --who-owns --quiet "$$target" 2>/dev/null)"
		case "$$owner" in
			''|luci-app-adguardhome|luci-app-AdGuardHome) ;;
			*) echo "$$target is owned by $$owner; resolve the package conflict before installing." >&2; exit 1 ;;
		esac
	done
done
# Discover supervision before stopping a core and losing its parent chain.
services="$$(ubus -t 5 -S call service list | adguardhome_inventory services)" || {
	echo "Unable to identify old AdGuard Home services; installation cleanup is incomplete." >&2
	exit 1
}
coordinator_retry=0
if [ -e /etc/init.d/AdGuardHome ] || [ -L /etc/init.d/AdGuardHome ]; then
	if [ -f /etc/init.d/AdGuardHome ] && [ ! -L /etc/init.d/AdGuardHome ] &&
	   [ -x /etc/init.d/AdGuardHome ]; then
		run_bounded 180 5 /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || {
			grep -q '^stop_wrapper_locked()' /etc/init.d/AdGuardHome && coordinator_retry=1
			echo "Old AdGuard Home stop failed; clearing remaining core processes." >&2
		}
	fi
fi

for service in $$services; do
	service_script="/etc/init.d/$$service"
	if [ -f "$$service_script" ] && [ ! -L "$$service_script" ] && [ -x "$$service_script" ]; then
		[ "$$service" = AdGuardHome ] ||
			run_bounded 180 5 "$$service_script" stop >/dev/null 2>&1 || true
		run_bounded 5 1 "$$service_script" disable >/dev/null 2>&1 || true
	fi
	# Disabling boot links alone does not cancel a live procd respawn.
	ubus -t 5 call service delete "{\"name\":\"$$service\"}" >/dev/null 2>&1 || true
	service_target="$$(readlink -f "$$service_script")"
	[ -n "$$service_target" ] || continue
	for link in /etc/rc.d/[SK][0-9][0-9]*; do
		[ -L "$$link" ] || continue
		[ "$$(readlink -f "$$link")" != "$$service_target" ] || rm -f "$$link" || exit 1
	done
done
stop_adguardhome_processes || exit 1
# procd deletes a service after its last instance exits. A monitor sleeping
# inside ash may need procd's termination timeout before that happens.
remaining=10
while :; do
	cleanup_rc=0
	ubus -t 5 -S call service list | /usr/bin/ucode -e '
	import { stdin } from "fs";
	let registered;
	try { registered = json(stdin.read("all")); } catch (e) { exit(2); }
	if (type(registered) != "object") exit(2);
	for (let name in ARGV) if (registered[name]) exit(1);
	' $$services || cleanup_rc=$$?
	[ "$$cleanup_rc" != 0 ] || break
	[ "$$cleanup_rc" = 1 ] || {
		echo "Unable to inspect old AdGuard Home services; installation cleanup is incomplete." >&2
		exit 1
	}
	[ "$$remaining" -gt 0 ] || {
		echo "Old AdGuard Home services are still registered; installation cleanup is incomplete: $$services" >&2
		exit 1
	}
	sleep 1
	remaining=$$((remaining - 1))
done

# A leftover core under the same uid can make the first stop fail. Retry the
# coordinator now, and never discard a failed RAM write-back or DNS restore.
if [ "$$coordinator_retry" = 1 ]; then
	run_bounded 180 5 /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || {
		echo "Unable to finish coordinator cleanup; recovery data was kept." >&2
		exit 1
	}
fi
if [ -e /tmp/luci-app-adguardhome-memory/state ] ||
   [ -L /tmp/luci-app-adguardhome-memory/state ]; then
	echo "AdGuard Home RAM write-back is incomplete; memory data was kept." >&2
	exit 1
fi

# These are executable plugin files, not user configuration. Removing only
# these targets prevents APK from retaining modified old code as .apk-new.
for file in $$program_files; do
	rm -f "$$file" "$$file.apk-new" || exit 1
done
rm -f "$$install_marker" || exit 1
trap - 0 HUP INT TERM
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/PrivateFiles)

$(AdGuardHome/YamlMaintenance)

begin_yaml_maintenance || {
	echo "Unable to preserve the LuCI YAML maintenance gate." >&2
	exit 1
}

if [ -e /etc/uci-defaults/40_luci-AdGuardHome ] ||
   [ -L /etc/uci-defaults/40_luci-AdGuardHome ]; then
	echo "AdGuard Home initialization failed; installed files were kept for repair." >&2
	exit 1
fi

# default_postinst enables init scripts only on first install. Recreate the
# new coordinator's boot links after clearing the previous service on upgrade.
/etc/init.d/AdGuardHome enable >/dev/null 2>&1 || exit 1

rm -f /tmp/luci-indexcache.* || exit 1
if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-modulecache || exit 1
elif [ -d /tmp/luci-modulecache ]; then
	rm -rf /tmp/luci-modulecache/ || exit 1
fi
# Load the updated RPC module without restarting the shared daemon.
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || exit 1
install_rc=0
/etc/init.d/AdGuardHome install_check >/dev/null || {
	echo "AdGuard Home files were installed, but service verification failed; check the plugin and core logs." >&2
	install_rc=1
}
finish_yaml_maintenance || exit 1
exit "$$install_rc"
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0
case "$$PKG_UPGRADE:$$1" in
	1:*|*:upgrade) exit 0 ;;
esac

$(AdGuardHome/RunBounded)

$(AdGuardHome/PrivateFiles)

runtime_dir=/var/run/luci-app-adguardhome
remove_state="$$runtime_dir/remove-ok"
if [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; then
	root_private_directory "$$runtime_dir" || exit 1
else
	mkdir -m 0700 "$$runtime_dir" || exit 1
	chown 0:0 "$$runtime_dir" && chmod 0700 "$$runtime_dir" || exit 1
fi
# A previous failed post-deinstall may have left a success marker. Invalidate
# it before this removal can fail, including maintenance or service preflight.
if [ -e "$$remove_state" ] || [ -L "$$remove_state" ]; then
	root_private_file "$$remove_state" && rm -f "$$remove_state" || exit 1
fi

$(AdGuardHome/YamlMaintenance)

# APK continues removal even if pre-deinstall fails. Never restart a service
# whose coordinator files are about to be removed; retain failed-stop state.
trap 'rollback_yaml_maintenance' 0
trap 'exit 1' HUP INT TERM
begin_yaml_maintenance || {
	echo "Unable to quiesce LuCI YAML updates; APK may still remove files." >&2
	exit 1
}

if [ -x /etc/init.d/AdGuardHome ]; then
	run_bounded 180 5 env LUCI_ADGUARDHOME_PRERM_PHASE=bounded /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || exit 1
fi
if [ -x /etc/init.d/adguardhome ]; then
	/etc/init.d/adguardhome disable >/dev/null 2>&1 || exit 1
fi

# Leave the current UCI, YAML and data in place for an explicit reinstall.
(umask 077; printf '1\n' >"$$remove_state") || exit 1
chown 0:0 "$$remove_state" && chmod 0600 "$$remove_state" || exit 1
trap - 0 HUP INT TERM
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
case "$$PKG_UPGRADE:$$1" in
	1:*|*:upgrade) exit 0 ;;
esac
rm -f "$$IPKG_INSTROOT/lib/upgrade/keep.d/luci-app-adguardhome"
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/PrivateFiles)

$(AdGuardHome/YamlMaintenance)

begin_yaml_maintenance || {
	echo "Unable to preserve the LuCI YAML maintenance gate." >&2
	exit 1
}

snapshot_dir=/root/.luci-app-adguardhome
runtime_dir=/var/run/luci-app-adguardhome
remove_state="$$runtime_dir/remove-ok"
root_private_directory "$$runtime_dir" && root_private_file "$$remove_state" &&
	grep -qx '1' "$$remove_state" || {
	echo "The verified AdGuard Home removal state is missing." >&2
	exit 1
}
managed_snapshot="$$snapshot_dir/managed-adguardhome.config"
if [ -e "$$managed_snapshot" ] || [ -L "$$managed_snapshot" ]; then
	root_private_directory "$$snapshot_dir" && root_private_file "$$managed_snapshot" || exit 1
	rm -f "$$managed_snapshot" || exit 1
fi
rmdir "$$snapshot_dir" 2>/dev/null || true
for applied_state in "$$runtime_dir/applied-runtime" "$$runtime_dir"/.applied-runtime.?????? "$$runtime_dir/apk-core-before"; do
	[ -e "$$applied_state" ] || [ -L "$$applied_state" ] || continue
	root_private_file "$$applied_state" || exit 1
	rm -f "$$applied_state" || exit 1
done
rm -f "$$remove_state" || exit 1
rmdir "$$runtime_dir" 2>/dev/null || true

rm -f /tmp/luci-indexcache.*
if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-modulecache
elif [ -d /tmp/luci-modulecache ]; then
	rm -rf /tmp/luci-modulecache/
fi
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || exit 1
finish_yaml_maintenance || exit 1
exit 0
endef

define Package/luci-i18n-adguardhome-zh-cn/preinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/UciPendingGuard)
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# APK has native file replacement metadata; this SDK exposes only its raw
# package arguments here. Do not provide the alias and run unknown removal hooks.
APK_SCRIPTS_luci-app-adguardhome += --info "replaces:luci-app-AdGuardHome"

# call BuildPackage - OpenWrt buildroot signature
