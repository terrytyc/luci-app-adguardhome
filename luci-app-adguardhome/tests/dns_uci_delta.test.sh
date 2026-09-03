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
load_dnsmasq_section() { DNSMASQ_UCI=dhcp.main; }
dnsmasq_takeover_is_safe() { return 0; }
reload_service_if_present() { :; }
refresh_managed_config_snapshot() { :; }
dns_ipv6_listening() { return 1; }
log_error() { :; }
dns_port=53335

seed_config() {
	printf "config dnsmasq 'main'\n option noresolv '1'\n list server '127.0.0.1#53335'\nconfig dhcp 'lan'\n option start '100'\n" | uci import dhcp
	printf "config luci 'luci'\n option managed_dnsmasq_upstream '53335'\n" | uci import adguardhome
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
set_dnsmasq_upstream || exit 1
[ "$(uci get dhcp.main.server)" = '127.0.0.1#53335' ]
[ "$(uci get dhcp.main.noresolv)" = 1 ]
[ -z "$(uci changes dhcp)" ]
set_firewall_redirect || exit 1
[ "$(uci get "firewall.$FIREWALL_SECTION.dest_port")" = 53335 ]
clear_firewall_redirect || exit 1
if uci -q get "firewall.$FIREWALL_SECTION"; then exit 1; fi
[ -z "$(uci changes firewall)" ]
uci set firewall.defaults.forward=ACCEPT
before="$(uci changes firewall)"
clear_firewall_redirect || exit 1
[ "$(uci changes firewall)" = "$before" ]
printf 'ok - real UCI rejects existing CLI deltas without committing or reverting them\n'
