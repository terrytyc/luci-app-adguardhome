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
	MEMORY_WRITEBACK_DEFAULT_MINUTES=60
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
require_text "$init_file" 'memory_begin_live_checkpoint || return 1'
require_text "$init_file" 'memory_checkpoint_full_locked || operation_rc=1'
require_text "$init_file" 'memory_restore_live_checkpoint_locked planned || restore_rc=$?'
require_text "$overview_file" "'memory_writeback_interval',"
require_text "$overview_file" 'option.default = String(DEFAULT_MEMORY_WRITEBACK_INTERVAL);'
require_text "$overview_file" "option.depends('run_from_memory', '1');"
require_text "$overview_file" 'interval > MAX_MEMORY_WRITEBACK_INTERVAL'
require_text "$overview_file" 'Set 0 to disable periodic write-back; normal stop or restart still writes back.'
require_text "$po_file" 'msgid "Memory write-back interval (minutes)"'
# Backticks and the package name are literal README contract text.
# shellcheck disable=SC2016
require_text "$readme_file" '不新增 `rsync`、cron、`coreutils-stat` 或 `coreutils-timeout` 等依赖'

if grep -Eq '^LUCI_DEPENDS:=.*\+coreutils-stat([[:space:]]|$)' "$makefile"; then
	printf 'RAM mode must not add a coreutils-stat package dependency\n' >&2
	exit 1
fi

if grep -Eq '^LUCI_DEPENDS:=.*\+coreutils-timeout([[:space:]]|$)' "$makefile"; then
	printf 'the plugin must not depend on coreutils-timeout\n' >&2
	exit 1
fi

printf 'ok - memory write-back interval product contract\n'
