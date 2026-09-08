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
' "$makefile" >"$temporary/guard.sh"
[ -s "$temporary/guard.sh" ]
sh -n "$temporary/guard.sh"
if grep -Eq 'uci[[:space:]]+-q[[:space:]]+(commit|revert)' "$temporary/guard.sh"; then
	exit 1
fi

make_dollar='$'
guard_reference="${make_dollar}(AdGuardHome/UciPendingGuard)"
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
[ "$(grep -Fc "$guard_reference" "$makefile")" = 2 ]
printf '%s\n' "$main_hook" | grep -Fq "$guard_reference"
printf '%s\n' "$i18n_hook" | grep -Fq "$guard_reference"
guard_line="$(printf '%s\n' "$main_hook" | grep -nF "$guard_reference" | cut -d: -f1)"
stop_line="$(printf '%s\n' "$main_hook" | grep -nF '/etc/init.d/AdGuardHome stop' | cut -d: -f1)"
[ "$guard_line" -lt "$stop_line" ]
i18n_line="$(grep -n '^define Package/luci-i18n-adguardhome-zh-cn/preinst$' "$makefile" | cut -d: -f1)"
include_reference="include ${make_dollar}(TOPDIR)/feeds/luci/luci.mk"
include_line="$(grep -nF "$include_reference" "$makefile" | cut -d: -f1)"
[ "$i18n_line" -lt "$include_line" ]

run_guard() {
	mode=$1
	events=$temporary/events-$mode
	error=$temporary/error-$mode
	: >"$events"
	if MODE="$mode" EVENTS="$events" sh -c '
		uci() {
			printf "inspect\n" >>"$EVENTS"
			case "$MODE" in
				clean) return 0 ;;
				pending) printf "network.lan.ipaddr=value\n" ;;
				failure) return 1 ;;
			esac
		}
		eval "$1"
		printf "stop\n" >>"$EVENTS"
	' sh "$(cat "$temporary/guard.sh")" 2>"$error"; then
		[ "$mode" = clean ] || return 1
		[ "$(cat "$events")" = "$(printf 'inspect\nstop')" ]
	else
		[ "$mode" != clean ] || return 1
		[ "$(cat "$events")" = inspect ]
		case "$mode" in
			pending) grep -Fq 'Commit or revert pending UCI changes' "$error" ;;
			failure) grep -Fq 'Unable to inspect pending UCI changes' "$error" ;;
		esac
	fi
}

run_guard clean
run_guard pending
run_guard failure
printf 'ok - main and translation installs reject pending or unreadable UCI before stop\n'
