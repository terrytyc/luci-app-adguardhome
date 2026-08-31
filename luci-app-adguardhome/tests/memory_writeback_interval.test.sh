#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
defaults_file="${package_dir}/root/etc/uci-defaults/40_luci-AdGuardHome"
init_file="${package_dir}/root/etc/init.d/AdGuardHome"
config_file="${package_dir}/root/etc/config/AdGuardHome"
overview_file="${package_dir}/htdocs/luci-static/resources/view/adguardhome/overview.js"
po_file="${package_dir}/po/zh_Hans/AdGuardHome.po"
readme_file="${package_dir}/../README.md"
makefile="${package_dir}/Makefile"

for required_file in \
	"$defaults_file" "$init_file" "$config_file" "$overview_file" "$po_file" "$readme_file" \
	"$makefile"; do
	[ -f "$required_file" ] || {
		printf 'required product file not found: %s\n' "$required_file" >&2
		exit 1
	}
done

# Exercise the exact dependency-free normalizers used during installation and
# at runtime.  Keeping both paths identical avoids octal interpretation of a
# manually-entered leading-zero value in the monitor's shell arithmetic.
run_normalizer() (
	local source_file="$1" input="$2" normalizer_source
	# The production function extracted below consumes these globals through
	# eval, which ShellCheck cannot follow statically.
	# shellcheck disable=SC2034
	MEMORY_WRITEBACK_DEFAULT_MINUTES=60
	# shellcheck disable=SC2034
	MEMORY_WRITEBACK_MAX_MINUTES=10080
	normalizer_source="$(awk '
		/^normalize_memory_writeback_interval\(\)/ { copying = 1 }
		copying { print }
		copying && /^}/ { exit }
	' "$source_file")"
	[ -n "$normalizer_source" ] || {
		printf 'memory write-back interval normalizer was not found in %s\n' \
			"$source_file" >&2
		exit 1
	}
	eval "$normalizer_source"
	normalize_memory_writeback_interval "$input"
)

expect_normalized() {
	local input="$1" expected="$2" actual source_file
	for source_file in "$defaults_file" "$init_file"; do
		actual="$(run_normalizer "$source_file" "$input")"
		[ "$actual" = "$expected" ] || {
			printf "normalization failed in %s for '%s': expected '%s', got '%s'\n" \
				"$source_file" "$input" "$expected" "$actual" >&2
			exit 1
		}
	done
}

expect_normalized '' 60
expect_normalized 0 0
expect_normalized 000 0
expect_normalized 1 1
expect_normalized 60 60
expect_normalized 00060 60
expect_normalized 10080 10080
expect_normalized 10081 60
expect_normalized 999999999999999999999999 60
expect_normalized -1 60
expect_normalized 1.5 60
expect_normalized invalid 60

require_text() {
	local file="$1" text="$2"
	grep -Fq -- "$text" "$file" || {
		printf 'missing product contract in %s: %s\n' "$file" "$text" >&2
		exit 1
	}
}

require_text "$config_file" "option memory_writeback_interval '60'"
# Literal shell variables are the source contract under inspection.
# shellcheck disable=SC2016
require_text "$defaults_file" 'set_upper_option memory_writeback_interval "$memory_writeback_interval"'
require_text "$init_file" 'memory_writeback_locked_command() {'
require_text "$init_file" 'memory_copy_live_data_locked() ('
require_text "$init_file" 'uid853_tree_is_writable() {'
require_text "$init_file" 'memory_copy_live_data_locked || return $?'
# shellcheck disable=SC2016
require_text "$init_file" '-n AGHMemorySave -x /bin/cp -- -pR "${source}/." "$target/"'
require_text "$init_file" 'PACKAGED_CONFIG_TEMPLATE="/usr/share/luci-app-adguardhome/default.yaml"'
require_text "$overview_file" "'memory_writeback_interval',"
require_text "$overview_file" 'option.default = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);'
require_text "$overview_file" "option.depends('run_from_memory', '1');"
require_text "$overview_file" 'interval > MAX_MEMORY_WRITEBACK_INTERVAL'
require_text "$overview_file" 'Set 0 to disable periodic write-back; a normal stop or restart still performs a complete write-back.'
require_text "$po_file" 'msgid "Memory write-back interval (minutes)"'
# Backticks and the package name are literal README contract text.
# shellcheck disable=SC2016
require_text "$readme_file" '不新增 `rsync`、cron、`coreutils-stat` 或 `coreutils-timeout` 等依赖'

function_body() {
	awk -v function_name="$2" '
		$0 == function_name "() {" || $0 == function_name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' "$1"
}

writeback_body="$(function_body "$init_file" memory_writeback_locked_command)"
copy_body="$(function_body "$init_file" memory_copy_live_data_locked)"
writable_body="$(function_body "$init_file" uid853_tree_is_writable)"
ensure_body="$(function_body "$init_file" ensure_config_file)"
orchestrate_body="$(function_body "$init_file" orchestrate_core_locked)"
stop_body="$(function_body "$init_file" stop_wrapper_locked)"

if [ -z "$writeback_body" ] || [ -z "$copy_body" ] || [ -z "$writable_body" ] || [ -z "$ensure_body" ] ||
   [ -z "$orchestrate_body" ] || [ -z "$stop_body" ]; then
	printf 'unable to extract the memory/write-directory implementation contract\n' >&2
	exit 1
fi

# Literal shell fragments are the implementation contract being inspected.
# shellcheck disable=SC2016
for forbidden in \
	'memory_begin_live_checkpoint' \
	'clear_recorded_integration_locked' \
	'wait_for_core_stopped' \
	'memory_checkpoint_full_locked' \
	'memory_restore_live_checkpoint_locked' \
	'"$OFFICIAL_SERVICE" stop' \
	'"$OFFICIAL_SERVICE" start'; do
	if printf '%s\n' "$writeback_body" | grep -Fq -- "$forbidden"; then
		printf 'live memory write-back still performs a service/checkpoint transaction: %s\n' \
			"$forbidden" >&2
		exit 1
	fi
done

# shellcheck disable=SC2016
for forbidden in \
	'memory_write_journal' \
	'memory_advance_journal' \
	'memory_begin_live_checkpoint' \
	'clear_recorded_integration_locked' \
	'"$OFFICIAL_SERVICE"'; do
	if printf '%s\n' "$copy_body" | grep -Fq -- "$forbidden"; then
		printf 'direct live data copy reintroduced a journal or service mutation: %s\n' \
			"$forbidden" >&2
		exit 1
	fi
done

# A healthy persistent directory must be reused so cp overwrites matching files
# without deleting unrelated existing files.  Only the explicit unusable-target
# branch may remove and recreate it.
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- 'target_ready=1' || {
	printf 'direct live data copy does not preserve a valid persistent data directory\n' >&2
	exit 1
}
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- 'uid853_tree_is_writable "$target"' || {
	printf 'direct live data copy does not detect an unwritable persistent data tree\n' >&2
	exit 1
}
# These are intentionally literal source fragments.
# shellcheck disable=SC2016
for ownership_guard in '-user "$2"' '-group "$3"' '"$ADGUARD_UID" "$ADGUARD_GID"'; do
	if ! printf '%s\n' "$writable_body" | grep -Fq -- "$ownership_guard"; then
		printf 'direct live data copy does not reject foreign-owned target entries: %s\n' \
			"$ownership_guard" >&2
		exit 1
	fi
done
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- 'if [ "$target_ready" != 1 ]; then' || {
	printf 'direct live data copy lacks the damaged-target recovery boundary\n' >&2
	exit 1
}
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- '/bin/rm -rf "$target"' || {
	printf 'direct live data copy cannot recover an unusable persistent data target\n' >&2
	exit 1
}
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- \
	'-n AGHMemorySave -x /bin/cp -- -pR "${source}/." "$target/"' || {
	printf 'direct live data copy command is missing\n' >&2
	exit 1
}
# shellcheck disable=SC2016
printf '%s\n' "$ensure_body" | grep -Fq -- 'source="$PACKAGED_CONFIG_TEMPLATE"' || {
	printf 'an empty workdir is not initialized from the packaged template\n' >&2
	exit 1
}
if printf '%s\n' "$ensure_body" | grep -Fq -- 'previous_config'; then
	printf 'workdir initialization still copies the previous YAML\n' >&2
	exit 1
fi
if grep -Fq -- 'migrate_work_data' "$init_file"; then
	printf 'runtime workdir switching still contains old data migration logic\n' >&2
	exit 1
fi
if grep -Fq -- 'memory_begin_live_checkpoint' "$init_file"; then
	printf '2.3 runtime still contains a path that can create a live checkpoint marker\n' >&2
	exit 1
fi
# A normal wrapper restart and stop already cross a stopped-core boundary, so
# they must retain the complete YAML/data checkpoint used for orderly shutdown.
printf '%s\n' "$orchestrate_body" | grep -Fq -- 'memory_checkpoint_full_locked || return 1' || {
	printf 'normal restart no longer checkpoints the stopped RAM workdir\n' >&2
	exit 1
}
printf '%s\n' "$stop_body" | grep -Fq -- 'memory_deactivate_locked 1 || return 1' || {
	printf 'normal stop no longer checkpoints and deactivates the RAM workdir\n' >&2
	exit 1
}
require_text "$init_file" 'memory_restore_live_checkpoint_locked() {'
require_text "$init_file" 'memory_live_marker_load || marker_rc=$?'
require_text "$init_file" 'memory_clear_live_checkpoint || return 1'

if grep -Eq '^LUCI_DEPENDS:=.*\+coreutils-stat([[:space:]]|$)' "$makefile"; then
	printf 'RAM mode must not add a coreutils-stat package dependency\n' >&2
	exit 1
fi

if grep -Eq '^LUCI_DEPENDS:=.*\+coreutils-timeout([[:space:]]|$)' "$makefile"; then
	printf 'the plugin must not depend on coreutils-timeout\n' >&2
	exit 1
fi

printf 'ok - memory write-back interval product contract\n'
