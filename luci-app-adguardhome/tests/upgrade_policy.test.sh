#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
helper_dir="$package_dir/scripts"
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
temporary="$(mktemp -d /tmp/luci-agh-upgrade-policy.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

extract_policy() {
	awk '
		/^ADGUARDHOME_UPGRADE_SOURCES=/ { copying = 1 }
		copying { print }
		/^upgrade_state_source_allowed\(\) \{/ { last = 1 }
		copying && last && /^}/ { exit }
	' "$1"
}

# Expand the source with Make just as the package hooks do, then compare the
# generated default script and each complete hook against that exact policy.
printf 'include %s/upgrade-policy.mk\n$(info $(AdGuardHome/UpgradePolicy))\nall:; @:\n' \
	"$helper_dir" >"$temporary/policy.make"
make --no-print-directory -s -f "$temporary/policy.make" >"$temporary/policy.sh"
awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$defaults" >"$temporary/defaults.sh"
extract_policy "$temporary/defaults.sh" >"$temporary/defaults.policy"
diff -u "$temporary/policy.sh" "$temporary/defaults.policy"

for hook in preinst postinst; do
	{
		printf 'PKG_NAME := luci-app-adguardhome\n'
		for helper in run-bounded private-files upgrade-policy; do
			printf 'include %s/%s.mk\n' "$helper_dir" "$helper"
		done
		awk -v hook="$hook" '
			$0 == "define Package/$(PKG_NAME)/" hook { copying = 1 }
			copying { print }
			copying && /^endef$/ { exit }
		' "$makefile"
		# Defer the file expansion across eval, exercising both Make layers
		# without evaluating any of the generated installation shell commands.
		printf '\ndefine test_rules\nall:\n\t$$(file >%s/%s.sh,$$(Package/luci-app-adguardhome/%s))\n\t@:\nendef\n$(eval $(test_rules))\n' \
			"$temporary" "$hook" "$hook"
	} >"$temporary/$hook.make"
	make --no-print-directory -s -f "$temporary/$hook.make"
	busybox ash -n "$temporary/$hook.sh"
	! grep -Eq '\$\(AdGuardHome/|\$\$|# @include ' "$temporary/$hook.sh"
	extract_policy "$temporary/$hook.sh" >"$temporary/$hook.policy"
	cmp "$temporary/policy.sh" "$temporary/$hook.policy"
done
busybox ash -n "$temporary/defaults.sh"
! grep -Fq '# @include ' "$temporary/defaults.sh"
[ "$(grep -Fc '$(AdGuardHome/UpgradePolicy)' "$makefile")" = 2 ]
! grep -Eq '2\.4\.0-r[0-9]|source_version=2|Only luci-app-adguardhome' \
	"$makefile" "$defaults"
grep -Fq 'touch -r $(PKG_BUILD_DIR)/root/$$$$file $(PKG_BUILD_DIR)/root/$$$$file.expanded' \
	"$makefile"

for policy in "$temporary/policy.sh" "$temporary/preinst.policy" \
	"$temporary/postinst.policy" "$temporary/defaults.policy"; do
	# shellcheck disable=SC1090
	. "$policy"
	[ "$ADGUARDHOME_UPGRADE_SOURCES" = \
		'2.4.0-r1 2.4.0-r2 2.4.0-r3 2.4.0-r4 2.4.0-r5 2.4.0-r6 2.4.0-r7 2.4.0-r8 2.4.0-r9 2.4.0-r10 2.5.0-r1 2.6.0-r1' ]
	for release in 1 2 3 4 5 6 7 8 9 10; do
		upgrade_source_allowed "2.4.0-r$release"
		printf 'source_version=2.4.0-r%s\nwas_running=1\n' "$release" \
			>"$temporary/state"
		upgrade_state_source_allowed "$temporary/state"
	done
	upgrade_source_allowed '2.5.0-r1'
	printf 'source_version=2.5.0-r1\nwas_running=1\n' >"$temporary/state"
	upgrade_state_source_allowed "$temporary/state"
	upgrade_source_allowed '2.6.0-r1'
	printf 'source_version=2.6.0-r1\nwas_running=1\n' >"$temporary/state"
	upgrade_state_source_allowed "$temporary/state"
	for rejected in '' unknown 2.3.0-r6 2.4.0 2.4.0-r0 \
		2.4.0-r11 2.4.0-r99 2.4.0-r01 2.4.0-r8-extra 2.4.1-r1 2.5.0 2.5.0-r2 2.6.0 2.6.0-r2 \
		' 2.4.0-r6' '2.4.0-r6 ' '2.4.0-r1 2.4.0-r2' '*'; do
		if upgrade_source_allowed "$rejected" 2>"$temporary/error"; then
			printf 'unsupported upgrade source was accepted: %s\n' "$rejected" >&2
			exit 1
		fi
		grep -Fq "$ADGUARDHOME_UPGRADE_SOURCES" "$temporary/error"
		printf 'source_version=%s\nwas_running=0\n' "$rejected" >"$temporary/state"
		! upgrade_state_source_allowed "$temporary/state" 2>"$temporary/error"
	done
	printf 'source_version=2.4.0-r1\nsource_version=2.4.0-r6\n' >"$temporary/state"
	! upgrade_state_source_allowed "$temporary/state" 2>"$temporary/error"
	printf 'was_running=1\n' >"$temporary/state"
	! upgrade_state_source_allowed "$temporary/state" 2>"$temporary/error"
done

# Duplicating the new marker must fail, just like the other shared helpers.
printf '# @include run-bounded\n# @include upgrade-policy\n# @include upgrade-policy\n' \
	>"$temporary/invalid"
if awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$temporary/invalid" >"$temporary/invalid.out"; then
	printf 'duplicate upgrade-policy marker unexpectedly expanded\n' >&2
	exit 1
fi

printf 'ok - single-source 2.4/2.5/2.6-r1 upgrade policy, hook expansion and rejection gates\n'
