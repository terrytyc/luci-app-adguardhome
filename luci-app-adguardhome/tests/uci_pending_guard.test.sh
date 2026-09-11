#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
makefile="$package_dir/Makefile"
temporary="$(mktemp -d /tmp/luci-agh-uci-guard.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

awk '
	/^define AdGuardHome\/UciPendingGuard$/ { copying=1; next }
	copying && /^endef$/ { exit }
	copying { gsub(/\$\$/, "$"); print }
' "$makefile" >"$temporary/guard.template"
[ -s "$temporary/guard.template" ]

render_guard() {
	awk -v configs="$1" '{ gsub(/[$][(]1[)]/, configs); print }' \
		"$temporary/guard.template" >"$2"
	sh -n "$2"
}
render_guard 'adguardhome dhcp firewall' "$temporary/main-guard.sh"
render_guard luci "$temporary/i18n-guard.sh"

if grep -Eq 'uci[[:space:]]+-q[[:space:]]+(commit|revert)' "$temporary/guard.template"; then
	exit 1
fi

make_dollar='$'
main_reference="${make_dollar}(call AdGuardHome/UciPendingGuard,adguardhome dhcp firewall)"
i18n_reference="${make_dollar}(call AdGuardHome/UciPendingGuard,luci)"
main_start="define Package/${make_dollar}(PKG_NAME)/preinst"
extract_hook() {
	awk -v start="$1" '
		$0 == start { copying=1 }
		copying { print }
		copying && /^endef$/ { exit }
	' "$makefile"
}
main_hook="$(extract_hook "$main_start")"
i18n_hook="$(extract_hook 'define Package/luci-i18n-adguardhome-zh-cn/preinst')"
[ "$(grep -Fc 'call AdGuardHome/UciPendingGuard' "$makefile")" = 2 ]
printf '%s\n' "$main_hook" | grep -Fq "$main_reference"
printf '%s\n' "$i18n_hook" | grep -Fq "$i18n_reference"
guard_line="$(printf '%s\n' "$main_hook" | grep -nF "$main_reference" | cut -d: -f1)"
stop_line="$(printf '%s\n' "$main_hook" | grep -nF '/etc/init.d/AdGuardHome stop' | cut -d: -f1)"
[ "$guard_line" -lt "$stop_line" ]
i18n_line="$(grep -n '^define Package/luci-i18n-adguardhome-zh-cn/preinst$' "$makefile" | cut -d: -f1)"
include_reference="include ${make_dollar}(TOPDIR)/feeds/luci/luci.mk"
include_line="$(grep -nF "$include_reference" "$makefile" | cut -d: -f1)"
[ "$i18n_line" -lt "$include_line" ]

run_guard() {
	guard=$1
	mode=$2
	events=$temporary/events-$mode
	error=$temporary/error-$mode
	: >"$events"
	if MODE="$mode" EVENTS="$events" sh -c '
		uci() {
			printf "inspect:%s\n" "$3" >>"$EVENTS"
			case "$MODE:$3" in
				pending:dhcp|pending:luci) printf "pending=value\n" ;;
				failure:firewall) return 1 ;;
			esac
		}
		eval "$1"
		printf "stop\n" >>"$EVENTS"
	' sh "$(cat "$guard")" 2>"$error"; then
		[ "$mode" = clean ] || return 1
	else
		[ "$mode" != clean ] || return 1
	fi
}

run_guard "$temporary/main-guard.sh" clean
[ "$(cat "$temporary/events-clean")" = "$(printf 'inspect:adguardhome\ninspect:dhcp\ninspect:firewall\nstop')" ]
run_guard "$temporary/main-guard.sh" pending
[ "$(cat "$temporary/events-pending")" = "$(printf 'inspect:adguardhome\ninspect:dhcp')" ]
grep -Fq 'Commit or revert pending dhcp changes' "$temporary/error-pending"
run_guard "$temporary/main-guard.sh" failure
[ "$(cat "$temporary/events-failure")" = "$(printf 'inspect:adguardhome\ninspect:dhcp\ninspect:firewall')" ]
grep -Fq 'Unable to inspect pending firewall UCI changes' "$temporary/error-failure"

rm -f "$temporary/events-clean" "$temporary/events-pending"
run_guard "$temporary/i18n-guard.sh" clean
[ "$(cat "$temporary/events-clean")" = "$(printf 'inspect:luci\nstop')" ]
run_guard "$temporary/i18n-guard.sh" pending
[ "$(cat "$temporary/events-pending")" = inspect:luci ]
grep -Fq 'Commit or revert pending luci changes' "$temporary/error-pending"

printf 'ok - package hooks reject only their owned pending UCI configs\n'
