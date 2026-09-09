# This is free software, licensed under the Apache License, Version 2.0 .
#

ADGUARDHOME_SOURCE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(TOPDIR)/rules.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/run-bounded.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/private-files.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/original-snapshot.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=3.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0 BSD-3-Clause

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-digest +ucode-mod-uloop +flock +procd-ujail +adguardhome
LUCI_EXTRA_DEPENDS:=adguardhome (>=0.107.76-r1)
LUCI_DESCRIPTION:=LuCI integration for the packaged AdGuard Home service
LUCI_MAINTAINER:=terrytyc
LUCI_URL:=https://github.com/terrytyc/luci-app-adguardhome

define AdGuardHome/UciPendingGuard
pending_uci_changes="$$(uci -q changes 2>/dev/null)" || {
	echo "Unable to inspect pending UCI changes; package installation aborted." >&2
	exit 1
}
[ -z "$$pending_uci_changes" ] || {
	echo "Commit or revert pending UCI changes before installing this package." >&2
	exit 1
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

# A first installation captures the untouched official lowercase package state
# for uninstall. An overwrite stops the installed coordinator before replacing
# its files, leaving APK to preserve package conffiles.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/UciPendingGuard)

$(AdGuardHome/RunBounded)

$(AdGuardHome/PrivateFiles)

SNAPSHOT_DIR=/root/.luci-app-adguardhome
SNAPSHOT_CONFIG="$$SNAPSHOT_DIR/official-adguardhome.config"
SNAPSHOT_STATE="$$SNAPSHOT_DIR/official-adguardhome.state"
SNAPSHOT_VERSION="$$SNAPSHOT_DIR/snapshot-version"
SNAPSHOT_STAGE=""

$(AdGuardHome/OriginalSnapshot)

if [ -e /etc/init.d/AdGuardHome ] || [ -L /etc/init.d/AdGuardHome ]; then
	[ -f /etc/init.d/AdGuardHome ] && [ ! -L /etc/init.d/AdGuardHome ] &&
		[ -x /etc/init.d/AdGuardHome ] || {
		echo "The installed AdGuard Home coordinator is unsafe." >&2
		exit 1
	}
	validate_original_snapshot || {
		echo "Original official adguardhome snapshot is unavailable or unsafe." >&2
		exit 1
	}
	run_bounded 180 5 /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || {
		echo "Unable to stop the installed AdGuard Home coordinator." >&2
		exit 1
	}
	exit 0
fi
rollback_preinst() {
	local rc=$$?
	cleanup_snapshot_stage
	exit "$$rc"
}
trap rollback_preinst 0
trap 'exit 1' HUP INT TERM

ensure_original_snapshot || {
	echo "Unable to preserve the original official adguardhome state." >&2
	exit 1
}
trap - 0 HUP INT TERM
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

if [ -e /etc/uci-defaults/40_luci-AdGuardHome ] ||
   [ -L /etc/uci-defaults/40_luci-AdGuardHome ]; then
	echo "AdGuard Home initialization failed; package installation aborted." >&2
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
snapshot_dir=/root/.luci-app-adguardhome
snapshot_config="$$snapshot_dir/official-adguardhome.config"
snapshot_state="$$snapshot_dir/official-adguardhome.state"
snapshot_version="$$snapshot_dir/snapshot-version"
runtime_dir=/var/run/luci-app-adguardhome
remove_state="$$runtime_dir/remove-ok"

root_private_directory "$$snapshot_dir" &&
	bounded_private_file "$$snapshot_config" &&
	root_private_file "$$snapshot_state" &&
	root_private_file "$$snapshot_version" &&
	grep -qx '1' "$$snapshot_version" &&
	grep -Eq '^was_running=[01]$$' "$$snapshot_state" || {
	echo "Original official adguardhome snapshot is unavailable or unsafe." >&2
	exit 1
}
changes="$$(uci -q changes adguardhome 2>/dev/null)" || exit 1
[ -z "$$changes" ] || {
	echo "Commit or revert pending adguardhome changes before uninstalling." >&2
	exit 1
}

if [ -x /etc/init.d/AdGuardHome ]; then
	run_bounded 30 2 /etc/init.d/AdGuardHome do_redirect 0 \
		>/dev/null 2>&1 || exit 1
	if uci -q get adguardhome.luci.managed_dnsmasq_upstream >/dev/null 2>&1; then
		echo "The managed dnsmasq upstream is still active." >&2
		exit 1
	fi
	if [ "$$(uci -q get firewall.adguardhome_redirect.name)" = \
		'AdGuard Home (luci-app-adguardhome)' ]; then
		echo "The managed firewall redirect is still active." >&2
		exit 1
	fi
	run_bounded 180 5 /etc/init.d/AdGuardHome memory_cleanup \
		>/dev/null 2>&1 || exit 1
fi
if [ -x /etc/init.d/adguardhome ]; then
	run_bounded 20 2 /etc/init.d/adguardhome stop >/dev/null 2>&1 || exit 1
fi

uci -q revert adguardhome >/dev/null 2>&1 || true
restore="$$(mktemp /etc/config/.adguardhome.restore.XXXXXX)" || exit 1
trap 'rm -f "$$restore"' 0 HUP INT TERM
run_bounded 5 1 /bin/dd if="$$snapshot_config" of="$$restore" \
	bs=4096 count=129 2>/dev/null || exit 1
chown 0:0 "$$restore" && chmod 0600 "$$restore" || exit 1
mv -f "$$restore" /etc/config/adguardhome || exit 1
restore=""
cmp -s "$$snapshot_config" /etc/config/adguardhome || exit 1

was_running="$$(sed -n 's/^was_running=//p' "$$snapshot_state")"
case "$$was_running" in
	1)
		run_bounded 20 2 /etc/init.d/adguardhome start \
			>/dev/null 2>&1 || exit 1
		run_bounded 5 1 /etc/init.d/adguardhome running \
			>/dev/null 2>&1 || exit 1
		;;
	0)
		if /etc/init.d/adguardhome running >/dev/null 2>&1; then
			exit 1
		fi
		;;
	*) exit 1 ;;
esac

if [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; then
	root_private_directory "$$runtime_dir" || exit 1
else
	mkdir -m 0700 "$$runtime_dir" || exit 1
	chown 0:0 "$$runtime_dir" && chmod 0700 "$$runtime_dir" || exit 1
fi
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

snapshot_dir=/root/.luci-app-adguardhome
runtime_dir=/var/run/luci-app-adguardhome
remove_state="$$runtime_dir/remove-ok"
root_private_directory "$$runtime_dir" && root_private_file "$$remove_state" &&
	grep -qx '1' "$$remove_state" || {
	echo "The verified AdGuard Home removal state is missing." >&2
	exit 1
}
root_private_directory "$$snapshot_dir" || exit 1
for snapshot_file in \
	official-adguardhome.config official-adguardhome.state \
	snapshot-version; do
	root_private_file "$$snapshot_dir/$$snapshot_file" || exit 1
	rm -f "$$snapshot_dir/$$snapshot_file" || exit 1
done
managed_snapshot="$$snapshot_dir/managed-adguardhome.config"
if [ -e "$$managed_snapshot" ] || [ -L "$$managed_snapshot" ]; then
	root_private_file "$$managed_snapshot" || exit 1
	rm -f "$$managed_snapshot" || exit 1
fi
rmdir "$$snapshot_dir" 2>/dev/null || true
rm -f "$$remove_state" || exit 1
rmdir "$$runtime_dir" 2>/dev/null || true

rm -f /tmp/luci-indexcache.*
if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-modulecache
elif [ -d /tmp/luci-modulecache ]; then
	rm -rf /tmp/luci-modulecache/
fi
[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1
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
