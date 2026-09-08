# Shared only at build time; installed package scripts remain self-contained.
define AdGuardHome/OriginalSnapshot
official_delta_is_clean() {
	local changes
	changes="$$(uci -q changes adguardhome 2>/dev/null)" || return 1
	[ -z "$$changes" ]
}

validate_original_snapshot() {
	root_private_directory "$$SNAPSHOT_DIR" &&
		bounded_private_file "$$SNAPSHOT_CONFIG" &&
		root_private_file "$$SNAPSHOT_STATE" &&
		root_private_file "$$SNAPSHOT_VERSION" &&
		grep -Eq '^was_running=[01]$$' "$$SNAPSHOT_STATE" &&
		[ "$$(wc -l <"$$SNAPSHOT_STATE" 2>/dev/null)" = 1 ] &&
		grep -qx '1' "$$SNAPSHOT_VERSION"
}

cleanup_snapshot_stage() {
	[ -n "$$SNAPSHOT_STAGE" ] || return 0
	rm -f "$$SNAPSHOT_STAGE/official-adguardhome.config" \
		"$$SNAPSHOT_STAGE/official-adguardhome.state" \
		"$$SNAPSHOT_STAGE/snapshot-version" 2>/dev/null || true
	rmdir "$$SNAPSHOT_STAGE" 2>/dev/null || true
	SNAPSHOT_STAGE=""
}

create_original_snapshot() {
	local running_rc=0 was_running=0
	[ ! -e "$$SNAPSHOT_DIR" ] && [ ! -L "$$SNAPSHOT_DIR" ] || return 1
	[ -f /etc/config/adguardhome ] && [ ! -L /etc/config/adguardhome ] || return 1
	official_delta_is_clean || return 1
	SNAPSHOT_STAGE="$$(mktemp -d /root/.luci-app-adguardhome.XXXXXX)" || return 1
	chown 0:0 "$$SNAPSHOT_STAGE" && chmod 0700 "$$SNAPSHOT_STAGE" || return 1
	run_bounded 5 1 /bin/dd if=/etc/config/adguardhome \
		of="$$SNAPSHOT_STAGE/official-adguardhome.config" bs=4096 count=129 \
		2>/dev/null || return 1
	run_bounded 5 1 uci -q export adguardhome >/dev/null || return 1
	if [ -x /etc/init.d/adguardhome ]; then
		run_bounded 5 1 /etc/init.d/adguardhome running \
			>/dev/null 2>&1 || running_rc=$$?
		case "$$running_rc" in
			0) was_running=1 ;;
			1) was_running=0 ;;
			*) return 1 ;;
		esac
	fi
	printf 'was_running=%s\n' "$$was_running" \
		>"$$SNAPSHOT_STAGE/official-adguardhome.state" || return 1
	printf '1\n' >"$$SNAPSHOT_STAGE/snapshot-version" || return 1
	chown 0:0 "$$SNAPSHOT_STAGE"/* && chmod 0600 "$$SNAPSHOT_STAGE"/* || return 1
	mv "$$SNAPSHOT_STAGE" "$$SNAPSHOT_DIR" || return 1
	SNAPSHOT_STAGE=""
	validate_original_snapshot
}
endef
