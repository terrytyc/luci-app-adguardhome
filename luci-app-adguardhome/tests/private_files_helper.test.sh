#!/bin/sh
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="$script_dir/.."
helper_dir="$package_dir/scripts"
makefile="$package_dir/Makefile"
defaults="$package_dir/root/etc/uci-defaults/40_luci-AdGuardHome"
init_file="$package_dir/root/etc/init.d/AdGuardHome"
temporary="$(mktemp -d /tmp/luci-agh-private-helper.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

# Make expands the same canonical source used by all four package hooks.
printf 'include %s/private-files.mk\n$(info $(AdGuardHome/PrivateFiles))\nall:; @:\n' \
	"$helper_dir" >"$temporary/helper.make"
make --no-print-directory -s -f "$temporary/helper.make" >"$temporary/helper.sh"
busybox ash -n "$temporary/helper.sh"
awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$defaults" >"$temporary/defaults.sh"
busybox ash -n "$temporary/defaults.sh"
awk '
	/^entry_metadata\(\) \{/ { copying=1 }
	copying { print }
	/^root_private_file\(\) \{/ { last=1 }
	copying && last && /^}/ { exit }
' "$temporary/defaults.sh" >"$temporary/defaults.helper"
cmp "$temporary/helper.sh" "$temporary/defaults.helper"
awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$init_file" >"$temporary/init.sh"
busybox ash -n "$temporary/init.sh"
. "$script_dir/lib/function-body.sh"
for name in entry_metadata root_private_directory root_private_file; do
	function_body "$temporary/init.sh" "$name"
	printf '\n'
done >"$temporary/init.helper"
# Ignore separator blanks added by the function extractor.
sed '/^$/d' "$temporary/helper.sh" >"$temporary/helper.compact"
sed '/^$/d' "$temporary/init.helper" >"$temporary/init.compact"
cmp "$temporary/helper.compact" "$temporary/init.compact"
[ "$(grep -Fc '$(AdGuardHome/PrivateFiles)' "$makefile")" = 4 ]
! grep -Eq '^entry_metadata\(\)|^root_private_(directory|file)\(\)' "$makefile" "$defaults"
! grep -Fq '# @include ' "$temporary/defaults.sh"

# Missing, unknown or duplicated source markers must fail the build.
for marker in '# @include missing' '# @include private-files'; do
	printf '%s\n' "$marker" >"$temporary/invalid"
	if awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
		"$temporary/invalid" >"$temporary/invalid.out"; then
		printf 'invalid helper input unexpectedly expanded\n' >&2
		exit 1
	fi
done
printf '# @include run-bounded\n# @include run-bounded\n' >"$temporary/invalid"
if awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" \
	"$temporary/invalid" >"$temporary/invalid.out"; then
	printf 'duplicate helper marker unexpectedly expanded\n' >&2
	exit 1
fi

# Verify the preserved metadata policy without changing any system file.
# shellcheck disable=SC1090
. "$temporary/helper.sh"
mkdir -m 0700 "$temporary/private"
: >"$temporary/private/file"
chmod 0600 "$temporary/private/file"
if [ "$(id -u)" = 0 ] && [ "$(id -g)" = 0 ]; then
	root_private_directory "$temporary/private"
	root_private_file "$temporary/private/file"
fi
ln -s "$temporary/private/file" "$temporary/link"
! root_private_file "$temporary/link"
ln "$temporary/private/file" "$temporary/hardlink"
! root_private_file "$temporary/private/file"
chmod 0755 "$temporary/private"
! root_private_directory "$temporary/private"
! root_private_file "$temporary/missing"

# Runtime wrappers reuse the same policy but retain their path/size limits.
log_error() { :; }
for name in path_contains_symlink normalizer_lock_directory_is_private \
	normalizer_lock_is_private yaml_job_runtime_is_private \
	yaml_job_file_is_private yaml_job_lock_file_is_private; do
	eval "$(function_body "$temporary/init.sh" "$name")"
done
if [ "$(id -u):$(id -g)" = 0:0 ]; then
	YAML_JOB_RUNTIME_DIR="$temporary/jobs"
	mkdir -m 0700 "$YAML_JOB_RUNTIME_DIR"
	NORMALIZER_LOCK="$YAML_JOB_RUNTIME_DIR/normalizer.lock"
	mkdir -m 0700 "$NORMALIZER_LOCK"
	normalizer_lock_directory_is_private
	normalizer_lock_is_private
	yaml_job_runtime_is_private
	: >"$YAML_JOB_RUNTIME_DIR/update.lock"
	chmod 0600 "$YAML_JOB_RUNTIME_DIR/update.lock"
	yaml_job_lock_file_is_private
	! yaml_job_file_is_private "$YAML_JOB_RUNTIME_DIR/update.lock"
	printf 'pending\n' >"$YAML_JOB_RUNTIME_DIR/update.lock"
	! yaml_job_lock_file_is_private
	yaml_job_file_is_private "$YAML_JOB_RUNTIME_DIR/update.lock"
	ln -s "$YAML_JOB_RUNTIME_DIR" "$temporary/jobs-link"
	NORMALIZER_LOCK="$temporary/jobs-link/normalizer.lock"
	! normalizer_lock_is_private
fi
printf 'ok - single-source private-file checks and helper expansion\n'
