#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

hook_body() {
	awk -v hook="$2" '
		BEGIN { start = "define Package/$(PKG_NAME)/" hook }
		$0 == start { copying = 1; next }
		copying && /^endef$/ { exit }
		copying { print }
	' "$1"
}

preinst="$(hook_body "$makefile" preinst)"
postinst="$(hook_body "$makefile" postinst)"
prerm="$(hook_body "$makefile" prerm)"
postrm="$(hook_body "$makefile" postrm)"
for body in "$preinst" "$postinst" "$prerm" "$postrm"; do
	[ -n "$body" ] || {
		printf 'missing package lifecycle hook\n' >&2
		exit 1
	}
done

version_line="$(printf '%s\n' "$preinst" |
	grep -n '^source_version="\$\$(installed_source_version)"' | cut -d: -f1)"
state_line="$(printf '%s\n' "$preinst" |
	grep -n '^ensure_runtime_dir && write_upgrade_state' | cut -d: -f1)"
stop_line="$(printf '%s\n' "$preinst" |
	grep -n 'AdGuardHome stop' | tail -n 1 | cut -d: -f1)"
commit_line="$(printf '%s\n' "$preinst" |
	grep -n '^upgrade_committed=1' | cut -d: -f1)"
case "$version_line:$state_line:$stop_line:$commit_line" in
	""|*[!0-9:]*|:*|*:|*::*) exit 1 ;;
esac
[ "$version_line" -lt "$state_line" ] &&
	[ "$state_line" -lt "$stop_line" ] &&
	[ "$stop_line" -lt "$commit_line" ] || {
	printf 'baseline upgrade is not gated, recorded, stopped and committed in order\n' >&2
	exit 1
}

for required in \
	'validate_original_snapshot' \
	'bounded_private_file "$$managed_snapshot"' \
	'official_delta_is_clean && baseline_config_is_valid' \
	'AdGuardHome do_redirect 0' \
	'adguardhome.luci.managed_dnsmasq_upstream' \
	'rollback_preinst'; do
	printf '%s\n' "$preinst" | grep -Fq "$required" || {
		printf 'pre-upgrade contract missing: %s\n' "$required" >&2
		exit 1
	}
done

for required in \
	'upgrade_state_source_allowed "$$upgrade_state" || exit 1' \
	'case "$$was_running" in' \
	'ADGUARDHOME_BASELINE_RESUME=1' \
	'/etc/init.d/AdGuardHome start' \
	'/etc/init.d/AdGuardHome stop' \
	'rm -f "$$upgrade_state"'; do
	printf '%s\n' "$postinst" | grep -Fq "$required" || {
		printf 'post-upgrade convergence missing: %s\n' "$required" >&2
		exit 1
	}
done

init_file="$package_dir/root/etc/init.d/AdGuardHome"
grep -Fq 'BASELINE_UPGRADE_STATE="${NORMALIZER_RUNTIME_DIR}/upgrade-state"' \
	"$init_file" || {
	printf 'init baseline upgrade-state path is missing\n' >&2
	exit 1
}
start_body="$(function_body "$init_file" start_service)"
for required in \
	'ADGUARDHOME_BASELINE_RESUME:-0' \
	'START_PREPARED=1' \
	'START_DISABLED=1'; do
	printf '%s\n' "$start_body" | grep -Fq "$required" || {
		printf 'init stopped-upgrade barrier is missing: %s\n' "$required" >&2
		exit 1
	}
	done

barrier_dir="$(mktemp -d /tmp/luci-agh-baseline-barrier.XXXXXX)"
trap 'rm -rf "$barrier_dir"' EXIT HUP INT TERM
(
	eval "$start_body"
	BASELINE_UPGRADE_STATE="$barrier_dir/upgrade-state"
	: >"$BASELINE_UPGRADE_STATE"
	ADGUARDHOME_BASELINE_RESUME=0
	start_service
	[ "$START_PREPARED:$START_DISABLED" = 1:1 ]
) || {
	printf 'stopped baseline upgrade was not held behind the init start barrier\n' >&2
	exit 1
}
rm -rf "$barrier_dir"
trap - EXIT HUP INT TERM

printf '%s\n' "$prerm" | grep -Fq '1:*|*:upgrade) exit 0'
printf '%s\n' "$postrm" | grep -Fq '1:*|*:upgrade) exit 0'

upgrade_defaults="$(sed -n '/if \[ -e "$UPGRADE_STATE"/,/^fi$/p' "$defaults")"
for required in \
	'upgrade_state_is_valid' \
	'baseline_config_is_valid' \
	'keep_active_config' \
	'refresh_managed_config_snapshot'; do
	printf '%s\n' "$upgrade_defaults" | grep -Fq "$required" || {
		printf 'uci-defaults baseline path missing: %s\n' "$required" >&2
		exit 1
	}
done
if printf '%s\n' "$upgrade_defaults" |
	grep -Eq 'uci[[:space:]]+-q[[:space:]]+(set|delete|commit)'; then
	printf 'uci-defaults mutates UCI during the baseline upgrade\n' >&2
	exit 1
fi

# Reload the module after runtime restoration without replacing shared rpcd.
rpcd_reload='[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || exit 1'
[ "$(printf '%s\n' "$postinst" | grep -Fc "$rpcd_reload")" = 1 ]
[ "$(printf '%s\n' "$postinst" | tail -n 2)" = "$(printf '%s\nexit 0' "$rpcd_reload")" ]
if printf '%s\n' "$postinst" | grep -Fq '/etc/init.d/rpcd restart' ||
   grep -Fq '/etc/init.d/rpcd restart' "$init_file"; then exit 1; fi
printf '%s\n' "$postinst" | grep -Fq '[ -z "$$IPKG_INSTROOT" ] || exit 0'

# A failed upgrade or clean-install preflight must not restore the first-ever
# official config or revert someone else's CLI delta. Exercise real cleanup,
# snapshot validation and UCI against paths confined to this temporary tree.
real_uci="$(command -v uci || true)"
uci_root="${ADGUARDHOME_TEST_UCI_ROOT:-}"
if [ -n "$real_uci" ] || [ -n "$uci_root" ]; then
	rollback_dir="$(mktemp -d /tmp/luci-agh-defaults-rollback.XXXXXX)"
	trap 'rm -rf "$rollback_dir"' EXIT HUP INT TERM
	mkdir "$rollback_dir/config" "$rollback_dir/delta" "$rollback_dir/snapshot"
	chmod 0700 "$rollback_dir/snapshot"
	uci() {
		if [ -n "$uci_root" ]; then
			"$uci_root/lib/ld-musl-x86_64.so.1" --library-path "$uci_root/lib:$uci_root/usr/lib" \
				"$uci_root/sbin/uci" -c "$rollback_dir/config" -t "$rollback_dir/delta" "$@"
		else
			"$real_uci" -c "$rollback_dir/config" -t "$rollback_dir/delta" "$@"
		fi
	}
	awk -v helper_dir="$package_dir/scripts" -f "$package_dir/scripts/expand-helpers.awk" \
		"$defaults" >"$rollback_dir/defaults.expanded"
	for name in entry_metadata root_private_directory root_private_file run_bounded \
		bounded_private_file validate_original_snapshot cleanup_snapshot_stage cleanup_install; do
		eval "$(function_body "$rollback_dir/defaults.expanded" "$name")"
	done
	eval "$(function_body "$rollback_dir/defaults.expanded" restore_original_config |
		sed "s|/etc/config/|$rollback_dir/config/|g")"
	UCI_CONFIG=adguardhome
	MAX_FILE_SIZE=524288
	SNAPSHOT_DIR="$rollback_dir/snapshot"
	SNAPSHOT_CONFIG="$SNAPSHOT_DIR/official-adguardhome.config"
	SNAPSHOT_STATE="$SNAPSHOT_DIR/official-adguardhome.state"
	SNAPSHOT_VERSION="$SNAPSHOT_DIR/snapshot-version"
	SNAPSHOT_STAGE=""
	printf "config adguardhome 'config'\n option enabled '0'\n option work_dir '/var/lib/adguardhome'\n" | uci import adguardhome
	uci commit adguardhome
	cp "$rollback_dir/config/adguardhome" "$SNAPSHOT_CONFIG"
	printf 'was_running=0\n' >"$SNAPSHOT_STATE"
	printf '1\n' >"$SNAPSHOT_VERSION"
	chmod 0600 "$SNAPSHOT_CONFIG" "$SNAPSHOT_STATE" "$SNAPSHOT_VERSION"
	validate_original_snapshot
	for install_state in 0:0 1:0 1:1; do
		printf "config adguardhome 'config'\n option enabled '1'\n option work_dir '/etc/AdGuardHome'\nconfig luci 'luci'\n option redirect 'none'\n" | uci import adguardhome
		uci commit adguardhome
		uci set adguardhome.luci.redirect=dnsmasq-upstream
		before="$(cksum <"$rollback_dir/config/adguardhome")"
		delta_before="$(uci changes adguardhome)"
		INSTALL_STARTED="${install_state%:*}"
		INSTALL_COMMITTED="${install_state#*:}"
		YAML_STAGE="$rollback_dir/staged-yaml"
		printf 'temporary\n' >"$YAML_STAGE"
		rc=0
		(trap cleanup_install EXIT; exit 1) || rc=$?
		[ "$rc" = 1 ] && [ ! -e "$YAML_STAGE" ]
		if [ "$install_state" = 1:0 ]; then
			cmp -s "$SNAPSHOT_CONFIG" "$rollback_dir/config/adguardhome"
			[ -z "$(uci changes adguardhome)" ]
		else
			[ "$(cksum <"$rollback_dir/config/adguardhome")" = "$before" ]
			[ "$(uci changes adguardhome)" = "$delta_before" ]
		fi
		uci revert adguardhome
	done
	# The marker must be absent from the upgrade branch and set before the
	# first clean-install mutation (stopping the official service).
	! printf '%s\n' "$upgrade_defaults" | grep -Fq 'INSTALL_STARTED=1'
	[ "$(grep -Fc 'INSTALL_STARTED=1' "$defaults")" = 1 ]
	[ "$(grep -n '^INSTALL_STARTED=1' "$defaults" | cut -d: -f1)" -lt \
	  "$(grep -n '^run_bounded 20 2 /etc/init.d/adguardhome stop' "$defaults" | cut -d: -f1)" ]

	# New installations no longer create the unused .uci export. Old r9
	# installations still remove that optional file only after private-file checks.
	removal_body="$(printf '%s\n' "$postrm" | awk '
		/^for snapshot_file in/ { copying = 1 }
		copying { gsub(/\$\$/, "$"); print }
		copying && /^rmdir / { exit }
	')"
	for old_export in absent present unsafe; do
		snapshot_dir="$rollback_dir/remove-$old_export"
		mkdir -m 0700 "$snapshot_dir"
		for file in official-adguardhome.config official-adguardhome.state snapshot-version managed-adguardhome.config; do
			printf 'preserved\n' >"$snapshot_dir/$file"
			chmod 0600 "$snapshot_dir/$file"
		done
		case "$old_export" in
			present) printf 'package adguardhome\n' >"$snapshot_dir/official-adguardhome.uci";
				chmod 0600 "$snapshot_dir/official-adguardhome.uci" ;;
			unsafe) ln -s /dev/null "$snapshot_dir/official-adguardhome.uci" ;;
		esac
		if [ "$old_export" = unsafe ]; then
			if (eval "$removal_body"); then exit 1; fi
			[ -f "$snapshot_dir/official-adguardhome.config" ]
		else
			(eval "$removal_body")
			[ ! -e "$snapshot_dir" ]
		fi
	done
	printf 'ok - defaults rollback is mutation-scoped; optional legacy export cleanup is safe\n'
else
	printf 'skip - defaults rollback requires real UCI or ADGUARDHOME_TEST_UCI_ROOT\n'
fi

printf 'ok - supported baseline to 2.6.0-r2 lifecycle and final rpcd reload\n'
