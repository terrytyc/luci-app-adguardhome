#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
defaults_file="${package_dir}/root/etc/uci-defaults/40_luci-AdGuardHome"
init_file="${package_dir}/root/etc/init.d/AdGuardHome"
overview_file="${package_dir}/htdocs/luci-static/resources/view/adguardhome/overview.js"
po_file="${package_dir}/po/zh_Hans/AdGuardHome.po"
readme_file="${package_dir}/../README.md"
makefile="${package_dir}/Makefile"

for required_file in \
	"$defaults_file" "$init_file" "$overview_file" "$po_file" "$readme_file" \
	"$makefile"; do
	[ -f "$required_file" ] || {
		printf 'required product file not found: %s\n' "$required_file" >&2
		exit 1
	}
done

# Exercise the runtime's dependency-free normalizer.  The 2.4 baseline
# installer preserves a valid existing interval and writes the literal default
# on a clean install; runtime remains the single normalization boundary for
# manually-entered leading zeros and invalid values.
run_normalizer() (
	local source_file="$init_file" input="$1" normalizer_source
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
	local input="$1" expected="$2" actual
	actual="$(run_normalizer "$input")"
	[ "$actual" = "$expected" ] || {
		printf "normalization failed in %s for '%s': expected '%s', got '%s'\n" \
			"$init_file" "$input" "$expected" "$actual" >&2
		exit 1
	}
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

# Literal shell variables are the source contract under inspection.
# shellcheck disable=SC2016
require_text "$defaults_file" 'set_luci_option memory_writeback_interval 60'
require_text "$init_file" 'memory_writeback_locked_command() {'
require_text "$init_file" 'memory_copy_live_data_locked() ('
require_text "$init_file" 'uid853_tree_is_writable() {'
require_text "$init_file" 'sync_yaml_workdir_pattern() {'
require_text "$init_file" 'memory_copy_live_data_locked || return $?'
# shellcheck disable=SC2016
require_text "$init_file" '-n AGHMemorySave -x /bin/cp -- -pR "${source}/." "$target/"'
require_text "$init_file" 'PACKAGED_CONFIG_TEMPLATE="/usr/share/luci-app-adguardhome/default.yaml"'
require_text "$overview_file" "'memory_writeback_interval',"
require_text "$overview_file" 'option.default = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);'
require_text "$overview_file" 'option.retain = true;'
require_text "$overview_file" "option.depends('run_from_memory', '1');"
require_text "$overview_file" 'interval > MAX_MEMORY_WRITEBACK_INTERVAL'
require_text "$overview_file" 'Set 0 to disable periodic write-back; a normal stop or restart still performs a complete write-back.'
require_text "$po_file" 'msgid "Memory write-back interval (minutes)"'
# Backticks and the package name are literal README contract text.
# shellcheck disable=SC2016
require_text "$readme_file" '不新增 `rsync`、cron、`coreutils-stat` 或 `coreutils-timeout` 等依赖'

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

writeback_body="$(function_body "$init_file" memory_writeback_locked_command)"
copy_body="$(function_body "$init_file" memory_copy_live_data_locked)"
prepare_body="$(function_body "$init_file" memory_prepare_runtime_locked)"
writable_body="$(function_body "$init_file" uid853_mounted_tree_is_writable)"
ensure_body="$(function_body "$init_file" ensure_config_file)"
orchestrate_body="$(function_body "$init_file" orchestrate_core_locked)"
stop_body="$(function_body "$init_file" stop_wrapper_locked)"

if [ -z "$writeback_body" ] || [ -z "$copy_body" ] || [ -z "$prepare_body" ] ||
   [ -z "$writable_body" ] || [ -z "$ensure_body" ] ||
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

# RAM mode moves only the data directory.  The core's YAML path must remain the
# authoritative file under the persistent workdir throughout preparation.
# shellcheck disable=SC2016
for required in \
	'data_source="${persistent_work_dir}/data"' \
	'data_target="$MEMORY_DATA_DIR"' \
	'config_file="$persistent_config_file"'; do
	if ! printf '%s\n' "$prepare_body" | grep -Fq -- "$required"; then
		printf 'RAM preparation does not preserve the data-only contract: %s\n' \
			"$required" >&2
		exit 1
	fi
done
if printf '%s\n' "$prepare_body" |
	grep -E '(^|[[:space:]])(/bin/)?cp([[:space:]]|.*AdGuardHome[.]yaml)' >/dev/null; then
	printf 'RAM preparation still copies the persistent YAML into memory\n' >&2
	exit 1
fi

# The persistent workdir is also the live YAML directory in v2.4.  A periodic
# data copy must never change ownership or mode
# on the persistent parent (including through the held directory descriptor).
if printf '%s\n' "$copy_body" |
	grep -Eq '(chown|chmod).*[$](MEMORY_BACKING_WORK_DIR|backing_fd)'; then
	printf 'direct live data copy changes ownership or mode on the persistent backing parent\n' >&2
	exit 1
fi

# Every data-tree mutator must run behind start-stop-daemon's uid-853 boundary;
# the live-copy subprocess must not execute a root chown/chmod/mkdir/rm itself.
root_mutators="$(printf '%s\n' "$copy_body" |
	sed '/^[[:space:]]*#/d' |
	grep -E '(^|[[:space:]])(/bin/)?(chown|chmod|mkdir|rm)([[:space:]]|$)' |
	grep -Fv -- '-x /bin/' || true)"
if [ -n "$root_mutators" ]; then
	printf 'direct live data copy contains a root target mutator:\n%s\n' \
		"$root_mutators" >&2
	exit 1
fi

# These exact argv boundaries keep each permitted target mutation unprivileged.
# shellcheck disable=SC2016
for unprivileged_mutator in \
	'-n AGHDataMode -x /bin/chmod -- 0700 "$target"' \
	'-n AGHMemorySave -x /bin/cp -- -pR "${source}/." "$target/"'; do
	if ! printf '%s\n' "$copy_body" | grep -Fq -- "$unprivileged_mutator"; then
		printf 'direct live data copy lacks an unprivileged target mutation: %s\n' \
			"$unprivileged_mutator" >&2
		exit 1
	fi
done

# The persistent directory is always reused: cp overwrites matching files while
# retaining unrelated files.  No clear/recreate path is permitted.
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- 'uid853_mounted_tree_is_writable "$target"' || {
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
for forbidden_mutator in 'AGHDataClear' 'AGHDataMake' '/bin/rm' '/bin/mkdir'; do
	if printf '%s\n' "$copy_body" | grep -Fq -- "$forbidden_mutator"; then
		printf 'direct live data copy may clear or recreate persistent data: %s\n' \
			"$forbidden_mutator" >&2
		exit 1
	fi
done
# shellcheck disable=SC2016
printf '%s\n' "$copy_body" | grep -Fq -- 'target="$MEMORY_BACKING_DATA_MOUNT"' || {
	printf 'direct live data copy does not target the authenticated persistent alias\n' >&2
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
	printf 'v2.4 runtime still contains a path that can create a live checkpoint marker\n' >&2
	exit 1
fi
# A normal wrapper restart directly copies to the persistent alias without
# tearing down the RAM generation; an orderly stop performs full deactivation.
printf '%s\n' "$orchestrate_body" | grep -Fq -- 'memory_copy_stopped_data_locked || return 1' || {
	printf 'normal restart no longer writes stopped RAM data directly\n' >&2
	exit 1
}
printf '%s\n' "$stop_body" | grep -Fq -- 'memory_deactivate_locked 1 || return 1' || {
	printf 'normal stop no longer checkpoints and deactivates the RAM workdir\n' >&2
	exit 1
}
for obsolete in \
	'MEMORY_JOURNAL' \
	'memory_write_journal' \
	'memory_recover_journal' \
	'memory_restore_live_checkpoint' \
	'memory_live_marker_load' \
	'memory_clear_live_checkpoint' \
	'MEMORY_LIVE_MARKER'; do
	if grep -Fq -- "$obsolete" "$init_file"; then
		printf 'removed RAM history mechanism remains in init: %s\n' "$obsolete" >&2
		exit 1
	fi
done
require_text "$init_file" 'memory_discard_incomplete_runtime_locked() {'

if grep -Eq '^LUCI_DEPENDS:=.*\+coreutils-stat([[:space:]]|$)' "$makefile"; then
	printf 'RAM mode must not add a coreutils-stat package dependency\n' >&2
	exit 1
fi

if grep -Eq '^LUCI_DEPENDS:=.*\+coreutils-timeout([[:space:]]|$)' "$makefile"; then
	printf 'the plugin must not depend on coreutils-timeout\n' >&2
	exit 1
fi

printf 'ok - memory write-back interval product contract\n'
