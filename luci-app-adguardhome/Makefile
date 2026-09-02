# This is free software, licensed under the Apache License, Version 2.0 .
#

ADGUARDHOME_SOURCE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
include $(TOPDIR)/rules.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/run-bounded.mk
include $(ADGUARDHOME_SOURCE_DIR)scripts/private-files.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=2.4.0
PKG_RELEASE:=6
PKG_LICENSE:=Apache-2.0 BSD-3-Clause

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-digest +ucode-mod-uloop +flock +procd-ujail +adguardhome
LUCI_EXTRA_DEPENDS:=adguardhome (>=0.107.76-r1)
LUCI_DESCRIPTION:=LuCI integration for the packaged AdGuard Home service
LUCI_MAINTAINER:=terrytyc
LUCI_URL:=https://github.com/terrytyc/luci-app-adguardhome

define Build/Prepare/luci-app-adguardhome
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

# Version 2.4 is the only in-place upgrade baseline. A clean installation
# captures the untouched official lowercase package state for uninstall.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/RunBounded)

$(AdGuardHome/PrivateFiles)

bounded_private_file() {
	local size
	root_private_file "$$1" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ]
}

official_delta_is_clean() {
	local changes
	changes="$$(uci -q changes adguardhome 2>/dev/null)" || return 1
	[ -z "$$changes" ]
}

snapshot_dir=/root/.luci-app-adguardhome
snapshot_uci="$$snapshot_dir/official-adguardhome.uci"
snapshot_config="$$snapshot_dir/official-adguardhome.config"
snapshot_state="$$snapshot_dir/official-adguardhome.state"
snapshot_version="$$snapshot_dir/snapshot-version"
managed_snapshot="$$snapshot_dir/managed-adguardhome.config"
runtime_dir=/var/run/luci-app-adguardhome
upgrade_state="$$runtime_dir/upgrade-state"
snapshot_stage=""
upgrade_committed=0
was_running=0
is_upgrade=0
source_version=""

validate_original_snapshot() {
	root_private_directory "$$snapshot_dir" &&
		bounded_private_file "$$snapshot_uci" &&
		bounded_private_file "$$snapshot_config" &&
		root_private_file "$$snapshot_state" &&
		root_private_file "$$snapshot_version" &&
		grep -qx 'package adguardhome' "$$snapshot_uci" &&
		grep -Eq '^was_running=[01]$$' "$$snapshot_state" &&
		[ "$$(wc -l <"$$snapshot_state" 2>/dev/null)" = 1 ] &&
		grep -qx '1' "$$snapshot_version"
}

cleanup_snapshot_stage() {
	[ -n "$$snapshot_stage" ] || return 0
	rm -f "$$snapshot_stage/official-adguardhome.uci" \
		"$$snapshot_stage/official-adguardhome.config" \
		"$$snapshot_stage/official-adguardhome.state" \
		"$$snapshot_stage/snapshot-version" 2>/dev/null || true
	rmdir "$$snapshot_stage" 2>/dev/null || true
	snapshot_stage=""
}

create_original_snapshot() {
	local running_rc=0
	[ ! -e "$$snapshot_dir" ] && [ ! -L "$$snapshot_dir" ] || return 1
	[ -f /etc/config/adguardhome ] && [ ! -L /etc/config/adguardhome ] || return 1
	official_delta_is_clean || return 1
	snapshot_stage="$$(mktemp -d /root/.luci-app-adguardhome.XXXXXX)" || return 1
	chown 0:0 "$$snapshot_stage" && chmod 0700 "$$snapshot_stage" || return 1
	run_bounded 5 1 /bin/dd if=/etc/config/adguardhome \
		of="$$snapshot_stage/official-adguardhome.config" bs=4096 count=129 \
		2>/dev/null || return 1
	run_bounded 5 1 uci -q export adguardhome \
		>"$$snapshot_stage/official-adguardhome.uci" || return 1
	if [ -x /etc/init.d/adguardhome ]; then
		run_bounded 5 1 /etc/init.d/adguardhome running \
			>/dev/null 2>&1 || running_rc=$$?
		case "$$running_rc" in
			0) was_running=1 ;;
			1) was_running=0 ;;
			*) return 1 ;;
		esac
	fi
	printf 'was_running=%s\n' "$$was_running" \
		>"$$snapshot_stage/official-adguardhome.state" || return 1
	printf '1\n' >"$$snapshot_stage/snapshot-version" || return 1
	chown 0:0 "$$snapshot_stage"/* && chmod 0600 "$$snapshot_stage"/* || return 1
	mv "$$snapshot_stage" "$$snapshot_dir" || return 1
	snapshot_stage=""
	validate_original_snapshot
}

installed_source_version() {
	local record count
	[ -f /lib/apk/packages/luci-app-adguardhome.list ] || return 1
	command -v apk >/dev/null 2>&1 || return 1
	record="$$(apk list --installed luci-app-adguardhome 2>/dev/null |
		sed -n 's/^luci-app-adguardhome-\([^ ][^ ]*\).*/\1/p')" || return 1
	count="$$(printf '%s\n' "$$record" | sed '/^$$/d' | wc -l)" || return 1
	[ "$$count" = 1 ] || return 1
	printf '%s\n' "$$record"
}

baseline_config_is_valid() {
	local work config enabled verbose redirect memory interval
	[ "$$(uci -q get adguardhome.config)" = adguardhome ] || return 1
	[ "$$(uci -q get adguardhome.luci)" = luci ] || return 1
	work="$$(uci -q get adguardhome.config.work_dir)" || return 1
	config="$$(uci -q get adguardhome.config.config_file)" || return 1
	[ "$$config" = "$$work/AdGuardHome.yaml" ] || return 1
	[ -f "$$config" ] && [ ! -L "$$config" ] || return 1
	enabled="$$(uci -q get adguardhome.config.enabled)" || return 1
	verbose="$$(uci -q get adguardhome.config.verbose)" || return 1
	redirect="$$(uci -q get adguardhome.luci.redirect)" || return 1
	memory="$$(uci -q get adguardhome.luci.run_from_memory)" || return 1
	interval="$$(uci -q get adguardhome.luci.memory_writeback_interval)" || return 1
	case "$$enabled:$$verbose:$$memory" in [01]:[01]:[01]) ;; *) return 1 ;; esac
	case "$$redirect" in none|dnsmasq-upstream|redirect) ;; *) return 1 ;; esac
	case "$$interval" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$interval" -le 10080 ]
}

ensure_runtime_dir() {
	if [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; then
		root_private_directory "$$runtime_dir" || return 1
		[ ! -e "$$upgrade_state" ] && [ ! -L "$$upgrade_state" ] || return 1
		return 0
	fi
	mkdir -m 0700 "$$runtime_dir" || return 1
	chown 0:0 "$$runtime_dir" && chmod 0700 "$$runtime_dir"
}

write_upgrade_state() {
	(umask 077; {
		printf 'source_version=%s\n' "$$source_version"
		printf 'was_running=%s\n' "$$was_running"
	} >"$$upgrade_state") || return 1
	chown 0:0 "$$upgrade_state" && chmod 0600 "$$upgrade_state" &&
		root_private_file "$$upgrade_state"
}

rollback_preinst() {
	local rc=$$?
	cleanup_snapshot_stage
	if [ "$$is_upgrade" = 1 ] && [ "$$upgrade_committed" != 1 ]; then
		rm -f "$$upgrade_state" 2>/dev/null || true
		rmdir "$$runtime_dir" 2>/dev/null || true
		if [ "$$was_running" = 1 ] && [ -x /etc/init.d/AdGuardHome ]; then
			/etc/init.d/AdGuardHome start >/dev/null 2>&1 || true
		fi
	fi
	exit "$$rc"
}
trap rollback_preinst 0
trap 'exit 1' HUP INT TERM

case "$$PKG_UPGRADE:$$1" in
	1:*|*:upgrade) is_upgrade=1 ;;
esac
[ -f /lib/apk/packages/luci-app-adguardhome.list ] && is_upgrade=1

if [ "$$is_upgrade" != 1 ]; then
	create_original_snapshot || {
		echo "Unable to preserve the original official adguardhome state." >&2
		exit 1
	}
	trap - 0 HUP INT TERM
	exit 0
fi

source_version="$$(installed_source_version)" || source_version=""
case "$$source_version" in
	2.4.0-r1|2.4.0-r2|2.4.0-r3|2.4.0-r4|2.4.0-r5) ;;
	*)
		echo "Only luci-app-adguardhome 2.4.0-r1, r2, r3, r4 or r5 can be upgraded in place." >&2
		exit 1
		;;
esac
validate_original_snapshot || {
	echo "The original official adguardhome snapshot is unavailable or unsafe." >&2
	exit 1
}
bounded_private_file "$$managed_snapshot" || {
	echo "The managed adguardhome recovery snapshot is unavailable or unsafe." >&2
	exit 1
}
official_delta_is_clean && baseline_config_is_valid || {
	echo "The installed 2.4 configuration is invalid or has pending changes." >&2
	exit 1
}

running_rc=0
run_bounded 5 1 /etc/init.d/adguardhome running >/dev/null 2>&1 || running_rc=$$?
case "$$running_rc" in
	0) was_running=1 ;;
	1) was_running=0 ;;
	*) echo "Unable to determine the AdGuard Home runtime state." >&2; exit 1 ;;
esac
ensure_runtime_dir && write_upgrade_state || {
	echo "Unable to create the 2.4 baseline upgrade state." >&2
	exit 1
}
run_bounded 180 5 /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || {
	echo "Unable to stop the installed AdGuard Home coordinator." >&2
	exit 1
}
run_bounded 30 2 /etc/init.d/AdGuardHome do_redirect 0 >/dev/null 2>&1 || {
	echo "Unable to remove the installed AdGuard Home DNS integration." >&2
	exit 1
}
if uci -q get adguardhome.luci.managed_dnsmasq_upstream >/dev/null 2>&1; then
	echo "The managed dnsmasq upstream is still active." >&2
	exit 1
fi
if [ "$$(uci -q get firewall.adguardhome_redirect.name)" = \
	'AdGuard Home (luci-app-adguardhome)' ]; then
	echo "The managed firewall redirect is still active." >&2
	exit 1
fi
running_rc=0
run_bounded 5 1 /etc/init.d/adguardhome running >/dev/null 2>&1 || running_rc=$$?
[ "$$running_rc" = 1 ] || {
	echo "The official AdGuard Home core did not stop for upgrade." >&2
	exit 1
}

upgrade_committed=1
trap - 0 HUP INT TERM
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -z "$$IPKG_INSTROOT" ] || exit 0

$(AdGuardHome/PrivateFiles)

if [ -e /etc/uci-defaults/40_luci-AdGuardHome ] ||
   [ -L /etc/uci-defaults/40_luci-AdGuardHome ]; then
	echo "AdGuard Home initialization failed; package installation aborted." >&2
	exit 1
fi

runtime_dir=/var/run/luci-app-adguardhome
upgrade_state="$$runtime_dir/upgrade-state"
if [ -e "$$upgrade_state" ] || [ -L "$$upgrade_state" ]; then
	root_private_directory "$$runtime_dir" && root_private_file "$$upgrade_state" ||
		exit 1
	[ "$$(wc -l <"$$upgrade_state" 2>/dev/null)" = 2 ] || exit 1
	grep -Eq '^source_version=2[.]4[.]0-r[12345]$$' "$$upgrade_state" || exit 1
	was_running="$$(sed -n 's/^was_running=//p' "$$upgrade_state")"
	case "$$was_running" in
		1)
			ADGUARDHOME_BASELINE_RESUME=1 \
				/etc/init.d/AdGuardHome start >/dev/null 2>&1 || exit 1
			/etc/init.d/adguardhome running >/dev/null 2>&1 || exit 1
			;;
		0)
			/etc/init.d/AdGuardHome stop >/dev/null 2>&1 || exit 1
			if /etc/init.d/adguardhome running >/dev/null 2>&1; then
				echo "AdGuard Home was stopped before upgrade but is running now." >&2
				exit 1
			fi
			;;
		*) exit 1 ;;
	esac
	rm -f "$$upgrade_state" || exit 1
	rmdir "$$runtime_dir" 2>/dev/null || true
fi

rm -f /tmp/luci-indexcache.* || exit 1
if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-modulecache || exit 1
elif [ -d /tmp/luci-modulecache ]; then
	rm -rf /tmp/luci-modulecache/ || exit 1
fi
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
bounded_private_file() {
	local size
	root_private_file "$$1" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ]
}

snapshot_dir=/root/.luci-app-adguardhome
snapshot_config="$$snapshot_dir/official-adguardhome.config"
snapshot_uci="$$snapshot_dir/official-adguardhome.uci"
snapshot_state="$$snapshot_dir/official-adguardhome.state"
snapshot_version="$$snapshot_dir/snapshot-version"
managed_snapshot="$$snapshot_dir/managed-adguardhome.config"
runtime_dir=/var/run/luci-app-adguardhome
remove_state="$$runtime_dir/remove-ok"

root_private_directory "$$snapshot_dir" &&
	bounded_private_file "$$snapshot_config" &&
	bounded_private_file "$$snapshot_uci" &&
	root_private_file "$$snapshot_state" &&
	root_private_file "$$snapshot_version" &&
	bounded_private_file "$$managed_snapshot" &&
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
	official-adguardhome.uci official-adguardhome.config \
	official-adguardhome.state snapshot-version managed-adguardhome.config; do
	root_private_file "$$snapshot_dir/$$snapshot_file" || exit 1
	rm -f "$$snapshot_dir/$$snapshot_file" || exit 1
done
rmdir "$$snapshot_dir" || exit 1
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

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
