#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)
PACKAGE_DIR=$REPO/luci-app-adguardhome
SDK=${SDK:-/root/sdk-x86-64}
TARGET_ROOT=${TARGET_ROOT:-$SDK/staging_dir/target-x86_64_musl/root-x86}
UCODE_BIN=${UCODE_BIN:-$TARGET_ROOT/usr/bin/ucode}
UCODE_LOADER=${UCODE_LOADER:-$TARGET_ROOT/lib/ld-musl-x86_64.so.1}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

mode=full
case "$#" in
	0) ;;
	1)
		case "$1" in
			--light) mode=light ;;
			--full) ;;
			*) die "unknown option: $1" ;;
		esac
		;;
	*) die 'usage: scripts/test.sh [--light|--full]' ;;
esac

for command_name in busybox git mktemp; do
	command -v "$command_name" >/dev/null 2>&1 ||
		die "required command is unavailable: $command_name"
done

if [[ -n ${NODE_BIN:-} ]]; then
	[[ -x $NODE_BIN ]] || die "NODE_BIN is not executable: $NODE_BIN"
elif command -v node >/dev/null 2>&1 &&
	node -e "require('node:assert/strict')" >/dev/null 2>&1; then
	NODE_BIN=$(command -v node)
elif command -v node.exe >/dev/null 2>&1 &&
	node.exe -e "require('node:assert/strict')" >/dev/null 2>&1; then
	NODE_BIN=$(command -v node.exe)
else
	die 'Node.js 16 or newer is unavailable; set NODE_BIN'
fi
"$NODE_BIN" -e "require('node:assert/strict')" >/dev/null 2>&1 ||
	die 'Node.js is too old for the JavaScript tests; set NODE_BIN to Node.js 16 or newer'

temporary=$(mktemp -d /tmp/luci-app-adguardhome-tests.XXXXXX)
cleanup() {
	local rc=$?
	trap - EXIT INT TERM
	case "$temporary" in
		/tmp/luci-app-adguardhome-tests.*) rm -rf -- "$temporary" ;;
	esac
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $mode == full ]]; then
	[[ -x $UCODE_BIN && -x $UCODE_LOADER ]] ||
		die "target ucode runtime is missing: $TARGET_ROOT"
	[[ -x $TARGET_ROOT/sbin/uci ]] || die "target UCI is missing: $TARGET_ROOT"
	export APK_BIN=${APK_BIN:-$SDK/staging_dir/host/bin/apk}
	export STATIC_BUSYBOX=${STATIC_BUSYBOX:-$(command -v busybox)}
	[[ -x $APK_BIN ]] || die "APK v3 test tool is missing: $APK_BIN"
	ucode_library_path=$TARGET_ROOT/lib:$TARGET_ROOT/usr/lib
	"$UCODE_LOADER" --library-path "$ucode_library_path" \
		"$UCODE_BIN" -L "$TARGET_ROOT/usr/lib/ucode" -S -c \
		-o "$temporary/luci.adguardhome.uc" \
		"$PACKAGE_DIR/root/usr/share/rpcd/ucode/luci.adguardhome"

	export UCODE=$UCODE_BIN
	export UCODE_LOADER
	export UCODE_LIBRARY_PATH=$ucode_library_path
	export ADGUARDHOME_TEST_UCI_ROOT=$TARGET_ROOT
fi

shopt -s nullglob
shell_tests=("$PACKAGE_DIR"/tests/*.test.sh)
js_tests=("$PACKAGE_DIR"/tests/*.test.js)
((${#shell_tests[@]} > 0 && ${#js_tests[@]} > 0)) || die 'source tests are missing'

shell_count=0
for test_file in "${shell_tests[@]}"; do
	if [[ $mode == light && $test_file == */password_yaml_parser.test.sh ]]; then
		printf 'SKIP %s (requires SDK ucode)\n' "${test_file#"$REPO/"}"
		continue
	fi
	printf 'TEST %s\n' "${test_file#"$REPO/"}"
	busybox ash "$test_file"
	((shell_count += 1))
done

for test_file in "${js_tests[@]}"; do
	printf 'TEST %s\n' "${test_file#"$REPO/"}"
	if [[ $NODE_BIN == *.exe ]]; then
		"$NODE_BIN" "$(wslpath -w "$test_file")"
	else
		"$NODE_BIN" "$test_file"
	fi
done

for test_file in "$SCRIPT_DIR"/tests/*.test.sh; do
	printf 'TEST %s\n' "${test_file#"$REPO/"}"
	bash "$test_file"
done

if [[ $mode == light ]]; then
	printf 'LIGHT_TEST_OK shell=%d javascript=%d skipped=%d\n' \
		"$shell_count" "${#js_tests[@]}" "$((${#shell_tests[@]} - shell_count))"
else
	printf 'TEST scripts/tests/apk-hook.integration.sh\n'
	bash "$SCRIPT_DIR/tests/apk-hook.integration.sh"
	printf 'TEST_OK shell=%d javascript=%d apk_integration=1\n' \
		"${#shell_tests[@]}" "${#js_tests[@]}"
fi
