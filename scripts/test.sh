#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)
PACKAGE_DIR=$REPO/luci-app-adguardhome
SDK=${SDK:-/root/sdk-x86-64}
TARGET_ROOT=$SDK/staging_dir/target-x86_64_musl/root-x86
UCODE_BIN=${UCODE_BIN:-$TARGET_ROOT/usr/bin/ucode}
UCODE_LOADER=${UCODE_LOADER:-$TARGET_ROOT/lib/ld-musl-x86_64.so.1}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

for command_name in busybox git mktemp; do
	command -v "$command_name" >/dev/null 2>&1 ||
		die "required command is unavailable: $command_name"
done
[[ -x $UCODE_BIN && -x $UCODE_LOADER ]] || die "SDK target ucode runtime is missing: $SDK"

if [[ -n ${NODE_BIN:-} ]]; then
	[[ -x $NODE_BIN ]] || die "NODE_BIN is not executable: $NODE_BIN"
elif command -v node >/dev/null 2>&1; then
	NODE_BIN=$(command -v node)
elif command -v node.exe >/dev/null 2>&1; then
	NODE_BIN=$(command -v node.exe)
else
	die 'Node.js is unavailable; set NODE_BIN'
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

ucode_library_path=$TARGET_ROOT/lib:$TARGET_ROOT/usr/lib
"$UCODE_LOADER" --library-path "$ucode_library_path" \
	"$UCODE_BIN" -L "$TARGET_ROOT/usr/lib/ucode" -S -c \
	-o "$temporary/luci.adguardhome.uc" \
	"$PACKAGE_DIR/root/usr/share/rpcd/ucode/luci.adguardhome"

export UCODE=$UCODE_BIN
export UCODE_LOADER
export UCODE_LIBRARY_PATH=$ucode_library_path
export ADGUARDHOME_TEST_UCI_ROOT=$TARGET_ROOT

shopt -s nullglob
shell_tests=("$PACKAGE_DIR"/tests/*.test.sh)
js_tests=("$PACKAGE_DIR"/tests/*.test.js)
((${#shell_tests[@]} > 0 && ${#js_tests[@]} > 0)) || die 'source tests are missing'

for test_file in "${shell_tests[@]}"; do
	printf 'TEST %s\n' "${test_file#"$REPO/"}"
	busybox ash "$test_file"
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

printf 'TEST_OK shell=%d javascript=%d\n' "${#shell_tests[@]}" "${#js_tests[@]}"
