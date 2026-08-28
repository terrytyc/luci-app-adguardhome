#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
source_file="${1:-${script_dir}/../root/usr/share/rpcd/ucode/luci.adguardhome}"

[ -f "$source_file" ] || {
	printf 'RPC source not found: %s\n' "$source_file" >&2
	exit 1
}

awk '
	/^function same_inode\(left, right\) \{/ {
		definitions++
		definition_line = NR
		next
	}
	/same_inode\(/ {
		if (!first_call_line)
			first_call_line = NR
	}
	END {
		if (definitions != 1) {
			printf "same_inode must have exactly one definition, found %d\n", definitions > "/dev/stderr"
			exit 1
		}
		if (!first_call_line) {
			print "same_inode has no call site" > "/dev/stderr"
			exit 1
		}
		if (definition_line >= first_call_line) {
			printf "same_inode definition at line %d follows its first call at line %d\n", definition_line, first_call_line > "/dev/stderr"
			exit 1
		}
	}
' "$source_file"

printf 'ok - ucode helpers are declared before their first call\n'
