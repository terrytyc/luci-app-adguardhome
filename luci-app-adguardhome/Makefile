# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +adguardhome
LUCI_EXTRA_DEPENDS:=adguardhome (>=0.107.76-r1)
LUCI_DESCRIPTION:=LuCI integration for the packaged AdGuard Home service
LUCI_MAINTAINER:=terrytyc
LUCI_URL:=https://github.com/terrytyc/luci-app-adguardhome

# Git and Windows checkouts cannot represent every Unix mode.  Normalize the
# complete payload before packaging so APK/IPK output is independent of the
# builder's umask, then tighten the credential-bearing defaults.
define Build/Prepare/luci-app-adguardhome
	find $(PKG_BUILD_DIR)/root $(PKG_BUILD_DIR)/htdocs -type d -exec chmod 0755 {} +
	find $(PKG_BUILD_DIR)/root $(PKG_BUILD_DIR)/htdocs -type f -exec chmod 0644 {} +
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/AdGuardHome
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/uci-defaults/40_luci-AdGuardHome
	chmod 0700 $(PKG_BUILD_DIR)/root/etc/AdGuardHome
	chmod 0600 $(PKG_BUILD_DIR)/root/etc/AdGuardHome/AdGuardHome.yaml
endef

# Keep the legacy location in sysupgrade backups during migration.
define Package/$(PKG_NAME)/conffiles
/etc/config/AdGuardHome
/etc/AdGuardHome/AdGuardHome.yaml
/etc/AdGuardHome.yaml
endef

# APK maps this hook to pre-upgrade with PKG_UPGRADE=1.  opkg passes
# "upgrade" as the first argument.  Stop the legacy mixed-case supervisor
# before its init script is replaced so that the packaged lowercase service is
# the only remaining owner of the core process.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
is_upgrade=0
case "$${PKG_UPGRADE}:$$1" in
	1:*|*:upgrade) is_upgrade=1 ;;
esac
[ -f /usr/lib/opkg/info/luci-app-adguardhome.list ] && is_upgrade=1
[ -f /lib/apk/packages/luci-app-adguardhome.list ] && is_upgrade=1
[ "$$is_upgrade" = 1 ] || exit 0
touch /tmp/luci-app-adguardhome.upgrade || {
	echo "Unable to mark the AdGuard Home package upgrade." >&2
	exit 1
}
trap 'rm -f /tmp/luci-app-adguardhome.upgrade' 0

ensure_dnsmasq_generic_upstream() {
	local rollback_port="$$1" servers server has_generic=0 resolvfile

	servers="$$(uci -q get 'dhcp.@dnsmasq[0].server')"
	for server in $$servers; do
		case "$$server" in
			/#/*) has_generic=1; break ;;
			/*) ;;
			*) has_generic=1; break ;;
		esac
	done
	[ "$$has_generic" = 0 ] || return 0

	resolvfile="$$(uci -q get 'dhcp.@dnsmasq[0].resolvfile')"
	if [ -z "$$resolvfile" ] || [ ! -f "$$resolvfile" ]; then
		resolvfile=/tmp/resolv.conf.d/resolv.conf.auto
		[ -f "$$resolvfile" ] || resolvfile=/tmp/resolv.conf.auto
	fi
	if [ ! -f "$$resolvfile" ]; then
		# DNS cleanup runs before the old supervisor is stopped.  If no usable
		# system resolver exists, put its upstream back before aborting so a
		# failed upgrade cannot leave dnsmasq in a resolver black hole.
		uci -q add_list "dhcp.@dnsmasq[0].server=127.0.0.1#$${rollback_port}" || return 1
		uci -q set 'dhcp.@dnsmasq[0].noresolv=1' || return 1
		uci -q set 'AdGuardHome.AdGuardHome.old_redirect=dnsmasq-upstream' || return 1
		uci -q set "AdGuardHome.AdGuardHome.old_port=$${rollback_port}" || return 1
		uci -q set 'AdGuardHome.AdGuardHome.old_enabled=1' || return 1
		uci -q commit AdGuardHome || return 1
		uci -q commit dhcp || return 1
		printf '1' >/var/run/AdGredir || return 1
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || {
			echo "Unable to restore dnsmasq after legacy cleanup failed." >&2
			return 1
		}
		echo "dnsmasq has no generic upstream or usable resolvfile; restored the previous AdGuard Home upstream and aborted the upgrade." >&2
		return 1
	fi
	uci -q set "dhcp.@dnsmasq[0].resolvfile=$$resolvfile" || return 1
	if uci -q get 'dhcp.@dnsmasq[0].noresolv' >/dev/null 2>&1; then
		uci -q delete 'dhcp.@dnsmasq[0].noresolv' || return 1
	fi
}

if [ -x /etc/init.d/AdGuardHome ]; then
	old_redirect="$$(uci -q get AdGuardHome.AdGuardHome.old_redirect)"
	old_port="$$(uci -q get AdGuardHome.AdGuardHome.old_port)"
	old_enabled="$$(uci -q get AdGuardHome.AdGuardHome.old_enabled)"
	redirect_rc=0
	/etc/init.d/AdGuardHome do_redirect 0 >/dev/null 2>&1 || redirect_rc=$$?
	if grep -q 'clear_recorded_integration_locked' /etc/init.d/AdGuardHome; then
		[ "$$redirect_rc" = 0 ] || {
			echo "Unable to remove the existing AdGuard Home DNS integration; upgrade aborted." >&2
			exit 1
		}
	else
		case "$$redirect_rc" in
			0|1) ;;
			*)
				echo "Legacy AdGuard Home DNS cleanup failed with status $$redirect_rc; upgrade aborted." >&2
				exit 1
				;;
		esac
		case "$$old_enabled" in
		1)
		case "$$old_redirect" in
			redirect)
				uci -q commit firewall || exit 1
				if uci -q get firewall.adguardhome_redirect >/dev/null 2>&1; then
					echo "Legacy AdGuard Home firewall redirection is still configured; upgrade aborted." >&2
					exit 1
				fi
				/etc/init.d/firewall reload >/dev/null 2>&1 || {
					echo "Unable to reload firewall after legacy AdGuard Home cleanup; upgrade aborted." >&2
					exit 1
				}
				;;
			dnsmasq-upstream)
				case "$$old_port" in
					""|0|*[!0-9]*)
						echo "Unable to verify the previous AdGuard Home DNS port; upgrade aborted." >&2
						exit 1
						;;
				esac
				uci -q commit dhcp || exit 1
				servers="$$(uci -q get 'dhcp.@dnsmasq[0].server')"
				case " $$servers " in
					*" 127.0.0.1#$${old_port} "*)
						echo "Legacy AdGuard Home remains configured as a dnsmasq upstream; upgrade aborted." >&2
						exit 1
						;;
				esac
				ensure_dnsmasq_generic_upstream "$$old_port" || exit 1
				uci -q commit dhcp || exit 1
				/etc/init.d/dnsmasq restart >/dev/null 2>&1 || {
					echo "Unable to restart dnsmasq after legacy AdGuard Home cleanup; upgrade aborted." >&2
					exit 1
				}
				;;
			exchange)
				uci -q commit dhcp || exit 1
				[ "$$(uci -q get 'dhcp.@dnsmasq[0].port')" = 53 ] || {
					echo "dnsmasq port 53 was not restored after legacy AdGuard Home cleanup; upgrade aborted." >&2
					exit 1
				}
				/etc/init.d/dnsmasq restart >/dev/null 2>&1 || {
					echo "Unable to restart dnsmasq after legacy AdGuard Home cleanup; upgrade aborted." >&2
					exit 1
				}
				;;
			""|none) ;;
			*)
				echo "Unknown legacy AdGuard Home DNS integration '$$old_redirect'; upgrade aborted." >&2
				exit 1
				;;
		esac
			;;
		""|0) ;;
		*)
			echo "Unknown legacy AdGuard Home DNS ownership state '$$old_enabled'; upgrade aborted." >&2
			exit 1
			;;
		esac
	fi
	/etc/init.d/AdGuardHome stop >/dev/null 2>&1 || {
		echo "Unable to stop the existing AdGuard Home service; upgrade aborted." >&2
		exit 1
	}
else
	old_redirect="$$(uci -q get AdGuardHome.AdGuardHome.old_redirect)"
	old_port="$$(uci -q get AdGuardHome.AdGuardHome.old_port)"
	old_enabled="$$(uci -q get AdGuardHome.AdGuardHome.old_enabled)"
	case "$$old_enabled" in
		0) old_redirect=none ;;
		1|"") ;;
		*)
			echo "Unknown previous AdGuard Home DNS ownership state '$$old_enabled'; upgrade aborted." >&2
			exit 1
			;;
	esac
	[ -n "$$old_redirect" ] || old_redirect="$$(uci -q get AdGuardHome.AdGuardHome.redirect)"
	case "$$old_port" in
		""|0|*[!0-9]*) old_port="$$(uci -q get AdGuardHome.AdGuardHome.dnsport)" ;;
	esac
	case "$$old_redirect" in
		redirect)
			if uci -q get firewall.adguardhome_redirect >/dev/null 2>&1; then
				uci -q delete firewall.adguardhome_redirect || exit 1
				uci -q commit firewall || exit 1
				/etc/init.d/firewall reload || exit 1
			fi
			;;
		dnsmasq-upstream)
			case "$$old_port" in
				""|0|*[!0-9]*)
					echo "Unable to determine the previous AdGuard Home DNS port; upgrade aborted." >&2
					exit 1
					;;
			esac
			servers="$$(uci -q get 'dhcp.@dnsmasq[0].server')"
			case " $$servers " in
				*" 127.0.0.1#$${old_port} "*)
					uci -q del_list "dhcp.@dnsmasq[0].server=127.0.0.1#$${old_port}" || exit 1
					ensure_dnsmasq_generic_upstream "$$old_port" || exit 1
					uci -q commit dhcp || exit 1
					/etc/init.d/dnsmasq restart || exit 1
					;;
			esac
			;;
		exchange)
			uci -q set dhcp.@dnsmasq[0].port='53' || exit 1
			uci -q commit dhcp || exit 1
			/etc/init.d/dnsmasq restart || exit 1
			;;
		""|none) ;;
		*)
			echo "Unknown previous AdGuard Home DNS integration '$$old_redirect'; upgrade aborted." >&2
			exit 1
			;;
	esac
fi

[ ! -x /etc/init.d/adguardhome ] || /etc/init.d/adguardhome stop >/dev/null 2>&1 || {
	echo "Unable to stop the packaged AdGuard Home service; upgrade aborted." >&2
	exit 1
}
if pidof AdGuardHome >/dev/null 2>&1; then
	killall -TERM AdGuardHome >/dev/null 2>&1 || true
	for attempt in 1 2 3 4 5; do
		pidof AdGuardHome >/dev/null 2>&1 || break
		sleep 1
	done
	if pidof AdGuardHome >/dev/null 2>&1; then
		killall -KILL AdGuardHome >/dev/null 2>&1 || true
		sleep 1
	fi
	if pidof AdGuardHome >/dev/null 2>&1; then
		echo "An AdGuard Home process could not be stopped; upgrade aborted." >&2
		exit 1
	fi
fi

trap - 0
exit 0
endef

# default_prerm intentionally ignores init-script failures.  Retry and verify
# DNS cleanup directly so package removal cannot leave a resolver takeover or
# a running lower service after this coordinator has disappeared.
define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
case "$${PKG_UPGRADE}:$$1" in
	1:*|*:upgrade) exit 0 ;;
esac

if [ -x /etc/init.d/AdGuardHome ]; then
	/etc/init.d/AdGuardHome do_redirect 0 >/dev/null 2>&1 || {
		echo "Unable to remove AdGuard Home DNS integration; uninstall aborted." >&2
		exit 1
	}
	[ "$$(uci -q get AdGuardHome.AdGuardHome.old_enabled)" != 1 ] || {
		echo "AdGuard Home DNS integration is still marked active; uninstall aborted." >&2
		exit 1
	}
	[ "$$(uci -q get AdGuardHome.AdGuardHome.dnsmasq_snapshot)" != 1 ] || {
		echo "AdGuard Home dnsmasq snapshot was not restored; uninstall aborted." >&2
		exit 1
	}
	if [ "$$(uci -q get firewall.adguardhome_redirect.name)" = 'AdGuard Home (luci-app-adguardhome)' ]; then
		echo "AdGuard Home firewall redirect is still present; uninstall aborted." >&2
		exit 1
	fi
fi

if [ -x /etc/init.d/adguardhome ]; then
	if uci -q get adguardhome.config >/dev/null 2>&1; then
		uci -q set adguardhome.config.enabled='0' || exit 1
		uci -q commit adguardhome || exit 1
	fi
	/etc/init.d/adguardhome stop >/dev/null 2>&1 || {
		echo "Unable to stop the packaged AdGuard Home service; uninstall aborted." >&2
		exit 1
	}
	if /etc/init.d/adguardhome running >/dev/null 2>&1; then
		echo "The packaged AdGuard Home service is still running; uninstall aborted." >&2
		exit 1
	fi
fi

exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
case "$${PKG_UPGRADE}:$$1" in
	1:*|*:upgrade) exit 0 ;;
esac
rm -f "$${IPKG_INSTROOT}/lib/upgrade/keep.d/luci-app-adguardhome"
rm -f "$${IPKG_INSTROOT}/var/run/AdGredir"
rm -f "$${IPKG_INSTROOT}/tmp/luci-app-adguardhome.upgrade"
if [ -z "$${IPKG_INSTROOT}" ]; then
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	[ ! -x /etc/init.d/rpcd ] || /etc/init.d/rpcd reload >/dev/null 2>&1 || true
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
