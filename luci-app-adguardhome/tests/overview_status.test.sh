#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/lib/function-body.sh"
eval "$(init_source "$script_dir/../root/etc/init.d/AdGuardHome")"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
INTEGRATION_LOCK="$test_tmp/integration.lock"
: >"$INTEGRATION_LOCK"
calls="$test_tmp/calls"
MODE=redirect LIVE=1 MATCHES=1 UCI_OK=1 DNS_READY=1
uci() {
	[ "$UCI_OK" = 1 ] || return 1
	case "$2" in
		export) ;;
		get) printf '%s\n' "$MODE" ;;
		*) exit 1 ;;
	esac
}
uci_guard_no_delta() { [ "$UCI_OK" = 1 ]; }
official_socket_snapshot() {
	printf 'snapshot\n' >>"$calls"
	OFFICIAL_SOCKET_INODES=" $LIVE "
	[ "$LIVE" = 1 ]
}
dns_port_listening() {
	[ "$OFFICIAL_SOCKET_SNAPSHOT_READY" = 1 ] &&
		[ "$OFFICIAL_SOCKET_INODES" = ' 1 ' ] && [ "$DNS_READY" = 1 ]
}
integration_matches_desired() { [ "$MATCHES" = 1 ]; }
web_listening() {
	[ "$OFFICIAL_SOCKET_SNAPSHOT_READY" = 1 ] &&
		[ "$OFFICIAL_SOCKET_INODES" = ' 1 ' ] && [ "$1" = 443 ]
}
expect() {
	local expected="$1" scans="$2" result
	shift 2
	: >"$calls"
	result="$(overview_status "$@")"
	[ "$result" = "$(printf '%b' "$expected")" ]
	[ "$(wc -l <"$calls")" = "$scans" ]
}
expect 'integration=ready\nhttps=1\nhttp=0' 1 53335 redirect 443 3000
DNS_READY=0
expect 'integration=pending\nhttps=1\nhttp=0' 1 53335 redirect 443 3000
DNS_READY=1 MATCHES=0
expect 'integration=pending\nhttps=1\nhttp=0' 1 53335 redirect 443 3000
MATCHES=1 UCI_OK=0
expect 'integration=unknown\nhttps=1\nhttp=0' 1 53335 redirect 443 3000
UCI_OK=1
expect 'integration=unknown\nhttps=1\nhttp=0' 1 0 unknown 443 0
LIVE=0
expect 'integration=pending\nhttps=0\nhttp=0' 1 53335 redirect 443 3000
MODE=none
expect 'integration=none\nhttps=0\nhttp=0' 0 53335 none 0 0
expect 'integration=unknown\nhttps=0\nhttp=0' 0 0 none 0 0
reject() {
	local result rc=0
	result="$(overview_status "$@")" || rc=$?
	[ "$rc" = 2 ] && [ -z "$result" ]
}
for port in 00 053335 65536 -1 invalid ''; do
	reject "$port" none 0 0
	reject 53335 none "$port" 0
	reject 53335 none 0 "$port"
done
reject 53335 invalid 0 0
reject 53335 none 0
exec 199<"$INTEGRATION_LOCK"
/usr/bin/flock -x 199
reject 53335 none 443 3000
/usr/bin/flock -u 199
exec 199<&-
INTEGRATION_LOCK="$test_tmp/missing"
reject 53335 none 0 0
[ ! -e "$INTEGRATION_LOCK" ]
printf 'ok - one read-only overview snapshot, strict protocol and busy/unknown fallback\n'
