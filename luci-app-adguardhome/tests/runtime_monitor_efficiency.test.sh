#!/bin/sh

if ! (eval 'exec 1000<&0 && exec 1000<&-') 2>/dev/null; then
	exec busybox ash "$0" "$@"
fi
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
grep -qx MONITOR_INTERVAL=5 "$init_file"
for name in reconcile_core_locked monitor_interval_locked monitor wait_for_core_ready \
	normalize_memory_writeback_interval; do
	eval "$(function_body "$init_file" "$name")"
done

events="${test_tmp}/reconcile"
record() { printf '%s\n' "$*" >>"$events"; }
load_settings() {
	[ "$*" = light ] || return 1
	record settings
	service_enabled="$TEST_ENABLED"
	MEMORY_ACTIVE="$TEST_MEMORY_ACTIVE"
	memory_requested="$TEST_MEMORY_REQUESTED"
	MEMORY_BACKING_WORK_DIR="$TEST_BACKING"
	persistent_work_dir=/etc/AdGuardHome
	work_dir="$persistent_work_dir"
	redirect_mode="$TEST_MODE"
	memory_writeback_interval="${TEST_INTERVAL:-60}"
	MONITOR_SETTINGS_READY=1
}
clear_recorded_integration_locked() { record cleanup; }
orchestrate_core_locked() { record orchestrate; }
official_running() { [ "$TEST_RUNNING" = 1 ]; }
official_test_service() { record "service:$*"; }
wait_for_core_stopped() { record stopped; }
memory_deactivate_locked() { record "deactivate:$*"; }
sync_monitor_instance() { record monitor-sync; }
load_runtime_dns_port() { record dns-port; dns_port=53335; }
dns_port_listening() { record socket; }
integration_matches_desired() { record integration; }
fail_safe_locked() { record failsafe; }
OFFICIAL_SERVICE=official_test_service
TEST_ENABLED=1
TEST_MEMORY_ACTIVE=0
TEST_MEMORY_REQUESTED=0
TEST_RUNNING=1
TEST_BACKING=/etc/AdGuardHome
TEST_MODE=none

reconcile_core_locked
[ "$(cat "$events")" = "$(printf 'settings\ncleanup')" ]
: >"$events"
TEST_MEMORY_ACTIVE=1
TEST_MEMORY_REQUESTED=1
reconcile_core_locked
[ "$(cat "$events")" = "$(printf 'settings\ncleanup')" ]
: >"$events"
TEST_BACKING=/etc/AdGuardHome-old
reconcile_core_locked
[ "$(cat "$events")" = "$(printf 'settings\norchestrate')" ]
: >"$events"
TEST_BACKING=/etc/AdGuardHome
TEST_ENABLED=0
reconcile_core_locked
[ "$(cat "$events")" = "$(printf 'settings\ncleanup\nservice:stop\nstopped\ndeactivate:\nmonitor-sync')" ]
: >"$events"
TEST_ENABLED=1
TEST_MODE=dnsmasq-upstream
reconcile_core_locked
[ "$(cat "$events")" = "$(printf 'settings\ndns-port\nsocket\nintegration')" ]

# Start/apply readiness remains a short one-second stable-listener check,
# including none mode.  Only the long-lived monitor skips none-mode probes.
: >"$events"
READY_TIMEOUT=120
READY_STABLE_COUNT=3
runtime_settings_match() { record runtime-settings; }
log_error() { record "error:$*"; }
sleep() { record "sleep:$*"; }
wait_for_core_ready 53335 none /etc/AdGuardHome
[ "$(grep -c '^sleep:1$' "$events")" = 2 ]
[ "$(grep -c '^runtime-settings$' "$events")" = 3 ]
[ "$(grep -c '^socket$' "$events")" = 3 ]

# A failed listener still resets the consecutive-success count.  Readiness
# checks every round, but does not repeat the successful final round.
(
	: >"$events"
	probes=0
	dns_port_listening() {
		record socket
		probes=$((probes + 1))
		[ "$probes" -ne 2 ]
	}
	wait_for_core_ready 53335 none /etc/AdGuardHome
	[ "$(grep -c '^runtime-settings$' "$events")" = 5 ]
	[ "$(grep -c '^socket$' "$events")" = 5 ]
	[ "$(grep -c '^sleep:1$' "$events")" = 4 ]
	: >"$events"
	READY_TIMEOUT=3
	dns_port_listening() { record socket; return 1; }
	if wait_for_core_ready 53335 none /etc/AdGuardHome; then
		printf 'an unavailable listener passed readiness\n' >&2
		exit 1
	fi
	[ "$(grep -c '^runtime-settings$' "$events")" = 3 ]
	[ "$(grep -c '^socket$' "$events")" = 3 ]
	[ "$(grep -c '^sleep:1$' "$events")" = 3 ]
	: >"$events"
	checks=0
	runtime_settings_match() {
		[ "$*" = '53335 none /etc/AdGuardHome' ] || return 1
		record runtime-settings
		checks=$((checks + 1))
		[ "$checks" -ne 2 ]
	}
	dns_port_listening() { record socket; }
	if wait_for_core_ready 53335 none /etc/AdGuardHome; then
		printf 'readiness concealed a settings change between rounds\n' >&2
		exit 1
	fi
	[ "$(grep -c '^runtime-settings$' "$events")" = 2 ]
	[ "$(grep -c '^socket$' "$events")" = 1 ]
	[ "$(grep -c '^sleep:1$' "$events")" = 1 ]
)

# Readiness is not authorization to install DNS takeover.  The real apply
# path must freshly reject YAML/core changes after the wait, and must remove
# takeover again if either changes while the resolver reload is in progress.
(
	eval "$(function_body "$init_file" runtime_settings_match)"
	eval "$(function_body "$init_file" apply_integration_locked)"
	load_settings() {
		[ "$*" = light ] || return 1
		record runtime-settings
		service_enabled=1
		redirect_mode=dnsmasq-upstream
		work_dir=/etc/AdGuardHome
	}
	load_runtime_dns_port() { dns_port="$TEST_PORT"; }
	dns_port_listening() { record socket; [ "$TEST_CORE_RUNNING" = 1 ]; }
	set_dnsmasq_upstream() {
		record upstream
		case "$scenario" in
			yaml-during) TEST_PORT=55353 ;;
			core-during) TEST_CORE_RUNNING=0 ;;
		esac
	}
	for scenario in unchanged yaml-before core-before yaml-during core-during; do
		: >"$events"
		TEST_PORT=53335
		TEST_CORE_RUNNING=1
		wait_for_core_ready 53335 dnsmasq-upstream /etc/AdGuardHome
		[ "$(grep -c '^runtime-settings$' "$events")" = 3 ]
		[ "$(grep -c '^socket$' "$events")" = 3 ]
		[ "$(grep -c '^sleep:1$' "$events")" = 2 ]
		: >"$events"
		case "$scenario" in
			yaml-before) TEST_PORT=55353 ;;
			core-before) TEST_CORE_RUNNING=0 ;;
		esac
		if [ "$scenario" = unchanged ]; then
			apply_integration_locked 53335 dnsmasq-upstream /etc/AdGuardHome
			expected='runtime-settings\nsocket\ncleanup\nupstream\nruntime-settings\nsocket'
		else
			if apply_integration_locked 53335 dnsmasq-upstream /etc/AdGuardHome; then
				printf 'DNS takeover accepted changed readiness: %s\n' "$scenario" >&2
				exit 1
			fi
			case "$scenario" in
				yaml-before) expected='runtime-settings\ncleanup' ;;
				core-before) expected='runtime-settings\nsocket\ncleanup' ;;
				yaml-during) expected='runtime-settings\nsocket\ncleanup\nupstream\nruntime-settings\ncleanup' ;;
				core-during) expected='runtime-settings\nsocket\ncleanup\nupstream\nruntime-settings\nsocket\ncleanup' ;;
			esac
		fi
		[ "$(cat "$events")" = "$(printf '%b' "$expected")" ]
	done
)

# The scheduling result must survive command substitution without relying on
# variable changes escaping run_locked's subshell.  Only an active, matching
# RAM generation gets a nonzero interval, and reconciliation output is private.
(
	TEST_MODE=none
	TEST_ENABLED=1
	TEST_MEMORY_ACTIVE=1
	TEST_MEMORY_REQUESTED=1
	TEST_BACKING=/etc/AdGuardHome
	TEST_INTERVAL=60
	clear_recorded_integration_locked() { printf 'unrelated reconcile output\n'; }
	[ "$(monitor_interval_locked)" = 60 ]
	TEST_MEMORY_ACTIVE=0
	[ "$(monitor_interval_locked)" = 0 ]
	TEST_MEMORY_ACTIVE=1
	TEST_MEMORY_REQUESTED=0
	[ "$(monitor_interval_locked)" = 0 ]
	TEST_MEMORY_REQUESTED=1
	TEST_ENABLED=0
	[ "$(monitor_interval_locked)" = 0 ]
	TEST_ENABLED=1
	TEST_BACKING=/etc/AdGuardHome-old
	[ "$(monitor_interval_locked)" = 0 ]
	TEST_BACKING=/etc/AdGuardHome
	TEST_INTERVAL=0
	[ "$(monitor_interval_locked)" = 0 ]
	load_settings() { return 1; }
	[ "$(monitor_interval_locked)" = 0 ]
)

# Drive real monitor control flow with deterministic clock/interval fixtures.
# These test rounds never enter production code as a loop counter or scheduler.
events="${test_tmp}/monitor"
(
	ROUND=0
	MONITOR_INTERVAL=5
	# Only bound the otherwise-infinite loop; all production scheduling branches
	# and the real lock-result wrapper are executed unchanged.
	eval "$(function_body "$init_file" monitor | sed 's/while :; do/while monitor_next_round; do/')"
	monitor_next_round() {
		ROUND=$((ROUND + 1))
		[ "$ROUND" -le 16 ]
	}
	monitor_terminate() { exit 0; }
	reconcile_core_locked() {
		record "reconcile:$ROUND"
		MONITOR_SETTINGS_READY=1
		service_enabled=1
		memory_requested=1
		MEMORY_ACTIVE=1
		MEMORY_BACKING_WORK_DIR=/etc/AdGuardHome
		persistent_work_dir=/etc/AdGuardHome
		memory_writeback_interval=1
		case "$ROUND" in
			1) MEMORY_ACTIVE=0; memory_writeback_interval=60 ;;
			2) service_enabled=0; memory_writeback_interval=60 ;;
			5) memory_writeback_interval=0 ;;
			13|14|15) memory_writeback_interval=60 ;;
			9) record dns-reconcile-failed; return 1 ;;
			16) MONITOR_SETTINGS_READY=0; record settings-failed; return 1 ;;
		esac
	}
	run_locked() {
		case "$1" in
			monitor_interval_locked) "$1" ;;
			memory_writeback_locked_command)
				record "writeback:$ROUND"
				case "$ROUND" in 8) return 1 ;; 12) return 2 ;; esac
				;;
			*) exit 1 ;;
		esac
	}
	uci() {
		record unexpected-uci
		return 1
	}
	normalize_memory_writeback_interval() {
		record unexpected-normalization
		return 1
	}
	monotonic_seconds() {
		local previous=0
		previous="$(grep -c "^clock:${ROUND}$" "$events" || true)"
		record "clock:$ROUND"
		case "$ROUND:$previous" in
			3:0) printf '100\n' ;; 4:0) printf '159\n' ;;
			6:0) printf '200\n' ;; 7:0) printf '259\n' ;;
			8:0) printf '260\n' ;; 8:1) printf '265\n' ;;
			9:0) printf '324\n' ;; 10:0) printf '325\n' ;;
			10:1) printf '330\n' ;; 11:0) printf '389\n' ;;
			12:0) printf '390\n' ;; 12:1) printf '395\n' ;;
			13:0) printf '400\n' ;; 14:0) printf '3999\n' ;;
			15:0) printf '4000\n' ;; 15:1) printf '4005\n' ;;
			*) record unexpected-clock; return 1 ;;
		esac
	}
	sleep() {
		[ "$*" = 5 ] || exit 1
		record "state:${ROUND}:${next_writeback}:${last_interval}"
	}
	monitor
)
[ "$(grep -c '^reconcile:' "$events")" = 16 ]
[ "$(grep -c '^clock:' "$events")" = 16 ]
if grep -Eq '^clock:(1|2|5|16)$|^unexpected-(clock|uci|normalization)$' "$events"; then
	printf 'inactive write-back still reads the clock/UCI or scheduling leaked\n' >&2
	exit 1
fi
[ "$(grep '^writeback:' "$events")" = "$(printf 'writeback:8\nwriteback:10\nwriteback:12\nwriteback:15')" ]
for expected in state:3:160:1 state:5:0:0 state:6:260:1 state:8:325:1 state:9:325:1 \
	state:10:390:1 state:12:455:1 state:13:4000:60 state:15:7605:60 state:16:0:0; do
	grep -qx "$expected" "$events"
done
grep -q 'retrying in 60 seconds' "$events"
grep -qx dns-reconcile-failed "$events"
grep -qx settings-failed "$events"

printf 'ok - live lock-result scheduling, inactive RAM bypass and unchanged retry timing\n'
