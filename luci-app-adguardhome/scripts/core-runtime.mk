# Runtime identity used to reuse a core only while its startup inputs match.
define AdGuardHome/CoreRuntime
core_runtime_fingerprint() (
	local snapshot official package yaml_hash digest certificate_hash="" key_hash=""
	local work_identity data_identity=absent
	local TLS_PREFLIGHT_ONLY=1
	# ash unwinds function locals before EXIT traps; this subshell already
	# isolates the cleanup pathname from every caller.
	runtime_check_directory="$$(mktemp -d /tmp/AdGuardHome-runtime-check.XXXXXX)" || exit 1
	trap 'rm -rf "$$runtime_check_directory"' EXIT
	snapshot="$${runtime_check_directory}/AdGuardHome.yaml"
	snapshot_config_file "$$config_file" "$$snapshot" "" "" || exit 1
	yaml_hash="$$SNAPSHOT_CONFIG_HASH"
	# Only the official section affects the core. DNS mode and the RAM timer
	# belong to the coordinator; all other official options remain significant.
	official="$$(uci -q show "$${OFFICIAL_CONFIG}.$${OFFICIAL_SECTION}")" || exit 1
	package="$$(core_package_fingerprint)" || exit 1
	memory_backing_identity "$$work_dir" || exit 1
	work_identity="$${MEMORY_IDENTITY_DEVICE}:$${MEMORY_IDENTITY_INODE}"
	if [ -e "$${work_dir}/data" ] || [ -L "$${work_dir}/data" ]; then
		memory_backing_identity "$${work_dir}/data" || exit 1
		data_identity="$${MEMORY_IDENTITY_DEVICE}:$${MEMORY_IDENTITY_INODE}"
	fi
	load_tls_access "$$snapshot" || exit 1
	if [ -n "$$TLS_CERT_REAL" ]; then
		certificate_hash="$$(tls_file_hash "$$TLS_CERT_REAL")" || exit 1
		key_hash="$$(tls_file_hash "$$TLS_KEY_REAL")" || exit 1
	fi
	digest="$$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$$official" "$$package" "$$yaml_hash" \
		"$$certificate_hash" "$$key_hash" "$$work_identity" "$$data_identity" | sha256sum)" || exit 1
	digest="$${digest%% *}"
	[ "$${#digest}" = 64 ] || exit 1
	case "$$digest" in *[!0-9a-f]*) exit 1 ;; esac
	printf '%s\n' "$$digest"
)

core_runtime_identity() {
	local pid started
	pid="$$(official_pid)" || return 1
	case "$$pid" in ""|*[!0-9]*) return 1 ;; esac
	started="$$(awk '{ sub(/^.*\) /, ""); print $$20 }' "/proc/$${pid}/stat" 2>/dev/null)" || return 1
	case "$$started" in ""|*[!0-9]*) return 1 ;; esac
	printf '%s:%s\n' "$$pid" "$$started"
}

core_runtime_matches() {
	local record="$${NORMALIZER_RUNTIME_DIR}/applied-runtime" expected identity fingerprint
	root_private_directory "$$NORMALIZER_RUNTIME_DIR" && root_private_file "$$record" || return 1
	[ "$$(wc -c <"$$record")" -le 128 ] || return 1
	expected="$$(cat "$$record")" || return 1
	identity="$$(core_runtime_identity)" && fingerprint="$$(core_runtime_fingerprint)" || return 1
	[ "$$expected" = "$$identity $$fingerprint" ] &&
		[ "$$(core_runtime_identity)" = "$$identity" ]
}

remember_core_runtime() {
	local expected="$$1" record="$${NORMALIZER_RUNTIME_DIR}/applied-runtime"
	local fingerprint identity temporary
	[ -n "$$expected" ] || return 1
	if [ ! -e "$$NORMALIZER_RUNTIME_DIR" ] && [ ! -L "$$NORMALIZER_RUNTIME_DIR" ]; then
		(umask 077; mkdir "$$NORMALIZER_RUNTIME_DIR") || return 1
	fi
	root_private_directory "$$NORMALIZER_RUNTIME_DIR" || return 1
	[ ! -e "$$record" ] && [ ! -L "$$record" ] || root_private_file "$$record" || return 1
	identity="$$(core_runtime_identity)" && fingerprint="$$(core_runtime_fingerprint)" || return 1
	# Only publish the startup inputs or the canonical YAML already validated by
	# the caller. A mismatch leaves the next Apply on the full lifecycle.
	[ "$$fingerprint" = "$$expected" ] && [ "$$(core_runtime_identity)" = "$$identity" ] || return 1
	temporary="$$(mktemp "$${NORMALIZER_RUNTIME_DIR}/.applied-runtime.XXXXXX")" || return 1
	if ! printf '%s %s\n' "$$identity" "$$fingerprint" >"$$temporary" ||
	   ! chown 0:0 "$$temporary" || ! chmod 0600 "$$temporary" ||
	   ! mv -f "$$temporary" "$$record"; then
		rm -f "$$temporary"
		return 1
	fi
}

# Call after successful readiness/configuration checks. Recording is optional:
# a failure keeps the working core and makes the next Apply recheck it fully.
record_ready_core_runtime() {
	remember_core_runtime "$$1" ||
		log_error "Runtime baseline unavailable; the next settings Apply will recheck and restart the core"
	return 0
}
endef
