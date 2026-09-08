# Shared source for the self-contained package hooks and initialization script.
define AdGuardHome/PrivateFiles
entry_metadata() {
	LC_ALL=C ls -ldn "$$1" 2>/dev/null
}

root_private_directory() {
	local metadata mode owner group
	[ -d "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode _links owner group _rest <<-EOF
	$$metadata
	EOF
	[ "$$mode" = drwx------ ] && [ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

root_private_file() {
	local metadata mode links owner group
	[ -f "$$1" ] && [ ! -L "$$1" ] || return 1
	metadata="$$(entry_metadata "$$1")" || return 1
	read -r mode links owner group _rest <<-EOF
	$$metadata
	EOF
	[ "$$mode" = -rw------- ] && [ "$$links" = 1 ] &&
		[ "$$owner" = 0 ] && [ "$$group" = 0 ]
}

bounded_private_file() {
	local size
	root_private_file "$$1" || return 1
	size="$$(wc -c <"$$1" 2>/dev/null)" || return 1
	case "$$size" in ""|*[!0-9]*) return 1 ;; esac
	[ "$$size" -gt 0 ] && [ "$$size" -le 524288 ]
}
endef
