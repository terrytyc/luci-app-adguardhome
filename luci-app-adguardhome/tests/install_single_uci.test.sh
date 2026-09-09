#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"

require_text() {
	grep -Fq "$2" "$1" || {
		printf 'missing installer contract in %s: %s\n' "$1" "$2" >&2
		exit 1
	}
}

reject_text() {
	if grep -Fq "$2" "$1"; then
		printf 'removed installer history remains in %s: %s\n' "$1" "$2" >&2
		exit 1
	fi
}

grep -Eq '^PKG_VERSION:=3\.[0-9]+\.[0-9]+$' "$makefile"
grep -Eq '^PKG_RELEASE:=[1-9][0-9]*$' "$makefile"
reject_text "$makefile" '/usr/lib/opkg/'
require_text "$makefile" 'run_bounded 180 5 /etc/init.d/AdGuardHome stop'
require_text "$makefile" 'managed_dnsmasq_upstream'
require_text "$makefile" 'official-adguardhome.config'
require_text "$makefile" 'managed-adguardhome.config'
require_text "$makefile" '/etc/init.d/AdGuardHome memory_cleanup'
require_text "$makefile" 'cmp -s "$$snapshot_config" /etc/config/adguardhome'
require_text "$makefile" '$(AdGuardHome/OriginalSnapshot)'
require_text "$defaults" '# @include original-snapshot'

conffiles="$(sed -n '/^define Package\/$(PKG_NAME)\/conffiles$/,/^endef$/p' "$makefile")"
printf '%s\n' "$conffiles" | grep -Fqx '/etc/AdGuardHome/AdGuardHome.yaml'
printf '%s\n' "$conffiles" | grep -Fqx '/root/.luci-app-adguardhome/'
if printf '%s\n' "$conffiles" | grep -Fq '/etc/AdGuardHome.yaml'; then
	printf 'the removed root-level YAML is still a package conffile\n' >&2
	exit 1
fi

[ ! -e "$package_dir/root/etc/config/AdGuardHome" ] || {
	printf 'the package still ships a mixed-case UCI file\n' >&2
	exit 1
}
[ ! -e "$package_dir/root/etc/config/adguardhome" ] || {
	printf 'the LuCI package overlaps the official lowercase UCI file\n' >&2
	exit 1
}

require_text "$defaults" 'UCI_CONFIG="adguardhome"'
require_text "$defaults" 'OFFICIAL_SECTION="config"'
require_text "$defaults" 'LUCI_SECTION="luci"'
require_text "$defaults" 'select_clean_install_source()'
require_text "$defaults" 'initialize_clean_options()'
require_text "$defaults" 'set_official_option config_file "$TARGET_CONFIG_FILE"'
require_text "$defaults" 'set_official_option work_dir "$TARGET_WORK_DIR"'
require_text "$defaults" 'set_luci_option redirect "$redirect"'
require_text "$defaults" 'set_luci_option run_from_memory 0'
require_text "$defaults" 'set_luci_option memory_writeback_interval 60'
require_text "$defaults" 'managed_config_is_valid'
require_text "$defaults" 'run_bounded 5 1 /etc/init.d/AdGuardHome check_work_dir "$1"'
require_text "$defaults" 'mkdir -p -m 0700 "$TARGET_WORK_DIR"'
require_text "$defaults" 'if [ "$(uci -q get "$UCI_CONFIG.$LUCI_SECTION")" = luci ]; then'
require_text "$defaults" 'refresh_managed_config_snapshot'
require_text "$defaults" 'normalize_config'
require_text "$defaults" 'SOURCE_WORK_DIR="$(resolve_source_work_dir "$configured_work")"'

managed_block="$(sed -n '/^if \[ "$(uci -q get "$UCI_CONFIG.$LUCI_SECTION")" = luci \]; then$/,/^fi$/p' "$defaults")"
printf '%s\n' "$managed_block" | grep -Fq 'managed_config_is_valid'
printf '%s\n' "$managed_block" | grep -Fq 'validate_original_snapshot'
printf '%s\n' "$managed_block" | grep -Fq 'refresh_managed_config_snapshot'
if printf '%s\n' "$managed_block" | grep -Fq 'ensure_original_snapshot'; then
	printf 'the overwrite path recreates a missing original snapshot\n' >&2
	exit 1
fi
if printf '%s\n' "$managed_block" | grep -Eq 'uci[[:space:]]+-q[[:space:]]+(set|delete|commit)'; then
	printf 'the overwrite path mutates UCI instead of preserving it\n' >&2
	exit 1
fi

for removed in \
	'/etc/config/AdGuardHome' \
	'/etc/AdGuardHome.yaml' \
	'ADGUARDHOME_UPGRADE_SOURCES' \
	'UpgradePolicy' \
	'upgrade-policy' \
	'upgrade_state' \
	'UPGRADE_STATE' \
	'BASELINE_UPGRADE_STATE' \
	'ADGUARDHOME_BASELINE_RESUME' \
	'source_version' \
	'baseline_config_is_valid' \
	'official-adguardhome.uci' \
	'exchange' \
	'dnsmasq_snapshot' \
	'dnsmasq_active_fingerprint' \
	'old_enabled' \
	'old_redirect' \
	'old_port' \
	'/var/run/AdGredir' \
	'upgrade-active.yaml' \
	'upgrade-workdir.meta' \
	'upgrade-legacy.config'; do
	reject_text "$makefile" "$removed"
	reject_text "$defaults" "$removed"
done

prerm="$(sed -n '/^define Package\/$(PKG_NAME)\/prerm$/,/^endef$/p' "$makefile")"
postrm="$(sed -n '/^define Package\/$(PKG_NAME)\/postrm$/,/^endef$/p' "$makefile")"
if printf '%s\n' "$prerm" | grep -Fq 'managed-adguardhome.config'; then
	printf 'uninstall still requires the optional managed recovery snapshot\n' >&2
	exit 1
fi
printf '%s\n' "$postrm" | grep -Fq 'if [ -e "$$managed_snapshot" ] || [ -L "$$managed_snapshot" ]; then'

make_lines="$(wc -l <"$makefile")"
defaults_lines="$(wc -l <"$defaults")"
[ "$make_lines" -lt 800 ] && [ "$defaults_lines" -lt 700 ] || {
	printf 'the simplified lifecycle grew beyond its explicit size budget\n' >&2
	exit 1
}

sh -n "$defaults"
temporary_dir="$(mktemp -d /tmp/luci-agh-install-contract.XXXXXX)"
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
	' "$makefile" >"$temporary_dir/$hook.sh"
	[ -s "$temporary_dir/$hook.sh" ] || exit 1
	$syntax_shell -n "$temporary_dir/$hook.sh"
done

printf 'ok - compact install, overwrite and uninstall contract\n'
