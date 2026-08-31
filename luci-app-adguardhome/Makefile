# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-adguardhome
PKG_VERSION:=2.3.0
PKG_RELEASE:=2
PKG_LICENSE:=Apache-2.0 BSD-3-Clause

LUCI_TITLE:=LuCI support for AdGuard Home
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-digest +ucode-mod-uloop +flock +procd-ujail +adguardhome
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
	chmod 0644 $(PKG_BUILD_DIR)/root/usr/share/luci-app-adguardhome/default.yaml
	cmp -s $(PKG_BUILD_DIR)/root/etc/AdGuardHome/AdGuardHome.yaml \
		$(PKG_BUILD_DIR)/root/usr/share/luci-app-adguardhome/default.yaml
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

# APK maps this hook to both pre-install and pre-upgrade.  A first install
# snapshots the untouched official UCI/runtime state for safe uninstall.  The
# supported in-place sources are the released v2.1.0-r1, v2.2.0-r1,
# v2.2.0-r2 and v2.3.0-r1 packages; reject any other installed version before
# creating maintenance state or touching DNS.  The v2.3.0-r1 source and any
# v2.2 source that requests or actively uses its old RAM-YAML mode use the cold
# path because r2 deliberately no longer creates a YAML copy in RAM.
define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0

# Bound lifecycle helpers with the BusyBox tools already in the base system.
run_bounded() (
	local limit="$$1" grace="$$2" marker="" child="" watchdog="" rc=0 expired=0
	shift 2
	case "$$limit" in ""|*[!0-9]*) exit 125 ;; esac
	case "$$grace" in ""|*[!0-9]*) exit 125 ;; esac
	[ "$$#" -gt 0 ] || exit 125
	[ -x /usr/bin/setsid ] || exit 125
	marker="$$(mktemp /tmp/luci-app-adguardhome-bounded.XXXXXX)" || exit 125
	chmod 0600 "$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	printf '0\n' >"$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	bounded_signal_session() {
		/bin/kill "-$$1" -- "-$$child" 2>/dev/null ||
			/bin/kill "-$$1" "$$child" 2>/dev/null || true
	}
	bounded_abort() {
		trap - HUP INT QUIT TERM
		[ -z "$$watchdog" ] || /bin/kill -TERM "$$watchdog" 2>/dev/null || true
		[ -z "$$watchdog" ] || wait "$$watchdog" 2>/dev/null || true
		if [ -n "$$child" ]; then
			bounded_signal_session TERM
			sleep "$$grace" 2>/dev/null || true
			bounded_signal_session KILL
			wait "$$child" 2>/dev/null || true
		fi
		rm -f "$$marker"
		exit 125
	}
	trap bounded_abort HUP INT QUIT TERM
	[ ! -e /proc/self/fd/187 ] || bounded_abort
	exec 187<&0 || bounded_abort
	/usr/bin/setsid "$$@" <&187 187<&- &
	child=$$!
	exec 187<&-
	(
		bounded_sleeper=""
		bounded_watchdog_abort() {
			trap - HUP INT QUIT TERM
			[ -z "$$bounded_sleeper" ] || /bin/kill -TERM "$$bounded_sleeper" 2>/dev/null || true
			[ -z "$$bounded_sleeper" ] || wait "$$bounded_sleeper" 2>/dev/null || true
			exit 1
		}
		bounded_watchdog_sleep() {
			sleep "$$1" &
			bounded_sleeper=$$!
			wait "$$bounded_sleeper"
			bounded_sleep_rc=$$?
			bounded_sleeper=""
			return "$$bounded_sleep_rc"
		}
		trap bounded_watchdog_abort HUP INT QUIT TERM
		bounded_watchdog_sleep "$$limit" || exit 1
		/bin/kill -0 -- "-$$child" 2>/dev/null || /bin/kill -0 "$$child" 2>/dev/null || exit 1
		printf '1\n' >"$$marker" || exit 1
		bounded_signal_session TERM
		bounded_watchdog_sleep "$$grace" || exit 0
		bounded_signal_session KILL
	) &
	watchdog=$$!
	wait "$$child" 2>/dev/null || rc=$$?
	read -r expired <"$$marker" 2>/dev/null || expired=0
	if [ "$$expired" = 1 ]; then
		wait "$$watchdog" 2>/dev/null || true
	else
		/bin/kill -TERM "$$watchdog" 2>/dev/null || true
		wait "$$watchdog" 2>/dev/null || true
	fi
	trap - HUP INT QUIT TERM
	rm -f "$$marker"
	[ "$$expired" = 1 ] && exit 124
	exit "$$rc"
)

# APK supplies PKG_UPGRADE=1 from its pre-upgrade wrapper; opkg passes
# "upgrade" as argv[1].  Installed manifests cover callers which omit both
# lifecycle hints.  Version discovery is deliberately read-only and happens
# before legacy-marker cleanup, YAML quiescing, or snapshot creation.
is_upgrade=0
case "$${PKG_UPGRADE}:$${1}" in
	1:*|*:upgrade) is_upgrade=1 ;;
esac
[ -f /usr/lib/opkg/info/luci-app-adguardhome.list ] && is_upgrade=1
[ -f /lib/apk/packages/luci-app-adguardhome.list ] && is_upgrade=1

installed_source_version() {
	local apk_record opkg_record
	if [ -f /lib/apk/packages/luci-app-adguardhome.list ]; then
		[ ! -f /usr/lib/opkg/info/luci-app-adguardhome.list ] || return 1
		command -v apk >/dev/null 2>&1 || return 1
		apk_record="$$(apk list --installed luci-app-adguardhome 2>/dev/null | awk '
			$$1 ~ /^luci-app-adguardhome-/ { matches++; record=$$1 }
			END { if (matches == 1) print record; else exit 1 }
		')" || return 1
		case "$$apk_record" in
			luci-app-adguardhome-*) ;;
			*) return 1 ;;
		esac
		printf '%s\n' "$${apk_record#luci-app-adguardhome-}"
		return
	fi
	if [ -f /usr/lib/opkg/info/luci-app-adguardhome.list ]; then
		command -v opkg >/dev/null 2>&1 || return 1
		opkg_record="$$(opkg status luci-app-adguardhome 2>/dev/null)" || return 1
		printf '%s\n' "$$opkg_record" | awk '
			$$1 == "Package:" && $$2 == "luci-app-adguardhome" { packages++; next }
			$$1 == "Version:" && NF == 2 { versions++; version=$$2 }
			END { if (packages == 1 && versions == 1) print version; else exit 1 }
		'
		return
	fi
	return 1
}

if [ "$$is_upgrade" = 1 ]; then
	installed_version="$$(installed_source_version)" || {
		echo "Unable to determine the installed luci-app-adguardhome version; upgrade aborted before any state change." >&2
		exit 1
	}
	case "$$installed_version" in
		2.1.0-r1|2.3.0-r1)
			maintenance_upgrade=0
			upgrade_source_version="$$installed_version"
			;;
		2.2.0-r1|2.2.0-r2)
			maintenance_upgrade=1
			maintenance_source_version="$$installed_version"
			;;
		*)
			echo "In-place upgrade requires luci-app-adguardhome 2.1.0-r1, 2.2.0-r1, 2.2.0-r2 or 2.3.0-r1; found '$$installed_version'." >&2
			exit 1
			;;
	esac
fi

snapshot_dir=/root/.luci-app-adguardhome
snapshot_uci="$${snapshot_dir}/official-adguardhome.uci"
snapshot_config="$${snapshot_dir}/official-adguardhome.config"
snapshot_state="$${snapshot_dir}/official-adguardhome.state"
snapshot_version="$${snapshot_dir}/snapshot-version"
runtime_dir=/var/run/luci-app-adguardhome
upgrade_marker="$${runtime_dir}/upgrade"
init_enabled_marker="$${runtime_dir}/init-enabled"
maintenance_upgrade_marker="$${runtime_dir}/maintenance-upgrade"
maintenance_config_snapshot="$${runtime_dir}/maintenance-adguardhome.config"
maintenance_delta_snapshot="$${runtime_dir}/maintenance-adguardhome.delta"
upgrade_yaml_snapshot="$${runtime_dir}/upgrade-active.yaml"
upgrade_workdir_metadata="$${runtime_dir}/upgrade-workdir.meta"
cold_postinst_dir=/var/run/luci-app-adguardhome-postinst
cold_postinst_state="$${cold_postinst_dir}/cold-upgrade"
cold_postinst_dir_created=0
cold_postinst_committed=0
yaml_runtime_dir=/var/run/luci-app-adguardhome-yaml
yaml_update_lock="$${yaml_runtime_dir}/update.lock"
yaml_maintenance_marker="$${yaml_runtime_dir}/removing"
yaml_maintenance_created=0
yaml_maintenance_committed=0
snapshot_stage=""
upgrade_restore_required=0
upgrade_was_running=0
upgrade_workdir=""
upgrade_source_version="$${upgrade_source_version:-}"
maintenance_upgrade="$${maintenance_upgrade:-0}"
maintenance_source_version="$${maintenance_source_version:-}"
maintenance_marker_created=0
maintenance_config_created=0
maintenance_delta_created=0
maintenance_upgrade_committed=0

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

root_private_single_file() {
	local metadata mode links owner group
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_owned_directory_allow_writable() {
	local metadata owner group
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r _mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_owned_regular_file() {
	local metadata mode owner group
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	case "$$mode" in -?????????) ;; *) return 1 ;; esac
	[ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

path_contains_symlink() {
	local remaining="$${1#/}" component current=""
	while [ -n "$$remaining" ]; do
		component="$${remaining%%/*}"
		current="$${current}/$${component}"
		[ ! -L "$$current" ] || return 0
		[ "$$remaining" = "$$component" ] && break
		remaining="$${remaining#*/}"
	done
	return 1
}

trusted_mnt_ancestors() {
	local value="$${1%/}" parent remaining component current
	case "$$value" in /mnt/*/*) ;; *) return 1 ;; esac
	parent="$${value%/*}"
	[ "$$parent" != /mnt ] || return 1
	current=/mnt
	root_owned_safe_directory "$$current" || return 1
	remaining="$${parent#/mnt/}"
	while [ -n "$$remaining" ]; do
		component="$${remaining%%/*}"
		current="$${current}/$${component}"
		root_owned_safe_directory "$$current" || return 1
		[ "$$remaining" = "$$component" ] && break
		remaining="$${remaining#*/}"
	done
}

valid_upgrade_workdir_path() {
	local value="$$1" parent leaf
	case "$$value" in
		""|/|//*|*//*|*/) return 1 ;;
		/*) ;;
		*) return 1 ;;
	esac
	case "$$value" in *[!A-Za-z0-9_./+@%:,=-]*) return 1 ;; esac
	case "$${value}/" in */./*|*/../*) return 1 ;; esac
	parent="$${value%/*}"
	leaf="$${value##*/}"
	case "$$leaf" in AdGuardHome|AdGuardHome-?*) ;; *) return 1 ;; esac
	case "$$parent" in
		/etc) root_owned_directory_allow_writable /etc || return 1 ;;
		/mnt/*) trusted_mnt_ancestors "$$value" || return 1 ;;
		*) return 1 ;;
	esac
	[ -d "$$value" ] && [ ! -L "$$value" ] || return 1
	! path_contains_symlink "$$value"
}

upgrade_workdir_metadata() {
	local metadata mode owner group
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	case "$$owner:$$group:$$mode" in
		0:0:drwx------|0:853:drwx------|853:853:drwx------) ;;
		*) return 1 ;;
	esac
}

upgrade_yaml_metadata() {
	local metadata mode links owner group size
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group size _remainder <<-EOF
	$$metadata
	EOF
	[ "$$links" = 1 ] || return 1
	case "$$owner:$$group:$$mode" in
		0:0:-rw-------|0:853:-rw-r-----|853:853:-rw-------|853:853:-rw-r-----) ;;
		*) return 1 ;;
	esac
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ]
}

upgrade_source_anchors_match() {
	local value="$$1" upper_work lower_work lower_config
	upper_work="$$(uci -q get AdGuardHome.AdGuardHome.workdir)" || return 1
	lower_work="$$(uci -q get adguardhome.config.work_dir)" || return 1
	lower_config="$$(uci -q get adguardhome.config.config_file)" || return 1
	[ "$$upper_work" = "$$value" ] && [ "$$lower_work" = "$$value" ] &&
		[ "$$lower_config" = "$${value}/AdGuardHome.yaml" ]
}

legacy_memory_source_deltas_safe() {
	local changes line package count=0 seen_config=0 seen_work=0
	local effective_config effective_work memory_status
	for package in AdGuardHome dhcp firewall; do
		[ -z "$$(uci -q changes "$$package" 2>/dev/null)" ] || return 1
	done
	changes="$$(uci -q changes adguardhome 2>/dev/null)" || return 1
	while IFS= read -r line; do
		[ -n "$$line" ] || continue
		count=$$((count + 1))
		case "$$line" in
			"adguardhome.config.config_file='/tmp/luci-app-adguardhome-memory/work/AdGuardHome.yaml'")
				[ "$$seen_config" = 0 ] || return 1
				seen_config=1
				;;
			"adguardhome.config.work_dir='/tmp/luci-app-adguardhome-memory/work'")
				[ "$$seen_work" = 0 ] || return 1
				seen_work=1
				;;
			*) return 1 ;;
		esac
	done <<-EOF
	$$changes
	EOF
	[ "$$count" -le 2 ] 2>/dev/null || return 1
	effective_config="$$(uci -q get adguardhome.config.config_file)"
	effective_work="$$(uci -q get adguardhome.config.work_dir)"
	if [ "$$effective_config" = /tmp/luci-app-adguardhome-memory/work/AdGuardHome.yaml ] ||
	   [ "$$effective_work" = /tmp/luci-app-adguardhome-memory/work ]; then
		[ "$$effective_config" = /tmp/luci-app-adguardhome-memory/work/AdGuardHome.yaml ] &&
			[ "$$effective_work" = /tmp/luci-app-adguardhome-memory/work ] || return 1
		memory_status="$$(/etc/init.d/AdGuardHome memory_status 2>/dev/null)" || return 1
		printf '%s\n' "$$memory_status" | grep -qx 'active=1' &&
			printf '%s\n' "$$memory_status" | grep -qx \
			'active_config_file=/tmp/luci-app-adguardhome-memory/work/AdGuardHome.yaml'
		return
	fi
	[ "$$count" = 0 ]
}

stop_memory_source_for_cold_upgrade() {
	local upper_enabled wrapper_rc=0 running_rc=0
	case "$$upgrade_source_version" in
		2.2.0-r1|2.2.0-r2|2.3.0-r1) ;;
		*) return 1 ;;
	esac
	[ -x /etc/init.d/AdGuardHome ] && [ -f /etc/init.d/AdGuardHome ] &&
		[ ! -L /etc/init.d/AdGuardHome ] &&
		root_owned_regular_file /etc/init.d/AdGuardHome || return 1
	[ -x /etc/init.d/adguardhome ] && [ -f /etc/init.d/adguardhome ] &&
		[ ! -L /etc/init.d/adguardhome ] &&
		root_owned_regular_file /etc/init.d/adguardhome || return 1
	legacy_memory_source_deltas_safe || return 1
	upper_enabled="$$(uci -q get AdGuardHome.AdGuardHome.enabled)" || return 1
	case "$$upper_enabled" in 0|1) ;; *) return 1 ;; esac
	# The registered coordinator is the durable running-state authority.  Its
	# monitor remains registered while the lower procd instance is between
	# respawns, so sampling only the core PID would incorrectly preserve that
	# installation as stopped.
	maintenance_wrapper_registered || wrapper_rc=$$?
	case "$$wrapper_rc" in
		0)
			[ "$$upper_enabled" = 1 ] || return 1
			upgrade_was_running=1
			;;
		1) upgrade_was_running=0 ;;
		*) return 1 ;;
	esac
	run_bounded 5 1 /etc/init.d/adguardhome running \
		>/dev/null 2>&1 || running_rc=$$?
	case "$$wrapper_rc:$$running_rc" in
		0:0|0:1) ;;
		1:1) ;;
		*) return 1 ;;
	esac
	# The installed wrapper owns the only safe conversion from its optional
	# RAM YAML generation to a persistent YAML plus durable data checkpoint.
	run_bounded 180 5 /etc/init.d/AdGuardHome stop \
		>/dev/null 2>&1 || return 1
	running_rc=0
	run_bounded 5 1 /etc/init.d/adguardhome running \
		>/dev/null 2>&1 || running_rc=$$?
	[ "$$running_rc" = 1 ]
}

prepare_upgrade_snapshot_source() {
	local upper_enabled running_rc=0
	[ -x /etc/init.d/AdGuardHome ] && [ -f /etc/init.d/AdGuardHome ] &&
		[ ! -L /etc/init.d/AdGuardHome ] &&
		root_owned_regular_file /etc/init.d/AdGuardHome || return 1
	[ -x /etc/init.d/adguardhome ] && [ -f /etc/init.d/adguardhome ] &&
		[ ! -L /etc/init.d/adguardhome ] &&
		root_owned_regular_file /etc/init.d/adguardhome || return 1
	upgrade_workdir="$$(uci -q get AdGuardHome.AdGuardHome.workdir)" || return 1
	valid_upgrade_workdir_path "$$upgrade_workdir" || return 1
	upper_enabled="$$(uci -q get AdGuardHome.AdGuardHome.enabled)" || return 1
	case "$$upper_enabled" in 0|1) ;; *) return 1 ;; esac
	case "$$upgrade_source_version" in
		2.1.0-r1)
			run_bounded 5 1 /etc/init.d/adguardhome running \
				>/dev/null 2>&1 || running_rc=$$?
			case "$$running_rc" in
				0)
					[ "$$upper_enabled" = 1 ] || return 1
					upgrade_was_running=1
					;;
				1) upgrade_was_running=0 ;;
				*) return 1 ;;
			esac
			;;
		2.2.0-r1|2.2.0-r2|2.3.0-r1)
			case "$$upgrade_was_running" in 0|1) ;; *) return 1 ;; esac
			running_rc=0
			run_bounded 5 1 /etc/init.d/adguardhome running \
				>/dev/null 2>&1 || running_rc=$$?
			[ "$$running_rc" = 1 ] || return 1
			;;
		*) return 1 ;;
	esac
	upgrade_source_anchors_match "$$upgrade_workdir" || return 1
	upgrade_workdir_metadata "$$upgrade_workdir" || return 1
	upgrade_yaml_metadata "$${upgrade_workdir}/AdGuardHome.yaml" || return 1
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
	run_bounded 5 1 /bin/dd if="$$fd_path" \
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

ensure_no_official_pending_delta() {
	local delta_dir=/tmp/.uci delta_file=/tmp/.uci/adguardhome
	if [ ! -e "$$delta_dir" ] && [ ! -L "$$delta_dir" ]; then
		return 0
	fi
	root_private_directory "$$delta_dir" || return 1
	if [ -e "$$delta_file" ] || [ -L "$$delta_file" ]; then
		# ImmortalWrt's UCI commit truncates its saved delta to zero bytes but
		# may leave the file in place.  That is committed state, not a pending
		# user change; accept only the exact root-private empty-file form.
		root_private_empty_file "$$delta_file" && return 0
		echo "Pending official adguardhome UCI changes must be committed or reverted before installing this plugin." >&2
		return 1
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
	if ! run_bounded 5 1 uci -q -c "$$stage" \
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
		run_bounded 5 1 /etc/init.d/adguardhome running \
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

private_single_file_at_most() {
	local size
	root_private_single_file "$$1" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -le "$$2" ]
}

private_single_file_between() {
	local size
	private_single_file_at_most "$$1" "$$3" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	[ "$$size" -ge "$$2" ]
}

validate_cold_postinst_state() {
	local line1 line2 line3 extra entry source_version was_running
	validate_runtime_parent || return 1
	root_private_directory "$$cold_postinst_dir" || return 1
	root_private_single_file "$$cold_postinst_state" || return 1
	private_single_file_between "$$cold_postinst_state" 1 256 || return 1
	{
		IFS= read -r line1 && IFS= read -r line2 &&
			IFS= read -r line3 && ! IFS= read -r extra
	} <"$$cold_postinst_state" || return 1
	[ "$$line1" = format=1 ] || return 1
	case "$$line2" in
		source_version=2.1.0-r1|source_version=2.2.0-r1|source_version=2.2.0-r2|source_version=2.3.0-r1)
			source_version="$${line2#*=}"
			;;
		*) return 1 ;;
	esac
	case "$$line3" in
		was_running=0|was_running=1) was_running="$${line3#*=}" ;;
		*) return 1 ;;
	esac
	[ "$$source_version" = "$$upgrade_source_version" ] &&
		[ "$$was_running" = "$$upgrade_was_running" ] || return 1
	for entry in \
		"$$cold_postinst_dir"/* \
		"$$cold_postinst_dir"/.[!.]* \
		"$$cold_postinst_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		[ "$$entry" = "$$cold_postinst_state" ] || return 1
	done
}

write_cold_postinst_state() {
	local stage
	[ ! -e "$$cold_postinst_dir" ] && [ ! -L "$$cold_postinst_dir" ] || return 1
	validate_runtime_parent || return 1
	mkdir -m 0700 "$$cold_postinst_dir" || return 1
	cold_postinst_dir_created=1
	chown 0:0 "$$cold_postinst_dir" && chmod 0700 "$$cold_postinst_dir" || return 1
	root_private_directory "$$cold_postinst_dir" || return 1
	stage="$$(mktemp "$$cold_postinst_dir/.cold-upgrade.XXXXXX")" || return 1
	case "$$stage" in "$$cold_postinst_dir"/.cold-upgrade.??????) ;; *) return 1 ;; esac
	{
		printf 'format=1\n'
		printf 'source_version=%s\n' "$$upgrade_source_version"
		printf 'was_running=%s\n' "$$upgrade_was_running"
	} >"$$stage" || return 1
	chown 0:0 "$$stage" && chmod 0600 "$$stage" || return 1
	private_single_file_between "$$stage" 1 256 || return 1
	[ ! -e "$$cold_postinst_state" ] && [ ! -L "$$cold_postinst_state" ] || return 1
	mv "$$stage" "$$cold_postinst_state" || return 1
	validate_cold_postinst_state
}

cleanup_cold_postinst_state() {
	local entry cleanup_rc=0
	[ "$$cold_postinst_committed" != 1 ] || return 0
	[ "$$cold_postinst_dir_created" = 1 ] || return 0
	root_private_directory "$$cold_postinst_dir" || return 1
	for entry in \
		"$$cold_postinst_dir"/* \
		"$$cold_postinst_dir"/.[!.]* \
		"$$cold_postinst_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		case "$$entry" in
			"$$cold_postinst_state"|"$$cold_postinst_dir"/.cold-upgrade.??????)
				root_private_single_file "$$entry" || {
					cleanup_rc=1
					continue
				}
				rm -f "$$entry" || cleanup_rc=1
				;;
			*) cleanup_rc=1 ;;
		esac
	done
	[ "$$cleanup_rc" = 0 ] && rmdir "$$cold_postinst_dir" || cleanup_rc=1
	return "$$cleanup_rc"
}

valid_runtime_temp_name() {
	local entry="$$1" suffix
	case "$$entry" in
		"$$runtime_dir"/.upgrade-active.yaml.??????|\
		"$$runtime_dir"/.upgrade-verify.yaml.??????|\
		"$$runtime_dir"/.upgrade-workdir.meta.??????) ;;
		*) return 1 ;;
	esac
	suffix="$${entry##*.}"
	case "$$suffix" in ??????) ;; *) return 1 ;; esac
	case "$$suffix" in *[!A-Za-z0-9]*) return 1 ;; esac
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
			"$$upgrade_marker"|"$$init_enabled_marker")
				private_single_file_between "$$entry" 1 64 || return 1
				;;
			"$$upgrade_yaml_snapshot")
				private_single_file_between "$$entry" 1 524288 || return 1
				;;
			"$$upgrade_workdir_metadata")
				private_single_file_between "$$entry" 1 4096 || return 1
				;;
			"$$runtime_dir"/.upgrade-active.yaml.??????|\
			"$$runtime_dir"/.upgrade-verify.yaml.??????)
				valid_runtime_temp_name "$$entry" &&
					private_single_file_at_most "$$entry" 524288 || return 1
				;;
			"$$runtime_dir"/.upgrade-workdir.meta.??????)
				valid_runtime_temp_name "$$entry" &&
					private_single_file_at_most "$$entry" 4096 || return 1
				;;
			*) return 1 ;;
		esac
	done
}

clear_upgrade_snapshot_artifacts() {
	local entry
	validate_runtime_dir || return 1
	rm -f "$$upgrade_yaml_snapshot" "$$upgrade_workdir_metadata" \
		"$$runtime_dir"/.upgrade-active.yaml.?????? \
		"$$runtime_dir"/.upgrade-verify.yaml.?????? \
		"$$runtime_dir"/.upgrade-workdir.meta.?????? || return 1
	for entry in \
		"$$upgrade_yaml_snapshot" \
		"$$upgrade_workdir_metadata" \
		"$$runtime_dir"/.upgrade-active.yaml.?????? \
		"$$runtime_dir"/.upgrade-verify.yaml.?????? \
		"$$runtime_dir"/.upgrade-workdir.meta.??????; do
		[ ! -e "$$entry" ] && [ ! -L "$$entry" ] || return 1
	done
}

fd_directory_metadata_matches() {
	local metadata mode owner group
	metadata="$$(LC_ALL=C ls -ldnL "$$1" 2>/dev/null)" || return 1
	read -r mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "$$2" ] && [ "$$owner" = "$$3" ] && [ "$$group" = "$$4" ]
}

adguard_uid_process_exists() {
	local status uids
	for status in /proc/[0-9]*/task/[0-9]*/status; do
		if [ ! -r "$$status" ]; then
			[ ! -e "$$status" ] && continue
			return 0
		fi
		uids="$$(awk '$$1 == "Uid:" {
			if (NF != 5) exit 2
			for (i=2; i<=5; i++) if ($$i !~ /^[0-9]+$$/) exit 2
			print $$2, $$3, $$4, $$5; found=1; exit }
			END { if (!found) exit 1 }' "$$status" 2>/dev/null)" || {
			[ ! -e "$$status" ] && continue
			return 0
		}
		case " $$uids " in *" 853 "*) return 0 ;; esac
	done
	return 1
}

snapshot_sha256() {
	local digest
	command -v sha256sum >/dev/null 2>&1 || return 1
	digest="$$(sha256sum "$$1" 2>/dev/null)" || return 1
	digest="$${digest%% *}"
	[ "$${#digest}" -eq 64 ] || return 1
	case "$$digest" in *[!0-9a-f]*) return 1 ;; esac
	printf '%s\n' "$$digest"
}

# The supported cold-upgrade core is stopped before this transaction.  Hold the exact
# persistent workdir inode and capture the active YAML twice without changing
# its metadata.  A service-owned namespace is read only by uid 853 through the
# inherited directory descriptor, so root never opens a replaceable pathname.
# No data subtree is traversed or copied here.
cold_snapshot_upgrade_yaml() (
	snapshot_workdir="$$1"
	snapshot_config="$${snapshot_workdir}/AdGuardHome.yaml"
	snapshot_workdir_fd=""
	snapshot_config_fd=""
	snapshot_original_owner=""
	snapshot_original_group=""
	snapshot_committed=0
	snapshot_yaml_tmp=""
	snapshot_verify_tmp=""
	snapshot_meta_tmp=""

	cleanup_cold_upgrade_snapshot() {
		snapshot_primary_rc="$$1"
		snapshot_cleanup_rc=0
		for snapshot_temporary in \
			"$$snapshot_yaml_tmp" "$$snapshot_verify_tmp" "$$snapshot_meta_tmp"; do
			[ -n "$$snapshot_temporary" ] || continue
			case "$$snapshot_temporary" in
				"$$runtime_dir"/.upgrade-active.yaml.??????|\
				"$$runtime_dir"/.upgrade-verify.yaml.??????|\
				"$$runtime_dir"/.upgrade-workdir.meta.??????)
					rm -f "$$snapshot_temporary" || snapshot_cleanup_rc=1
					;;
				*) snapshot_cleanup_rc=1 ;;
			esac
		done
		if [ "$$snapshot_primary_rc" -ne 0 ] ||
		   [ "$$snapshot_cleanup_rc" -ne 0 ] ||
		   [ "$$snapshot_committed" != 1 ]; then
			rm -f "$$upgrade_yaml_snapshot" "$$upgrade_workdir_metadata" ||
				snapshot_cleanup_rc=1
		fi
		if [ "$$snapshot_primary_rc" -ne 0 ]; then
			return "$$snapshot_primary_rc"
		fi
		return "$$snapshot_cleanup_rc"
	}

	cold_upgrade_snapshot_on_exit() {
		snapshot_exit_rc=$$?
		trap '' 0 HUP INT TERM
		snapshot_exit_final_rc=0
		cleanup_cold_upgrade_snapshot "$$snapshot_exit_rc" ||
			snapshot_exit_final_rc=$$?
		exit "$$snapshot_exit_final_rc"
	}

	trap cold_upgrade_snapshot_on_exit 0
	trap 'exit 1' HUP INT TERM
	validate_runtime_dir || exit 1
	[ ! -e "$$upgrade_yaml_snapshot" ] && [ ! -L "$$upgrade_yaml_snapshot" ] || exit 1
	[ ! -e "$$upgrade_workdir_metadata" ] && [ ! -L "$$upgrade_workdir_metadata" ] || exit 1
	case "$$upgrade_source_version" in
		2.1.0-r1|2.2.0-r1|2.2.0-r2|2.3.0-r1) ;;
		*) exit 1 ;;
	esac
	valid_upgrade_workdir_path "$$snapshot_workdir" || exit 1
	upgrade_source_anchors_match "$$snapshot_workdir" || exit 1
	upgrade_workdir_metadata "$$snapshot_workdir" || exit 1

	exec 7<"$$snapshot_workdir" || exit 1
	snapshot_workdir_fd=/proc/self/fd/7
	[ -d "$$snapshot_workdir_fd" ] &&
		[ "$$snapshot_workdir_fd" -ef "$$snapshot_workdir" ] || exit 1
	snapshot_directory_metadata="$$(LC_ALL=C ls -ldnL \
		"$$snapshot_workdir_fd" 2>/dev/null)" || exit 1
	read -r snapshot_directory_mode _snapshot_directory_links \
		snapshot_original_owner snapshot_original_group \
		_snapshot_directory_remainder <<-EOF
	$$snapshot_directory_metadata
	EOF
	case "$$snapshot_original_owner:$$snapshot_original_group:$$snapshot_directory_mode" in
		0:0:drwx------|0:853:drwx------|853:853:drwx------) ;;
		*) exit 1 ;;
	esac
	adguard_uid_process_exists && exit 1
	[ "$$snapshot_workdir_fd" -ef "$$snapshot_workdir" ] &&
		fd_directory_metadata_matches "$$snapshot_workdir_fd" drwx------ \
			"$$snapshot_original_owner" "$$snapshot_original_group" || exit 1

	upgrade_yaml_metadata "$$snapshot_config" || exit 1
	snapshot_config_metadata="$$(LC_ALL=C ls -ldn \
		"$$snapshot_config" 2>/dev/null)" || exit 1
	read -r snapshot_config_mode snapshot_config_links snapshot_config_owner \
		snapshot_config_group snapshot_config_size _snapshot_config_remainder <<-EOF
	$$snapshot_config_metadata
	EOF
	[ "$$snapshot_config_links" = 1 ] || exit 1
	case "$$snapshot_config_owner:$$snapshot_config_group:$$snapshot_config_mode" in
		0:0:-rw-------|0:853:-rw-r-----|853:853:-rw-------|853:853:-rw-r-----) ;;
		*) exit 1 ;;
	esac
	case "$$snapshot_config_size" in ""|*[!0-9]*) exit 1 ;; esac
	[ "$$snapshot_config_size" -gt 0 ] &&
		[ "$$snapshot_config_size" -le 524288 ] || exit 1

	umask 077
	snapshot_yaml_tmp="$$(mktemp \
		"$$runtime_dir/.upgrade-active.yaml.XXXXXX")" || exit 1
	snapshot_verify_tmp="$$(mktemp \
		"$$runtime_dir/.upgrade-verify.yaml.XXXXXX")" || exit 1
	snapshot_meta_tmp="$$(mktemp \
		"$$runtime_dir/.upgrade-workdir.meta.XXXXXX")" || exit 1
	valid_runtime_temp_name "$$snapshot_yaml_tmp" &&
		valid_runtime_temp_name "$$snapshot_verify_tmp" &&
		valid_runtime_temp_name "$$snapshot_meta_tmp" || exit 1
	chown 0:0 "$$snapshot_yaml_tmp" "$$snapshot_verify_tmp" "$$snapshot_meta_tmp" &&
		chmod 0600 "$$snapshot_yaml_tmp" "$$snapshot_verify_tmp" \
			"$$snapshot_meta_tmp" || exit 1

	case "$$snapshot_original_owner" in
		853)
			run_bounded 5 1 \
				/sbin/start-stop-daemon -S -c 853:853 -n AGHUpgradeRead \
				-x /bin/dd -- if="$$snapshot_workdir_fd/AdGuardHome.yaml" \
				bs=4096 count=129 >"$$snapshot_yaml_tmp" 2>/dev/null || exit 1
			run_bounded 5 1 \
				/sbin/start-stop-daemon -S -c 853:853 -n AGHUpgradeRead \
				-x /bin/dd -- if="$$snapshot_workdir_fd/AdGuardHome.yaml" \
				bs=4096 count=129 >"$$snapshot_verify_tmp" 2>/dev/null || exit 1
			;;
		0)
			exec 8<"$$snapshot_config" || exit 1
			snapshot_config_fd=/proc/self/fd/8
			[ -f "$$snapshot_config_fd" ] &&
				[ "$$snapshot_config_fd" -ef "$$snapshot_config" ] || exit 1
			run_bounded 5 1 /bin/dd if="$$snapshot_config_fd" \
				bs=4096 count=129 of="$$snapshot_yaml_tmp" 2>/dev/null || exit 1
			run_bounded 5 1 /bin/dd if="$$snapshot_config_fd" \
				bs=4096 count=129 of="$$snapshot_verify_tmp" 2>/dev/null || exit 1
			[ "$$snapshot_config_fd" -ef "$$snapshot_config" ] || exit 1
			;;
		*) exit 1 ;;
	esac
	[ "$$snapshot_workdir_fd" -ef "$$snapshot_workdir" ] || exit 1
	fd_directory_metadata_matches "$$snapshot_workdir_fd" drwx------ \
		"$$snapshot_original_owner" "$$snapshot_original_group" || exit 1
	upgrade_yaml_metadata "$$snapshot_config" || exit 1
	[ "$$(LC_ALL=C ls -ldn "$$snapshot_config" 2>/dev/null)" = \
		"$$snapshot_config_metadata" ] || exit 1
	private_single_file_between "$$snapshot_yaml_tmp" 1 524288 &&
		private_single_file_between "$$snapshot_verify_tmp" 1 524288 || exit 1
	cmp -s "$$snapshot_yaml_tmp" "$$snapshot_verify_tmp" || exit 1
	snapshot_yaml_size="$$(wc -c <"$$snapshot_yaml_tmp" 2>/dev/null)" || exit 1
	[ "$$snapshot_yaml_size" = "$$snapshot_config_size" ] || exit 1
	snapshot_yaml_hash="$$(snapshot_sha256 "$$snapshot_yaml_tmp")" || exit 1
	[ "$$(snapshot_sha256 "$$snapshot_verify_tmp")" = "$$snapshot_yaml_hash" ] || exit 1

	{
		printf 'format=1\n'
		printf 'source_version=%s\n' "$$upgrade_source_version"
		printf 'workdir=%s\n' "$$snapshot_workdir"
		printf 'uid=%s\n' "$$snapshot_original_owner"
		printf 'gid=%s\n' "$$snapshot_original_group"
		printf 'mode=0700\n'
		printf 'config_file=%s\n' "$$snapshot_config"
		printf 'yaml_sha256=%s\n' "$$snapshot_yaml_hash"
		printf 'yaml_size=%s\n' "$$snapshot_yaml_size"
		printf 'was_running=%s\n' "$$upgrade_was_running"
	} >"$$snapshot_meta_tmp" || exit 1
	chown 0:0 "$$snapshot_meta_tmp" && chmod 0600 "$$snapshot_meta_tmp" || exit 1
	private_single_file_between "$$snapshot_meta_tmp" 1 4096 || exit 1
	[ "$$(wc -l <"$$snapshot_meta_tmp" 2>/dev/null)" = 10 ] || exit 1

	rm -f "$$snapshot_verify_tmp" || exit 1
	snapshot_verify_tmp=""
	mv "$$snapshot_yaml_tmp" "$$upgrade_yaml_snapshot" || exit 1
	snapshot_yaml_tmp=""
	mv "$$snapshot_meta_tmp" "$$upgrade_workdir_metadata" || exit 1
	snapshot_meta_tmp=""
	private_single_file_between "$$upgrade_yaml_snapshot" 1 524288 &&
		private_single_file_between "$$upgrade_workdir_metadata" 1 4096 || exit 1
	[ "$$(snapshot_sha256 "$$upgrade_yaml_snapshot")" = "$$snapshot_yaml_hash" ] || exit 1
	[ "$$(wc -c <"$$upgrade_yaml_snapshot" 2>/dev/null)" = \
		"$$snapshot_yaml_size" ] || exit 1
	snapshot_committed=1

	trap '' 0 HUP INT TERM
	snapshot_final_rc=0
	cleanup_cold_upgrade_snapshot 0 || snapshot_final_rc=$$?
	exit "$$snapshot_final_rc"
)

write_runtime_marker() {
	local marker="$$1"
	case "$$marker" in "$$runtime_dir"/*) ;; *) return 1 ;; esac
	[ ! -e "$$marker" ] && [ ! -L "$$marker" ] || rm -f "$$marker" || return 1
	printf '1\n' >"$$marker" || return 1
	chown 0:0 "$$marker" && chmod 0600 "$$marker" || return 1
	root_private_file "$$marker" &&
		[ "$$(wc -c <"$$marker" 2>/dev/null)" = 2 ] && grep -qx '1' "$$marker"
}

runtime_dir_is_empty() {
	local entry
	validate_runtime_dir || return 1
	for entry in \
		"$$runtime_dir"/* \
		"$$runtime_dir"/.[!.]* \
		"$$runtime_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		return 1
	done
}

# Treat a procd instance in its respawn delay as running by checking whether
# the expected monitor is registered, rather than relying on its transient PID.
# Return 0 for the exact coordinator instance, 1 when the service is absent,
# and 2 for an unreadable or unexpected service object.
maintenance_wrapper_registered() {
	local payload command0 command1
	payload="$$(run_bounded 5 1 ubus -S call service list \
		'{"name":"AdGuardHome"}' 2>/dev/null)" || return 2
	if ! printf '%s\n' "$$payload" |
	     jsonfilter -e '@.AdGuardHome.instances.monitor' >/dev/null 2>&1; then
		# An empty or absent uppercase service is stopped.  Any differently
		# named instance is unexpected and must not be mistaken for that state.
		if printf '%s\n' "$$payload" |
		   jsonfilter -e '@.AdGuardHome.instances.*' >/dev/null 2>&1; then
			return 2
		fi
		return 1
	fi
	command0="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.command[0]' 2>/dev/null)" || return 2
	command1="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.command[1]' 2>/dev/null)" || return 2
	[ "$$command0" = /etc/init.d/AdGuardHome ] &&
		[ "$$command1" = monitor ] && return 0
	return 2
}

capture_maintenance_delta() (
	local source=/tmp/.uci/adguardhome target="$$1" source_fd=/proc/self/fd/8
	root_private_directory /tmp/.uci || exit 1
	root_private_single_file "$$source" || exit 1
	exec 8<"$$source" || exit 1
	[ -f "$$source_fd" ] && [ "$$source_fd" -ef "$$source" ] || exit 1
	run_bounded 5 1 /bin/dd if="$$source_fd" of="$$target" \
		bs=4096 count=129 2>/dev/null || exit 1
	chown 0:0 "$$target" && chmod 0600 "$$target" || exit 1
	root_private_single_file "$$target" || exit 1
	[ "$$(wc -c <"$$target" 2>/dev/null)" -le 524288 ] 2>/dev/null || exit 1
	[ "$$source_fd" -ef "$$source" ] && cmp -s "$$source_fd" "$$target"
)

maintenance_upgrade_bundle_valid() {
	local line1 line2 line3 line4 line5 line6 line7 line8 extra entry
	local wrapper_running delta_present config_hash config_size delta_hash delta_size
	root_private_single_file "$$maintenance_upgrade_marker" || return 1
	private_single_file_between "$$maintenance_upgrade_marker" 1 4096 || return 1
	{
		IFS= read -r line1 && IFS= read -r line2 &&
		IFS= read -r line3 && IFS= read -r line4 &&
		IFS= read -r line5 && IFS= read -r line6 &&
		IFS= read -r line7 && IFS= read -r line8 &&
		! IFS= read -r extra
	} <"$$maintenance_upgrade_marker" || return 1
	[ "$$line1" = format=1 ] || return 1
	case "$$line2" in
		source_version=2.2.0-r1|source_version=2.2.0-r2) ;;
		*) return 1 ;;
	esac
	[ -z "$$maintenance_source_version" ] ||
		[ "$$line2" = "source_version=$$maintenance_source_version" ] || return 1
	case "$$line3" in wrapper_running=0|wrapper_running=1)
		wrapper_running="$${line3#*=}" ;; *) return 1 ;; esac
	case "$$line4" in delta_present=0|delta_present=1)
		delta_present="$${line4#*=}" ;; *) return 1 ;; esac
	case "$$line5" in config_sha256=*) config_hash="$${line5#*=}" ;; *) return 1 ;; esac
	case "$$line6" in config_size=*) config_size="$${line6#*=}" ;; *) return 1 ;; esac
	case "$$line7" in delta_sha256=*) delta_hash="$${line7#*=}" ;; *) return 1 ;; esac
	case "$$line8" in delta_size=*) delta_size="$${line8#*=}" ;; *) return 1 ;; esac
	case "$$config_hash" in *[!0-9a-f]*|'') return 1 ;; esac
	[ "$${#config_hash}" = 64 ] || return 1
	case "$$config_size" in ''|*[!0-9]*) return 1 ;; esac
	private_single_file_between "$$maintenance_config_snapshot" 1 524288 || return 1
	[ "$$(wc -c <"$$maintenance_config_snapshot")" = "$$config_size" ] &&
		[ "$$(snapshot_sha256 "$$maintenance_config_snapshot")" = "$$config_hash" ] || return 1
	case "$$delta_present" in
		0)
			[ "$$delta_hash" = none ] && [ "$$delta_size" = 0 ] &&
				[ ! -e "$$maintenance_delta_snapshot" ] &&
				[ ! -L "$$maintenance_delta_snapshot" ] || return 1
			;;
		1)
			case "$$delta_hash" in *[!0-9a-f]*|'') return 1 ;; esac
			[ "$${#delta_hash}" = 64 ] || return 1
			case "$$delta_size" in ''|*[!0-9]*) return 1 ;; esac
			private_single_file_at_most "$$maintenance_delta_snapshot" 524288 || return 1
			[ "$$(wc -c <"$$maintenance_delta_snapshot")" = "$$delta_size" ] &&
				[ "$$(snapshot_sha256 "$$maintenance_delta_snapshot")" = "$$delta_hash" ] || return 1
			;;
	esac
	for entry in \
		"$$runtime_dir"/* \
		"$$runtime_dir"/.[!.]* \
		"$$runtime_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		case "$$entry" in
			"$$maintenance_upgrade_marker"|"$$maintenance_config_snapshot") ;;
			"$$maintenance_delta_snapshot")
				[ "$$delta_present" = 1 ] || return 1 ;;
			*) return 1 ;;
		esac
	done
	MAINTENANCE_WRAPPER_RUNNING="$$wrapper_running"
	MAINTENANCE_DELTA_PRESENT="$$delta_present"
}

write_maintenance_upgrade_marker() {
	local wrapper_running="$$1" delta_present="$$2" config_hash config_size
	local delta_hash=none delta_size=0
	case "$$wrapper_running:$$delta_present" in [01]:[01]) ;; *) return 1 ;; esac
	case "$$maintenance_source_version" in 2.2.0-r1|2.2.0-r2) ;; *) return 1 ;; esac
	config_hash="$$(snapshot_sha256 "$$maintenance_config_snapshot")" || return 1
	config_size="$$(wc -c <"$$maintenance_config_snapshot")" || return 1
	if [ "$$delta_present" = 1 ]; then
		delta_hash="$$(snapshot_sha256 "$$maintenance_delta_snapshot")" || return 1
		delta_size="$$(wc -c <"$$maintenance_delta_snapshot")" || return 1
	fi
	[ ! -e "$$maintenance_upgrade_marker" ] &&
		[ ! -L "$$maintenance_upgrade_marker" ] || return 1
	{
		printf 'format=1\n'
		printf 'source_version=%s\n' "$$maintenance_source_version"
		printf 'wrapper_running=%s\n' "$$wrapper_running"
		printf 'delta_present=%s\n' "$$delta_present"
		printf 'config_sha256=%s\n' "$$config_hash"
		printf 'config_size=%s\n' "$$config_size"
		printf 'delta_sha256=%s\n' "$$delta_hash"
		printf 'delta_size=%s\n' "$$delta_size"
	} >"$$maintenance_upgrade_marker" || return 1
	maintenance_marker_created=1
	chown 0:0 "$$maintenance_upgrade_marker" &&
		chmod 0600 "$$maintenance_upgrade_marker" || return 1
	maintenance_upgrade_bundle_valid
}

cleanup_maintenance_upgrade() {
	local cleanup_rc=0
	[ "$$maintenance_upgrade_committed" != 1 ] || return 0
	cleanup_yaml_maintenance
	if validate_runtime_dir; then
		if [ "$$maintenance_marker_created" = 1 ]; then
			rm -f "$$maintenance_upgrade_marker" || cleanup_rc=1
		fi
		if [ "$$maintenance_delta_created" = 1 ]; then
			rm -f "$$maintenance_delta_snapshot" || cleanup_rc=1
		fi
		if [ "$$maintenance_config_created" = 1 ]; then
			rm -f "$$maintenance_config_snapshot" || cleanup_rc=1
		fi
		rmdir "$$runtime_dir" 2>/dev/null || cleanup_rc=1
	elif [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; then
		cleanup_rc=1
	fi
	return "$$cleanup_rc"
}

maintenance_preinst_exit() {
	local primary_rc=$$? cleanup_rc=0
	trap '' 0 HUP INT TERM
	cleanup_maintenance_upgrade || cleanup_rc=$$?
	[ "$$primary_rc" -ne 0 ] && exit "$$primary_rc"
	exit "$$cleanup_rc"
}

restore_failed_upgrade() {
	local running_rc=0
	[ "$$upgrade_restore_required" = 1 ] || return 0
	[ "$$upgrade_was_running" = 1 ] || return 0
	run_bounded 150 5 /etc/init.d/AdGuardHome start \
		>/dev/null 2>&1 || return 1
	run_bounded 5 1 /etc/init.d/adguardhome running \
		>/dev/null 2>&1 || running_rc=$$?
	[ "$$running_rc" = 0 ] || return 1
	run_bounded 150 5 /etc/init.d/AdGuardHome do_redirect 1 \
		>/dev/null 2>&1
}

cleanup_upgrade_markers() {
	local cleanup_rc=0
	if ! restore_failed_upgrade; then
		echo "Unable to restore the previously running AdGuard Home service after the failed upgrade." >&2
		cleanup_rc=1
	fi
	cleanup_yaml_maintenance
	cleanup_snapshot_stage "$$snapshot_stage"
	if validate_runtime_dir; then
		clear_upgrade_snapshot_artifacts || cleanup_rc=1
		rm -f "$$upgrade_marker" "$$init_enabled_marker" || cleanup_rc=1
		rmdir "$$runtime_dir" 2>/dev/null || true
	elif [ "$$is_upgrade" = 1 ] &&
	     { [ -e "$$runtime_dir" ] || [ -L "$$runtime_dir" ]; }; then
		cleanup_rc=1
	fi
	return "$$cleanup_rc"
}

preinst_exit() {
	local primary_rc=$$? cleanup_rc=0
	trap '' 0 HUP INT TERM
	cleanup_upgrade_markers || cleanup_rc=$$?
	cleanup_cold_postinst_state || cleanup_rc=1
	[ "$$primary_rc" -ne 0 ] && exit "$$primary_rc"
	exit "$$cleanup_rc"
}

select_v22_upgrade_path() {
	local status requested active
	[ "$$maintenance_upgrade" = 1 ] || return 0
	case "$$maintenance_source_version" in 2.2.0-r1|2.2.0-r2) ;; *) return 1 ;; esac
	[ -x /etc/init.d/AdGuardHome ] && [ -f /etc/init.d/AdGuardHome ] &&
		[ ! -L /etc/init.d/AdGuardHome ] &&
		root_owned_regular_file /etc/init.d/AdGuardHome || return 1
	status="$$(run_bounded 180 5 /etc/init.d/AdGuardHome memory_status)" || return 1
	[ "$$(printf '%s\n' "$$status" | grep -c '^requested=')" = 1 ] || return 1
	[ "$$(printf '%s\n' "$$status" | grep -c '^active=')" = 1 ] || return 1
	requested="$$(printf '%s\n' "$$status" | sed -n 's/^requested=//p')"
	active="$$(printf '%s\n' "$$status" | sed -n 's/^active=//p')"
	case "$$requested:$$active" in
		0:0) return 0 ;;
		0:1|1:0|1:1)
			upgrade_source_version="$$maintenance_source_version"
			maintenance_source_version=""
			maintenance_upgrade=0
			return 0
			;;
		*) return 1 ;;
	esac
}

if [ -e "$$cold_postinst_dir" ] || [ -L "$$cold_postinst_dir" ]; then
	echo "Unfinished AdGuard Home cold-upgrade state exists; installation aborted." >&2
	exit 1
fi

select_v22_upgrade_path || {
	echo "Unable to determine the installed AdGuard Home memory layout; upgrade aborted." >&2
	exit 1
}

if [ "$$maintenance_upgrade" = 1 ]; then
	trap maintenance_preinst_exit 0
	trap 'exit 1' HUP INT TERM
	quiesce_yaml_updates || {
		echo "Unable to quiesce LuCI YAML updates; maintenance upgrade aborted." >&2
		exit 1
	}
	ensure_runtime_dir || {
		echo "Unable to create the private AdGuard Home lifecycle directory." >&2
		exit 1
	}
	if [ -e /tmp/.uci ] || [ -L /tmp/.uci ]; then
		root_private_directory /tmp/.uci || {
			echo "Unsafe UCI delta directory; maintenance upgrade aborted." >&2
			exit 1
		}
	else
		(umask 077; mkdir /tmp/.uci) || exit 1
		chown 0:0 /tmp/.uci && chmod 0700 /tmp/.uci || exit 1
		root_private_directory /tmp/.uci || exit 1
	fi
	if ! runtime_dir_is_empty; then
		maintenance_upgrade_bundle_valid || {
			echo "Unexpected AdGuard Home lifecycle state; maintenance upgrade aborted." >&2
			exit 1
		}
		maintenance_upgrade_committed=1
		yaml_maintenance_committed=1
		trap '' 0 HUP INT TERM
		exit 0
	fi
	wrapper_registered_rc=0
	maintenance_wrapper_registered || wrapper_registered_rc=$$?
	case "$$wrapper_registered_rc" in
		0) maintenance_wrapper_running=1 ;;
		1) maintenance_wrapper_running=0 ;;
		*)
			echo "Unable to determine the registered AdGuard Home coordinator state." >&2
			exit 1
			;;
	esac
	(umask 077; : >"$$maintenance_config_snapshot") || exit 1
	maintenance_config_created=1
	chown 0:0 "$$maintenance_config_snapshot" &&
		chmod 0600 "$$maintenance_config_snapshot" || exit 1
	capture_official_config "$$maintenance_config_snapshot" || {
		echo "Unable to snapshot the official AdGuard Home UCI file." >&2
		exit 1
	}
	maintenance_delta_present=0
	if [ -e /tmp/.uci/adguardhome ] || [ -L /tmp/.uci/adguardhome ]; then
		(umask 077; : >"$$maintenance_delta_snapshot") || exit 1
		maintenance_delta_created=1
		chown 0:0 "$$maintenance_delta_snapshot" &&
			chmod 0600 "$$maintenance_delta_snapshot" || exit 1
		capture_maintenance_delta "$$maintenance_delta_snapshot" || {
			echo "Unable to snapshot the active AdGuard Home UCI delta." >&2
			exit 1
		}
		maintenance_delta_present=1
	fi
	write_maintenance_upgrade_marker "$$maintenance_wrapper_running" \
		"$$maintenance_delta_present" || {
		echo "Unable to mark the AdGuard Home maintenance upgrade." >&2
		exit 1
	}
	maintenance_upgrade_committed=1
	yaml_maintenance_committed=1
	trap '' 0 HUP INT TERM
	exit 0
fi

trap preinst_exit 0
trap 'exit 1' HUP INT TERM
quiesce_yaml_updates || {
	echo "Unable to quiesce LuCI YAML updates; installation aborted." >&2
	exit 1
}
# A released RAM-YAML source owns an authenticated volatile lower-UCI delta.
# Stop through the still-installed wrapper before applying the ordinary
# no-pending-delta gate; every unrelated pending value remains visible and is
# still rejected.
case "$$upgrade_source_version" in
	2.2.0-r1|2.2.0-r2|2.3.0-r1)
	upgrade_restore_required=1
	stop_memory_source_for_cold_upgrade || {
		echo "Unable to stop and checkpoint the installed AdGuard Home RAM-YAML source; upgrade aborted." >&2
		exit 1
	}
	;;
esac
ensure_no_official_pending_delta || exit 1
ensure_original_snapshot || exit 1
is_upgrade=0
case "$${PKG_UPGRADE}:$$1" in
	1:*|*:upgrade) is_upgrade=1 ;;
esac
[ -f /usr/lib/opkg/info/luci-app-adguardhome.list ] && is_upgrade=1
[ -f /lib/apk/packages/luci-app-adguardhome.list ] && is_upgrade=1
[ "$$is_upgrade" = 1 ] || {
	yaml_maintenance_committed=1
	trap '' 0 HUP INT TERM
	cleanup_upgrade_markers || exit 1
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
clear_upgrade_snapshot_artifacts || {
	echo "Unable to clear stale AdGuard Home upgrade snapshots; upgrade aborted." >&2
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

# Arm rollback before validating the source so any later failure restarts a
# previously running coordinator through its still-present script.
upgrade_restore_required=1
prepare_upgrade_snapshot_source || {
	echo "The active AdGuard Home upgrade source or service state is not trustworthy; upgrade aborted." >&2
	exit 1
}

# Every path below may change resolver or runtime state.  An EXIT cleanup will
# restart a previously running supported installation unless preinst commits the
# cold upgrade snapshot successfully.

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
	run_bounded 20 2 /etc/init.d/adguardhome stop \
		>/dev/null 2>&1 || {
		echo "Unable to stop the packaged AdGuard Home service; upgrade aborted." >&2
		exit 1
	}
	lower_running_rc=0
	run_bounded 5 1 /etc/init.d/adguardhome running \
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

cold_snapshot_upgrade_yaml "$$upgrade_workdir" || {
	echo "Unable to capture a stable private snapshot of the active AdGuard Home YAML; upgrade aborted." >&2
	exit 1
}
write_cold_postinst_state || {
	echo "Unable to publish the private AdGuard Home cold-upgrade completion state; upgrade aborted." >&2
	exit 1
}

trap '' 0 HUP INT TERM
upgrade_restore_required=0
cold_postinst_committed=1
yaml_maintenance_committed=1
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

# ImmortalWrt's default_postinst ignores init start failures.  Bound the final
# cold-upgrade convergence check without an external timeout package so an APK
# transaction cannot report success while the coordinator is still unusable.
run_bounded() (
	local limit="$$1" grace="$$2" marker="" child="" watchdog="" rc=0 expired=0
	shift 2
	case "$$limit" in ""|*[!0-9]*) exit 125 ;; esac
	case "$$grace" in ""|*[!0-9]*) exit 125 ;; esac
	[ "$$#" -gt 0 ] || exit 125
	[ -x /usr/bin/setsid ] || exit 125
	marker="$$(mktemp /tmp/luci-app-adguardhome-bounded.XXXXXX)" || exit 125
	chmod 0600 "$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	printf '0\n' >"$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	bounded_signal_session() {
		/bin/kill "-$$1" -- "-$$child" 2>/dev/null ||
			/bin/kill "-$$1" "$$child" 2>/dev/null || true
	}
	bounded_abort() {
		trap - HUP INT QUIT TERM
		[ -z "$$watchdog" ] || /bin/kill -TERM "$$watchdog" 2>/dev/null || true
		[ -z "$$watchdog" ] || wait "$$watchdog" 2>/dev/null || true
		if [ -n "$$child" ]; then
			bounded_signal_session TERM
			sleep "$$grace" 2>/dev/null || true
			bounded_signal_session KILL
			wait "$$child" 2>/dev/null || true
		fi
		rm -f "$$marker"
		exit 125
	}
	trap bounded_abort HUP INT QUIT TERM
	[ ! -e /proc/self/fd/187 ] || bounded_abort
	exec 187<&0 || bounded_abort
	/usr/bin/setsid "$$@" <&187 187<&- &
	child=$$!
	exec 187<&-
	(
		bounded_sleeper=""
		bounded_watchdog_abort() {
			trap - HUP INT QUIT TERM
			[ -z "$$bounded_sleeper" ] || /bin/kill -TERM "$$bounded_sleeper" 2>/dev/null || true
			[ -z "$$bounded_sleeper" ] || wait "$$bounded_sleeper" 2>/dev/null || true
			exit 1
		}
		bounded_watchdog_sleep() {
			sleep "$$1" &
			bounded_sleeper=$$!
			wait "$$bounded_sleeper"
			bounded_sleep_rc=$$?
			bounded_sleeper=""
			return "$$bounded_sleep_rc"
		}
		trap bounded_watchdog_abort HUP INT QUIT TERM
		bounded_watchdog_sleep "$$limit" || exit 1
		/bin/kill -0 -- "-$$child" 2>/dev/null || /bin/kill -0 "$$child" 2>/dev/null || exit 1
		printf '1\n' >"$$marker" || exit 1
		bounded_signal_session TERM
		bounded_watchdog_sleep "$$grace" || exit 0
		bounded_signal_session KILL
	) &
	watchdog=$$!
	wait "$$child" 2>/dev/null || rc=$$?
	read -r expired <"$$marker" 2>/dev/null || expired=0
	if [ "$$expired" = 1 ]; then
		wait "$$watchdog" 2>/dev/null || true
	else
		/bin/kill -TERM "$$watchdog" 2>/dev/null || true
		wait "$$watchdog" 2>/dev/null || true
	fi
	trap - HUP INT QUIT TERM
	rm -f "$$marker"
	[ "$$expired" = 1 ] && exit 124
	exit "$$rc"
)

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

root_owned_directory_allow_writable() {
	local metadata owner group
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r _mode _links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$owner" = 0 ] && [ "$$group" = 0 ]
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

root_private_single_file() {
	local metadata mode links owner group
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_owned_single_file() {
	local metadata mode links owner group
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _remainder <<-EOF
	$$metadata
	EOF
	case "$$mode" in -?????????) ;; *) return 1 ;; esac
	[ "$$links" = 1 ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

snapshot_sha256() {
	local digest
	command -v sha256sum >/dev/null 2>&1 || return 1
	digest="$$(sha256sum "$$1" 2>/dev/null)" || return 1
	printf '%s\n' "$${digest%% *}"
}

maintenance_upgrade_bundle_valid() {
	local line1 line2 line3 line4 line5 line6 line7 line8 extra entry
	local config_hash config_size delta_hash delta_size
	root_private_directory "$$runtime_dir" || return 1
	root_private_single_file "$$maintenance_upgrade_marker" || return 1
	[ "$$(wc -c <"$$maintenance_upgrade_marker" 2>/dev/null)" -le 4096 ] \
		2>/dev/null || return 1
	{
		IFS= read -r line1 && IFS= read -r line2 &&
		IFS= read -r line3 && IFS= read -r line4 &&
		IFS= read -r line5 && IFS= read -r line6 &&
		IFS= read -r line7 && IFS= read -r line8 &&
		! IFS= read -r extra
	} <"$$maintenance_upgrade_marker" || return 1
	[ "$$line1" = format=1 ] || return 1
	case "$$line2" in
		source_version=2.2.0-r1|source_version=2.2.0-r2) ;;
		*) return 1 ;;
	esac
	case "$$line3" in wrapper_running=0|wrapper_running=1)
		maintenance_wrapper_running="$${line3#*=}" ;; *) return 1 ;; esac
	case "$$line4" in delta_present=0|delta_present=1)
		maintenance_delta_present="$${line4#*=}" ;; *) return 1 ;; esac
	case "$$line5" in config_sha256=*) config_hash="$${line5#*=}" ;; *) return 1 ;; esac
	case "$$line6" in config_size=*) config_size="$${line6#*=}" ;; *) return 1 ;; esac
	case "$$line7" in delta_sha256=*) delta_hash="$${line7#*=}" ;; *) return 1 ;; esac
	case "$$line8" in delta_size=*) delta_size="$${line8#*=}" ;; *) return 1 ;; esac
	case "$$config_hash" in ''|*[!0-9a-f]*) return 1 ;; esac
	[ "$${#config_hash}" = 64 ] || return 1
	case "$$config_size" in ''|*[!0-9]*) return 1 ;; esac
	[ "$$config_size" -ge 1 ] 2>/dev/null &&
		[ "$$config_size" -le 524288 ] 2>/dev/null || return 1
	root_private_single_file "$$maintenance_config_snapshot" || return 1
	[ "$$(wc -c <"$$maintenance_config_snapshot" 2>/dev/null)" = "$$config_size" ] &&
		[ "$$(snapshot_sha256 "$$maintenance_config_snapshot")" = "$$config_hash" ] || return 1
	case "$$maintenance_delta_present" in
		0)
			[ "$$delta_hash" = none ] && [ "$$delta_size" = 0 ] &&
				[ ! -e "$$maintenance_delta_snapshot" ] &&
				[ ! -L "$$maintenance_delta_snapshot" ] || return 1
			;;
		1)
			case "$$delta_hash" in ''|*[!0-9a-f]*) return 1 ;; esac
			[ "$${#delta_hash}" = 64 ] || return 1
			case "$$delta_size" in ''|*[!0-9]*) return 1 ;; esac
			[ "$$delta_size" -le 524288 ] 2>/dev/null || return 1
			root_private_single_file "$$maintenance_delta_snapshot" || return 1
			[ "$$(wc -c <"$$maintenance_delta_snapshot" 2>/dev/null)" = "$$delta_size" ] &&
				[ "$$(snapshot_sha256 "$$maintenance_delta_snapshot")" = "$$delta_hash" ] || return 1
			;;
	esac
	for entry in \
		"$$runtime_dir"/* \
		"$$runtime_dir"/.[!.]* \
		"$$runtime_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		case "$$entry" in
			"$$maintenance_upgrade_marker"|"$$maintenance_config_snapshot") ;;
			"$$maintenance_delta_snapshot")
				[ "$$maintenance_delta_present" = 1 ] || return 1 ;;
			*) return 1 ;;
		esac
	done
}

ensure_root_private_directory() {
	if [ -e "$$1" ] || [ -L "$$1" ]; then
		root_private_directory "$$1"
		return
	fi
	mkdir -m 0700 "$$1" || return 1
	chown 0:0 "$$1" && chmod 0700 "$$1" || return 1
	root_private_directory "$$1"
}

# Restore through file descriptors held across a same-directory rename.  This
# preserves the exact persistent and saved-delta bytes while refusing a
# replaced source, staging path, or destination object.
atomic_restore_maintenance_file() (
	local source="$$1" target="$$2" directory="$$3" prefix="$$4" minimum="$$5"
	local temporary="" source_fd=/proc/self/fd/8 target_fd=/proc/self/fd/9
	local metadata mode links owner group size
	cleanup_atomic_restore() {
		[ -z "$$temporary" ] || rm -f "$$temporary"
	}
	trap cleanup_atomic_restore 0
	trap 'exit 1' HUP INT TERM
	case "$$target" in "$$directory"/*) ;; *) exit 1 ;; esac
	case "$$minimum" in 0|1) ;; *) exit 1 ;; esac
	root_private_single_file "$$source" || exit 1
	case "$$directory" in
		/etc/config) root_owned_directory_allow_writable "$$directory" || exit 1 ;;
		/tmp/.uci) root_private_directory "$$directory" || exit 1 ;;
		*) exit 1 ;;
	esac
	if [ -e "$$target" ] || [ -L "$$target" ]; then
		root_owned_single_file "$$target" || exit 1
	fi
	temporary="$$(mktemp "$${directory}/$${prefix}.XXXXXX")" || exit 1
	chown 0:0 "$$temporary" && chmod 0600 "$$temporary" || exit 1
	exec 8<"$$source" || exit 1
	exec 9<>"$$temporary" || exit 1
	[ "$$source_fd" -ef "$$source" ] &&
		[ ! -L "$$temporary" ] && [ "$$target_fd" -ef "$$temporary" ] || exit 1
	/bin/dd if="$$source_fd" of="$$target_fd" bs=4096 count=129 2>/dev/null || exit 1
	chown 0:0 "$$target_fd" && chmod 0600 "$$target_fd" || exit 1
	metadata="$$(LC_ALL=C ls -ldnL "$$target_fd" 2>/dev/null)" || exit 1
	read -r mode links owner group size _remainder <<-EOF
	$$metadata
	EOF
	[ "$$mode" = "-rw-------" ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ] || exit 1
	case "$$size" in ''|*[!0-9]*) exit 1 ;; esac
	[ "$$size" -ge "$$minimum" ] 2>/dev/null &&
		[ "$$size" -le 524288 ] 2>/dev/null || exit 1
	cmp -s "$$source_fd" "$$target_fd" || exit 1
	[ "$$source_fd" -ef "$$source" ] &&
		[ ! -L "$$temporary" ] && [ "$$target_fd" -ef "$$temporary" ] || exit 1
	if [ -e "$$target" ] || [ -L "$$target" ]; then
		root_owned_single_file "$$target" || exit 1
	fi
	mv -f "$$temporary" "$$target" || exit 1
	temporary=""
	[ "$$target_fd" -ef "$$target" ] || exit 1
	root_private_single_file "$$target" || exit 1
	cmp -s "$$source_fd" "$$target_fd" && cmp -s "$$source" "$$target"
)

restore_maintenance_layers() {
	atomic_restore_maintenance_file "$$maintenance_config_snapshot" \
		/etc/config/adguardhome /etc/config .adguardhome.luci-maintenance 1 || return 1
	case "$$maintenance_delta_present" in
		0)
			if [ -e /tmp/.uci ] || [ -L /tmp/.uci ]; then
				root_private_directory /tmp/.uci || return 1
			fi
			if [ -e /tmp/.uci/adguardhome ] || [ -L /tmp/.uci/adguardhome ]; then
				root_private_empty_file /tmp/.uci/adguardhome || return 1
				rm -f /tmp/.uci/adguardhome || return 1
			fi
			[ ! -e /tmp/.uci/adguardhome ] && [ ! -L /tmp/.uci/adguardhome ]
			;;
		1)
			ensure_root_private_directory /tmp/.uci || return 1
			atomic_restore_maintenance_file "$$maintenance_delta_snapshot" \
				/tmp/.uci/adguardhome /tmp/.uci .adguardhome.luci-maintenance 0
			;;
		*) return 1 ;;
	esac
}

verify_maintenance_layers() {
	root_private_single_file /etc/config/adguardhome &&
		cmp -s "$$maintenance_config_snapshot" /etc/config/adguardhome || return 1
	case "$$maintenance_delta_present" in
		0) [ ! -e /tmp/.uci/adguardhome ] && [ ! -L /tmp/.uci/adguardhome ] ;;
		1)
			root_private_directory /tmp/.uci &&
				root_private_single_file /tmp/.uci/adguardhome &&
				cmp -s "$$maintenance_delta_snapshot" /tmp/.uci/adguardhome
			;;
		*) return 1 ;;
	esac
}

maintenance_process_identity() {
	local pid="$$1" started
	case "$$pid" in ''|*[!0-9]*) return 1 ;; esac
	[ "$$pid" -ge 2 ] 2>/dev/null && [ -r "/proc/$$pid/stat" ] || return 1
	started="$$(awk 'NR == 1 { print $$22 }' "/proc/$$pid/stat" 2>/dev/null)" || return 1
	case "$$started" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s:%s\n' "$$pid" "$$started"
}

maintenance_wrapper_registered() {
	local payload command0 command1
	payload="$$(ubus -S call service list '{"name":"AdGuardHome"}' 2>/dev/null)" || return 2
	if ! printf '%s\n' "$$payload" |
	     jsonfilter -e '@.AdGuardHome.instances.monitor' >/dev/null 2>&1; then
		if printf '%s\n' "$$payload" |
		   jsonfilter -e '@.AdGuardHome.instances.*' >/dev/null 2>&1; then
			return 2
		fi
		return 1
	fi
	command0="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.command[0]' 2>/dev/null)" || return 2
	command1="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.command[1]' 2>/dev/null)" || return 2
	[ "$$command0" = /etc/init.d/AdGuardHome ] &&
		[ "$$command1" = monitor ] && return 0
	return 2
}

maintenance_monitor_pid() {
	local pid
	pid="$$(ubus -S call service list '{"name":"AdGuardHome"}' 2>/dev/null |
		jsonfilter -e '@.AdGuardHome.instances.monitor.pid' 2>/dev/null)" || return 1
	case "$$pid" in ''|*[!0-9]*) return 1 ;; esac
	[ "$$pid" -ge 2 ] 2>/dev/null || return 1
	printf '%s\n' "$$pid"
}

# Capture the official lowercase service state without changing it.  A PID
# identity detects any restart while an explicit registered/absent token also
# covers its own procd respawn delay.
maintenance_core_identity() {
	local payload pid identity
	payload="$$(ubus -S call service list '{"name":"adguardhome"}' 2>/dev/null)" || return 1
	if ! printf '%s\n' "$$payload" |
	     jsonfilter -e '@.adguardhome.instances.adguardhome' >/dev/null 2>&1; then
		if printf '%s\n' "$$payload" |
		   jsonfilter -e '@.adguardhome.instances.*' >/dev/null 2>&1; then
			return 1
		fi
		printf 'absent\n'
		return 0
	fi
	pid="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.adguardhome.instances.adguardhome.pid' 2>/dev/null)" || {
		printf 'registered\n'
		return 0
	}
	identity="$$(maintenance_process_identity "$$pid")" || return 1
	printf 'running:%s\n' "$$identity"
}

load_cold_postinst_state() {
	local line1 line2 line3 extra entry size
	root_private_directory "$$cold_postinst_dir" || return 1
	root_private_single_file "$$cold_postinst_state" || return 1
	size="$$(wc -c <"$$cold_postinst_state" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -ge 1 ] 2>/dev/null && [ "$$size" -le 256 ] 2>/dev/null || return 1
	{
		IFS= read -r line1 && IFS= read -r line2 &&
			IFS= read -r line3 && ! IFS= read -r extra
	} <"$$cold_postinst_state" || return 1
	[ "$$line1" = format=1 ] || return 1
	case "$$line2" in
		source_version=2.1.0-r1|source_version=2.2.0-r1|source_version=2.2.0-r2|source_version=2.3.0-r1)
			cold_source_version="$${line2#*=}"
			;;
		*) return 1 ;;
	esac
	case "$$line3" in
		was_running=0|was_running=1) cold_was_running="$${line3#*=}" ;;
		*) return 1 ;;
	esac
	for entry in \
		"$$cold_postinst_dir"/* \
		"$$cold_postinst_dir"/.[!.]* \
		"$$cold_postinst_dir"/..?*; do
		[ -e "$$entry" ] || [ -L "$$entry" ] || continue
		[ "$$entry" = "$$cold_postinst_state" ] || return 1
	done
}

cold_status_value() {
	local key="$$1"
	printf '%s\n' "$$cold_memory_status" | awk -F= -v key="$$key" '
		$$1 == key { count++; value=substr($$0, length(key) + 2) }
		END { if (count == 1) print value; else exit 1 }
	'
}

verify_cold_storage_state() {
	local expected_running="$$1" requested work_dir active active_work active_config
	local status_requested status_persistent status_backing backing_count
	requested="$$(uci -q get AdGuardHome.AdGuardHome.run_from_memory)" || return 1
	case "$$requested" in 0|1) ;; *) return 1 ;; esac
	work_dir="$$(uci -q get AdGuardHome.AdGuardHome.workdir)" || return 1
	case "$$work_dir" in ""|/|*/) return 1 ;; /*) ;; *) return 1 ;; esac
	cold_memory_status="$$(run_bounded 20 2 /etc/init.d/AdGuardHome memory_status)" || return 1
	status_requested="$$(cold_status_value requested)" || return 1
	active="$$(cold_status_value active)" || return 1
	status_persistent="$$(cold_status_value persistent_work_dir)" || return 1
	active_work="$$(cold_status_value active_work_dir)" || return 1
	active_config="$$(cold_status_value active_config_file)" || return 1
	[ "$$status_requested" = "$$requested" ] &&
		[ "$$status_persistent" = "$$work_dir" ] &&
		[ "$$active_config" = "$${work_dir}/AdGuardHome.yaml" ] || return 1
	if [ "$$expected_running" = 1 ] && [ "$$requested" = 1 ]; then
		if [ "$$active" = 1 ]; then
			[ "$$active_work" = /tmp/luci-app-adguardhome-memory/work ] || return 1
			status_backing="$$(cold_status_value backing_work_dir)" || return 1
			[ "$$status_backing" = "$$work_dir" ]
			return
		fi
		# RAM mode is best-effort: the coordinator deliberately falls back to
		# the persistent data tree when a safe RAM generation cannot be made.
		# Accept that successful degraded state, but never a partial backing
		# record that could make the active layout ambiguous.
		[ "$$active" = 0 ] && [ "$$active_work" = "$$work_dir" ] || return 1
		backing_count="$$(printf '%s\n' "$$cold_memory_status" |
			awk '/^backing_work_dir=/ { count++ } END { print count + 0 }')" || return 1
		[ "$$backing_count" = 0 ]
		return
	fi
	[ "$$active" = 0 ] && [ "$$active_work" = "$$work_dir" ] || return 1
	backing_count="$$(printf '%s\n' "$$cold_memory_status" |
		awk '/^backing_work_dir=/ { count++ } END { print count + 0 }')" || return 1
	[ "$$backing_count" = 0 ]
}

verify_cold_upgrade_completion() {
	local wrapper_rc=0 core_identity old_enabled
	[ "$$cold_upgrade" = 1 ] || return 0
	case "$$cold_was_running" in
		1)
			maintenance_wrapper_registered || wrapper_rc=$$?
			[ "$$wrapper_rc" = 0 ] || return 1
			run_bounded 180 5 /etc/init.d/AdGuardHome do_redirect 1 \
				>/dev/null 2>&1 || return 1
			wrapper_rc=0
			maintenance_wrapper_registered || wrapper_rc=$$?
			[ "$$wrapper_rc" = 0 ] || return 1
			run_bounded 5 1 /etc/init.d/AdGuardHome running \
				>/dev/null 2>&1 || return 1
			core_identity="$$(maintenance_core_identity)" || return 1
			case "$$core_identity" in running:*) ;; *) return 1 ;; esac
			old_enabled="$$(uci -q get AdGuardHome.AdGuardHome.old_enabled)" || return 1
			[ "$$old_enabled" = 1 ] || return 1
			verify_cold_storage_state 1
			;;
		0)
			maintenance_wrapper_registered || wrapper_rc=$$?
			[ "$$wrapper_rc" = 1 ] || return 1
			core_identity="$$(maintenance_core_identity)" || return 1
			[ "$$core_identity" = absent ] || return 1
			old_enabled="$$(uci -q get AdGuardHome.AdGuardHome.old_enabled 2>/dev/null || true)"
			case "$$old_enabled" in ''|0) ;; *) return 1 ;; esac
			verify_cold_storage_state 0
			;;
		*) return 1 ;;
	esac
}

retire_cold_postinst_state() {
	local expected_source="$$cold_source_version" expected_running="$$cold_was_running"
	[ "$$cold_upgrade" = 1 ] || return 0
	load_cold_postinst_state || return 1
	[ "$$cold_source_version" = "$$expected_source" ] &&
		[ "$$cold_was_running" = "$$expected_running" ] || return 1
	rm -f "$$cold_postinst_state" || return 1
	[ ! -e "$$cold_postinst_state" ] && [ ! -L "$$cold_postinst_state" ] || return 1
	rmdir "$$cold_postinst_dir"
}

maintenance_monitor_cgroup_supported() {
	local directory=/sys/fs/cgroup/services/AdGuardHome/monitor
	[ -d "$$directory" ] && [ ! -L "$$directory" ] || return 1
	[ -e "$$directory/cgroup.kill" ] && [ ! -L "$$directory/cgroup.kill" ] &&
		[ -w "$$directory/cgroup.kill" ] || return 1
	[ -r "$$directory/cgroup.procs" ] && [ ! -L "$$directory/cgroup.procs" ] || return 1
	[ -r "$$directory/cgroup.events" ] && [ ! -L "$$directory/cgroup.events" ]
}

maintenance_monitor_pid_is_contained() {
	local directory=/sys/fs/cgroup/services/AdGuardHome/monitor
	local payload command0 command1 running pid
	payload="$$(ubus -S call service list '{"name":"AdGuardHome"}' 2>/dev/null)" || return 1
	command0="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.command[0]' 2>/dev/null)" || return 1
	command1="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.command[1]' 2>/dev/null)" || return 1
	[ "$$command0" = /etc/init.d/AdGuardHome ] &&
		[ "$$command1" = monitor ] || return 1
	running="$$(printf '%s\n' "$$payload" |
		jsonfilter -e '@.AdGuardHome.instances.monitor.running' 2>/dev/null)" || return 1
	case "$$running" in
		true|1)
			pid="$$(printf '%s\n' "$$payload" |
				jsonfilter -e '@.AdGuardHome.instances.monitor.pid' 2>/dev/null)" || return 1
			case "$$pid" in ''|*[!0-9]*) return 1 ;; esac
			[ "$$pid" -ge 2 ] 2>/dev/null || return 1
			grep -qx "$$pid" "$$directory/cgroup.procs" 2>/dev/null && return 0
			# A main process may exit naturally between the ubus snapshot and
			# cgroup read.  Only that confirmed disappearance is equivalent to
			# respawn delay.
			[ ! -e "/proc/$$pid" ] && [ ! -L "/proc/$$pid" ]
			;;
		false|0)
			# A stopped registered instance is precisely procd's respawn-delay
			# state.  It must not expose a contradictory PID field.
			! printf '%s\n' "$$payload" |
				jsonfilter -e '@.AdGuardHome.instances.monitor.pid' >/dev/null 2>&1
			;;
		*) return 1 ;;
	esac
}

maintenance_monitor_cgroup_quiescent() {
	local directory=/sys/fs/cgroup/services/AdGuardHome/monitor procs populated
	if [ ! -e "$$directory" ] && [ ! -L "$$directory" ]; then
		return 0
	fi
	maintenance_monitor_cgroup_supported || return 1
	procs="$$(cat "$$directory/cgroup.procs" 2>/dev/null)" || return 1
	populated="$$(awk '
		$$1 == "populated" { count++; value=$$2 }
		END { if (count == 1) print value; else exit 1 }
	' "$$directory/cgroup.events" 2>/dev/null)" || return 1
	[ -z "$$procs" ] && [ "$$populated" = 0 ]
}

maintenance_kill_monitor_cgroup() {
	local directory=/sys/fs/cgroup/services/AdGuardHome/monitor
	if [ ! -e "$$directory" ] && [ ! -L "$$directory" ]; then
		return 0
	fi
	maintenance_monitor_cgroup_supported || return 1
	{ printf '1\n' >"$$directory/cgroup.kill"; } 2>/dev/null && return 0
	# procd may remove an already empty instance cgroup between validation and
	# the write.  Accept only that confirmed disappearance; every other failure
	# remains fatal rather than falling back to incomplete PID signalling.
	[ ! -e "$$directory" ] && [ ! -L "$$directory" ]
}

# Deleting the procd instance cancels a pending respawn but signals only its
# main PID.  cgroup.kill then atomically removes every old child, including a
# run_locked shell waiting on the integration lock with v2.2 code in memory.
retire_maintenance_monitor() {
	local registered_rc=0 delete_rc=0 attempt=0
	local directory=/sys/fs/cgroup/services/AdGuardHome/monitor
	maintenance_wrapper_registered || registered_rc=$$?
	case "$$registered_rc" in
		0)
			# The supported 25.12.1 procd retains this cgroup even during its
			# respawn delay.  Without cgroup.kill, a complete generation retire
			# cannot be guaranteed, so validate before changing procd state.
			maintenance_monitor_cgroup_supported &&
				maintenance_monitor_pid_is_contained || return 1
			ubus -S call service delete \
				'{"name":"AdGuardHome","instance":"monitor"}' \
				>/dev/null 2>&1 || delete_rc=$$?
			if [ "$$delete_rc" != 0 ]; then
				registered_rc=0
				maintenance_wrapper_registered || registered_rc=$$?
				[ "$$registered_rc" = 1 ] || return 1
			fi
			;;
		1)
			if [ -e "$$directory" ] || [ -L "$$directory" ]; then
				maintenance_monitor_cgroup_supported || return 1
			fi
			;;
		*) return 1 ;;
	esac
	while [ "$$attempt" -lt 30 ]; do
		maintenance_kill_monitor_cgroup || return 1
		registered_rc=0
		maintenance_wrapper_registered || registered_rc=$$?
		case "$$registered_rc" in 0) ;; 1) ;; *) return 1 ;; esac
		if [ "$$registered_rc" = 1 ] && maintenance_monitor_cgroup_quiescent; then
			return 0
		fi
		attempt=$$((attempt + 1))
		sleep 1
	done
	return 1
}

verify_maintenance_wrapper_state() {
	local registered_rc=0 running_rc=0
	maintenance_wrapper_registered || registered_rc=$$?
	case "$$maintenance_wrapper_running:$$registered_rc" in
		1:0)
			/etc/init.d/AdGuardHome running >/dev/null 2>&1 || running_rc=$$?
			[ "$$running_rc" = 0 ]
			;;
		0:1) return 0 ;;
		*) return 1 ;;
	esac
}

replace_maintenance_monitor() {
	local core_identity attempt=0 old_monitor_pid="" old_monitor_identity=""
	local new_monitor_pid new_monitor_identity
	core_identity="$$(maintenance_core_identity)" || return 1
	old_monitor_pid="$$(maintenance_monitor_pid)" || old_monitor_pid=""
	if [ -n "$$old_monitor_pid" ]; then
		old_monitor_identity="$$(maintenance_process_identity "$$old_monitor_pid")" || return 1
	fi
	retire_maintenance_monitor || return 1
	[ "$$(maintenance_core_identity)" = "$$core_identity" ] || return 1
	case "$$maintenance_wrapper_running" in
		0) ;;
		1)
			# With the authenticated marker present, start_service() registers
			# only the installed v2.3 monitor and service_started() leaves the
			# official lowercase core and resolver integration untouched.
			PKG_UPGRADE=1 /etc/init.d/AdGuardHome start >/dev/null 2>&1 || return 1
			while [ "$$attempt" -lt 30 ]; do
				if verify_maintenance_wrapper_state; then
					break
				fi
				attempt=$$((attempt + 1))
				sleep 1
			done
			[ "$$attempt" -lt 30 ] || return 1
			new_monitor_pid="$$(maintenance_monitor_pid)" || return 1
			new_monitor_identity="$$(maintenance_process_identity "$$new_monitor_pid")" || return 1
			[ -z "$$old_monitor_identity" ] ||
				[ "$$new_monitor_identity" != "$$old_monitor_identity" ] || return 1
			[ -r "/proc/$$new_monitor_pid/cgroup" ] &&
				grep -qx '0::/services/AdGuardHome/monitor' \
					"/proc/$$new_monitor_pid/cgroup" || return 1
			;;
		*) return 1 ;;
	esac
	[ "$$(maintenance_core_identity)" = "$$core_identity" ]
}
runtime_dir=/var/run/luci-app-adguardhome
maintenance_upgrade_marker="$${runtime_dir}/maintenance-upgrade"
maintenance_config_snapshot="$${runtime_dir}/maintenance-adguardhome.config"
maintenance_delta_snapshot="$${runtime_dir}/maintenance-adguardhome.delta"
maintenance_upgrade=0
cold_postinst_dir=/var/run/luci-app-adguardhome-postinst
cold_postinst_state="$${cold_postinst_dir}/cold-upgrade"
cold_source_version=""
cold_was_running=""
cold_memory_status=""
cold_upgrade=0
package_upgrade=0
case "$${PKG_UPGRADE}:$${1}" in
	1:*|*:upgrade) package_upgrade=1 ;;
esac
yaml_runtime_dir=/var/run/luci-app-adguardhome-yaml
yaml_update_lock="$${yaml_runtime_dir}/update.lock"
yaml_maintenance_marker="$${yaml_runtime_dir}/removing"
integration_lock=/var/lock/AdGuardHome-integration.lock

if [ -e "$$maintenance_upgrade_marker" ] ||
   [ -L "$$maintenance_upgrade_marker" ]; then
	maintenance_upgrade_bundle_valid || {
		echo "Unsafe AdGuard Home maintenance-upgrade bundle; installation aborted." >&2
		exit 1
	}
	maintenance_upgrade=1
elif [ -e "$$maintenance_config_snapshot" ] ||
     [ -L "$$maintenance_config_snapshot" ] ||
     [ -e "$$maintenance_delta_snapshot" ] ||
     [ -L "$$maintenance_delta_snapshot" ]; then
	echo "Incomplete AdGuard Home maintenance-upgrade bundle; installation aborted." >&2
	exit 1
fi

if [ "$$maintenance_upgrade" = 1 ]; then
	if [ -e "$$cold_postinst_dir" ] || [ -L "$$cold_postinst_dir" ]; then
		echo "Conflicting AdGuard Home cold and maintenance upgrade state; installation aborted." >&2
		exit 1
	fi
elif [ "$$package_upgrade" = 1 ]; then
	load_cold_postinst_state || {
		echo "Missing or unsafe AdGuard Home cold-upgrade completion state; installation aborted." >&2
		exit 1
	}
	cold_upgrade=1
elif [ -e "$$cold_postinst_dir" ] || [ -L "$$cold_postinst_dir" ]; then
	echo "Unexpected AdGuard Home cold-upgrade state on a clean installation; installation aborted." >&2
	exit 1
fi

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
	if [ "$$maintenance_upgrade" = 1 ]; then
		echo "The AdGuard Home maintenance guard disappeared during upgrade." >&2
		exit 1
	fi
	(umask 077; : >"$$yaml_maintenance_marker") || exit 1
	chown 0:0 "$$yaml_maintenance_marker" &&
		chmod 0600 "$$yaml_maintenance_marker" || exit 1
	root_private_empty_file "$$yaml_maintenance_marker" || exit 1
fi

if [ "$$maintenance_upgrade" = 1 ]; then
	maintenance_upgrade_bundle_valid || exit 1
	mkdir -p "$${integration_lock%/*}" || exit 1
	[ ! -e /proc/self/fd/190 ] || exit 1
	exec 190>>"$$integration_lock" || exit 1
	/usr/bin/flock -x 190 || exit 1
	maintenance_upgrade_bundle_valid || exit 1
	# Replace the complete old procd instance after acquiring the integration
	# lock.  Its dedicated cgroup is emptied before the installed monitor is
	# registered, so no v2.2 child can resume after this hook releases the lock.
	replace_maintenance_monitor || {
		echo "Unable to activate the v2.3 AdGuard Home monitor without restarting the core." >&2
		exit 1
	}
	restore_maintenance_layers || {
		echo "Unable to restore the AdGuard Home UCI layers after upgrade." >&2
		exit 1
	}
	verify_maintenance_layers || {
		echo "Unable to verify the restored AdGuard Home UCI layers." >&2
		exit 1
	}
	verify_maintenance_wrapper_state || {
		echo "The AdGuard Home coordinator state changed during upgrade." >&2
		exit 1
	}
fi

if [ "$$cold_upgrade" = 1 ]; then
	verify_cold_upgrade_completion || {
		echo "AdGuard Home did not reach its preserved cold-upgrade service state; installation aborted." >&2
		exit 1
	}
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

if [ "$$maintenance_upgrade" = 1 ]; then
	maintenance_upgrade_bundle_valid &&
		verify_maintenance_layers &&
		verify_maintenance_wrapper_state || exit 1
	if [ "$$maintenance_delta_present" = 1 ]; then
		rm -f "$$maintenance_delta_snapshot" || exit 1
		[ ! -e "$$maintenance_delta_snapshot" ] &&
			[ ! -L "$$maintenance_delta_snapshot" ] || exit 1
	fi
	rm -f "$$maintenance_config_snapshot" || exit 1
	[ ! -e "$$maintenance_config_snapshot" ] &&
		[ ! -L "$$maintenance_config_snapshot" ] || exit 1
	rm -f "$$maintenance_upgrade_marker" || exit 1
	[ ! -e "$$maintenance_upgrade_marker" ] &&
		[ ! -L "$$maintenance_upgrade_marker" ] || exit 1
	rmdir "$$runtime_dir" || exit 1
fi

[ /proc/self/fd/191 -ef "$$yaml_update_lock" ] || exit 1
root_private_directory "$$yaml_runtime_dir" &&
	root_private_empty_file "$$yaml_update_lock" &&
	root_private_empty_file "$$yaml_maintenance_marker" || exit 1
rm -f "$$yaml_maintenance_marker" || exit 1
[ ! -e "$$yaml_maintenance_marker" ] && [ ! -L "$$yaml_maintenance_marker" ] || exit 1
retire_cold_postinst_state || {
	echo "Unable to retire the verified AdGuard Home cold-upgrade state; installation aborted." >&2
	exit 1
}
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

# Keep uninstall cleanup bounded without a target timeout package.
run_bounded() (
	local limit="$$1" grace="$$2" marker="" child="" watchdog="" rc=0 expired=0
	shift 2
	case "$$limit" in ""|*[!0-9]*) exit 125 ;; esac
	case "$$grace" in ""|*[!0-9]*) exit 125 ;; esac
	[ "$$#" -gt 0 ] || exit 125
	[ -x /usr/bin/setsid ] || exit 125
	marker="$$(mktemp /tmp/luci-app-adguardhome-bounded.XXXXXX)" || exit 125
	chmod 0600 "$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	printf '0\n' >"$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	bounded_signal_session() {
		/bin/kill "-$$1" -- "-$$child" 2>/dev/null ||
			/bin/kill "-$$1" "$$child" 2>/dev/null || true
	}
	bounded_abort() {
		trap - HUP INT QUIT TERM
		[ -z "$$watchdog" ] || /bin/kill -TERM "$$watchdog" 2>/dev/null || true
		[ -z "$$watchdog" ] || wait "$$watchdog" 2>/dev/null || true
		if [ -n "$$child" ]; then
			bounded_signal_session TERM
			sleep "$$grace" 2>/dev/null || true
			bounded_signal_session KILL
			wait "$$child" 2>/dev/null || true
		fi
		rm -f "$$marker"
		exit 125
	}
	trap bounded_abort HUP INT QUIT TERM
	[ ! -e /proc/self/fd/187 ] || bounded_abort
	exec 187<&0 || bounded_abort
	/usr/bin/setsid "$$@" <&187 187<&- &
	child=$$!
	exec 187<&-
	(
		bounded_sleeper=""
		bounded_watchdog_abort() {
			trap - HUP INT QUIT TERM
			[ -z "$$bounded_sleeper" ] || /bin/kill -TERM "$$bounded_sleeper" 2>/dev/null || true
			[ -z "$$bounded_sleeper" ] || wait "$$bounded_sleeper" 2>/dev/null || true
			exit 1
		}
		bounded_watchdog_sleep() {
			sleep "$$1" &
			bounded_sleeper=$$!
			wait "$$bounded_sleeper"
			bounded_sleep_rc=$$?
			bounded_sleeper=""
			return "$$bounded_sleep_rc"
		}
		trap bounded_watchdog_abort HUP INT QUIT TERM
		bounded_watchdog_sleep "$$limit" || exit 1
		/bin/kill -0 -- "-$$child" 2>/dev/null || /bin/kill -0 "$$child" 2>/dev/null || exit 1
		printf '1\n' >"$$marker" || exit 1
		bounded_signal_session TERM
		bounded_watchdog_sleep "$$grace" || exit 0
		bounded_signal_session KILL
	) &
	watchdog=$$!
	wait "$$child" 2>/dev/null || rc=$$?
	read -r expired <"$$marker" 2>/dev/null || expired=0
	if [ "$$expired" = 1 ]; then
		wait "$$watchdog" 2>/dev/null || true
	else
		/bin/kill -TERM "$$watchdog" 2>/dev/null || true
		wait "$$watchdog" 2>/dev/null || true
	fi
	trap - HUP INT QUIT TERM
	rm -f "$$marker"
	[ "$$expired" = 1 ] && exit 124
	exit "$$rc"
)

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

clear_owned_memory_delta_or_refuse() {
	local delta_dir=/tmp/.uci delta_file=/tmp/.uci/adguardhome
	local effective_config effective_work memory_status
	if [ ! -e "$$delta_dir" ] && [ ! -L "$$delta_dir" ]; then
		return 0
	fi
	root_private_directory "$$delta_dir" || return 1
	if [ -e "$$delta_file" ] || [ -L "$$delta_file" ]; then
		effective_config="$$(uci -q get adguardhome.config.config_file)"
		effective_work="$$(uci -q get adguardhome.config.work_dir)"
		if [ "$$effective_work" = /tmp/luci-app-adguardhome-memory/work ] &&
		   [ -x /etc/init.d/AdGuardHome ]; then
			memory_status="$$(/etc/init.d/AdGuardHome memory_status 2>/dev/null)" || return 1
			printf '%s\n' "$$memory_status" | grep -qx 'active=1' || return 1
			# r2 owns only the volatile work_dir override; YAML remains at the
			# active persistent path reported by the state-bound coordinator.
			printf '%s\n' "$$memory_status" |
				grep -Fqx "active_config_file=$$effective_config" || return 1
			uci -q revert adguardhome.config.work_dir || return 1
			# Accept and remove an exact leftover r1 config override only as a
			# compatibility repair; r2 itself never creates this value.
			if [ "$$effective_config" = \
			     /tmp/luci-app-adguardhome-memory/work/AdGuardHome.yaml ]; then
				uci -q revert adguardhome.config.config_file || return 1
			fi
		fi
		if [ -e "$$delta_file" ] || [ -L "$$delta_file" ]; then
			# Both UCI commit and reverting the plugin-owned RAM overrides may
			# leave an empty saved-delta inode.  It contains no pending state,
			# so remove only that exact validated object before restoration.
			if root_private_empty_file "$$delta_file"; then
				rm -f "$$delta_file" || return 1
				[ ! -e "$$delta_file" ] && [ ! -L "$$delta_file" ] || return 1
				return 0
			fi
			echo "Pending official adguardhome UCI changes must be committed or reverted before uninstalling this plugin." >&2
			return 1
		fi
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
	run_bounded 5 1 /bin/dd if="$$source_fd" of="$$target_fd" \
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
	if ! run_bounded 5 1 /bin/dd if="$$snapshot_config" \
		of="$${verify_config_dir}/$${verify_package}" bs=4096 count=129 2>/dev/null ||
	   ! chown 0:0 "$${verify_config_dir}/$${verify_package}" ||
	   ! chmod 0600 "$${verify_config_dir}/$${verify_package}" ||
	   ! bounded_private_file "$${verify_config_dir}/$${verify_package}" ||
	   ! cmp -s "$$snapshot_config" "$${verify_config_dir}/$${verify_package}" ||
	   ! run_bounded 5 1 uci -q -c "$$verify_config_dir" \
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
			run_bounded 20 2 /etc/init.d/adguardhome start \
				>/dev/null 2>&1 || {
				echo "Unable to restart the originally running official adguardhome service." >&2
				return 1
			}
			run_bounded 5 1 /etc/init.d/adguardhome running \
				>/dev/null 2>&1 || {
				echo "The restored official adguardhome service is not running." >&2
				return 1
			}
			;;
		0)
			run_bounded 5 1 /etc/init.d/adguardhome running \
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
clear_owned_memory_delta_or_refuse || {
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
	run_bounded 20 2 /etc/init.d/adguardhome stop \
		>/dev/null 2>&1 || {
		echo "Unable to stop the packaged AdGuard Home service; uninstall aborted." >&2
		exit 1
	}
	lower_running_rc=0
	run_bounded 5 1 /etc/init.d/adguardhome running \
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

if [ -x /etc/init.d/AdGuardHome ]; then
	run_bounded 180 5 /etc/init.d/AdGuardHome memory_cleanup \
		>/dev/null 2>&1 || {
		echo "Unable to checkpoint and remove the AdGuard Home memory workdir; uninstall aborted." >&2
		exit 1
	}
fi

clear_owned_memory_delta_or_refuse || {
	echo "Unsafe official adguardhome UCI delta after memory cleanup; uninstall aborted." >&2
	exit 1
}
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
	cold_postinst_dir=/var/run/luci-app-adguardhome-postinst
	cold_postinst_state="$${cold_postinst_dir}/cold-upgrade"
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
	if [ -e "$$cold_postinst_dir" ] || [ -L "$$cold_postinst_dir" ]; then
		if ! root_private_directory "$$cold_postinst_dir" ||
		   ! root_private_bounded_job_file "$$cold_postinst_state"; then
			echo "Unsafe cold-upgrade completion state was preserved after uninstall." >&2
			exit 1
		fi
		for cold_entry in \
			"$$cold_postinst_dir"/* \
			"$$cold_postinst_dir"/.[!.]* \
			"$$cold_postinst_dir"/..?*; do
			[ -e "$$cold_entry" ] || [ -L "$$cold_entry" ] || continue
			[ "$$cold_entry" = "$$cold_postinst_state" ] || {
				echo "Unexpected cold-upgrade completion entry was preserved after uninstall." >&2
				exit 1
			}
		done
		rm -f "$$cold_postinst_state" || exit 1
		rmdir "$$cold_postinst_dir" || exit 1
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
