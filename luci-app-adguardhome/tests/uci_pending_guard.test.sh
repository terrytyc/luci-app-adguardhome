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
			printf "inspect:%s\n" "$*" >>"$EVENTS"
			[ "$*" = "-q changes" ] || return 2
			case "$MODE" in
				pending-*) printf "%s.test.value=pending\n" "${MODE#pending-}" ;;
				failure) return 1 ;;
			esac
			return 0
		}
		. "$1"
		printf "stop\n" >>"$EVENTS"
	' sh "$temporary/guard.sh" 2>"$error"; then
		[ "$mode" = clean ] || return 1
	else
		[ "$mode" != clean ] || return 1
	fi
}

run_guard clean
[ "$(cat "$temporary/events-clean")" = "$(printf 'inspect:-q changes\nstop')" ]
for config in adguardhome dhcp firewall luci network system custom_pkg; do
	run_guard "pending-$config"
	[ "$(cat "$temporary/events-pending-$config")" = 'inspect:-q changes' ]
	grep -Fq 'Commit or revert pending UCI changes' "$temporary/error-pending-$config"
done
run_guard failure
[ "$(cat "$temporary/events-failure")" = 'inspect:-q changes' ]
grep -Fq 'Unable to inspect pending UCI changes' "$temporary/error-failure"

# Use the SDK's native UCI when available; isolate both its committed config
# directory and shared CLI delta store from the host (not per-session deltas).
real_uci="$(command -v uci || true)"
uci_root="${ADGUARDHOME_TEST_UCI_ROOT:-}"
if [ -n "$real_uci" ] || [ -n "$uci_root" ]; then
	mkdir "$temporary/config" "$temporary/delta"
	uci() {
		if [ -n "$uci_root" ]; then
			"$uci_root/lib/ld-musl-x86_64.so.1" --library-path "$uci_root/lib:$uci_root/usr/lib" \
				"$uci_root/sbin/uci" -c "$temporary/config" -t "$temporary/delta" "$@"
		else
			"$real_uci" -c "$temporary/config" -t "$temporary/delta" "$@"
		fi
	}
	for config in network system; do
		printf "config probe 'test'\n\toption value 'committed'\n" >"$temporary/config/$config"
		cp "$temporary/config/$config" "$temporary/committed-$config"
	done
	( . "$temporary/guard.sh" )
	for config in network system; do
		uci set "$config.test.value=pending-$config"
		uci changes >"$temporary/changes-before"
		cp "$temporary/delta/$config" "$temporary/delta-before"
		if ( . "$temporary/guard.sh"; : >"$temporary/stopped" ) 2>"$temporary/native-error"; then
			printf 'native %s CLI delta was accepted by the installation guard\n' "$config" >&2
			exit 1
		fi
		[ ! -e "$temporary/stopped" ]
		grep -Fq 'Commit or revert pending UCI changes' "$temporary/native-error"
		uci changes >"$temporary/changes-after"
		cmp "$temporary/changes-before" "$temporary/changes-after"
		cmp "$temporary/config/$config" "$temporary/committed-$config"
		cmp "$temporary/delta/$config" "$temporary/delta-before"
		uci revert "$config"
	done
else
	printf 'skip - native installation delta check; set ADGUARDHOME_TEST_UCI_ROOT\n'
fi

printf 'ok - package hooks reject all default CLI deltas before stopping services\n'
