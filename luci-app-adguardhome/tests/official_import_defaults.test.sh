#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
defaults="${script_dir}/../root/etc/uci-defaults/40_luci-AdGuardHome"

function_body() {
	awk -v function_name="$2" '
		$0 == function_name "() {" { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$1"
}

initialize_body="$(function_body "$defaults" initialize_merged_options)"
select_body="$(function_body "$defaults" select_migration_source)"
[ -n "$initialize_body" ] && [ -n "$select_body" ] || {
	printf '%s\n' 'unable to extract official import functions' >&2
	exit 1
}

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/luci-agh-import-defaults.XXXXXX")"
cleanup() {
	rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$temporary_dir/target" "$temporary_dir/volatile"
printf '%s\n' template >"$temporary_dir/packaged-default.yaml"

exercise_source_selection() (
	mode=$1
	eval "$select_body"
	LEGACY_CONFIG_PRESENT=0
	IS_UPGRADE=0
	IMPORT_OFFICIAL=0
	IMPORT_OFFICIAL_USES_TEMPLATE=0
	DATA_SOURCE_WORK_DIR=""
	DEFAULT_WORK_DIR="$temporary_dir/target"
	DEFAULT_CONFIG_FILE="$DEFAULT_WORK_DIR/AdGuardHome.yaml"
	PACKAGED_CONFIG_TEMPLATE="$temporary_dir/packaged-default.yaml"
	OFFICIAL_WORK_DIR="$temporary_dir/volatile"
	OFFICIAL_CONFIG_FILE="$temporary_dir/official.yaml"
	target_config="$DEFAULT_WORK_DIR/AdGuardHome.yaml"
	rm -f "$OFFICIAL_CONFIG_FILE" "$target_config"
	case "$mode" in
		template)
			cp "$PACKAGED_CONFIG_TEMPLATE" "$target_config"
			expected_source=$target_config
			expected_template=1
			;;
		official)
			printf '%s\n' official >"$OFFICIAL_CONFIG_FILE"
			expected_source=$OFFICIAL_CONFIG_FILE
			expected_template=0
			;;
		official-target-template)
			OFFICIAL_CONFIG_FILE=$target_config
			cp "$PACKAGED_CONFIG_TEMPLATE" "$target_config"
			expected_source=$target_config
			expected_template=1
			;;
		official-target-user)
			OFFICIAL_CONFIG_FILE=$target_config
			printf '%s\n' user >"$target_config"
			expected_source=$target_config
			expected_template=0
			;;
		target)
			printf '%s\n' target >"$target_config"
			expected_source=$target_config
			expected_template=0
			;;
		missing-target)
			expected_source=$PACKAGED_CONFIG_TEMPLATE
			expected_template=1
			;;
		*) return 1 ;;
	esac
	official_state_is_meaningful() { return 0; }
	normalize_work_dir() { printf '%s\n' "$1"; }
	is_safe_source_work_dir() { return 0; }
	valid_yaml_source_path() { [ -f "$1" ] && [ ! -L "$1" ]; }
	trusted_root_file_source() {
		[ "$1" = "$PACKAGED_CONFIG_TEMPLATE" ] && [ -f "$1" ] && [ ! -L "$1" ]
	}
	select_migration_source >/dev/null
	[ "$IMPORT_OFFICIAL" = 1 ]
	[ "$SOURCE_CONFIG_FILE" = "$expected_source" ]
	[ "$IMPORT_OFFICIAL_USES_TEMPLATE" = "$expected_template" ]
)

for source_mode in template official official-target-template \
	official-target-user target missing-target; do
	exercise_source_selection "$source_mode" || {
		printf 'official import source selection failed: %s\n' "$source_mode" >&2
		exit 1
	}
done

(
	eval "$initialize_body"
	LEGACY_CONFIG_PRESENT=0
	IMPORT_OFFICIAL=1
	IMPORT_OFFICIAL_USES_TEMPLATE=1
	OFFICIAL_ENABLED=1
	OFFICIAL_VERBOSE=1
	DEFAULT_CONFIG_FILE=/usr/share/luci-app-adguardhome/default.yaml
	SOURCE_CONFIG_FILE=$DEFAULT_CONFIG_FILE
	set_official_option() {
		case "$1" in
			enabled) official_enabled=$2 ;;
			verbose) official_verbose=$2 ;;
			*) return 1 ;;
		esac
	}
	set_luci_option() {
		case "$1" in
			redirect) luci_redirect=$2 ;;
			run_from_memory) luci_run_from_memory=$2 ;;
			memory_writeback_interval) luci_memory_writeback_interval=$2 ;;
			*) return 1 ;;
		esac
	}
	initialize_merged_options
	[ "$official_enabled:$official_verbose" = 1:1 ]
	[ "$luci_redirect:$luci_run_from_memory:$luci_memory_writeback_interval" = \
		dnsmasq-upstream:0:60 ]
) || {
	printf '%s\n' 'official state without YAML did not receive the confirmed plugin defaults' >&2
	exit 1
}

(
	eval "$initialize_body"
	LEGACY_CONFIG_PRESENT=0
	IMPORT_OFFICIAL=1
	IMPORT_OFFICIAL_USES_TEMPLATE=0
	OFFICIAL_ENABLED=1
	OFFICIAL_VERBOSE=0
	DEFAULT_CONFIG_FILE=/usr/share/luci-app-adguardhome/default.yaml
	SOURCE_CONFIG_FILE=/etc/adguardhome/adguardhome.yaml
	set_official_option() {
		case "$1" in
			enabled) official_enabled=$2 ;;
			verbose) official_verbose=$2 ;;
			*) return 1 ;;
		esac
	}
	set_luci_option() {
		case "$1" in
			redirect) luci_redirect=$2 ;;
			run_from_memory) luci_run_from_memory=$2 ;;
			memory_writeback_interval) luci_memory_writeback_interval=$2 ;;
			*) return 1 ;;
		esac
	}
	initialize_merged_options
	[ "$official_enabled:$official_verbose" = 1:0 ]
	[ "$luci_redirect:$luci_run_from_memory:$luci_memory_writeback_interval" = \
		none:0:60 ]
) || {
	printf '%s\n' 'existing official YAML did not retain a non-invasive DNS policy' >&2
	exit 1
}

(
	eval "$initialize_body"
	LEGACY_CONFIG_PRESENT=0
	IMPORT_OFFICIAL=1
	IMPORT_OFFICIAL_USES_TEMPLATE=0
	OFFICIAL_ENABLED=1
	OFFICIAL_VERBOSE=0
	DEFAULT_CONFIG_FILE=/etc/AdGuardHome/AdGuardHome.yaml
	SOURCE_CONFIG_FILE=$DEFAULT_CONFIG_FILE
	set_official_option() {
		case "$1" in
			enabled) official_enabled=$2 ;;
			verbose) official_verbose=$2 ;;
			*) return 1 ;;
		esac
	}
	set_luci_option() {
		case "$1" in
			redirect) luci_redirect=$2 ;;
			run_from_memory) luci_run_from_memory=$2 ;;
			memory_writeback_interval) luci_memory_writeback_interval=$2 ;;
			*) return 1 ;;
		esac
	}
	initialize_merged_options
	[ "$luci_redirect" = none ]
) || {
	printf '%s\n' 'existing official YAML at the target path was mistaken for the package template' >&2
	exit 1
}

printf '%s\n' 'ok - official import DNS defaults follow YAML ownership'
