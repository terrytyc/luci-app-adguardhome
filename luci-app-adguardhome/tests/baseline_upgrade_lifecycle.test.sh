#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"

hook_body() {
	awk -v hook="$2" '
		BEGIN { start = "define Package/$(PKG_NAME)/" hook }
		$0 == start { copying = 1; next }
		copying && /^endef$/ { exit }
		copying { print }
	' "$1"
}

preinst="$(hook_body "$makefile" preinst)"
postinst="$(hook_body "$makefile" postinst)"
prerm="$(hook_body "$makefile" prerm)"
postrm="$(hook_body "$makefile" postrm)"
for body in "$preinst" "$postinst" "$prerm" "$postrm"; do
	[ -n "$body" ] || {
		printf 'missing package lifecycle hook\n' >&2
		exit 1
	}
done

version_line="$(printf '%s\n' "$preinst" |
	grep -n '^source_version="\$\$(installed_source_version)"' | cut -d: -f1)"
state_line="$(printf '%s\n' "$preinst" |
	grep -n '^ensure_runtime_dir && write_upgrade_state' | cut -d: -f1)"
stop_line="$(printf '%s\n' "$preinst" |
	grep -n 'AdGuardHome stop' | tail -n 1 | cut -d: -f1)"
commit_line="$(printf '%s\n' "$preinst" |
	grep -n '^upgrade_committed=1' | cut -d: -f1)"
case "$version_line:$state_line:$stop_line:$commit_line" in
	""|*[!0-9:]*|:*|*:|*::*) exit 1 ;;
esac
[ "$version_line" -lt "$state_line" ] &&
	[ "$state_line" -lt "$stop_line" ] &&
	[ "$stop_line" -lt "$commit_line" ] || {
	printf '2.4 baseline upgrade is not gated, recorded, stopped and committed in order\n' >&2
	exit 1
}

for required in \
	'validate_original_snapshot' \
	'bounded_private_file "$$managed_snapshot"' \
	'official_delta_is_clean && baseline_config_is_valid' \
	'AdGuardHome do_redirect 0' \
	'adguardhome.luci.managed_dnsmasq_upstream' \
	'rollback_preinst'; do
	printf '%s\n' "$preinst" | grep -Fq "$required" || {
		printf 'pre-upgrade contract missing: %s\n' "$required" >&2
		exit 1
	}
done

for required in \
	"grep -Eq '^source_version=2[.]4[.]0-r[123]\$\$'" \
	'case "$$was_running" in' \
	'ADGUARDHOME_BASELINE_RESUME=1' \
	'/etc/init.d/AdGuardHome start' \
	'/etc/init.d/AdGuardHome stop' \
	'rm -f "$$upgrade_state"'; do
	printf '%s\n' "$postinst" | grep -Fq "$required" || {
		printf 'post-upgrade convergence missing: %s\n' "$required" >&2
		exit 1
	}
done

init_file="$package_dir/root/etc/init.d/AdGuardHome"
grep -Fq 'BASELINE_UPGRADE_STATE="${NORMALIZER_RUNTIME_DIR}/upgrade-state"' \
	"$init_file" || {
	printf 'init baseline upgrade-state path is missing\n' >&2
	exit 1
}
start_body="$(awk '
	/^start_service\(\) \{/ { copying = 1 }
	copying { print }
	copying && /^}/ { exit }
' "$init_file")"
for required in \
	'ADGUARDHOME_BASELINE_RESUME:-0' \
	'START_PREPARED=1' \
	'START_DISABLED=1'; do
	printf '%s\n' "$start_body" | grep -Fq "$required" || {
		printf 'init stopped-upgrade barrier is missing: %s\n' "$required" >&2
		exit 1
	}
	done

barrier_dir="$(mktemp -d /tmp/luci-agh-baseline-barrier.XXXXXX)"
trap 'rm -rf "$barrier_dir"' EXIT HUP INT TERM
(
	eval "$start_body"
	BASELINE_UPGRADE_STATE="$barrier_dir/upgrade-state"
	: >"$BASELINE_UPGRADE_STATE"
	ADGUARDHOME_BASELINE_RESUME=0
	start_service
	[ "$START_PREPARED:$START_DISABLED" = 1:1 ]
) || {
	printf 'stopped baseline upgrade was not held behind the init start barrier\n' >&2
	exit 1
}
rm -rf "$barrier_dir"
trap - EXIT HUP INT TERM

printf '%s\n' "$prerm" | grep -Fq '1:*|*:upgrade) exit 0'
printf '%s\n' "$postrm" | grep -Fq '1:*|*:upgrade) exit 0'

upgrade_defaults="$(sed -n '/if \[ -e "$UPGRADE_STATE"/,/^fi$/p' "$defaults")"
for required in \
	'upgrade_state_is_valid' \
	'baseline_config_is_valid' \
	'keep_active_config' \
	'refresh_managed_config_snapshot'; do
	printf '%s\n' "$upgrade_defaults" | grep -Fq "$required" || {
		printf 'uci-defaults baseline path missing: %s\n' "$required" >&2
		exit 1
	}
done
if printf '%s\n' "$upgrade_defaults" |
	grep -Eq 'uci[[:space:]]+-q[[:space:]]+(set|delete|commit)'; then
	printf 'uci-defaults mutates UCI during the 2.4 baseline upgrade\n' >&2
	exit 1
fi

printf 'ok - 2.4.0-r1/r2/r3 to 2.4.0-r4 baseline lifecycle\n'
