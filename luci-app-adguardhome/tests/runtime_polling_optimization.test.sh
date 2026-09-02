#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

function_body() {
	awk -v name="$1" '
		$0 == name "() {" || $0 == name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' "$init_file"
}

for name in official_socket_snapshot official_owns_socket \
	official_owns_ipv4_reachable_socket official_memory_data_mount_visible \
	dns_port_listening dns_ipv6_listening web_listening runtime_settings_match; do
	eval "$(function_body "$name")"
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
pid_body="$(function_body official_pid)"
printf '%s\n' "$pid_body" |
	grep -Fq "@.adguardhome.instances[@.running=true].pid"
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

printf 'ok - light readiness, fresh official socket snapshots, PID/FD reuse and bind checks\n'
