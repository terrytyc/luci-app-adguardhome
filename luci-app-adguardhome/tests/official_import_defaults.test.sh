#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
defaults="$script_dir/../root/etc/uci-defaults/40_luci-AdGuardHome"

if grep -Fq -- '-quit' "$defaults"; then
	printf 'installer uses find -quit, which BusyBox 1.37 does not support\n' >&2
	exit 1
fi

function_body() {
	awk -v function_name="$2" '
		$0 == function_name "() {" { copying = 1 }
		copying { print }
		copying && $0 == "}" { exit }
	' "$1"
}

select_body="$(function_body "$defaults" select_clean_install_source)"
initialize_body="$(function_body "$defaults" initialize_clean_options)"
normalize_body="$(function_body "$defaults" normalize_bool)"
[ -n "$select_body" ] && [ -n "$initialize_body" ] &&
	[ -n "$normalize_body" ] || {
	printf 'unable to extract clean-install source functions\n' >&2
	exit 1
}

temporary_dir="$(mktemp -d /tmp/luci-agh-import-defaults.XXXXXX)"
cleanup() {
	rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$temporary_dir/target" "$temporary_dir/volatile"
printf '%s\n' template >"$temporary_dir/default.yaml"

exercise_source_selection() (
	mode="$1"
	eval "$select_body"
	DEFAULT_WORK_DIR="$temporary_dir/target"
	PACKAGED_CONFIG_TEMPLATE="$temporary_dir/default.yaml"
	OFFICIAL_DEFAULT_CONFIG="$temporary_dir/missing-official.yaml"
	OFFICIAL_DEFAULT_WORK_DIR="$temporary_dir/volatile"
	UCI_CONFIG=adguardhome
	OFFICIAL_SECTION=config
	TARGET_WORK_DIR=""
	TARGET_CONFIG_FILE=""
	SOURCE_WORK_DIR=""
	SOURCE_CONFIG_FILE=""
	USING_TEMPLATE=0
	fixture_work="$temporary_dir/volatile"
	fixture_file="$temporary_dir/missing-official.yaml"
	case "$mode" in
		template)
			cp "$PACKAGED_CONFIG_TEMPLATE" "$DEFAULT_WORK_DIR/AdGuardHome.yaml"
			expected_source="$DEFAULT_WORK_DIR/AdGuardHome.yaml"
			expected_template=1
			;;
		official)
			printf '%s\n' official >"$temporary_dir/official.yaml"
			fixture_file="$temporary_dir/official.yaml"
			expected_source="$fixture_file"
			expected_template=0
			;;
		missing)
			rm -f "$DEFAULT_WORK_DIR/AdGuardHome.yaml"
			expected_source="$PACKAGED_CONFIG_TEMPLATE"
			expected_template=1
			;;
		managed)
			fixture_work=/mnt/storage/AdGuardHome
			printf '%s\n' managed >"$temporary_dir/managed.yaml"
			fixture_file="$temporary_dir/managed.yaml"
			expected_source="$fixture_file"
			expected_template=0
			;;
		*) return 1 ;;
	esac
	uci() {
		[ "$1:$2" = -q:get ] || return 1
		case "$3" in
			adguardhome.config.work_dir) printf '%s\n' "$fixture_work" ;;
			adguardhome.config.config_file) printf '%s\n' "$fixture_file" ;;
			*) return 1 ;;
		esac
	}
	resolve_source_work_dir() {
		printf '%s\n' "$1"
	}
	resolve_source_file() {
		[ -f "$1" ] && [ ! -L "$1" ] || return 1
		printf '%s\n' "$1"
	}
	valid_managed_work_dir() {
		case "$1" in /mnt/*/AdGuardHome) return 0 ;; esac
		return 1
	}
	trim_trailing_slashes() {
		printf '%s\n' "$1" | sed 's:/*$::'
	}
	select_clean_install_source
	[ "$TARGET_WORK_DIR" = "$DEFAULT_WORK_DIR" ] || [ "$mode" = managed ]
	[ "$SOURCE_CONFIG_FILE" = "$expected_source" ]
	[ "$USING_TEMPLATE" = "$expected_template" ]
	if [ "$mode" = managed ]; then
		[ "$TARGET_WORK_DIR" = /mnt/storage/AdGuardHome ]
	fi
)

for source_mode in template official missing managed; do
	exercise_source_selection "$source_mode" || {
		printf 'clean official source selection failed: %s\n' "$source_mode" >&2
		exit 1
	}
done

exercise_defaults() (
	mode="$1"
	eval "$normalize_body"
	eval "$initialize_body"
	UCI_CONFIG=adguardhome
	OFFICIAL_SECTION=config
	TARGET_CONFIG_FILE=/etc/AdGuardHome/AdGuardHome.yaml
	TARGET_WORK_DIR=/etc/AdGuardHome
	case "$mode" in
		template)
			USING_TEMPLATE=1
			configured_enabled=0
			configured_verbose=1
			expected=1:1:dnsmasq-upstream:0:60
			;;
		existing)
			USING_TEMPLATE=0
			configured_enabled=1
			configured_verbose=0
			expected=1:0:none:0:60
			;;
		*) return 1 ;;
	esac
	uci() {
		[ "$1:$2" = -q:get ] || return 1
		case "$3" in
			adguardhome.config.enabled) printf '%s\n' "$configured_enabled" ;;
			adguardhome.config.verbose) printf '%s\n' "$configured_verbose" ;;
			*) return 1 ;;
		esac
	}
	set_official_option() {
		case "$1" in
			enabled) result_enabled="$2" ;;
			verbose) result_verbose="$2" ;;
			config_file|work_dir) ;;
			*) return 1 ;;
		esac
	}
	set_luci_option() {
		case "$1" in
			redirect) result_redirect="$2" ;;
			run_from_memory) result_memory="$2" ;;
			memory_writeback_interval) result_interval="$2" ;;
			*) return 1 ;;
		esac
	}
	initialize_clean_options
	actual="$result_enabled:$result_verbose:$result_redirect:$result_memory:$result_interval"
	[ "$actual" = "$expected" ]
)

exercise_defaults template || {
	printf 'packaged template did not receive the confirmed defaults\n' >&2
	exit 1
}
exercise_defaults existing || {
	printf 'existing official YAML did not receive the non-invasive DNS default\n' >&2
	exit 1
}

printf 'ok - clean official import and DNS defaults\n'
