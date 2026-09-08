#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"

require_text() {
	grep -Fq -- "$2" "$1" || {
		printf 'missing simplified DNS integration contract: %s\n' "$2" >&2
		exit 1
	}
}

reject_text() {
	if grep -Fq -- "$2" "$1"; then
		printf 'obsolete DNS integration state remains: %s\n' "$2" >&2
		exit 1
	fi
}

require_text "$init_file" 'MANAGED_DNSMASQ_UPSTREAM="managed_dnsmasq_upstream"'
for obsolete in \
	dnsmasq_snapshot \
	dnsmasq_active_fingerprint \
	'/var/run/AdGredir' \
	'.old_enabled' \
	'.old_redirect' \
	'.old_port' \
	'clear_exchange_mode()' \
	'exchange) redirect_mode='; do
	reject_text "$init_file" "$obsolete"
done

dns_body="$(sed -n '/^remember_first_dnsmasq() {$/,/^set_firewall_redirect() {$/p' "$init_file")"
printf '%s\n' "$dns_body" | grep -Fq 'add_list "${DNSMASQ_UCI}.server=${upstream}"' || {
	printf 'simplified DNS integration does not add only its exact upstream\n' >&2
	exit 1
}
printf '%s\n' "$dns_body" | grep -Fq 'delete "${DNSMASQ_UCI}.noresolv"' || {
	printf 'simplified DNS cleanup does not remove noresolv\n' >&2
	exit 1
}
if printf '%s\n' "$dns_body" | grep -Fq 'resolvfile'; then
	printf 'simplified DNS integration still modifies resolvfile\n' >&2
	exit 1
fi

# Source the coordinator under plain ash, then replace its OpenWrt interfaces
# with a small deterministic UCI/config model for behavioral coverage.
# shellcheck disable=SC1090
. "$init_file"

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/luci-agh-dns-state.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
uci_log="${test_tmp}/uci.log"
: >"$uci_log"

config_context=adguardhome
config_load() {
	config_context="$1"
	printf 'load:%s\n' "$1" >>"$uci_log"
}
config_get() {
	local actual
	case "$config_context:$2:$3" in
		dhcp:cfg01411c:noresolv) actual="${TEST_NORESOLV:-}" ;;
		"firewall:${FIREWALL_SECTION}:TYPE") actual="${TEST_FW_TYPE:-redirect}" ;;
		"firewall:${FIREWALL_SECTION}:${FIREWALL_OWNER_OPTION}") actual="${TEST_FW_OWNER:-$FIREWALL_OWNER_VALUE}" ;;
		"firewall:${FIREWALL_SECTION}:src") actual="${TEST_FW_SRC:-lan}" ;;
		"firewall:${FIREWALL_SECTION}:proto") actual="${TEST_FW_PROTO:-tcp udp}" ;;
		"firewall:${FIREWALL_SECTION}:src_dport") actual="${TEST_FW_SRC_PORT:-53}" ;;
		"firewall:${FIREWALL_SECTION}:dest_port") actual="${TEST_FW_DEST_PORT:-53335}" ;;
		"firewall:${FIREWALL_SECTION}:target") actual="${TEST_FW_TARGET:-DNAT}" ;;
		"firewall:${FIREWALL_SECTION}:family") actual="${TEST_FW_FAMILY:-ipv4}" ;;
		"firewall:${FIREWALL_SECTION}:reflection") actual="${TEST_FW_REFLECTION:-0}" ;;
		*) printf 'unexpected config_get: %s:%s:%s\n' "$config_context" "$2" "$3" >&2; return 1 ;;
	esac
	eval "$1=\$actual"
}
config_foreach() {
	[ "$2" = dnsmasq ] || return 1
	local section
	for section in ${TEST_DNSMASQ_SECTIONS:-cfg01411c}; do
		"$1" "$section"
	done
}
config_list_foreach() {
	local callback="$3" value values
	[ "$2" = server ] || return 1
	case "$1" in
		cfg01411c) values="${TEST_SERVERS:-}" ;;
		cfgsecond) values="${TEST_SECOND_SERVERS:-}" ;;
		*) return 1 ;;
	esac
	while IFS= read -r value; do
		[ -n "$value" ] || continue
		"$callback" "$value"
	done <<-EOF
	$values
	EOF
}
log_error() { printf 'log:%s\n' "$*" >>"$uci_log"; }
refresh_managed_config_snapshot() { printf 'snapshot\n' >>"$uci_log"; }
reload_service_if_present() { printf 'reload:%s:%s\n' "$1" "$2" >>"$uci_log"; }

uci() {
	[ "${1:-}" != -q ] || shift
	command="${1:-}"
	shift || true
	case "$command:$*" in
		export:*) [ "$*" != "${TEST_UNREADABLE_PACKAGE:-}" ]; return ;;
		changes:*)
			[ "$*" != "${TEST_PENDING_PACKAGE:-}" ] || printf 'pending edit\n'
			return 0
			;;
		"get:${PLUGIN_CONFIG}.${PLUGIN_SECTION}.redirect")
			printf '%s\n' "${TEST_MODE:-none}"
			return 0
			;;
		"get:firewall.${FIREWALL_SECTION}.${FIREWALL_OWNER_OPTION}")
			[ "${TEST_FIREWALL_RECORDED:-0}" = 1 ] || return 1
			printf '%s\n' "$FIREWALL_OWNER_VALUE"
			return 0
			;;
		"get:${PLUGIN_CONFIG}.${PLUGIN_SECTION}.${MANAGED_DNSMASQ_UPSTREAM}")
			[ -n "${TEST_MANAGED_PORT:-}" ] || return 1
			printf '%s\n' "$TEST_MANAGED_PORT"
			return 0
			;;
		"get:dhcp.cfg01411c.noresolv")
			[ -n "${TEST_NORESOLV:-}" ] || return 1
			printf '%s\n' "$TEST_NORESOLV"
			return 0
			;;
	esac
	printf '%s:%s\n' "$command" "$*" >>"$uci_log"
	return 0
}

TEST_SERVERS='/example.test/192.0.2.53'
load_dnsmasq_section
dnsmasq_takeover_is_safe
for generic in '9.9.9.9' '/#/9.9.9.9'; do
	TEST_SERVERS="/example.test/192.0.2.53
${generic}"
	if dnsmasq_takeover_is_safe; then
		printf 'generic dnsmasq upstream was accepted: %s\n' "$generic" >&2
		exit 1
	fi
done

: >"$uci_log"
dns_port=53335
TEST_SERVERS="/example.test/192.0.2.53
9.9.9.9"
if set_dnsmasq_upstream; then
	printf 'DNS takeover succeeded despite an existing generic upstream\n' >&2
	exit 1
fi
if grep -Eq '^(add_list|set|delete|del_list|commit):' "$uci_log"; then
	printf 'rejected DNS takeover changed UCI state\n' >&2
	exit 1
fi

: >"$uci_log"
TEST_SERVERS='/example.test/192.0.2.53'
TEST_MANAGED_PORT=''
set_dnsmasq_upstream
for expected in \
	'add_list:dhcp.cfg01411c.server=127.0.0.1#53335' \
	'set:dhcp.cfg01411c.noresolv=1' \
	'set:adguardhome.luci.managed_dnsmasq_upstream=53335' \
	'commit:dhcp' \
	'commit:adguardhome' \
	'reload:/etc/init.d/dnsmasq:restart'; do
	grep -Fqx -- "$expected" "$uci_log" || {
		printf 'DNS takeover omitted operation: %s\n' "$expected" >&2
		exit 1
	}
done
if grep -Fq 'delete:dhcp.cfg01411c.server' "$uci_log"; then
	printf 'DNS takeover replaced existing conditional server entries\n' >&2
	exit 1
fi

: >"$uci_log"
TEST_MANAGED_PORT=53335
clear_managed_dnsmasq_upstream
for expected in \
	'del_list:dhcp.cfg01411c.server=127.0.0.1#53335' \
	'delete:dhcp.cfg01411c.noresolv' \
	'delete:adguardhome.luci.managed_dnsmasq_upstream'; do
	grep -Fqx -- "$expected" "$uci_log" || {
		printf 'DNS cleanup omitted operation: %s\n' "$expected" >&2
		exit 1
	}
done

# Cleanup may locate its unique recorded upstream after another dnsmasq
# instance is added, but takeover remains single-instance only.
TEST_DNSMASQ_SECTIONS='cfg01411c cfgsecond'
TEST_SERVERS='/example.test/192.0.2.53'
TEST_SECOND_SERVERS="/second.test/192.0.2.54
127.0.0.1#53335"
: >"$uci_log"
clear_managed_dnsmasq_upstream
grep -Fqx -- 'del_list:dhcp.cfgsecond.server=127.0.0.1#53335' "$uci_log"
if grep -Fq 'dhcp.cfg01411c' "$uci_log"; then
	printf 'DNS cleanup modified an unrelated dnsmasq instance\n' >&2
	exit 1
fi
: >"$uci_log"
if set_dnsmasq_upstream; then
	printf 'DNS takeover accepted multiple dnsmasq instances\n' >&2
	exit 1
fi
if grep -Eq '^(add_list|set|delete|del_list|commit):' "$uci_log"; then
	printf 'rejected multi-instance takeover changed UCI state\n' >&2
	exit 1
fi

# More than one section containing the recorded upstream is ambiguous and
# must fail before any UCI mutation.
TEST_SERVERS='127.0.0.1#53335'
: >"$uci_log"
if clear_managed_dnsmasq_upstream; then
	printf 'ambiguous managed dnsmasq upstream was cleaned\n' >&2
	exit 1
fi
if grep -Eq '^(add_list|set|delete|del_list|commit):' "$uci_log"; then
	printf 'ambiguous DNS cleanup changed UCI state\n' >&2
	exit 1
fi
TEST_DNSMASQ_SECTIONS=cfg01411c
TEST_SECOND_SERVERS=''

TEST_MANAGED_PORT=53335
TEST_NORESOLV=1
dns_port=53335
TEST_SERVERS="/example.test/192.0.2.53
127.0.0.1#53335"
config_context=adguardhome
: >"$uci_log"
dnsmasq_integration_matches
[ "$config_context" = adguardhome ]
[ "$(grep -c '^load:dhcp$' "$uci_log")" = 1 ]
TEST_SERVERS="${TEST_SERVERS}
9.9.9.9"
if dnsmasq_integration_matches; then
	printf 'active DNS validation accepted a bypassing generic upstream\n' >&2
	exit 1
fi

# Nine fields come from one firewall config snapshot.  Its temporary config
# context must not replace the caller's already-loaded adguardhome context.
dns_ipv6_listening() { [ "${TEST_IPV6:-0}" = 1 ]; }
config_context=adguardhome
: >"$uci_log"
firewall_integration_matches
[ "$config_context" = adguardhome ]
[ "$(grep -c '^load:firewall$' "$uci_log")" = 1 ]
if grep -q '^get:firewall[.]' "$uci_log"; then
	printf 'firewall matching still forks individual UCI readers\n' >&2
	exit 1
fi
for changed in TEST_FW_TYPE TEST_FW_OWNER TEST_FW_SRC TEST_FW_PROTO \
	TEST_FW_SRC_PORT TEST_FW_DEST_PORT TEST_FW_TARGET TEST_FW_FAMILY TEST_FW_REFLECTION; do
	eval "$changed=unexpected"
	if firewall_integration_matches; then
		printf 'firewall mismatch accepted: %s\n' "$changed" >&2
		exit 1
	fi
	unset "$changed"
done
TEST_IPV6=1
if firewall_integration_matches; then
	printf 'IPv6 listener accepted without matching firewall family\n' >&2
	exit 1
fi
TEST_FW_FAMILY=any
firewall_integration_matches

# Status uses the same matching rules without reconciling or waiting.  Even
# none mode verifies that no plugin-owned takeover remains, without DNS probes.
(
	for action in integration_status web_listening; do
		. "$init_file"
		[ -z "$USE_PROCD" ]
	done
	action=restart
	. "$init_file"
	[ "$USE_PROCD" = 1 ]
)
INTEGRATION_LOCK="${test_tmp}/integration.lock"
: >"$INTEGRATION_LOCK"
load_settings() { printf 'unexpected-settings\n' >>"$uci_log"; return 1; }
run_locked() { printf 'unexpected-lock\n' >>"$uci_log"; return 1; }
wait_for_core_ready() { printf 'unexpected-wait\n' >>"$uci_log"; return 1; }
dns_port_listening() { printf 'probe\n' >>"$uci_log"; [ "${TEST_LISTENING:-1}" = 1 ]; }
expect_status() {
	local expected="$1" rc=0
	shift
	integration_status "$@" || rc=$?
	[ "$rc" = "$expected" ] || { printf 'unexpected integration status: %s (expected %s)\n' "$rc" "$expected" >&2; exit 1; }
}
: >"$uci_log"
TEST_MODE=none TEST_MANAGED_PORT=''
expect_status 0 53335 none
! grep -q '^probe$' "$uci_log"
TEST_FIREWALL_RECORDED=1 expect_status 1 53335 none
TEST_MANAGED_PORT=53335
expect_status 1 53335 none
TEST_MODE=dnsmasq-upstream TEST_SERVERS='127.0.0.1#53335'
expect_status 0 53335 dnsmasq-upstream
TEST_PENDING_PACKAGE=dhcp expect_status 2 53335 dnsmasq-upstream
TEST_LISTENING=0 expect_status 1 53335 dnsmasq-upstream
TEST_SERVERS='9.9.9.9' expect_status 1 53335 dnsmasq-upstream
TEST_MODE=redirect TEST_MANAGED_PORT=''
expect_status 0 53335 redirect
TEST_FW_DEST_PORT=55353 expect_status 1 53335 redirect
TEST_UNREADABLE_PACKAGE=firewall expect_status 2 53335 redirect
TEST_PENDING_PACKAGE=adguardhome expect_status 2 53335 redirect
expect_status 2 53335 none
for port in 0 65536 053335 -1 invalid ''; do expect_status 2 "$port" redirect; done
expect_status 2 53335 invalid
expect_status 2 53335 redirect extra
exec 199<"$INTEGRATION_LOCK"
/usr/bin/flock -x 199
expect_status 2 53335 redirect
/usr/bin/flock -u 199
exec 199<&-
INTEGRATION_LOCK="${test_tmp}/missing.lock"
expect_status 2 53335 redirect
[ ! -e "$INTEGRATION_LOCK" ]
if grep -Eq '^(unexpected-|add_list:|set:|delete:|del_list:|commit:|reload:|snapshot)' "$uci_log"; then
	printf 'integration status entered a mutating or blocking path\n' >&2
	exit 1
fi

printf 'ok - simplified DNS ownership state and exact dnsmasq lifecycle\n'
