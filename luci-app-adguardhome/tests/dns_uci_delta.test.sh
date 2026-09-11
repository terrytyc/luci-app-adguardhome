#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
real_uci="$(command -v uci || true)"
# Host regression may use the existing SDK payload without installing a tool.
uci_root="${ADGUARDHOME_TEST_UCI_ROOT:-}"
if [ -z "$real_uci" ] && [ -z "$uci_root" ]; then
	printf 'skip - real UCI unavailable; set ADGUARDHOME_TEST_UCI_ROOT to the SDK rootfs\n'
	exit 0
fi
# shellcheck disable=SC1090
. "$script_dir/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
mkdir "$test_tmp/config" "$test_tmp/delta"
UCI_CONFIG_DIRECTORY="$test_tmp/config"
UCI_DELTA_DIRECTORY="$test_tmp/delta"
uci() {
	if [ -n "$uci_root" ]; then
		"$uci_root/lib/ld-musl-x86_64.so.1" --library-path "$uci_root/lib:$uci_root/usr/lib" \
			"$uci_root/sbin/uci" -c "$test_tmp/config" -t "$test_tmp/delta" "$@"
	else
		"$real_uci" -c "$test_tmp/config" -t "$test_tmp/delta" "$@"
	fi
}
# Keep every UCI operation real; only service/snapshot effects and section
# discovery are isolated from the host. Existing DNS tests cover discovery.
config_context=dhcp
config_load() { config_context="$1"; }
config_get() {
	local actual="${4:-}"
	case "$3" in
		server_LENGTH)
			if grep -Eq '^[[:space:]]*list server ' "$test_tmp/config/$config_context"; then
				actual=1
			else
				actual=0
			fi
			;;
		TYPE) actual="$(uci -q get "$config_context.$2" || true)" ;;
		*) actual="$(uci -q get "$config_context.$2.$3" || true)" ;;
	esac
	eval "$1=\$actual"
}
config_list_foreach() {
	local value
	for value in $(uci -q get "$config_context.$1.$2" || true); do
		"$3" "$value"
	done
}
load_dnsmasq_section() {
	config_load dhcp
	DNSMASQ_SECTION=main
	DNSMASQ_UCI=dhcp.main
}
reload_service_if_present() { :; }
refresh_managed_config_snapshot() { [ "${TEST_SNAPSHOT_FAIL:-0}" != 1 ]; }
memory_durability_barrier() { :; }
dns_ipv6_listening() { return 1; }
log_error() { :; }
dns_port=53335

seed_config() {
	printf "config dnsmasq 'main'\n option noresolv '1'\n list server '127.0.0.1#53335'\nconfig dhcp 'lan'\n option start '100'\n" | uci import dhcp
	printf "config luci 'luci'\n option managed_dnsmasq_upstream '53335'\n option managed_dnsmasq_noresolv_present '1'\n option managed_dnsmasq_noresolv_value '1'\n" | uci import adguardhome
	printf "config redirect '%s'\n option name '%s'\nconfig defaults 'defaults'\n option forward 'REJECT'\n" \
		"$FIREWALL_SECTION" "$FIREWALL_OWNER_VALUE" | uci import firewall
}

for operation in set_dnsmasq_upstream clear_managed_dnsmasq_upstream \
	set_firewall_redirect clear_firewall_redirect; do
	seed_config
	case "$operation" in
		*dnsmasq*) package=dhcp; change=dhcp.lan.start=222 ;;
		*) package=firewall; change=firewall.defaults.forward=ACCEPT ;;
	esac
	uci set "$change"
	before="$(uci changes "$package")"
	committed="$(cksum <"$test_tmp/config/$package")"
	if "$operation"; then
		printf 'pending CLI delta was accepted by %s\n' "$operation" >&2
		exit 1
	fi
	[ "$(uci changes "$package")" = "$before" ]
	[ "$(cksum <"$test_tmp/config/$package")" = "$committed" ]
	uci revert "$package"
done

# Upstream ownership commits the plugin package too, so protect its CLI delta.
seed_config
uci set adguardhome.luci.redirect=none
before="$(uci changes adguardhome)"
for operation in set_dnsmasq_upstream clear_managed_dnsmasq_upstream; do
	if "$operation"; then exit 1; fi
	[ "$(uci changes adguardhome)" = "$before" ]
	[ -z "$(uci changes dhcp)" ]
done
uci revert adguardhome

# A pending deletion can hide the marker from ordinary `uci get`; cleanup must
# reject it before treating the managed takeover as absent. Malformed plugin
# UCI is likewise an error, never a successful no-op.
seed_config
uci delete adguardhome.luci.managed_dnsmasq_upstream
before="$(uci changes adguardhome)"
committed="$(cksum <"$test_tmp/config/dhcp")"
if clear_managed_dnsmasq_upstream; then exit 1; fi
[ "$(uci changes adguardhome)" = "$before" ]
[ "$(cksum <"$test_tmp/config/dhcp")" = "$committed" ]
uci revert adguardhome
printf "config 'unterminated\n" >"$test_tmp/config/adguardhome"
if clear_managed_dnsmasq_upstream; then exit 1; fi
[ "$(cksum <"$test_tmp/config/dhcp")" = "$committed" ]
seed_config

# An unrelated pending delta must not block a genuine no-op cleanup.
seed_config
uci delete adguardhome.luci.managed_dnsmasq_upstream
uci commit adguardhome
uci set dhcp.lan.start=222
before="$(uci changes dhcp)"
clear_managed_dnsmasq_upstream || exit 1
[ "$(uci changes dhcp)" = "$before" ]
uci revert dhcp
uci set "firewall.$FIREWALL_SECTION.name=User-owned rule"
uci commit firewall
uci set firewall.defaults.forward=ACCEPT
before="$(uci changes firewall)"
clear_firewall_redirect || exit 1
[ "$(uci changes firewall)" = "$before" ]
uci revert firewall

# Normal clean transactions still apply and remove precisely the owned state.
seed_config
clear_managed_dnsmasq_upstream || exit 1
[ -z "$(uci changes dhcp)" ]
[ -z "$(uci -q get dhcp.main.server || true)" ]
[ "$(uci get dhcp.main.noresolv)" = 1 ]
set_dnsmasq_upstream || exit 1
[ "$(uci get dhcp.main.server)" = '127.0.0.1#53335' ]
[ "$(uci get dhcp.main.noresolv)" = 1 ]
[ "$(uci get adguardhome.luci.managed_dnsmasq_noresolv_present)" = 1 ]
[ "$(uci get adguardhome.luci.managed_dnsmasq_noresolv_value)" = 1 ]
[ -z "$(uci changes dhcp)" ]
uci add_list "firewall.$FIREWALL_SECTION.dest_ip=192.0.2.53"
uci add_list "firewall.$FIREWALL_SECTION.dest_ip=2001:db8::53"
uci set "firewall.$FIREWALL_SECTION.enabled=0"
uci set "firewall.$FIREWALL_SECTION.src_ip=192.0.2.0/24"
uci commit firewall
set_firewall_redirect || exit 1
[ "$(uci get "firewall.$FIREWALL_SECTION.dest_port")" = 53335 ]
for stale_option in dest_ip enabled src_ip; do
	if uci -q get "firewall.$FIREWALL_SECTION.$stale_option"; then
		printf 'managed firewall redirect retained stale option: %s\n' "$stale_option" >&2
		exit 1
	fi
done
[ "$(uci get "firewall.$FIREWALL_SECTION.target")" = DNAT ]
[ "$(uci get "firewall.$FIREWALL_SECTION.src")" = lan ]
[ "$(uci get "firewall.$FIREWALL_SECTION.src_dport")" = 53 ]
[ "$(uci get "firewall.$FIREWALL_SECTION.family")" = ipv4 ]
clear_firewall_redirect || exit 1
if uci -q get "firewall.$FIREWALL_SECTION"; then exit 1; fi
[ -z "$(uci changes firewall)" ]
uci set firewall.defaults.forward=ACCEPT
before="$(uci changes firewall)"
clear_firewall_redirect || exit 1
[ "$(uci changes firewall)" = "$before" ]

# UCI accepts both scalar `option server` and list form. A scalar public
# resolver must block takeover, while an exact scalar managed value can be
# removed without losing its recovery marker prematurely.
printf "config dnsmasq 'main'\n option server '8.8.8.8'\n" | uci import dhcp
printf "config luci 'luci'\n" | uci import adguardhome
if set_dnsmasq_upstream; then
	printf 'scalar public DNS upstream was accepted\n' >&2
	exit 1
fi
[ "$(uci get dhcp.main.server)" = 8.8.8.8 ]
[ -z "$(uci changes dhcp)" ] && [ -z "$(uci changes adguardhome)" ]

printf "config dnsmasq 'main'\n option noresolv '1'\n option server '127.0.0.1#53335'\n" |
	uci import dhcp
printf "config luci 'luci'\n option managed_dnsmasq_upstream '53335'\n option managed_dnsmasq_noresolv_present '1'\n option managed_dnsmasq_noresolv_value '1'\n" |
	uci import adguardhome
clear_managed_dnsmasq_upstream || exit 1
if uci -q get dhcp.main.server ||
   uci -q get adguardhome.luci.managed_dnsmasq_upstream; then
	exit 1
fi
[ "$(uci get dhcp.main.noresolv)" = 1 ]

# A takeover owns only its temporary noresolv change.  Normal cleanup and a
# post-commit rollback must restore both the old value and option absence.
for previous_noresolv in absent 0 1; do
	if [ "$previous_noresolv" = absent ]; then
		printf "config dnsmasq 'main'\n" | uci import dhcp
	else
		printf "config dnsmasq 'main'\n option noresolv '%s'\n" \
			"$previous_noresolv" | uci import dhcp
	fi
	printf "config luci 'luci'\n" | uci import adguardhome
	set_dnsmasq_upstream || exit 1
	if [ "$previous_noresolv" = absent ]; then
		[ "$(uci get adguardhome.luci.managed_dnsmasq_noresolv_present)" = 0 ]
		if uci -q get adguardhome.luci.managed_dnsmasq_noresolv_value; then exit 1; fi
	else
		[ "$(uci get adguardhome.luci.managed_dnsmasq_noresolv_present)" = 1 ]
		[ "$(uci get adguardhome.luci.managed_dnsmasq_noresolv_value)" = \
			"$previous_noresolv" ]
	fi
	clear_managed_dnsmasq_upstream || exit 1
	if [ "$previous_noresolv" = absent ]; then
		if uci -q get dhcp.main.noresolv; then exit 1; fi
	else
		[ "$(uci get dhcp.main.noresolv)" = "$previous_noresolv" ]
	fi
	if uci -q get adguardhome.luci.managed_dnsmasq_noresolv_present ||
	   uci -q get adguardhome.luci.managed_dnsmasq_noresolv_value; then
		exit 1
	fi
done

printf "config dnsmasq 'main'\n option noresolv '0'\n" | uci import dhcp
printf "config luci 'luci'\n" | uci import adguardhome
TEST_SNAPSHOT_FAIL=1
if set_dnsmasq_upstream; then
	printf 'failed takeover unexpectedly succeeded\n' >&2
	exit 1
fi
TEST_SNAPSHOT_FAIL=0
[ "$(uci get dhcp.main.noresolv)" = 0 ]
if uci -q get dhcp.main.server ||
   uci -q get adguardhome.luci.managed_dnsmasq_upstream ||
   uci -q get adguardhome.luci.managed_dnsmasq_noresolv_present ||
   uci -q get adguardhome.luci.managed_dnsmasq_noresolv_value; then
	exit 1
fi

# The real settings loader must tell monitoring that an ordinary pending edit
# is busy, without stopping a healthy core or touching DNS/the user's delta.
printf "config adguardhome 'config'\n option enabled '1'\n option work_dir '/etc/AdGuardHome'\nconfig luci 'luci'\n option redirect 'none'\n" | uci import adguardhome
UCI_CONFIG_DIRECTORY="$test_tmp/config"
UCI_DELTA_DIRECTORY="$test_tmp/delta"
OFFICIAL_SERVICE=/bin/true
CORE_RUNNING=1
CORE_STOPS=0
DNS_CLEANUPS=0
clear_recorded_integration_locked() { DNS_CLEANUPS=$((DNS_CLEANUPS + 1)); }
wait_for_core_stopped() { CORE_RUNNING=0; CORE_STOPS=$((CORE_STOPS + 1)); }
uci set adguardhome.luci.memory_writeback_interval=120
before="$(uci changes adguardhome)"
committed="$(cksum <"$test_tmp/config/adguardhome")"
rc=0
load_settings light || rc=$?
[ "$rc:$MONITOR_SETTINGS_READY" = 2:0 ]
reconcile_core_locked
[ "$CORE_RUNNING:$CORE_STOPS:$DNS_CLEANUPS" = 1:0:0 ]
[ "$(uci changes adguardhome)" = "$before" ]
[ "$(cksum <"$test_tmp/config/adguardhome")" = "$committed" ]
uci revert adguardhome
ensure_managed_config_present
[ "$CORE_RUNNING:$CORE_STOPS:$DNS_CLEANUPS" = 1:0:0 ]

# A pending edit must not hide an unsafe committed file, and malformed UCI
# must still fail closed rather than being treated as a harmless busy round.
uci set adguardhome.luci.memory_writeback_interval=120
chmod 0666 "$test_tmp/config/adguardhome"
rc=0
reconcile_core_locked || rc=$?
[ "$rc:$CORE_RUNNING:$CORE_STOPS:$DNS_CLEANUPS" = 1:0:1:1 ]
chmod 0600 "$test_tmp/config/adguardhome"
uci revert adguardhome
printf "config 'unterminated\n" >"$test_tmp/config/adguardhome"
rc=0
reconcile_core_locked || rc=$?
[ "$rc:$CORE_STOPS:$DNS_CLEANUPS" = 1:2:2 ]
printf 'ok - real UCI rejects existing CLI deltas without committing or reverting them\n'
