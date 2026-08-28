# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=2.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-digest +ucode-mod-uloop +coreutils-timeout +flock +procd-ujail +adguardhome
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
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/hotplug.d/acme/95-AdGuardHome
	chmod 0700 $(PKG_BUILD_DIR)/root/etc/AdGuardHome
	chmod 0600 $(PKG_BUILD_DIR)/root/etc/AdGuardHome/AdGuardHome.yaml
endef

# Keep legacy YAML locations and the root-private original-state snapshot in
# sysupgrade backups.  The snapshot directory is created at runtime and adds
# no file overlap with the official adguardhome APK payload.
define Package/$(PKG_NAME)/conffiles
/etc/config/AdGuardHome
/etc/AdGuardHome/AdGuardHome.yaml
/etc/AdGuardHome.yaml
/root/.luci-app-adguardhome/
endef

# APK maps this hook to both pre-install and pre-upgrade; its generated upgrade
# wrapper supplies PKG_UPGRADE=1, while opkg passes "upgrade" as argv[1].
# Snapshot the untouched official UCI/runtime state on the first install, then
# stop the legacy mixed-case supervisor before an upgrade replaces it.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
snapshot_dir=/root/.luci-app-adguardhome
snapshot_uci="$${snapshot_dir}/official-adguardhome.uci"
snapshot_config="$${snapshot_dir}/official-adguardhome.config"
snapshot_state="$${snapshot_dir}/official-adguardhome.state"
snapshot_version="$${snapshot_dir}/snapshot-version"
runtime_dir=/var/run/luci-app-adguardhome
upgrade_marker="$${runtime_dir}/upgrade"
init_enabled_marker="$${runtime_dir}/init-enabled"
yaml_runtime_dir=/var/run/luci-app-adguardhome-yaml
yaml_update_lock="$${yaml_runtime_dir}/update.lock"
yaml_maintenance_marker="$${yaml_runtime_dir}/removing"
yaml_maintenance_created=0
yaml_maintenance_committed=0
snapshot_stage=""

# Historical versions trusted these world-writable marker paths.  Never read
# them; remove only the two exact legacy objects before doing any work.
for legacy_marker in \
	/tmp/luci-app-adguardhome.upgrade \
	/tmp/luci-app-adguardhome.init-enabled; do
	if [ -f "$$legacy_marker" ] || [ -L "$$legacy_marker" ]; then
		rm -f "$$legacy_marker" || exit 1
	fi
done

entry_metadata() {
	LC_ALL=C ls -ldn "$$1" 2>/dev/null
}

root_owned_safe_directory() {
	local metadata mode owner group
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$owner" = 0 ] && [ "$$group" = 0 ] || return 1
	case "$$mode" in ?????w*|????????w*) return 1 ;; esac
}

root_private_directory() {
	local metadata
	root_owned_safe_directory "$$1" || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	[ "$${metadata%% *}" = "drwx------" ]
}

root_private_file() {
	local metadata
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_private_empty_file() {
	local metadata mode links owner group size
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ] || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	[ "$$size" = 0 ]
}

quiesce_yaml_updates() {
	if [ -e "$$yaml_runtime_dir" ] || [ -L "$$yaml_runtime_dir" ]; then
		root_private_directory "$$yaml_runtime_dir" || return 1
	else
		mkdir -m 0700 "$$yaml_runtime_dir" || return 1
		chown 0:0 "$$yaml_runtime_dir" && chmod 0700 "$$yaml_runtime_dir" || return 1
		root_private_directory "$$yaml_runtime_dir" || return 1
	fi
	if [ -e "$$yaml_update_lock" ] || [ -L "$$yaml_update_lock" ]; then
		root_private_empty_file "$$yaml_update_lock" || return 1
	else
		(umask 077; : >"$$yaml_update_lock") || return 1
		chown 0:0 "$$yaml_update_lock" && chmod 0600 "$$yaml_update_lock" || return 1
		root_private_empty_file "$$yaml_update_lock" || return 1
	fi
	[ ! -e /proc/self/fd/191 ] || return 1
	exec 191>>"$$yaml_update_lock" || return 1
	[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || return 1
	/usr/bin/flock -x 191 || return 1
	[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || return 1
	if [ -e "$$yaml_maintenance_marker" ] || [ -L "$$yaml_maintenance_marker" ]; then
		root_private_empty_file "$$yaml_maintenance_marker" || return 1
	else
		(umask 077; : >"$$yaml_maintenance_marker") || return 1
		chown 0:0 "$$yaml_maintenance_marker" &&
			chmod 0600 "$$yaml_maintenance_marker" || return 1
		root_private_empty_file "$$yaml_maintenance_marker" || return 1
		yaml_maintenance_created=1
	fi
}

cleanup_yaml_maintenance() {
	[ "$$yaml_maintenance_committed" != 1 ] || return 0
	[ "$$yaml_maintenance_created" = 1 ] || return 0
	[ -e /proc/self/fd/191 ] &&
		[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] &&
		root_private_empty_file "$$yaml_maintenance_marker" || return 0
	rm -f "$$yaml_maintenance_marker" 2>/dev/null || true
}

# /etc/config is mode 0777 on the supported rootfs.  Capture the fixed
# official file through a held descriptor and require the pathname to retain
# the same regular root-owned inode before and after the bounded copy.
capture_official_config() (
	local target="$$1" fd_path fd_metadata fd_mode fd_owner fd_group
	[ -f /etc/config/adguardhome ] && [ ! -L /etc/config/adguardhome ] || exit 1
	exec 8</etc/config/adguardhome || exit 1
	fd_path=/proc/self/fd/8
	[ -f "$$fd_path" ] || exit 1
	fd_metadata="$$(LC_ALL=C ls -ldnL "$$fd_path" 2>/dev/null)" || exit 1
	read -r fd_mode _fd_links fd_owner fd_group _fd_remainder <<-EOF
	$$fd_metadata
	EOF
	case "$$fd_mode" in -?????????) ;; *) exit 1 ;; esac
	[ "$$fd_owner" = 0 ] && [ "$$fd_group" = 0 ] || exit 1
	[ "$$fd_path" -ef /etc/config/adguardhome ] || exit 1
	/usr/bin/timeout -k 1s 5s /bin/dd if="$$fd_path" \
		bs=4096 count=129 of="$$target" 2>/dev/null || exit 1
	[ ! -L /etc/config/adguardhome ] &&
		[ "$$fd_path" -ef /etc/config/adguardhome ]
)

bounded_private_file() {
	local size
	root_private_file "$$1" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ]
}

bounded_snapshot_uci() {
	bounded_private_file "$$snapshot_uci"
}

bounded_snapshot_config() {
	bounded_private_file "$$snapshot_config"
}

validate_original_snapshot() {
	root_private_directory "$$snapshot_dir" || return 1
	root_private_file "$$snapshot_version" || return 1
	root_private_file "$$snapshot_state" || return 1
	bounded_snapshot_uci || return 1
	bounded_snapshot_config || return 1
	[ "$$(wc -c <"$$snapshot_version" 2>/dev/null)" = 2 ] &&
		grep -qx '1' "$$snapshot_version" || return 1
	grep -Eq '^was_running=[01]$$' "$$snapshot_state" || return 1
	[ "$$(wc -l <"$$snapshot_state" 2>/dev/null)" = 1 ] || return 1
	grep -Eq '^package[[:space:]]+adguardhome$$' "$$snapshot_uci"
}

discard_official_pending_delta() {
	local delta_dir=/tmp/.uci delta_file=/tmp/.uci/adguardhome
	if [ ! -e "$$delta_dir" ] && [ ! -L "$$delta_dir" ]; then
		return 0
	fi
	root_private_directory "$$delta_dir" || return 1
	if [ -e "$$delta_file" ] || [ -L "$$delta_file" ]; then
		rm -f "$$delta_file" || return 1
	fi
	[ ! -e "$$delta_file" ] && [ ! -L "$$delta_file" ]
}

cleanup_snapshot_stage() {
	local stage="$$1"
	[ -n "$$stage" ] || return 0
	rm -f "$${stage}/official-adguardhome.uci" \
		"$${stage}/official-adguardhome.config" \
		"$${stage}/official-adguardhome.state" \
		"$${stage}/snapshot-version" "$${stage}/.semantic-export" \
		"$${stage}"/luci_agh_snapshot_?????? 2>/dev/null || true
	rmdir "$$stage" 2>/dev/null || true
	[ "$$snapshot_stage" != "$$stage" ] || snapshot_stage=""
}

ensure_original_snapshot() {
	local stage snapshot_suffix snapshot_package raw_export
	local was_running=0 running_rc=0
	if [ -e "$$snapshot_dir" ] || [ -L "$$snapshot_dir" ]; then
		validate_original_snapshot || {
			echo "Unsafe or incomplete original adguardhome snapshot; installation aborted." >&2
			return 1
		}
		return 0
	fi
	root_owned_safe_directory /root || return 1
	[ -x /usr/bin/timeout ] || {
		echo "The required coreutils timeout helper is missing." >&2
		return 1
	}
	stage="$$(mktemp -d /root/.luci-app-adguardhome.XXXXXX)" || return 1
	snapshot_stage="$$stage"
	if ! chown 0:0 "$$stage" || ! chmod 0700 "$$stage"; then
		cleanup_snapshot_stage "$$stage"
		return 1
	fi
	snapshot_suffix="$${stage##*.}"
	case "$$snapshot_suffix" in
		??????) ;;
		*) cleanup_snapshot_stage "$$stage"; return 1 ;;
	esac
	case "$$snapshot_suffix" in *[!A-Za-z0-9]*) cleanup_snapshot_stage "$$stage"; return 1 ;; esac
	snapshot_package="luci_agh_snapshot_$${snapshot_suffix}"
	raw_export="$${stage}/.semantic-export"
	if ! capture_official_config "$${stage}/$${snapshot_package}" ||
	   ! chown 0:0 "$${stage}/$${snapshot_package}" ||
	   ! chmod 0600 "$${stage}/$${snapshot_package}" ||
	   ! bounded_private_file "$${stage}/$${snapshot_package}"; then
		cleanup_snapshot_stage "$$stage"
		echo "Unable to capture the original official adguardhome config file." >&2
		return 1
	fi
	if ! /usr/bin/timeout -k 1s 5s uci -q -c "$$stage" \
		export "$$snapshot_package" >"$$raw_export" ||
	   ! chown 0:0 "$$raw_export" || ! chmod 0600 "$$raw_export" ||
	   ! bounded_private_file "$$raw_export" ||
	   [ "$$(sed -n '1p' "$$raw_export")" != "package $${snapshot_package}" ]; then
		cleanup_snapshot_stage "$$stage"
		echo "Unable to validate the captured official adguardhome UCI configuration." >&2
		return 1
	fi
	{
		printf 'package adguardhome\n'
		sed '1d' "$$raw_export"
	} >"$${stage}/official-adguardhome.uci" || {
		cleanup_snapshot_stage "$$stage"
		return 1
	}
	rm -f "$$raw_export" || return 1
	mv "$${stage}/$${snapshot_package}" "$${stage}/official-adguardhome.config" || {
		cleanup_snapshot_stage "$$stage"
		return 1
	}
	if [ -x /etc/init.d/adguardhome ]; then
		/usr/bin/timeout -k 1s 5s /etc/init.d/adguardhome running \
			>/dev/null 2>&1 || running_rc=$$?
		case "$$running_rc" in
			0) was_running=1 ;;
			1) ;;
			*)
				cleanup_snapshot_stage "$$stage"
				echo "Unable to determine the original official adguardhome runtime state." >&2
				return 1
				;;
		esac
	fi
	printf 'was_running=%s\n' "$$was_running" \
		>"$${stage}/official-adguardhome.state" || {
		cleanup_snapshot_stage "$$stage"
		return 1
	}
	printf '1\n' >"$${stage}/snapshot-version" || {
		cleanup_snapshot_stage "$$stage"
		return 1
	}
	if ! chown 0:0 "$${stage}/official-adguardhome.uci" \
		"$${stage}/official-adguardhome.config" \
		"$${stage}/official-adguardhome.state" "$${stage}/snapshot-version" ||
	   ! chmod 0600 "$${stage}/official-adguardhome.uci" \
			"$${stage}/official-adguardhome.config" \
			"$${stage}/official-adguardhome.state" "$${stage}/snapshot-version"; then
		cleanup_snapshot_stage "$$stage"
		return 1
	fi
	if ! bounded_private_file "$${stage}/official-adguardhome.uci" ||
	   ! bounded_private_file "$${stage}/official-adguardhome.config" ||
	   ! grep -Eq '^package[[:space:]]+adguardhome$$' \
		"$${stage}/official-adguardhome.uci" ||
	   ! grep -Eq '^was_running=[01]$$' \
		"$${stage}/official-adguardhome.state"; then
		cleanup_snapshot_stage "$$stage"
		return 1
	fi
	if [ -e "$$snapshot_dir" ] || [ -L "$$snapshot_dir" ]; then
		cleanup_snapshot_stage "$$stage"
		validate_original_snapshot
		return
	fi
	mv "$$stage" "$$snapshot_dir" || {
		cleanup_snapshot_stage "$$stage"
		return 1
	}
	snapshot_stage=""
	validate_original_snapshot
}

validate_runtime_parent() {
	local target
	if [ -L /var ]; then
		target="$$(readlink /var 2>/dev/null)"
		case "$$target" in tmp|/tmp) ;; *) return 1 ;; esac
	fi
	root_owned_safe_directory /var/run
}

validate_runtime_dir() {
	validate_runtime_parent || return 1
	root_private_directory "$$runtime_dir"
}

ensure_runtime_dir() {
	validate_runtime_parent || return 1
	if [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; then
		validate_runtime_dir || return 1
		return 0
	fi
	mkdir -m 0700 "$$runtime_dir" || return 1
	chown 0:0 "$$runtime_dir" && chmod 0700 "$$runtime_dir" || return 1
	validate_runtime_dir
}

validate_initial_runtime_contents() {
	local entry
	validate_runtime_dir || return 1
	for entry in \
		"$$runtime_dir"/* \
		"$$runtime_dir"/.[!.]* \
		"$$runtime_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		case "$$entry" in
			"$$upgrade_marker"|"$$init_enabled_marker") ;;
			*) return 1 ;;
		esac
	done
}

write_runtime_marker() {
	local marker="$$1"
	case "$$marker" in "$$runtime_dir"/*) ;; *) return 1 ;; esac
	[ ! -e "$$marker" ] && [ ! -L "$$marker" ] || rm -f "$$marker" || return 1
	printf '1\n' >"$$marker" || return 1
	chown 0:0 "$$marker" && chmod 0600 "$$marker" || return 1
	root_private_file "$$marker" &&
		[ "$$(wc -c <"$$marker" 2>/dev/null)" = 2 ] && grep -qx '1' "$$marker"
}

cleanup_upgrade_markers() {
	cleanup_yaml_maintenance
	cleanup_snapshot_stage "$$snapshot_stage"
	if validate_runtime_dir; then
		rm -f "$$upgrade_marker" "$$init_enabled_marker"
		rmdir "$$runtime_dir" 2>/dev/null || true
	fi
}

trap cleanup_upgrade_markers 0
trap 'exit 1' HUP INT TERM
quiesce_yaml_updates || {
	echo "Unable to quiesce LuCI YAML updates; installation aborted." >&2
	exit 1
}
ensure_original_snapshot || exit 1
is_upgrade=0
case "$${PKG_UPGRADE}:$$1" in
	1:*|*:upgrade) is_upgrade=1 ;;
esac
[ -f /usr/lib/opkg/info/luci-app-adguardhome.list ] && is_upgrade=1
[ -f /lib/apk/packages/luci-app-adguardhome.list ] && is_upgrade=1
[ "$$is_upgrade" = 1 ] || {
	yaml_maintenance_committed=1
	cleanup_upgrade_markers
	trap - 0 HUP INT TERM
	exit 0
}
ensure_runtime_dir || {
	echo "Unable to create the private AdGuard Home lifecycle directory." >&2
	exit 1
}
validate_initial_runtime_contents || {
	echo "Unexpected AdGuard Home lifecycle runtime entry; upgrade aborted." >&2
	exit 1
}
write_runtime_marker "$$upgrade_marker" || {
	echo "Unable to mark the AdGuard Home package upgrade." >&2
	exit 1
}

# Record the pre-upgrade rc.common state before APK replaces the init script.
# Either an S?? or K?? link means that the compatibility wrapper was enabled;
# the uci-defaults migration uses this marker to rebuild legacy priorities
# without enabling a wrapper that the administrator had explicitly disabled.
rm -f "$$init_enabled_marker" || exit 1
for init_link in /etc/rc.d/S??AdGuardHome /etc/rc.d/K??AdGuardHome; do
	[ -L "$$init_link" ] || continue
	write_runtime_marker "$$init_enabled_marker" || {
		echo "Unable to preserve the AdGuard Home init state." >&2
		exit 1
	}
	break
done

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

if [ -x /etc/init.d/adguardhome ]; then
	/usr/bin/timeout -k 2s 20s /etc/init.d/adguardhome stop \
		>/dev/null 2>&1 || {
		echo "Unable to stop the packaged AdGuard Home service; upgrade aborted." >&2
		exit 1
	}
	lower_running_rc=0
	/usr/bin/timeout -k 1s 5s /etc/init.d/adguardhome running \
		>/dev/null 2>&1 || lower_running_rc=$$?
	case "$$lower_running_rc" in
		1) ;;
		0)
			echo "The packaged AdGuard Home service is still running; upgrade aborted." >&2
			exit 1
			;;
		*)
			echo "Unable to verify that packaged AdGuard Home stopped; upgrade aborted." >&2
			exit 1
			;;
	esac
fi

yaml_maintenance_committed=1
trap - 0 HUP INT TERM
exit 0
endef

# base-files deliberately continues past a failed uci-defaults script and
# leaves that script in place for a later retry.  For this coordinator, a
# partially applied migration is not an acceptable successful installation:
# turn the retained package-owned script into a hard package-manager failure.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0

if [ -e /etc/uci-defaults/40_luci-AdGuardHome ] ||
   [ -L /etc/uci-defaults/40_luci-AdGuardHome ]; then
	echo "AdGuard Home configuration migration failed; package installation aborted." >&2
	exit 1
fi

entry_metadata() {
	LC_ALL=C ls -ldn "$$1" 2>/dev/null
}
root_private_directory() {
	local metadata
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "drwx------" ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ]
}
root_private_empty_file() {
	local metadata mode links owner group size
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ] || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	[ "$$size" = 0 ]
}
yaml_runtime_dir=/var/run/luci-app-adguardhome-yaml
yaml_update_lock="$${yaml_runtime_dir}/update.lock"
yaml_maintenance_marker="$${yaml_runtime_dir}/removing"

# Defensively establish or repair the stable YAML lock again in postinst.  The
# pre-install/pre-upgrade hook normally creates it, but postinst must not expose
# the freshly installed rpcd object unless this safety boundary still exists.
if [ -e "$$yaml_runtime_dir" ] || [ -L "$$yaml_runtime_dir" ]; then
	root_private_directory "$$yaml_runtime_dir" || exit 1
else
	mkdir -m 0700 "$$yaml_runtime_dir" || exit 1
	chown 0:0 "$$yaml_runtime_dir" && chmod 0700 "$$yaml_runtime_dir" || exit 1
	root_private_directory "$$yaml_runtime_dir" || exit 1
fi
if [ -e "$$yaml_update_lock" ] || [ -L "$$yaml_update_lock" ]; then
	root_private_empty_file "$$yaml_update_lock" || exit 1
else
	(umask 077; : >"$$yaml_update_lock") || exit 1
	chown 0:0 "$$yaml_update_lock" && chmod 0600 "$$yaml_update_lock" || exit 1
	root_private_empty_file "$$yaml_update_lock" || exit 1
fi
[ ! -e /proc/self/fd/191 ] || exit 1
exec 191>>"$$yaml_update_lock" || exit 1
[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || exit 1
/usr/bin/flock -x 191 || exit 1
[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || exit 1
if [ -e "$$yaml_maintenance_marker" ] || [ -L "$$yaml_maintenance_marker" ]; then
	root_private_empty_file "$$yaml_maintenance_marker" || exit 1
else
	(umask 077; : >"$$yaml_maintenance_marker") || exit 1
	chown 0:0 "$$yaml_maintenance_marker" &&
		chmod 0600 "$$yaml_maintenance_marker" || exit 1
	root_private_empty_file "$$yaml_maintenance_marker" || exit 1
fi

rm -f /tmp/luci-indexcache.* || exit 1
if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
	rm -f /tmp/luci-modulecache || exit 1
elif [ -d /tmp/luci-modulecache ]; then
	rm -rf /tmp/luci-modulecache/ || exit 1
fi
if [ ! -x /etc/init.d/rpcd ] ||
   ! /etc/init.d/rpcd reload >/dev/null 2>&1; then
	echo "Unable to reload rpcd; YAML updates remain blocked." >&2
	exit 1
fi

[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || exit 1
root_private_directory "$$yaml_runtime_dir" &&
	root_private_empty_file "$$yaml_update_lock" &&
	root_private_empty_file "$$yaml_maintenance_marker" || exit 1
rm -f "$$yaml_maintenance_marker" || exit 1
[ ! -e "$$yaml_maintenance_marker" ] && [ ! -L "$$yaml_maintenance_marker" ] || exit 1
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

snapshot_dir=/root/.luci-app-adguardhome
snapshot_uci="$${snapshot_dir}/official-adguardhome.uci"
snapshot_config="$${snapshot_dir}/official-adguardhome.config"
snapshot_state="$${snapshot_dir}/official-adguardhome.state"
snapshot_version="$${snapshot_dir}/snapshot-version"
runtime_dir=/var/run/luci-app-adguardhome
yaml_runtime_dir=/var/run/luci-app-adguardhome-yaml
yaml_update_lock="$${yaml_runtime_dir}/update.lock"
yaml_removal_marker="$${yaml_runtime_dir}/removing"
yaml_removal_created=0
yaml_removal_committed=0
verify_export=""
verify_config_dir=""
verify_package=""

entry_metadata() {
	LC_ALL=C ls -ldn "$$1" 2>/dev/null
}

root_owned_safe_directory() {
	local metadata mode
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$owner" = 0 ] && [ "$$group" = 0 ] || return 1
	case "$$mode" in ?????w*|????????w*) return 1 ;; esac
}

root_owned_directory_allow_writable() {
	local metadata
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r _mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_private_directory() {
	local metadata
	root_owned_safe_directory "$$1" || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	[ "$${metadata%% *}" = "drwx------" ]
}

root_private_file() {
	local metadata
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_private_empty_file() {
	local metadata mode links owner group size
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ] || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	[ "$$size" = 0 ]
}

quiesce_yaml_updates() {
	if [ -e "$$yaml_runtime_dir" ] || [ -L "$$yaml_runtime_dir" ]; then
		root_private_directory "$$yaml_runtime_dir" || return 1
	else
		mkdir -m 0700 "$$yaml_runtime_dir" || return 1
		chown 0:0 "$$yaml_runtime_dir" && chmod 0700 "$$yaml_runtime_dir" || return 1
		root_private_directory "$$yaml_runtime_dir" || return 1
	fi
	if [ -e "$$yaml_update_lock" ] || [ -L "$$yaml_update_lock" ]; then
		root_private_empty_file "$$yaml_update_lock" || return 1
	else
		(umask 077; : >>"$$yaml_update_lock") || return 1
		chown 0:0 "$$yaml_update_lock" && chmod 0600 "$$yaml_update_lock" || return 1
		root_private_empty_file "$$yaml_update_lock" || return 1
	fi
	[ ! -e /proc/self/fd/191 ] || return 1
	exec 191>>"$$yaml_update_lock" || return 1
	[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || return 1
	/usr/bin/flock -x 191 || return 1
	[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || return 1
	if [ -e "$$yaml_removal_marker" ] || [ -L "$$yaml_removal_marker" ]; then
		root_private_empty_file "$$yaml_removal_marker" || return 1
	else
		(umask 077; : >"$$yaml_removal_marker") || return 1
		chown 0:0 "$$yaml_removal_marker" && chmod 0600 "$$yaml_removal_marker" || return 1
		root_private_empty_file "$$yaml_removal_marker" || return 1
		yaml_removal_created=1
	fi
}

bounded_private_file() {
	local size
	root_private_file "$$1" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ]
}

discard_official_pending_delta() {
	local delta_dir=/tmp/.uci delta_file=/tmp/.uci/adguardhome
	if [ ! -e "$$delta_dir" ] && [ ! -L "$$delta_dir" ]; then
		return 0
	fi
	root_private_directory "$$delta_dir" || return 1
	if [ -e "$$delta_file" ] || [ -L "$$delta_file" ]; then
		rm -f "$$delta_file" || return 1
	fi
	[ ! -e "$$delta_file" ] && [ ! -L "$$delta_file" ]
}

# Restore through a descriptor held across the same-directory rename.  This
# keeps the operation functional on the target's root-owned mode-0777
# /etc/config while detecting any pathname replacement before or after mv.
atomic_restore_official_config() (
	local temporary="" source_fd target_fd metadata mode owner group size
	cleanup_atomic_restore() {
		case "$$temporary" in /etc/config/.adguardhome.luci-restore.*) rm -f "$$temporary" ;; esac
	}
	trap cleanup_atomic_restore 0
	trap 'exit 1' HUP INT TERM
	root_owned_directory_allow_writable /etc/config || exit 1
	root_private_file "$$snapshot_config" || exit 1
	[ -f /etc/config/adguardhome ] && [ ! -L /etc/config/adguardhome ] || exit 1
	temporary="$$(mktemp /etc/config/.adguardhome.luci-restore.XXXXXX)" || exit 1
	chown 0:0 "$$temporary" && chmod 0600 "$$temporary" || exit 1
	exec 8<"$$snapshot_config" || exit 1
	exec 9<>"$$temporary" || exit 1
	source_fd=/proc/self/fd/8
	target_fd=/proc/self/fd/9
	[ "$$source_fd" -ef "$$snapshot_config" ] || exit 1
	[ ! -L "$$temporary" ] && [ "$$target_fd" -ef "$$temporary" ] || exit 1
	/usr/bin/timeout -k 1s 5s /bin/dd if="$$source_fd" of="$$target_fd" \
		bs=4096 count=129 2>/dev/null || exit 1
	chown 0:0 "$$target_fd" && chmod 0600 "$$target_fd" || exit 1
	metadata="$$(LC_ALL=C ls -ldnL "$$target_fd" 2>/dev/null)" || exit 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ] || exit 1
	size="$$(wc -c <"$$target_fd" 2>/dev/null)" || exit 1
	case "$$size" in ""|*[!0-9]*) exit 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ] || exit 1
	cmp -s "$$source_fd" "$$target_fd" || exit 1
	[ "$$source_fd" -ef "$$snapshot_config" ] || exit 1
	[ ! -L "$$temporary" ] && [ "$$target_fd" -ef "$$temporary" ] || exit 1
	[ -f /etc/config/adguardhome ] && [ ! -L /etc/config/adguardhome ] || exit 1
	mv -f "$$temporary" /etc/config/adguardhome || exit 1
	temporary=""
	[ "$$target_fd" -ef /etc/config/adguardhome ] || exit 1
	root_private_file /etc/config/adguardhome || exit 1
	cmp -s "$$source_fd" "$$target_fd" &&
		cmp -s "$$snapshot_config" /etc/config/adguardhome
)

validate_original_snapshot() {
	root_private_directory "$$snapshot_dir" || return 1
	root_private_file "$$snapshot_version" || return 1
	root_private_file "$$snapshot_state" || return 1
	bounded_private_file "$$snapshot_uci" || return 1
	bounded_private_file "$$snapshot_config" || return 1
	[ "$$(wc -c <"$$snapshot_version" 2>/dev/null)" = 2 ] &&
		grep -qx '1' "$$snapshot_version" || return 1
	grep -Eq '^was_running=[01]$$' "$$snapshot_state" || return 1
	[ "$$(wc -l <"$$snapshot_state" 2>/dev/null)" = 1 ] || return 1
	grep -Eq '^package[[:space:]]+adguardhome$$' "$$snapshot_uci"
}

validate_runtime_parent() {
	local target
	if [ -L /var ]; then
		target="$$(readlink /var 2>/dev/null)"
		case "$$target" in tmp|/tmp) ;; *) return 1 ;; esac
	fi
	root_owned_safe_directory /var/run
}

ensure_runtime_dir() {
	validate_runtime_parent || return 1
	if [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; then
		root_private_directory "$$runtime_dir"
		return
	fi
	mkdir -m 0700 "$$runtime_dir" || return 1
	chown 0:0 "$$runtime_dir" && chmod 0700 "$$runtime_dir" || return 1
	root_private_directory "$$runtime_dir"
}

cleanup_restore_files() {
	if [ "$$yaml_removal_committed" != 1 ] &&
	   [ "$$yaml_removal_created" = 1 ] &&
	   [ -e /proc/self/fd/191 ] &&
	   [ /proc/self/fd/191 -ef "$$yaml_update_lock" ] &&
	   root_private_empty_file "$$yaml_removal_marker"; then
		rm -f "$$yaml_removal_marker" 2>/dev/null || true
	fi
	case "$$verify_export" in "$$runtime_dir"/restore-export.*) rm -f "$$verify_export" ;; esac
	case "$$verify_config_dir" in
		"$$runtime_dir"/restore-config.*)
			rm -f "$${verify_config_dir}/$${verify_package}" \
				"$${verify_config_dir}/.semantic-export" 2>/dev/null || true
			rmdir "$$verify_config_dir" 2>/dev/null || true
			;;
	esac
	if root_private_directory "$$runtime_dir"; then
		rmdir "$$runtime_dir" 2>/dev/null || true
	fi
}

restore_official_state() {
	local was_running running_rc=0 verify_suffix raw_export
	validate_original_snapshot || {
		echo "Original official adguardhome snapshot is unavailable or unsafe; uninstall aborted." >&2
		return 1
	}
	atomic_restore_official_config || {
		echo "The restored official adguardhome UCI bytes do not match the snapshot." >&2
		return 1
	}
	verify_config_dir="$$(mktemp -d "$${runtime_dir}/restore-config.XXXXXX")" || return 1
	chown 0:0 "$$verify_config_dir" && chmod 0700 "$$verify_config_dir" || return 1
	verify_suffix="$${verify_config_dir##*.}"
	case "$$verify_suffix" in
		??????) ;;
		*) return 1 ;;
	esac
	case "$$verify_suffix" in *[!A-Za-z0-9]*) return 1 ;; esac
	verify_package="luci_agh_restore_$${verify_suffix}"
	raw_export="$${verify_config_dir}/.semantic-export"
	if ! /usr/bin/timeout -k 1s 5s /bin/dd if="$$snapshot_config" \
		of="$${verify_config_dir}/$${verify_package}" bs=4096 count=129 2>/dev/null ||
	   ! chown 0:0 "$${verify_config_dir}/$${verify_package}" ||
	   ! chmod 0600 "$${verify_config_dir}/$${verify_package}" ||
	   ! bounded_private_file "$${verify_config_dir}/$${verify_package}" ||
	   ! cmp -s "$$snapshot_config" "$${verify_config_dir}/$${verify_package}" ||
	   ! /usr/bin/timeout -k 1s 5s uci -q -c "$$verify_config_dir" \
		export "$$verify_package" >"$$raw_export" ||
	   ! chown 0:0 "$$raw_export" || ! chmod 0600 "$$raw_export" ||
	   ! bounded_private_file "$$raw_export" ||
	   [ "$$(sed -n '1p' "$$raw_export")" != "package $${verify_package}" ]; then
		echo "The restored official adguardhome UCI file cannot be parsed." >&2
		return 1
	fi
	verify_export="$$(mktemp "$${runtime_dir}/restore-export.XXXXXX")" || return 1
	{
		printf 'package adguardhome\n'
		sed '1d' "$$raw_export"
	} >"$$verify_export" || return 1
	chown 0:0 "$$verify_export" && chmod 0600 "$$verify_export" || return 1
	bounded_private_file "$$verify_export" || return 1
	cmp -s "$$snapshot_uci" "$$verify_export" || {
		echo "The restored official adguardhome UCI semantics do not match the snapshot." >&2
		return 1
	}
	was_running="$$(sed -n 's/^was_running=//p' "$$snapshot_state")"
	case "$$was_running" in
		1)
			/usr/bin/timeout -k 2s 20s /etc/init.d/adguardhome start \
				>/dev/null 2>&1 || {
				echo "Unable to restart the originally running official adguardhome service." >&2
				return 1
			}
			/usr/bin/timeout -k 1s 5s /etc/init.d/adguardhome running \
				>/dev/null 2>&1 || {
				echo "The restored official adguardhome service is not running." >&2
				return 1
			}
			;;
		0)
			/usr/bin/timeout -k 1s 5s /etc/init.d/adguardhome running \
				>/dev/null 2>&1 || running_rc=$$?
			case "$$running_rc" in
				1) ;;
				0)
					echo "The originally stopped official adguardhome service started unexpectedly." >&2
					return 1
					;;
				*) return 1 ;;
			esac
			;;
		*) return 1 ;;
	esac
}

trap cleanup_restore_files 0
trap 'exit 1' HUP INT TERM
quiesce_yaml_updates || {
	echo "Unable to quiesce LuCI YAML updates; uninstall aborted." >&2
	exit 1
}
validate_original_snapshot || {
	echo "Original official adguardhome snapshot is unavailable or unsafe; uninstall aborted." >&2
	exit 1
}
ensure_runtime_dir || exit 1
discard_official_pending_delta || {
	echo "Unsafe official adguardhome UCI delta; uninstall aborted." >&2
	exit 1
}

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
	/usr/bin/timeout -k 2s 20s /etc/init.d/adguardhome stop \
		>/dev/null 2>&1 || {
		echo "Unable to stop the packaged AdGuard Home service; uninstall aborted." >&2
		exit 1
	}
	lower_running_rc=0
	/usr/bin/timeout -k 1s 5s /etc/init.d/adguardhome running \
		>/dev/null 2>&1 || lower_running_rc=$$?
	case "$$lower_running_rc" in
		1) ;;
		0)
			echo "The packaged AdGuard Home service is still running; uninstall aborted." >&2
			exit 1
			;;
		*)
			echo "Unable to verify that packaged AdGuard Home stopped; uninstall aborted." >&2
			exit 1
			;;
	esac
fi

restore_official_state || exit 1
yaml_removal_committed=1
cleanup_restore_files
trap - 0 HUP INT TERM

exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
case "$${PKG_UPGRADE}:$$1" in
	1:*|*:upgrade) exit 0 ;;
esac
rm -f "$${IPKG_INSTROOT}/lib/upgrade/keep.d/luci-app-adguardhome"
rm -f "$${IPKG_INSTROOT}/var/run/AdGredir"
if [ -z "$${IPKG_INSTROOT}" ]; then
	entry_metadata() {
		LC_ALL=C ls -ldn "$$1" 2>/dev/null
	}
	root_private_directory() {
		local metadata
		[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
		metadata="$$(entry_metadata "$$1")" || return 1
		read -r mode _links owner group _remainder <<-EOF
		$$metadata
		EOF
		[ "$$mode" = "drwx------" ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ]
	}
	root_private_file() {
		local metadata
		[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
		metadata="$$(entry_metadata "$$1")" || return 1
		read -r mode links owner group _remainder <<-EOF
		$$metadata
		EOF
		[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
			[ "$$owner" = 0 ] && [ "$$group" = 0 ]
	}
	root_private_empty_file() {
		local size
		root_private_file "$$1" || return 1
		size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
		[ "$$size" = 0 ]
	}
	root_private_bounded_job_file() {
		local size
		root_private_file "$$1" || return 1
		size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
		case "$$size" in ""|*[!0-9]*) return 1 ;; esac
		[ "$$size" -le 256 ]
	}
	snapshot_dir=/root/.luci-app-adguardhome
	runtime_dir=/var/run/luci-app-adguardhome
	yaml_runtime_dir=/var/run/luci-app-adguardhome-yaml
	if root_private_directory "$$snapshot_dir" &&
	   root_private_file "$${snapshot_dir}/official-adguardhome.uci" &&
	   root_private_file "$${snapshot_dir}/official-adguardhome.config" &&
	   root_private_file "$${snapshot_dir}/official-adguardhome.state" &&
	   root_private_file "$${snapshot_dir}/snapshot-version"; then
		rm -f "$${snapshot_dir}/official-adguardhome.uci" \
			"$${snapshot_dir}/official-adguardhome.config" \
			"$${snapshot_dir}/official-adguardhome.state" \
			"$${snapshot_dir}/snapshot-version"
		rmdir "$$snapshot_dir" 2>/dev/null || true
	fi
	if root_private_directory "$$runtime_dir"; then
		rm -f "$${runtime_dir}/upgrade" "$${runtime_dir}/init-enabled"
		rmdir "$$runtime_dir" 2>/dev/null || true
	fi
	# The package files, including the RPC object, have already been removed.
	# Unload the in-memory object before unlinking its stable lock inode.
	if [ ! -x /etc/init.d/rpcd ] ||
	   ! /etc/init.d/rpcd reload >/dev/null 2>&1; then
		echo "Unable to unload the AdGuard Home RPC; YAML maintenance state was preserved." >&2
		exit 1
	fi
	if [ -e "$$yaml_runtime_dir" ] || [ -L "$$yaml_runtime_dir" ]; then
		yaml_update_lock="$${yaml_runtime_dir}/update.lock"
		yaml_removal_marker="$${yaml_runtime_dir}/removing"
		if ! root_private_directory "$$yaml_runtime_dir" ||
		   ! root_private_empty_file "$$yaml_update_lock" ||
		   ! root_private_empty_file "$$yaml_removal_marker"; then
			echo "Unsafe YAML maintenance state was preserved after uninstall." >&2
			exit 1
		fi
		[ ! -e /proc/self/fd/191 ] || exit 1
		exec 191>>"$$yaml_update_lock" || exit 1
		[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || exit 1
		/usr/bin/flock -x 191 || exit 1
		[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] &&
			root_private_empty_file "$$yaml_update_lock" &&
			root_private_empty_file "$$yaml_removal_marker" || exit 1
		for yaml_runtime_entry in \
			"$$yaml_runtime_dir"/* \
			"$$yaml_runtime_dir"/.[!.]* \
			"$$yaml_runtime_dir"/..?*; do
			[ -e "$$yaml_runtime_entry" ] || [ -L "$$yaml_runtime_entry" ] || continue
			yaml_runtime_name="$${yaml_runtime_entry##*/}"
			case "$$yaml_runtime_name" in update.lock|removing) continue ;; esac
			printf '%s\n' "$$yaml_runtime_name" | grep -Eq \
				'^([0-9a-f]{32}|\.[0-9a-f]{32}(\.rpcd-[0-9a-f]{32}|\.[A-Za-z0-9]{6}))$$' || {
				echo "Unexpected YAML runtime entry was preserved: $$yaml_runtime_name" >&2
				exit 1
			}
			root_private_bounded_job_file "$$yaml_runtime_entry" || exit 1
			rm -f "$$yaml_runtime_entry" || exit 1
		done
		root_private_empty_file "$$yaml_removal_marker" &&
			root_private_empty_file "$$yaml_update_lock" || exit 1
		rm -f "$$yaml_removal_marker" || exit 1
		rm -f "$$yaml_update_lock" || exit 1
		rmdir "$$yaml_runtime_dir" || exit 1
	fi
	for legacy_marker in \
		/tmp/luci-app-adguardhome.upgrade \
		/tmp/luci-app-adguardhome.init-enabled; do
		if [ -f "$$legacy_marker" ] || [ -L "$$legacy_marker" ]; then
			rm -f "$$legacy_marker"
		fi
	done
	rm -f /tmp/luci-indexcache.*
	if [ -L /tmp/luci-modulecache ] || [ -f /tmp/luci-modulecache ]; then
		rm -f /tmp/luci-modulecache
	elif [ -d /tmp/luci-modulecache ]; then
		rm -rf /tmp/luci-modulecache/
	fi
	fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
