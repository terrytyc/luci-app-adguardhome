#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

[ -f "$init_file" ] || {
	printf 'init script not found: %s\n' "$init_file" >&2
	exit 1
}

function_body="$(awk '
	/^memory_active_tree_valid\(\) \{/ { copying = 1 }
	copying { print }
	copying && /^}/ { exit }
' "$init_file")"

[ -n "$function_body" ] || {
	printf 'memory_active_tree_valid was not found\n' >&2
	exit 1
}

# The single-quoted pattern intentionally matches the literal production
# variable reference.
# shellcheck disable=SC2016
[ "$(printf '%s\n' "$function_body" |
	grep -Fc 'uid853_tree_is_plain "$MEMORY_WORK_DIR"')" -eq 1 ] || {
	printf 'active RAM validation is not guarded by the plain-tree mount scan\n' >&2
	exit 1
}

printf '%s\n' "$function_body" |
	awk '
		/\[ "\$found" = 1 \] \|\| return 1/ { shape = NR }
		/uid853_tree_is_plain "\$MEMORY_WORK_DIR"/ { guard = NR }
		END { exit !(shape > 0 && guard > shape) }
	' || {
	printf 'active RAM mount scan must run after the exact top-level shape check\n' >&2
	exit 1
}

printf 'ok - active RAM tree mount guard\n'
