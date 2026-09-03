# Shared only at build time; installed init/defaults remain self-contained.
define AdGuardHome/KeepActiveConfig
keep_active_config() {
	local expected directory="$${KEEP_FILE%/*}" temporary
	expected="$$(printf '%s\n%s/\n' "$$1" "$${2%/}")" || return 1
	[ ! -L "$$KEEP_FILE" ] || return 1
	if [ -f "$$KEEP_FILE" ] &&
	   [ "$$(cat "$$KEEP_FILE")" = "$$expected" ]; then
		return 0
	fi
	[ ! -e "$$KEEP_FILE" ] || [ -f "$$KEEP_FILE" ] || return 1
	mkdir -p "$$directory" || return 1
	temporary="$$(mktemp "$${directory}/.luci-adguardhome-keep.XXXXXX")" || return 1
	if ! printf '%s\n' "$$expected" >"$$temporary" ||
	   ! chmod 0600 "$$temporary" || ! mv -f "$$temporary" "$$KEEP_FILE"; then
		rm -f "$$temporary"
		return 1
	fi
}
endef
