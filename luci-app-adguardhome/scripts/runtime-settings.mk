# Shared settings loading for lifecycle repair and side-effect-free queries.
define AdGuardHome/RuntimeSettings
load_settings() {
	local configured_work_dir official_work official_config state_rc=0
	local MEMORY_STATE_CHECK="$${1:-full}"
	local read_only="$${2:-0}"
	MONITOR_SETTINGS_READY=0
	if [ "$$read_only" = 1 ]; then
		uci_guard_config_file_valid "$${UCI_CONFIG_DIRECTORY}/$${OFFICIAL_CONFIG}" || return 1
	else
		ensure_managed_config_present || return $$?
	fi
	config_load "$$PLUGIN_CONFIG" || return 1
	validate_loaded_merged_sections || {
		log_error "Merged AdGuard Home UCI must contain exactly the named config and luci sections"
		return 1
	}
	config_get_bool service_enabled "$$OFFICIAL_SECTION" enabled 0
	config_get configured_work_dir "$$OFFICIAL_SECTION" work_dir "$$DEFAULT_WORK_DIR"
	config_get redirect_mode "$$PLUGIN_SECTION" redirect "dnsmasq-upstream"
	config_get_bool verbose "$$OFFICIAL_SECTION" verbose 0
	config_get_bool memory_requested "$$PLUGIN_SECTION" run_from_memory 0
	config_get memory_writeback_interval "$$PLUGIN_SECTION" memory_writeback_interval \
		"$$MEMORY_WRITEBACK_DEFAULT_MINUTES"
	memory_writeback_interval="$$(normalize_memory_writeback_interval \
		"$$memory_writeback_interval")" || return 1
	# Reuse the package already loaded above instead of spawning two more UCI
	# readers within the same settings snapshot.
	config_get official_work "$$OFFICIAL_SECTION" work_dir ""
	config_get official_config "$$OFFICIAL_SECTION" config_file ""
	uci_guard_no_delta "$$OFFICIAL_CONFIG" || return $$?
	previous_work_dir="$$official_work"
	# config_file is never an independent YAML selector.  Validate the
	# authoritative workdir first, then repair its derived field before any
	# normal runtime code can read a YAML pathname.
	validate_managed_work_dir_namespace "$$configured_work_dir" || return 1
	if [ "$$read_only" = 1 ]; then
		[ "$$official_config" = "$${configured_work_dir%/}/AdGuardHome.yaml" ] || return 1
	else
		normalize_managed_config_file "$$configured_work_dir" "$$official_config" || return 1
	fi
	official_config="$${configured_work_dir%/}/AdGuardHome.yaml"
	# A preparation interrupted before the volatile state was published has no
	# authoritative data.  Remove only the validated plugin-owned /tmp tree and
	# rebuild it from persistent data on demand.
	[ "$$read_only" = 1 ] ||
		memory_discard_incomplete_runtime_locked "$$configured_work_dir" || return 1

	MEMORY_ACTIVE=0
	MEMORY_BACKING_WORK_DIR=""
	memory_state_load "$$MEMORY_STATE_CHECK" || state_rc=$$?
	case "$$state_rc" in
		0)
			;;
		1) ;;
		2)
			log_error "Unsafe or incomplete AdGuard Home memory namespace"
			return 1
			;;
		*) return 1 ;;
	esac

	persistent_work_dir="$${configured_work_dir%/}"
	persistent_config_file="$${persistent_work_dir}/AdGuardHome.yaml"
	work_dir="$$persistent_work_dir"
	config_file="$$persistent_config_file"
	if [ "$$state_rc" = 0 ]; then
		MEMORY_ACTIVE=1
		MEMORY_BACKING_WORK_DIR="$$MEMORY_STATE_PERSISTENT_WORK_DIR"
		previous_work_dir="$$MEMORY_BACKING_WORK_DIR"
		work_dir="$$persistent_work_dir"
		# A new authoritative workdir request is reconciled only after the current
		# generation has stopped and been written back.  Until then its YAML remains
		# the persistent file bound by the v4 state record, never the newly
		# requested directory and never a RAM copy.
		config_file="$${MEMORY_BACKING_WORK_DIR}/AdGuardHome.yaml"
		# The official work_dir and YAML remain persistent.  The state record
		# authenticates only the RAM data overlay and its persistent backing.
		memory_apply_official_path_delta || return 1
	fi

	case "$$redirect_mode" in
		none|redirect|dnsmasq-upstream) ;;
		*)
			log_error "Invalid redirect mode '$${redirect_mode}', using none"
			redirect_mode="none"
			;;
	esac
	MONITOR_SETTINGS_READY=1
}

# Queries and readiness checks share the loader without repairing configuration
# or removing an interrupted RAM preparation. Mutating callers hold run_locked.
read_settings() {
	load_settings "$${1:-light}" 1
}
endef
