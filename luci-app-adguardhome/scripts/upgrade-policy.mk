# One explicit source-version policy for all self-contained install scripts.
define AdGuardHome/UpgradePolicy
ADGUARDHOME_UPGRADE_SOURCES='2.4.0-r1 2.4.0-r2 2.4.0-r3 2.4.0-r4 2.4.0-r5 2.4.0-r6 2.4.0-r7 2.4.0-r8 2.4.0-r9'

upgrade_source_allowed() {
	local allowed
	for allowed in $$ADGUARDHOME_UPGRADE_SOURCES; do
		[ "$$1" = "$$allowed" ] && return 0
	done
	printf 'Only luci-app-adguardhome versions %s can be upgraded in place.\n' "$$ADGUARDHOME_UPGRADE_SOURCES" >&2
	return 1
}

upgrade_state_source_allowed() {
	local version
	version="$$(sed -n 's/^source_version=//p' "$$1")" || return 1
	upgrade_source_allowed "$$version"
}
endef
