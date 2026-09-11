#!/bin/sh
# SPDX-License-Identifier: Apache-2.0

set -eu

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 4 ] ||
	die "usage: $0 APK_BIN EXPECTED_VERSION MAIN_APK I18N_APK"

apk_bin=$1
expected_version=$2
main_apk=$3
i18n_apk=$4

[ -x "$apk_bin" ] || die "APK tool is not executable: $apk_bin"
case "$expected_version" in
	''|*[!0-9A-Za-z.+_~-]*) die "unsafe expected APK version: $expected_version" ;;
esac
for command_name in awk basename cat grep mkdir mktemp rm; do
	command -v "$command_name" >/dev/null 2>&1 ||
		die "required command is unavailable: $command_name"
done

temporary=$(mktemp -d "${TMPDIR:-/tmp}/verify-adguardhome-apk.XXXXXX") ||
	die 'unable to create APK verification directory'
cleanup() {
	rc=$?
	trap - EXIT HUP INT TERM
	case "$temporary" in
		*/verify-adguardhome-apk.*) rm -rf -- "$temporary" ;;
	esac
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

metadata_value() {
	awk -v key="$2" '
		$0 == "info:" { inside = 1; next }
		inside && /^[^ ]/ { exit }
		inside && index($0, "  " key ": ") == 1 {
			print substr($0, length(key) + 5)
			found++
		}
		END { if (found != 1) exit 1 }
	' "$1"
}

metadata_has_dependency() {
	awk -v wanted="$2" '
		$0 ~ /^  depends:/ { inside = 1; next }
		inside && /^    - / {
			if (substr($0, 7) == wanted) found = 1
			next
		}
		inside { exit }
		END { if (!found) exit 1 }
	' "$1"
}

extract_script() {
	awk -v header="  $2: |" '
		$0 == header { found = 1; copying = 1; next }
		copying && /^  [-a-z]+: \|$/ { exit }
		copying && /^# data block/ { exit }
		copying { sub(/^    /, ""); print }
		END { if (!found) exit 1 }
	' "$1"
}

script_line() {
	awk -v wanted="$2" '{ line = $0; sub(/^[[:space:]]*/, "", line) }
		line == wanted { print NR; exit }' "$1"
}

verify_identity() {
	package_path=$1
	expected_name=$2
	metadata=$3
	extract_dir=$4
	[ -f "$package_path" ] && [ ! -L "$package_path" ] ||
		die "APK is missing or unsafe: $package_path"
	[ "$(basename "$package_path")" = "$expected_name-$expected_version.apk" ] ||
		die "APK filename does not match expected package: $package_path"
	"$apk_bin" verify --allow-untrusted "$package_path" >/dev/null ||
		die "invalid APK: $package_path"
	"$apk_bin" adbdump --format yaml "$package_path" >"$metadata" ||
		die "unable to read APK metadata: $package_path"
	[ "$(metadata_value "$metadata" name)" = "$expected_name" ] ||
		die "APK name mismatch: $package_path"
	[ "$(metadata_value "$metadata" version)" = "$expected_version" ] ||
		die "APK version mismatch: $package_path"
	[ "$(metadata_value "$metadata" arch)" = noarch ] ||
		die "APK is not noarch: $package_path"
	mkdir "$extract_dir" || die "unable to create extraction directory: $extract_dir"
	"$apk_bin" extract --allow-untrusted --destination "$extract_dir" \
		"$package_path" >/dev/null || die "unable to extract APK: $package_path"
}

main_metadata=$temporary/main.yaml
i18n_metadata=$temporary/i18n.yaml
main_root=$temporary/main
i18n_root=$temporary/i18n
verify_identity "$main_apk" luci-app-adguardhome "$main_metadata" "$main_root"
verify_identity "$i18n_apk" luci-i18n-adguardhome-zh-cn \
	"$i18n_metadata" "$i18n_root"

metadata_has_dependency "$main_metadata" 'adguardhome>=0.107.76-r1' ||
	die 'main APK lost its versioned adguardhome dependency'
metadata_has_dependency "$main_metadata" dnsmasq ||
	die 'main APK lost its dnsmasq dependency'
metadata_has_dependency "$main_metadata" firewall4 ||
	die 'main APK lost its firewall4 dependency'
metadata_has_dependency "$i18n_metadata" luci-app-adguardhome ||
	die 'zh-cn APK lost its luci-app-adguardhome dependency'

conffiles=$main_root/lib/apk/packages/luci-app-adguardhome.conffiles
[ -f "$conffiles" ] && [ ! -L "$conffiles" ] ||
	die 'main APK conffile manifest is missing or unsafe'
grep -Fqx '/etc/AdGuardHome/AdGuardHome.yaml' "$conffiles" ||
	die 'main APK does not preserve its active YAML'
grep -Fqx '/root/.luci-app-adguardhome/' "$conffiles" ||
	die 'main APK does not preserve its private snapshot directory'
version_file=$main_root/usr/share/luci-app-adguardhome/version
[ -f "$version_file" ] && [ ! -L "$version_file" ] &&
	[ "$(cat "$version_file")" = "$expected_version" ] ||
	die 'main APK embedded version does not match package metadata'

for hook in pre-install post-install pre-deinstall post-deinstall pre-upgrade post-upgrade; do
	extract_script "$main_metadata" "$hook" >"$temporary/main-$hook" ||
		die "main APK is missing its $hook hook"
	[ -s "$temporary/main-$hook" ] || die "main APK has an empty $hook hook"
done
for hook in pre-install pre-upgrade; do
	extract_script "$i18n_metadata" "$hook" >"$temporary/i18n-$hook" ||
		die "zh-cn APK is missing its $hook hook"
	for guard_script in "$temporary/main-$hook" "$temporary/i18n-$hook"; do
		grep -Fq 'pending_uci_changes="$(uci -q changes 2>/dev/null)"' \
			"$guard_script" || die "$hook UCI guard no longer checks all default deltas"
	done
	grep -Fq 'run_bounded 180 5 /etc/init.d/AdGuardHome stop' \
		"$temporary/main-$hook" || die "main APK $hook lost safe coordinator stop"
done
for hook in post-install post-upgrade; do
	grep -Fq default_postinst "$temporary/main-$hook" ||
		die "main APK $hook lost the platform installation hook"
	grep -Fq 'AdGuard Home initialization failed; package installation aborted.' \
		"$temporary/main-$hook" || die "main APK $hook lost initialization validation"
	grep -Fq '/etc/init.d/rpcd reload' "$temporary/main-$hook" ||
		die "main APK $hook lost RPC reload"
done
grep -Fq default_prerm "$temporary/main-pre-deinstall" ||
	die 'main APK pre-deinstall lost the platform removal hook'
grep -Fq 'run_bounded 180 5 env LUCI_ADGUARDHOME_PRERM_PHASE=bounded' \
	"$temporary/main-pre-deinstall" ||
	die 'main APK pre-deinstall lost safe coordinator stop'
grep -Fq "trap 'recover_failed_removal' 0" "$temporary/main-pre-deinstall" ||
	die 'main APK pre-deinstall lost failed-removal recovery'
grep -Fq 'for recovery_config in adguardhome dhcp firewall; do' \
	"$temporary/main-pre-deinstall" ||
	die 'main APK pre-deinstall recovery does not guard every owned UCI config'
grep -Fq '[ -z "$recovery_changes" ] || return 0' \
	"$temporary/main-pre-deinstall" ||
	die 'main APK pre-deinstall recovery may start through pending UCI changes'
if grep -Fq 'Commit or revert pending adguardhome changes before uninstalling.' \
	"$temporary/main-pre-deinstall"; then
	die 'main APK pre-deinstall retained its ineffective late UCI guard'
fi
default_line=$(script_line "$temporary/main-pre-deinstall" default_prerm)
rollback_line=$(script_line "$temporary/main-pre-deinstall" \
	'rollback_yaml_maintenance >/dev/null 2>&1 || true')
enable_line=$(script_line "$temporary/main-pre-deinstall" \
	'/etc/init.d/AdGuardHome enable >/dev/null 2>&1 || true')
recovery_guard_line=$(script_line "$temporary/main-pre-deinstall" \
	'for recovery_config in adguardhome dhcp firewall; do')
start_line=$(script_line "$temporary/main-pre-deinstall" \
	'run_bounded 180 5 /etc/init.d/AdGuardHome start >/dev/null 2>&1 || true')
recovery_trap_line=$(script_line "$temporary/main-pre-deinstall" \
	"trap 'recover_failed_removal' 0")
stop_line=$(script_line "$temporary/main-pre-deinstall" \
	'run_bounded 180 5 env LUCI_ADGUARDHOME_PRERM_PHASE=bounded /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || exit 1')
clear_trap_line=$(script_line "$temporary/main-pre-deinstall" 'trap - 0 HUP INT TERM')
for line in "$default_line" "$rollback_line" "$enable_line" "$recovery_guard_line" \
	"$start_line" "$recovery_trap_line" "$stop_line" "$clear_trap_line"; do
	case "$line" in
		''|*[!0-9]*) die 'main APK pre-deinstall recovery ordering is incomplete' ;;
	esac
done
if ! { [ "$default_line" -lt "$rollback_line" ] &&
	[ "$rollback_line" -lt "$enable_line" ] &&
	[ "$enable_line" -lt "$recovery_guard_line" ] &&
	[ "$recovery_guard_line" -lt "$start_line" ] &&
	[ "$start_line" -lt "$recovery_trap_line" ] &&
	[ "$recovery_trap_line" -lt "$stop_line" ] &&
	[ "$stop_line" -lt "$clear_trap_line" ]; }; then
	die 'main APK pre-deinstall does not recover around its verified stop'
fi
grep -Fq 'verified AdGuard Home removal state' "$temporary/main-post-deinstall" ||
	die 'main APK post-deinstall lost verified cleanup state'

printf 'APK_OK version=%s\n' "$expected_version"
