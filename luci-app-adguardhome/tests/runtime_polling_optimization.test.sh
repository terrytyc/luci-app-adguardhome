#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

for name in official_socket_snapshot official_owns_socket \
	official_owns_ipv4_reachable_socket official_memory_data_mount_visible \
	dns_port_listening dns_ipv6_listening web_listening runtime_settings_match; do
	eval "$(function_body "$init_file" "$name")"
done

# Readiness still loads fresh settings/YAML each time, but requests the light
# mount-identity check instead of traversing the active data tree every second.
load_settings() {
	[ "$*" = light ]
	service_enabled=1
	work_dir=/etc/AdGuardHome
	redirect_mode=none
}
load_runtime_dns_port() { dns_port="$TEST_PORT"; }
TEST_PORT=53335
runtime_settings_match 53335 none /etc/AdGuardHome
TEST_PORT=55353
if runtime_settings_match 53335 none /etc/AdGuardHome; then
	printf 'readiness concealed a fresh DNS port change\n' >&2
	exit 1
fi

# The exact filter is additionally exercised against the target jsonfilter in
# the SDK/rootfs check (supply JSONFILTER_BINARY and optionally its musl loader).
pid_body="$(function_body "$init_file" official_pid)"
printf '%s\n' "$pid_body" |
	grep -Fq "@.adguardhome.instances[@.running=true].pid"
pid_text_calls="${test_tmp}/pid-text-calls"
: >"$pid_text_calls"
(
	eval "$pid_body"
	awk() { printf 'awk\n' >>"$pid_text_calls"; return 1; }
	ubus() { printf '%b' "$PID_OUTPUT"; }
	jsonfilter() {
		[ "$*" = '-e @.adguardhome.instances[@.running=true].pid' ] || return 1
		cat
	}
	for PID_OUTPUT in '20\n30\n' '20' '  20 other-fields\n30\n'; do
		[ "$(official_pid)" = 20 ]
	done
	PID_OUTPUT='\t00020 extra\n30\n'
	[ "$(official_pid)" = 00020 ]
	for PID_OUTPUT in '' '\n20\n' 'invalid\n20\n' '-1\n20\n' '20x\n' '20\r\n'; do
		[ -z "$(official_pid)" ]
	done
)
[ ! -s "$pid_text_calls" ]
if [ -n "${JSONFILTER_BINARY:-}" ]; then
	jsonfilter() {
		if [ -n "${JSONFILTER_LOADER:-}" ]; then
			"$JSONFILTER_LOADER" --library-path "$JSONFILTER_LIBRARY_PATH" \
				"$JSONFILTER_BINARY" "$@"
		else
			"$JSONFILTER_BINARY" "$@"
		fi
	}
	(
		eval "$pid_body"
		ubus() {
			printf '%s\n' '{"adguardhome":{"instances":{"stopped":{"running":false,"pid":10},"core":{"running":true,"pid":20},"other":{"running":true,"pid":30}}}}'
		}
		[ "$(official_pid)" = 20 ]
		ubus() {
			printf '%s\n' '{"adguardhome":{"instances":{"core":{"running":false,"pid":20}}}}'
		}
		[ -z "$(official_pid)" ]
		ubus() { printf '%s\n' '{"adguardhome":{"instances":{}}}'; }
		[ -z "$(official_pid)" ]
	)
fi

# Keep one real procfs smoke check, then substitute only the /proc status root
# to exercise disappearing/malformed parents and the original 64-level bound.
descendant_body="$(function_body "$init_file" pid_is_supervised_descendant)"
(
	eval "$descendant_body"
	real_parent="$(awk '$1 == "PPid:" { print $2; exit }' "/proc/$$/status")"
	if [ "$real_parent" -gt 1 ]; then
		pid_is_supervised_descendant "$$" "$real_parent"
	fi
)
(
	status_root="${test_tmp}/status"
	# The substitution changes only the fixture location, not parent parsing.
	# shellcheck disable=SC2016
	eval "$(printf '%s\n' "$descendant_body" |
		sed 's#"/proc/${candidate}/status"#"${status_root}/${candidate}/status"#g')"
	awk() { printf 'awk\n' >>"$pid_text_calls"; return 1; }
	status_record() {
		mkdir -p "${status_root}/$1"
		printf '%b' "$2" >"${status_root}/$1/status"
	}
	reject_parent() {
		if pid_is_supervised_descendant "$1" "$2"; then
			printf 'invalid parent chain accepted: %s -> %s\n' "$1" "$2" >&2
			exit 1
		fi
	}
	status_record 10 'Name:\tAdGuardHome\nPPid:\t20 extra\nPPid:\t99\n'
	status_record 20 'PPid:\t30'
	status_record 30 'PPid:\t1\n'
	pid_is_supervised_descendant 10 30
	pid_is_supervised_descendant 10 10
	reject_parent 10 99
	reject_parent bad 30
	reject_parent 10 bad
	for record in 'Name: absent\n' 'PPid:\nPPid: 30\n' 'PPid: invalid\n' \
		'PPid: -1\n' 'PPid: 0\n' 'PPid: 1\n' 'PPid: 20\n' ''; do
		status_record 20 "$record"
		reject_parent 10 30
	done
	status_record 20 'PPid: 21\n'
	reject_parent 10 30
	status_record 20 'PPid: 10\n'
	reject_parent 10 30
	chain_pid=1000
	while [ "$chain_pid" -lt 1064 ]; do
		status_record "$chain_pid" "PPid: $((chain_pid + 1))\n"
		chain_pid=$((chain_pid + 1))
	done
	pid_is_supervised_descendant 1000 1063
	reject_parent 1000 1064
)
[ ! -s "$pid_text_calls" ]

calls="${test_tmp}/calls"
CORE_BINARY=/usr/bin/AdGuardHome
MEMORY_ACTIVE=0
LIVE=1
AUTHENTICATED=1
EXECUTABLE="$CORE_BINARY"
SOCKET_INODE=123
dns_port=53335
OFFICIAL_SOCKET_PIDS=stale
OFFICIAL_SOCKET_INODES=stale

official_pid() {
	printf 'service\n' >>"$calls"
	[ "$LIVE" = 1 ] && printf '%s\n' "$$"
}
pidof() { printf 'pidof\n' >>"$calls"; printf '%s\n' "$$"; }
pid_is_supervised_descendant() {
	printf 'identity\n' >>"$calls"
	[ "$1:$2:$AUTHENTICATED" = "$$:$$:1" ]
}
readlink() {
	case "$1" in
		"/proc/$$/exe") printf '%s\n' "$EXECUTABLE" ;;
		"/proc/$$/fd/"*)
			printf 'fd:%s\n' "$1" >>"$calls"
			printf 'socket:[%s]\n' "$SOCKET_INODE"
			;;
		*) return 1 ;;
	esac
}
# Run the production awk expression unchanged over deterministic kernel-table
# fixtures, while the PID/FD collection uses this real shell's /proc directory.
awk() {
	if [ "$#" = 8 ]; then
		case "$8" in
			/proc/net/*)
				command awk "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
					"${test_tmp}/${8##*/}"
				return
				;;
		esac
	fi
	command awk "$@"
}
table() {
	printf 'sl local_address rem_address st tx_queue tr retrnsmt uid timeout inode\n' >"${test_tmp}/$1"
	[ "$#" -gt 1 ] || return 0
	printf '0: %s:%04X 00000000:0000 %s 0:0 0:0 0 0 0 %s\n' \
		"$2" "$dns_port" "$3" "${4:-123}" >>"${test_tmp}/$1"
}
reject_dns() {
	if dns_port_listening; then
		printf 'unsafe/foreign/incomplete listener accepted: %s\n' "$1" >&2
		exit 1
	fi
}

redirect_mode=dnsmasq-upstream
table udp 0100007F 07
table tcp 0100007F 0A
table udp6
table tcp6
dns_port_listening
[ "$(grep -cx service "$calls")" = 1 ]
[ "$(grep -cx pidof "$calls")" = 1 ]
[ "$(grep -cx identity "$calls")" = 1 ]
# UDP and TCP must not scan the same FD more than once in one check.
[ "$(grep -c '^fd:' "$calls")" = "$(grep '^fd:' "$calls" | sort -u | wc -l)" ]
[ "$OFFICIAL_SOCKET_PIDS:$OFFICIAL_SOCKET_INODES" = stale:stale ]
LIVE=0
reject_dns stopped
[ "$(grep -cx service "$calls")" = 2 ]
LIVE=1
AUTHENTICATED=0
reject_dns foreign-parent
AUTHENTICATED=1
EXECUTABLE=/usr/bin/foreign
reject_dns foreign-executable
EXECUTABLE="$CORE_BINARY (deleted)"
dns_port_listening
SOCKET_INODE=456
reject_dns foreign-inode
SOCKET_INODE=123
table tcp 0100007F 01
reject_dns non-listening-tcp
table tcp
reject_dns missing-tcp
table udp 0101A8C0 07
table tcp 0101A8C0 0A
reject_dns lan-only-upstream
table udp
table tcp
table udp6 00000000000000000000000000000001 07
table tcp6 00000000000000000000000000000001 0A
reject_dns ipv6-loopback-only
table udp6 00000000000000000000000000000000 07
table tcp6 00000000000000000000000000000000 0A
dns_port_listening
dns_ipv6_listening

redirect_mode=redirect
dns_port_listening
table udp6
table tcp6
table udp 0100007F 07
table tcp 0100007F 0A
reject_dns redirect-loopback-only
table udp 00000000 07
table tcp 00000000 0A
dns_port_listening
redirect_mode=none
table udp 0101A8C0 07
table tcp 0101A8C0 0A
dns_port_listening

# The same authenticated PID set also verifies the RAM data bind; a different
# backing cannot accidentally become ready merely because DNS is listening.
mkdir -p "${test_tmp}/work/data" "${test_tmp}/other/data"
MEMORY_ACTIVE=1
MEMORY_BACKING_WORK_DIR="${test_tmp}/work"
MEMORY_DATA_DIR="${test_tmp}/work/data"
dns_port_listening
MEMORY_DATA_DIR="${test_tmp}/other/data"
reject_dns wrong-memory-bind
MEMORY_ACTIVE=0

is_valid_port() { [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
web_listening 53335
[ "$dns_port" = 53335 ]
if web_listening 53336; then
	printf 'web readiness accepted a different port\n' >&2
	exit 1
fi
[ "$dns_port" = 53335 ]

printf 'ok - builtin PID readers, parent-chain bounds and fresh owned socket checks\n'
