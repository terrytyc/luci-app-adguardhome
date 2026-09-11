#!/bin/sh
# shellcheck disable=SC2016,SC2034

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
fail_safe_body="$(function_body "$init_file" fail_safe_locked)"
stopped_copy_body="$(function_body "$init_file" memory_copy_stopped_data_locked)"
dnsmasq_clear_body="$(function_body "$init_file" clear_managed_dnsmasq_upstream)"
dnsmasq_rollback_body="$(function_body "$init_file" rollback_new_dnsmasq_upstream)"
dnsmasq_set_body="$(function_body "$init_file" set_dnsmasq_upstream)"
dnsmasq_marker_body="$(function_body "$init_file" clear_dnsmasq_recovery_marker)"
stop_wrapper_body="$(function_body "$init_file" stop_wrapper_locked)"
orchestrate_body="$(function_body "$init_file" orchestrate_core_locked)"

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/luci-agh-failure-boundaries.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM

# OpenWrt's generated pre-deinstall calls default_prerm before the package
# body.  Refuse that first stop before it can touch DNS state or the core when
# any configuration the stop may mutate has an external pending delta.
for pending_config in adguardhome dhcp firewall; do
	(
		eval "$stop_wrapper_body"
		events="$test_tmp/pre-deinstall-$pending_config.events"
		: >"$events"
		APK_SCRIPT=pre-deinstall
		PLUGIN_CONFIG=adguardhome
		OFFICIAL_SERVICE="$test_tmp/official-service"
		uci_guard_no_delta() {
			printf 'guard:%s\n' "$1" >>"$events"
			[ "$1" != "$pending_config" ]
		}
		load_settings() { printf 'load\n' >>"$events"; }
		clear_recorded_integration_locked() { printf 'cleanup\n' >>"$events"; }
		wait_for_core_stopped() { printf 'wait\n' >>"$events"; }
		memory_deactivate_locked() { printf 'memory\n' >>"$events"; }
		if stop_wrapper_locked 0; then
			printf 'pre-deinstall accepted pending %s changes\n' "$pending_config" >&2
			exit 1
		fi
		if grep -Eq '^(load|cleanup|wait|memory)$' "$events"; then
			printf 'pre-deinstall changed runtime state with pending %s changes\n' \
				"$pending_config" >&2
			exit 1
		fi
		[ "$(tail -n 1 "$events")" = "guard:$pending_config" ] || exit 1
	)
done

# With clean UCI, default_prerm still gets only a side-effect-free preflight.
# The package hook opts into the real stop after its gate and trap are ready.
(
	eval "$stop_wrapper_body"
	events="$test_tmp/pre-deinstall-phase.events"
	: >"$events"
	export TEST_EVENTS="$events"
	APK_SCRIPT=pre-deinstall
	PLUGIN_CONFIG=adguardhome
	OFFICIAL_SERVICE="$test_tmp/pre-deinstall-service"
	printf '%s\n' '#!/bin/sh' 'printf "service:%s\n" "$1" >>"$TEST_EVENTS"' \
		>"$OFFICIAL_SERVICE"
	chmod 0700 "$OFFICIAL_SERVICE"
	uci_guard_no_delta() { printf 'guard:%s\n' "$1" >>"$events"; }
	load_settings() { printf 'load\n' >>"$events"; MEMORY_ACTIVE=0; }
	clear_recorded_integration_locked() { printf 'cleanup\n' >>"$events"; }
	wait_for_core_stopped() { printf 'wait\n' >>"$events"; }
	stop_wrapper_locked 0
	[ "$(cat "$events")" = "$(printf 'guard:adguardhome\nguard:dhcp\nguard:firewall')" ] || {
		printf 'default pre-deinstall stop crossed the preflight boundary\n' >&2
		exit 1
	}
	: >"$events"
	LUCI_ADGUARDHOME_PRERM_PHASE=bounded stop_wrapper_locked 0
	[ "$(cat "$events")" = "$(printf 'guard:adguardhome\nguard:dhcp\nguard:firewall\nload\ncleanup\nservice:stop\nwait')" ] || {
		printf 'bounded pre-deinstall phase did not perform the verified stop\n' >&2
		exit 1
	}
)

# A failed resolver cleanup must leave the still-serving core untouched.
(
	eval "$fail_safe_body"
	events="$test_tmp/fail-safe.events"
	: >"$events"
	export TEST_EVENTS="$events"
	OFFICIAL_SERVICE="$test_tmp/official-service"
	printf '%s\n' '#!/bin/sh' 'printf "service:%s\n" "$1" >>"$TEST_EVENTS"' >"$OFFICIAL_SERVICE"
	chmod 0700 "$OFFICIAL_SERVICE"
	clear_recorded_integration_locked() {
		printf 'cleanup\n' >>"$events"
		return 1
	}
	wait_for_core_stopped() { printf 'wait\n' >>"$events"; }
	if fail_safe_locked; then
		printf 'fail-safe accepted a failed resolver cleanup\n' >&2
		exit 1
	fi
	[ "$(cat "$events")" = cleanup ] || {
		printf 'fail-safe stopped the core after resolver cleanup failed\n' >&2
		exit 1
	}
)

# A stopped-core RAM write-back failure keeps the RAM generation intact, so
# the orchestrator must restore that same runtime before reporting failure.
(
	eval "$orchestrate_body"
	events="$test_tmp/orchestrate-writeback.events"
	: >"$events"
	export TEST_EVENTS="$events"
	OFFICIAL_SERVICE="$test_tmp/orchestrate-service"
	printf '%s\n' '#!/bin/sh' 'printf "service:%s\n" "$1" >>"$TEST_EVENTS"' \
		>"$OFFICIAL_SERVICE"
	chmod 0700 "$OFFICIAL_SERVICE"
	load_settings() {
		MEMORY_ACTIVE=1
		service_enabled=1
		memory_requested=1
		MEMORY_BACKING_WORK_DIR=/persistent
		persistent_work_dir=/persistent
	}
	clear_recorded_integration_locked() { printf 'cleanup\n' >>"$events"; }
	wait_for_core_stopped() { printf 'wait\n' >>"$events"; }
	memory_copy_stopped_data_locked() { printf 'copy\n' >>"$events"; return 1; }
	resume_yaml_runtime() { printf 'resume:%s\n' "$1" >>"$events"; }
	log_error() { printf 'error:%s\n' "$*" >>"$events"; }
	if orchestrate_core_locked; then
		printf 'orchestrator accepted a failed stopped RAM write-back\n' >&2
		exit 1
	fi
	[ "$(cat "$events")" = "$(printf 'service:disable\ncleanup\nservice:stop\nwait\ncopy\nresume:1')" ] || {
		printf 'orchestrator did not restore service after stopped RAM write-back failure\n' >&2
		exit 1
	}
)

# A stopped RAM copy is not complete until both pruning and the durability
# barrier succeed.  The retry-after-quarantine path uses the same boundary.
(
	eval "$stopped_copy_body"
	events="$test_tmp/stopped-copy.events"
	: >"$events"
	memory_copy_live_data_locked() { printf 'copy\n' >>"$events"; }
	memory_prune_stopped_data_locked() { printf 'prune\n' >>"$events"; }
	memory_durability_barrier() { printf 'sync\n' >>"$events"; return 1; }
	memory_quarantine_stopped_conflicts_locked() {
		printf 'unexpected-quarantine\n' >>"$events"
		return 1
	}
	if memory_copy_stopped_data_locked; then
		printf 'stopped RAM write-back ignored a failed durability barrier\n' >&2
		exit 1
	fi
	[ "$(cat "$events")" = "$(printf 'copy\nprune\nsync')" ] || exit 1

	: >"$events"
	copy_attempt=0
	memory_copy_live_data_locked() {
		copy_attempt=$((copy_attempt + 1))
		printf 'copy\n' >>"$events"
		[ "$copy_attempt" -gt 1 ]
	}
	memory_quarantine_stopped_conflicts_locked() { printf 'quarantine\n' >>"$events"; }
	memory_durability_barrier() { printf 'sync\n' >>"$events"; }
	memory_copy_stopped_data_locked
	[ "$(cat "$events")" = "$(printf 'copy\nquarantine\ncopy\nprune\nsync')" ] || exit 1
)

# Model a sudden power loss at the DHCP commit.  The recovery marker must have
# crossed a durability barrier before that commit can become persistent.
dns_root="$test_tmp/dns"
mkdir -p "$dns_root/pending" "$dns_root/committed" "$dns_root/durable"
: >"$dns_root/events"
crash_rc=0
(
	eval "$dnsmasq_set_body"
	PLUGIN_CONFIG=adguardhome
	PLUGIN_SECTION=luci
	MANAGED_DNSMASQ_UPSTREAM=managed_dnsmasq_upstream
	MANAGED_DNSMASQ_NORESOLV_PRESENT=managed_dnsmasq_noresolv_present
	MANAGED_DNSMASQ_NORESOLV_VALUE=managed_dnsmasq_noresolv_value
	dns_port=53335
	load_dnsmasq_section() { DNSMASQ_UCI=dhcp.cfg; }
	dnsmasq_takeover_is_safe() { :; }
	uci_guard_no_delta() { :; }
	refresh_managed_config_snapshot() { printf 'snapshot\n' >>"$dns_root/events"; }
	reload_service_if_present() { printf 'reload\n' >>"$dns_root/events"; }
	rollback_new_dnsmasq_upstream() { printf 'rollback\n' >>"$dns_root/events"; }
	memory_durability_barrier() {
		printf 'barrier\n' >>"$dns_root/events"
		for marker in upstream noresolv-present noresolv-value; do
			cp "$dns_root/committed/$marker" "$dns_root/durable/$marker"
		done
	}
	uci() {
		[ "${1:-}" != -q ] || shift
		command="${1:-}"
		shift || true
		printf '%s:%s\n' "$command" "$*" >>"$dns_root/events"
		case "$command:$*" in
			get:dhcp.cfg.noresolv)
				printf '0\n'
				return 0
				;;
			set:adguardhome.luci.managed_dnsmasq_upstream=*)
				printf '%s\n' "${1#*=}" >"$dns_root/pending/upstream"
				;;
			set:adguardhome.luci.managed_dnsmasq_noresolv_present=*)
				printf '%s\n' "${1#*=}" >"$dns_root/pending/noresolv-present"
				;;
			set:adguardhome.luci.managed_dnsmasq_noresolv_value=*)
				printf '%s\n' "${1#*=}" >"$dns_root/pending/noresolv-value"
				;;
			commit:adguardhome)
				for marker in upstream noresolv-present noresolv-value; do
					cp "$dns_root/pending/$marker" "$dns_root/committed/$marker"
				done
				;;
			commit:dhcp)
				# Simulate the process disappearing immediately as DHCP becomes durable.
				exit 73
				;;
		esac
	}
	set_dnsmasq_upstream
) || crash_rc=$?
[ "$crash_rc" = 73 ] || {
	printf 'DNS crash simulation exited with %s instead of 73\n' "$crash_rc" >&2
	exit 1
}
[ "$(cat "$dns_root/durable/upstream")" = 53335 ]
[ "$(cat "$dns_root/durable/noresolv-present")" = 1 ]
[ "$(cat "$dns_root/durable/noresolv-value")" = 0 ]
barrier_line="$(grep -n '^barrier$' "$dns_root/events" | cut -d: -f1)"
dhcp_change_line="$(grep -n '^add_list:dhcp.cfg.server=' "$dns_root/events" | cut -d: -f1)"
[ "$barrier_line" -lt "$dhcp_change_line" ] || {
	printf 'DNS state changed before its recovery marker became durable\n' >&2
	exit 1
}

# Clearing an established takeover must persist and reload the restored DHCP
# state before deleting its recovery marker.  A failed barrier keeps it intact.
for clear_case in success barrier-fail; do
	events="$test_tmp/clear-$clear_case.events"
	: >"$events"
	(
		eval "$dnsmasq_clear_body"
		eval "$dnsmasq_marker_body"
		PLUGIN_CONFIG=adguardhome
		PLUGIN_SECTION=luci
		MANAGED_DNSMASQ_UPSTREAM=managed_dnsmasq_upstream
		MANAGED_DNSMASQ_NORESOLV_PRESENT=managed_dnsmasq_noresolv_present
		MANAGED_DNSMASQ_NORESOLV_VALUE=managed_dnsmasq_noresolv_value
		is_valid_port() { :; }
		load_dnsmasq_section() { DNSMASQ_UCI=dhcp.cfg; }
		remove_managed_dnsmasq_upstream() { :; }
		dnsmasq_restored_state_matches() { :; }
		uci_guard_no_delta() { :; }
		log_error() { :; }
		refresh_managed_config_snapshot() { printf 'snapshot\n' >>"$events"; }
		memory_durability_barrier() {
			printf 'barrier\n' >>"$events"
			[ "$clear_case" = success ]
		}
		reload_service_if_present() { printf 'reload\n' >>"$events"; }
		uci() {
			[ "${1:-}" != -q ] || shift
			command="${1:-}"
			shift || true
			printf '%s:%s\n' "$command" "$*" >>"$events"
			case "$command:$*" in
				get:adguardhome.luci.managed_dnsmasq_upstream) printf '53335\n' ;;
				get:adguardhome.luci.managed_dnsmasq_noresolv_present) printf '1\n' ;;
				get:adguardhome.luci.managed_dnsmasq_noresolv_value) printf '0\n' ;;
			esac
		}
		if [ "$clear_case" = success ]; then
			clear_managed_dnsmasq_upstream
		elif clear_managed_dnsmasq_upstream; then
			printf 'DNS cleanup ignored a failed durability barrier\n' >&2
			exit 1
		fi
	)
	if [ "$clear_case" = barrier-fail ]; then
		if grep -Eq '^delete:adguardhome[.]luci[.]managed_dnsmasq_|^commit:adguardhome$' "$events"; then
			printf 'DNS cleanup deleted its marker after a failed durability barrier\n' >&2
			exit 1
		fi
		continue
	fi
	commit_line="$(grep -n '^commit:dhcp$' "$events" | cut -d: -f1)"
	barrier_line="$(grep -n '^barrier$' "$events" | cut -d: -f1)"
	reload_line="$(grep -n '^reload$' "$events" | cut -d: -f1)"
	delete_line="$(grep -n '^delete:adguardhome.luci.managed_dnsmasq_upstream$' "$events" | cut -d: -f1)"
	if ! { [ "$commit_line" -lt "$barrier_line" ] &&
	       [ "$barrier_line" -lt "$reload_line" ] &&
	       [ "$reload_line" -lt "$delete_line" ]; }; then
		printf 'DNS cleanup removed its marker before durable restoration and reload\n' >&2
		exit 1
	fi
done

# Rollback failure is retryable only while the durable ownership marker stays
# published.  Exercise the real rollback body at both failure boundaries.
for rollback_failure in commit restart; do
	events="$test_tmp/rollback-$rollback_failure.events"
	: >"$events"
	(
		eval "$dnsmasq_rollback_body"
		eval "$dnsmasq_marker_body"
		PLUGIN_CONFIG=adguardhome
		PLUGIN_SECTION=luci
		MANAGED_DNSMASQ_UPSTREAM=managed_dnsmasq_upstream
		MANAGED_DNSMASQ_NORESOLV_PRESENT=managed_dnsmasq_noresolv_present
		MANAGED_DNSMASQ_NORESOLV_VALUE=managed_dnsmasq_noresolv_value
		DNSMASQ_UCI=dhcp.cfg
		dns_port=53335
		remove_managed_dnsmasq_upstream() { :; }
		dnsmasq_restored_state_matches() { :; }
		refresh_managed_config_snapshot() { printf 'snapshot\n' >>"$events"; }
		memory_durability_barrier() { printf 'barrier\n' >>"$events"; }
		reload_service_if_present() {
			printf 'reload\n' >>"$events"
			[ "$rollback_failure" != restart ]
		}
		uci() {
			[ "${1:-}" != -q ] || shift
			command="${1:-}"
			shift || true
			printf '%s:%s\n' "$command" "$*" >>"$events"
			[ "$rollback_failure:$command:$*" != commit:commit:dhcp ]
		}
		if rollback_new_dnsmasq_upstream 1 0; then
			printf 'DNS rollback unexpectedly succeeded after %s failure\n' \
				"$rollback_failure" >&2
			exit 1
		fi
	)
	if grep -Eq '^delete:adguardhome[.]luci[.]managed_dnsmasq_|^commit:adguardhome$' "$events"; then
		printf 'DNS rollback deleted its marker after %s failure\n' "$rollback_failure" >&2
		exit 1
	fi
	if [ "$rollback_failure" = commit ]; then
		grep -Fqx 'revert:dhcp' "$events" || {
			printf 'failed DNS rollback commit left its temporary UCI delta\n' >&2
			exit 1
		}
		if grep -Fqx reload "$events"; then exit 1; fi
	else
		grep -Fqx 'commit:dhcp' "$events"
		grep -Fqx barrier "$events"
		grep -Fqx reload "$events"
	fi
done

# Marker deletion is one checked UCI transaction. Delete/commit failures must
# revert its delta and retain the complete committed recovery record; a later
# snapshot failure is reported after the marker commit rather than hidden.
for marker_failure in delete commit snapshot; do
	events="$test_tmp/marker-$marker_failure.events"
	: >"$events"
	(
		eval "$dnsmasq_marker_body"
		PLUGIN_CONFIG=adguardhome
		PLUGIN_SECTION=luci
		MANAGED_DNSMASQ_UPSTREAM=managed_dnsmasq_upstream
		MANAGED_DNSMASQ_NORESOLV_PRESENT=managed_dnsmasq_noresolv_present
		MANAGED_DNSMASQ_NORESOLV_VALUE=managed_dnsmasq_noresolv_value
		marker_state=complete
		pending_deletes=""
		refresh_managed_config_snapshot() {
			printf 'snapshot\n' >>"$events"
			[ "$marker_failure" != snapshot ]
		}
		uci() {
			[ "${1:-}" != -q ] || shift
			command="${1:-}"
			shift || true
			printf '%s:%s\n' "$command" "$*" >>"$events"
			case "$command" in
				get) return 0 ;;
				delete)
					if [ "$marker_failure" = delete ] &&
					   [ "$*" = adguardhome.luci.managed_dnsmasq_upstream ]; then
						return 1
					fi
					pending_deletes="${pending_deletes}${pending_deletes:+ }$*"
					;;
				commit)
					[ "$marker_failure" != commit ] || return 1
					marker_state=""
					pending_deletes=""
					;;
				revert) pending_deletes="" ;;
			esac
		}
		if clear_dnsmasq_recovery_marker; then
			printf 'marker cleanup ignored %s failure\n' "$marker_failure" >&2
			exit 1
		fi
		[ -z "$pending_deletes" ] || {
			printf 'marker cleanup left a UCI delta after %s failure\n' \
				"$marker_failure" >&2
			exit 1
		}
		if [ "$marker_failure" = snapshot ]; then
			[ -z "$marker_state" ] || exit 1
		else
			[ "$marker_state" = complete ] || exit 1
			grep -Fqx 'revert:adguardhome' "$events" || exit 1
		fi
	)
done

printf 'ok - runtime failure boundaries preserve serving and recoverable state\n'
