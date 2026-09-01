#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
makefile="${package_dir}/Makefile"
defaults="${package_dir}/root/etc/uci-defaults/40_luci-AdGuardHome"

require_text() {
	grep -Fq "$2" "$1" || {
		printf 'missing single-UCI installer contract in %s: %s\n' "$1" "$2" >&2
		exit 1
	}
}

reject_text() {
	if grep -Fq "$2" "$1"; then
		printf 'obsolete dual-UCI installer contract remains in %s: %s\n' "$1" "$2" >&2
		exit 1
	fi
}

require_text "$makefile" 'PKG_VERSION:=2.4.0'
require_text "$makefile" 'PKG_RELEASE:=1'
require_text "$makefile" '2.3.0-r1|2.3.0-r2)'
require_text "$makefile" '0:0|0:1|1:0|1:1)'
require_text "$makefile" '# supported 2.2 layout therefore needs the cold migration path.'
reject_text "$makefile" '0:0) return 0 ;;'
require_text "$makefile" 'managed_config_snapshot="$${snapshot_dir}/managed-adguardhome.config"'
require_text "$makefile" 'upgrade_legacy_config_snapshot="$${runtime_dir}/upgrade-legacy.config"'
require_text "$makefile" 'cold_snapshot_legacy_config() ('
require_text "$makefile" 'cold_snapshot_legacy_config || {'
require_text "$makefile" 'The legacy AdGuard Home UCI snapshot was not consumed by migration'
require_text "$makefile" 'bounded_private_file "$$managed_config_snapshot"'
require_text "$makefile" '"$${snapshot_dir}/managed-adguardhome.config"'
conffiles="$(sed -n '/^define Package\/$(PKG_NAME)\/conffiles$/,/^endef$/p' "$makefile")"
if printf '%s\n' "$conffiles" | grep -Fq '/etc/config/AdGuardHome'; then
	printf 'the package conffile list still claims /etc/config/AdGuardHome\n' >&2
	exit 1
fi

[ ! -e "${package_dir}/root/etc/config/AdGuardHome" ] || {
	printf 'the LuCI package still ships the mixed-case UCI conffile\n' >&2
	exit 1
}
[ ! -e "${package_dir}/root/etc/config/adguardhome" ] || {
	printf 'the LuCI package overlaps the official lowercase UCI conffile\n' >&2
	exit 1
}

require_text "$defaults" 'UCI_CONFIG="adguardhome"'
require_text "$defaults" 'UCI_SECTION="luci"'
require_text "$defaults" 'OFFICIAL_SECTION="config"'
require_text "$defaults" 'LEGACY_CONFIG="AdGuardHome"'
require_text "$defaults" 'IMPORT_OFFICIAL_USES_TEMPLATE=0'
require_text "$defaults" 'IMPORT_OFFICIAL_USES_TEMPLATE=1'
require_text "$defaults" 'uci -q set "${UCI_CONFIG}.${UCI_SECTION}=luci"'
require_text "$defaults" 'set_official_option enabled "$enabled"'
require_text "$defaults" 'set_official_option verbose "$verbose"'
require_text "$defaults" 'set_official_option work_dir "$TARGET_WORK_DIR"'
require_text "$defaults" 'set_luci_option redirect'
require_text "$defaults" 'set_luci_option run_from_memory'
require_text "$defaults" 'set_luci_option memory_writeback_interval'
require_text "$defaults" 'ensure_official_config_present'
require_text "$defaults" 'mktemp /etc/config/.adguardhome.luci-create.XXXXXX'
require_text "$defaults" 'mv "$temporary" /etc/config/adguardhome'
require_text "$defaults" '/var/*|/tmp/*)'
require_text "$defaults" 'source is preserved.'
require_text "$defaults" 'remove_legacy_upper_config'
require_text "$defaults" 'rm -f /etc/config/AdGuardHome'
require_text "$defaults" 'MANAGED_CONFIG_SNAPSHOT="${SNAPSHOT_DIR}/managed-adguardhome.config"'
require_text "$defaults" 'UPGRADE_LEGACY_CONFIG_SNAPSHOT="${RUNTIME_DIR}/upgrade-legacy.config"'
require_text "$defaults" 'restore_legacy_config_snapshot() ('
require_text "$defaults" 'restore_legacy_config_snapshot || {'
require_text "$defaults" 'cmp -s "$descriptor" "$target"'
require_text "$defaults" 'refresh_managed_config_snapshot'
require_text "$defaults" 'validate_merged_config'

clean_defaults="$(sed -n '/# A genuinely untouched official installation adopts/,/^[[:space:]]*fi$/p' "$defaults")"
for expected in \
	'enabled=1' \
	'verbose=0' \
	'run_from_memory=0' \
	'memory_writeback_interval=60' \
	'redirect=dnsmasq-upstream'; do
	printf '%s\n' "$clean_defaults" | grep -Eq "^[[:space:]]*${expected}$" || {
		printf 'clean install does not publish the confirmed default: %s\n' "$expected" >&2
		exit 1
	}
done

import_defaults="$(sed -n '/# A meaningful official UCI\/data state can exist/,/^[[:space:]]*fi$/p' "$defaults")"
for expected in \
	'if [ "$IMPORT_OFFICIAL_USES_TEMPLATE" = 1 ]; then' \
	'redirect=dnsmasq-upstream' \
	'redirect=none'; do
	printf '%s\n' "$import_defaults" | grep -Fq "$expected" || {
		printf 'official import default selection is missing: %s\n' "$expected" >&2
		exit 1
	}
done
require_text "$defaults" 'set_luci_option redirect "$redirect"'

cleanup_line="$(grep -n '^cleanup_runtime_artifacts || exit 1$' "$defaults" | tail -n 1 | cut -d: -f1)"
remove_line="$(grep -n '^remove_legacy_upper_config || {' "$defaults" | tail -n 1 | cut -d: -f1)"
commit_line="$(grep -n '^INSTALL_COMMITTED=1$' "$defaults" | tail -n 1 | cut -d: -f1)"
case "$remove_line:$commit_line:$cleanup_line" in ""|*[!0-9:]*|:*|*:|*::*) exit 1 ;; esac
[ "$remove_line" -lt "$commit_line" ] && [ "$commit_line" -lt "$cleanup_line" ] || {
	printf 'the authenticated cold snapshot is retired before mixed-case UCI removal commits\n' >&2
	exit 1
}

# The plugin section must never receive the three official authorities.
reject_text "$defaults" 'set_luci_option enabled '
reject_text "$defaults" 'set_luci_option verbose '
reject_text "$defaults" 'set_luci_option workdir '
reject_text "$defaults" 'set_luci_option work_dir '

sh -n "$defaults"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/luci-agh-install-contract.XXXXXX")"
cleanup() {
	rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM
syntax_shell=sh
command -v busybox >/dev/null 2>&1 && syntax_shell='busybox ash'
for hook in preinst postinst prerm postrm; do
	awk -v hook="$hook" '
		BEGIN { start = "define Package/$(PKG_NAME)/" hook }
		$0 == start { copying = 1; next }
		copying && /^endef$/ { exit }
		copying { gsub(/\$\$/, "$"); print }
	' "$makefile" >"${temporary_dir}/${hook}.sh"
	[ -s "${temporary_dir}/${hook}.sh" ] || exit 1
	$syntax_shell -n "${temporary_dir}/${hook}.sh"
done
printf '2.4 single-UCI install, repair and r2 migration contracts passed\n'
