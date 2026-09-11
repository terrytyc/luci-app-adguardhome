# This is free software, licensed under the Apache License, Version 2.0 .
#

ADGUARDHOME_SOURCE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(TOPDIR)/rules.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/run-bounded.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/private-files.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=3.2.0
PKG_RELEASE:=2
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

# Stop an installed coordinator before replacing its files. APK preserves
# conffiles; first-install rollback is local to the initialization script.
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

$(AdGuardHome/UciPendingGuard)

$(AdGuardHome/RunBounded)

if [ -e /etc/init.d/AdGuardHome ] || [ -L /etc/init.d/AdGuardHome ]; then
	[ -f /etc/init.d/AdGuardHome ] && [ ! -L /etc/init.d/AdGuardHome ] &&
		[ -x /etc/init.d/AdGuardHome ] || {
		echo "The installed AdGuard Home coordinator is unsafe." >&2
		exit 1
	}
	run_bounded 180 5 /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || {
		echo "Unable to stop the installed AdGuard Home coordinator." >&2
		exit 1
	}
fi
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

rm -f /tmp/luci-indexcache.* || exit 1
if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-modulecache || exit 1
elif [ -d /tmp/luci-modulecache ]; then
	rm -rf /tmp/luci-modulecache/ || exit 1
fi
# Load the updated RPC module without restarting the shared daemon.
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || exit 1
finish_yaml_maintenance || exit 1
exit 0
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
for applied_state in "$$runtime_dir/applied-runtime" "$$runtime_dir"/.applied-runtime.??????; do
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

# call BuildPackage - OpenWrt buildroot signature
