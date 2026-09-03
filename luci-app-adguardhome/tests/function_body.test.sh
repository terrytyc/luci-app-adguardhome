#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
original_options="$-"
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
[ "$-" = "$original_options" ]

temporary="$(mktemp -d /tmp/luci-agh-function-body.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
brace='selected() {
	if [ "$1" = yes ]; then
		printf "%s\n" "$2"
	fi
}'
subshell='isolated() (
	printf "%s\n" "$1"
)'
# The top-level exit must never run; names must match exactly, and a pathname
# containing spaces must remain one argument. Extraction does not eval its text.
printf '%s\n' 'exit 77' "$brace" "$subshell" \
	'selected_extra() {' ' ignored' '}' >"$temporary/source with spaces"
[ "$(function_body "$temporary/source with spaces" selected)" = "$brace" ]
[ "$(function_body "$temporary/source with spaces" isolated)" = "$subshell" ]
[ -z "$(function_body "$temporary/source with spaces" missing)" ]
if function_body "$temporary/missing" selected >/dev/null 2>&1; then
	printf 'an unreadable function source unexpectedly succeeded\n' >&2
	exit 1
fi

printf 'ok - shared shell-function extraction preserves source and caller options\n'
