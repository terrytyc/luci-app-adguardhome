#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
makefile="${package_dir}/Makefile"
defaults="${package_dir}/root/etc/uci-defaults/40_luci-AdGuardHome"
init_file="${package_dir}/root/etc/init.d/AdGuardHome"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/luci-agh-cold-barrier.XXXXXX")"
cleanup() {
	rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

awk '
	$0 == "define Package/$(PKG_NAME)/postinst" { copying = 1; next }
	copying && /^endef$/ { exit }
	copying { gsub(/\$\$/, "$"); print }
' "$makefile" >"${temporary_dir}/postinst.sh"

function_body() {
	awk -v function_name="$2" '
		$0 == function_name "() {" || $0 == function_name "() (" {
			copying = 1
			depth = 0
		}
		copying {
			print
			line = $0
			opens = gsub(/\{/, "{", line)
			line = $0
			closes = gsub(/\}/, "}", line)
			depth += opens - closes
			if (depth == 0) exit
		}
	' "$1"
}

validator_body="$(function_body "$init_file" upgrade_stopped_marker_is_valid)"
[ -n "$validator_body" ] || {
	printf 'missing durable stopped-upgrade barrier validator\n' >&2
	exit 1
}
if printf '%s\n' "$validator_body" | grep -Eq 'rm[[:space:]]|rmdir[[:space:]]'; then
	printf 'init barrier validation still consumes lifecycle state\n' >&2
	exit 1
fi

create_body="$(function_body "$defaults" create_upgrade_stopped_marker)"
# Match literal shell source rather than expanding it in this test process.
# shellcheck disable=SC2016
printf '%s\n' "$create_body" |
	grep -Fq 'validate_runtime_marker "$UPGRADE_STOPPED_MARKER"' || {
	printf 'uci-defaults cannot reuse a valid stopped-upgrade barrier\n' >&2
	exit 1
}
initial_barrier_body="$(sed -n \
	'/# This durable barrier must survive/,/^[[:space:]]*fi$/p' "$defaults")"
printf '%s\n' "$initial_barrier_body" |
	grep -Fq 'UPGRADE_STOPPED_MARKER_FOUND=1' || {
	printf 'uci-defaults does not remember a pre-existing stop barrier\n' >&2
	exit 1
}
# Match literal shell source rather than expanding it in this test process.
# shellcheck disable=SC2016
if printf '%s\n' "$initial_barrier_body" |
	grep -Fq 'rm -f "$UPGRADE_STOPPED_MARKER"'; then
	printf 'uci-defaults still deletes the stop barrier on retry\n' >&2
	exit 1
fi

postinst="${temporary_dir}/postinst.sh"
rpcd_line="$(grep -n '^[[:space:]]*! /etc/init.d/rpcd reload' "$postinst" |
	cut -d: -f1)"
retire_line="$(grep -n '^retire_cold_postinst_state ||' "$postinst" | cut -d: -f1)"
early_consume_line="$(grep -n '^[[:space:]]*consume_cold_stopped_barrier ||' "$postinst" |
	head -n 1 | cut -d: -f1)"
consume_line="$(grep -n '^[[:space:]]*consume_cold_stopped_barrier ||' "$postinst" |
	tail -n 1 | cut -d: -f1)"
case "$early_consume_line:$rpcd_line:$retire_line:$consume_line" in
	*[!0-9:]*|:*|*:|*::*)
		printf 'ambiguous cold barrier postinst ordering\n' >&2
		exit 1
		;;
esac
if ! { [ "$early_consume_line" -lt "$rpcd_line" ] &&
	[ "$rpcd_line" -lt "$retire_line" ] &&
	[ "$retire_line" -lt "$consume_line" ]; }; then
	printf 'cold barrier can be consumed before the final rpcd/state checks\n' >&2
	exit 1
fi
[ "$(grep -c '^[[:space:]]*consume_cold_stopped_barrier ||' "$postinst")" = 2 ] || {
	printf 'postinst has an unexpected stopped-barrier consumption path\n' >&2
	exit 1
}
grep -Fq 'elif cold_stopped_barrier_valid; then' "$postinst" || {
	printf 'postinst cannot recover the safe marker-only interrupted tail\n' >&2
	exit 1
}

# Dynamically exercise the interruption boundary: state retirement is allowed
# to finish while the stop barrier remains.  A retry recognizes that marker-only
# tail and consumes it only as its final successful action.
(
	for function_name in \
		load_cold_postinst_state cold_stopped_barrier_valid \
		cold_postinst_dir_is_empty \
		consume_cold_stopped_barrier retire_cold_postinst_state; do
		body="$(function_body "$postinst" "$function_name")"
		[ -n "$body" ] || exit 1
		eval "$body"
	done
	root_private_directory() { [ -d "$1" ] && [ ! -L "$1" ]; }
	root_private_single_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
	runtime_dir="${temporary_dir}/runtime"
	upgrade_stopped_marker="${runtime_dir}/upgrade-was-stopped"
	cold_postinst_dir="${temporary_dir}/cold"
	cold_postinst_state="${cold_postinst_dir}/cold-upgrade"
	mkdir -m 0700 "$runtime_dir" "$cold_postinst_dir"
	printf '1\n' >"$upgrade_stopped_marker"
	chmod 0600 "$upgrade_stopped_marker"
	{
		printf 'format=1\n'
		printf 'source_version=2.3.0-r2\n'
		printf 'was_running=0\n'
	} >"$cold_postinst_state"
	chmod 0600 "$cold_postinst_state"
	# The eval-loaded lifecycle functions consume these variables.
	# shellcheck disable=SC2034
	cold_upgrade=1
	# shellcheck disable=SC2034
	cold_source_version=2.3.0-r2
	# shellcheck disable=SC2034
	cold_was_running=0

	retire_cold_postinst_state || exit 1
	[ ! -e "$cold_postinst_dir" ] || exit 1
	cold_stopped_barrier_valid || exit 1
	# Simulated interruption here leaves a marker-only state.  The retry's
	# default start remains suppressed; its custom tail can now finish safely.
	# shellcheck disable=SC2034
	cold_was_running=0
	consume_cold_stopped_barrier || exit 1
	[ ! -e "$upgrade_stopped_marker" ] && [ ! -L "$upgrade_stopped_marker" ]

	# A kill between unlinking the state file and rmdir leaves an authenticated
	# empty private directory plus the barrier.  The retry may remove only that
	# exact empty directory before consuming the still-valid barrier.
	printf '1\n' >"$upgrade_stopped_marker"
	chmod 0600 "$upgrade_stopped_marker"
	mkdir -m 0700 "$cold_postinst_dir"
	cold_postinst_dir_is_empty || exit 1
	cold_stopped_barrier_valid || exit 1
	rmdir "$cold_postinst_dir" || exit 1
	# shellcheck disable=SC2034
	cold_was_running=0
	consume_cold_stopped_barrier || exit 1
	[ ! -e "$upgrade_stopped_marker" ] && [ ! -L "$upgrade_stopped_marker" ]
) || {
	printf 'marker-only cold-upgrade tail recovery failed\n' >&2
	exit 1
}

printf 'ok - repeatable stopped cold-upgrade postinst barrier\n'
