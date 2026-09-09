#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
helper_dir="$package_dir/scripts"
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
temporary="$(mktemp -d /tmp/luci-agh-snapshot-helper.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

printf 'include %s/private-files.mk\ninclude %s/original-snapshot.mk\n$(info $(AdGuardHome/PrivateFiles))\n$(info $(AdGuardHome/OriginalSnapshot))\nall:; @:\n' \
	"$helper_dir" "$helper_dir" >"$temporary/helper.make"
make --no-print-directory -s -f "$temporary/helper.make" >"$temporary/helper.sh"
busybox ash -n "$temporary/helper.sh"

awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$defaults" >"$temporary/defaults.sh"
busybox ash -n "$temporary/defaults.sh"
for name in official_delta_is_clean validate_original_snapshot \
	cleanup_snapshot_stage create_original_snapshot ensure_original_snapshot; do
	[ "$(grep -Fc "$name() {" "$temporary/helper.sh")" = 1 ]
	[ "$(grep -Fc "$name() {" "$temporary/defaults.sh")" = 1 ]
done

[ "$(grep -Fc '$(AdGuardHome/OriginalSnapshot)' "$makefile")" = 1 ]
grep -Fq 'include $(ADGUARDHOME_SOURCE_DIR)scripts/original-snapshot.mk' "$makefile"
! grep -Eq '^official_delta_is_clean\(\)|^validate_original_snapshot\(\)|^cleanup_snapshot_stage\(\)|^create_original_snapshot\(\)|^ensure_original_snapshot\(\)' \
	"$makefile" "$defaults"
! grep -Fq '# @include original-snapshot' "$temporary/defaults.sh"

# Exercise validation and failure cleanup when the host can create root-owned files.
# shellcheck disable=SC1090
. "$temporary/helper.sh"
if [ "$(id -u):$(id -g)" = 0:0 ]; then
	SNAPSHOT_DIR="$temporary/snapshot"
	SNAPSHOT_CONFIG="$SNAPSHOT_DIR/official-adguardhome.config"
	SNAPSHOT_STATE="$SNAPSHOT_DIR/official-adguardhome.state"
	SNAPSHOT_VERSION="$SNAPSHOT_DIR/snapshot-version"
	mkdir -m 0700 "$SNAPSHOT_DIR"
	printf 'config\n' >"$SNAPSHOT_CONFIG"
	printf 'was_running=1\n' >"$SNAPSHOT_STATE"
	printf '1\n' >"$SNAPSHOT_VERSION"
	chmod 0600 "$SNAPSHOT_CONFIG" "$SNAPSHOT_STATE" "$SNAPSHOT_VERSION"
	validate_original_snapshot
	printf 'extra\n' >>"$SNAPSHOT_STATE"
	! validate_original_snapshot

	SNAPSHOT_STAGE="$temporary/stage"
	mkdir "$SNAPSHOT_STAGE"
	: >"$SNAPSHOT_STAGE/official-adguardhome.config"
	: >"$SNAPSHOT_STAGE/official-adguardhome.state"
	: >"$SNAPSHOT_STAGE/snapshot-version"
	cleanup_snapshot_stage
	[ -z "$SNAPSHOT_STAGE" ] && [ ! -e "$temporary/stage" ]

	events="$temporary/ensure-events"
	validate_original_snapshot() { printf 'validate\n' >>"$events"; }
	create_original_snapshot() { printf 'create\n' >>"$events"; }
	ensure_original_snapshot
	rm -rf "$SNAPSHOT_DIR"
	ensure_original_snapshot
	[ "$(cat "$events")" = "$(printf 'validate\ncreate')" ]
fi

printf 'ok - single-source original snapshot lifecycle\n'
