#!/bin/sh

# The shipped helper deliberately uses a high descriptor supported by the
# target BusyBox ash.  Re-enter that shell when a developer's /bin/sh is dash.
if ! (eval 'exec 187<&0 && exec 187<&-') 2>/dev/null; then
	if command -v busybox >/dev/null 2>&1; then
		exec busybox ash "$0" "$@"
	fi
	printf 'BusyBox ash is required for this target-specific test\n' >&2
	exit 1
fi

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
init_file="${package_dir}/root/etc/init.d/AdGuardHome"
defaults_file="${package_dir}/root/etc/uci-defaults/40_luci-AdGuardHome"
makefile="${package_dir}/Makefile"
helper_source="${package_dir}/scripts/run-bounded.mk"
expander="${package_dir}/scripts/expand-helpers.awk"

for required_file in "$init_file" "$defaults_file" "$makefile" "$helper_source" "$expander"; do
	[ -f "$required_file" ] || {
		printf 'required product file not found: %s\n' "$required_file" >&2
		exit 1
	}
done

# Marker assertions inspect a shared /tmp namespace, so serialize concurrent
# copies of this test without changing the production helper's fixed paths.
command -v flock >/dev/null 2>&1 || {
	printf 'flock is required to serialize the bounded-runner test\n' >&2
	exit 1
}
exec 9>"${TMPDIR:-/tmp}/luci-app-adguardhome-bounded-test.lock"
flock -x 9

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"

temp_dir="$(mktemp -d /tmp/luci-app-adguardhome-bounded-test.XXXXXX)"
cleanup() {
	rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT QUIT TERM

awk -v helper_dir="${package_dir}/scripts" -f "$expander" "$init_file" >"${temp_dir}/init.expanded"
awk -v helper_dir="${package_dir}/scripts" -f "$expander" "$defaults_file" >"${temp_dir}/defaults.expanded"
function_body "${temp_dir}/init.expanded" run_bounded >"${temp_dir}/init.helper"
function_body "${temp_dir}/defaults.expanded" run_bounded >"${temp_dir}/defaults.helper"
for expanded in "${temp_dir}/init.expanded" "${temp_dir}/defaults.expanded"; do
	busybox ash -n "$expanded"
	if grep -Fq '# @include run-bounded' "$expanded"; then
		printf 'shared helper was not expanded\n' >&2
		exit 1
	fi
done
[ "$(grep -Fc '$(AdGuardHome/RunBounded)' "$makefile")" = 2 ] || {
	printf 'preinst and prerm must embed the shared helper\n' >&2
	exit 1
}
grep -Fq 'include $(ADGUARDHOME_SOURCE_DIR)scripts/run-bounded.mk' "$makefile"
grep -Fq 'touch -r $(PKG_BUILD_DIR)/root/$$$$file $(PKG_BUILD_DIR)/root/$$$$file.expanded' "$makefile"

[ -s "${temp_dir}/init.helper" ] || {
	printf 'run_bounded was not found in the init script\n' >&2
	exit 1
}
cmp -s "${temp_dir}/init.helper" "${temp_dir}/defaults.helper" || {
	printf 'init and uci-defaults run_bounded implementations differ\n' >&2
	exit 1
}
if grep -Fq '/usr/bin/timeout' "$init_file" "$defaults_file" "$makefile" "$helper_source" ||
	grep -Fq 'coreutils-timeout' "$makefile"; then
	printf 'external timeout implementation is still referenced by the package\n' >&2
	exit 1
fi

# Exercise the exact implementation shipped in all four product paths.
# shellcheck disable=SC1090
. "${temp_dir}/init.helper"

expect_rc() {
	expected="$1"
	shift
	set +e
	"$@"
	actual=$?
	set -e
	[ "$actual" -eq "$expected" ] || {
		printf 'expected exit %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
		exit 1
	}
}

session_is_gone() {
	pgid="$1"
	remaining=5
	while [ "$remaining" -gt 0 ]; do
		if ! ps -eo pgid= 2>/dev/null | awk -v wanted="$pgid" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }'; then
			return 0
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

find /tmp -maxdepth 1 -type f -name 'luci-app-adguardhome-bounded.*' -print 2>/dev/null |
	sort >"${temp_dir}/markers.before"

expect_rc 125 run_bounded invalid 1 /bin/true
expect_rc 125 run_bounded 1 invalid /bin/true
expect_rc 125 run_bounded 1 1
expect_rc 7 run_bounded 30 1 /bin/sh -c 'exit 7'

printf 'alpha\nbeta\n' >"${temp_dir}/stdin.expected"
run_bounded 30 1 /bin/dd of="${temp_dir}/stdin.actual" \
	<"${temp_dir}/stdin.expected" 2>/dev/null
cmp -s "${temp_dir}/stdin.expected" "${temp_dir}/stdin.actual" || {
	printf 'run_bounded did not preserve pipeline input\n' >&2
	exit 1
}

# The inherited job/staging descriptor may legitimately be 187. Keep it and
# every occupied neighbor intact while capturing actual pipeline input.
(
	exec 187<"${temp_dir}/stdin.expected"
	for inherited_fd in 188 189 190 191 192 193 194 195 196 197 198 199; do
		eval "exec ${inherited_fd}</dev/null"
	done
	printf 'alpha\nbeta\n' | run_bounded 30 1 /bin/dd of="${temp_dir}/stdin.occupied" 2>/dev/null
	[ /proc/self/fd/187 -ef "${temp_dir}/stdin.expected" ]
	for inherited_fd in 188 189 190 191 192 193 194 195 196 197 198 199; do
		[ /proc/self/fd/"$inherited_fd" -ef /dev/null ]
	done
	cmp -s "${temp_dir}/stdin.expected" "${temp_dir}/stdin.occupied"
)

# A successful short command must cancel both the watchdog and its long sleep.
run_bounded 913 1 /bin/true
# Exact argv matching also catches an orphaned sleep.
# shellcheck disable=SC2009
if ps -eo args= 2>/dev/null |
	grep -Eq '^[[:space:]]*(/[^[:space:]]*/)?sleep[[:space:]]+913[[:space:]]*$'; then
	printf 'successful run left its watchdog sleep running\n' >&2
	exit 1
fi

expect_rc 124 run_bounded 1 1 /bin/sleep 10

tree_dir="${temp_dir}/tree"
mkdir "$tree_dir"
set +e
# Dollars are intentionally expanded by the child shell.
# shellcheck disable=SC2016
run_bounded 1 1 /bin/sh -c '
	trap "" TERM
	printf "%s\n" "$$" >"$1/leader.pid"
	(
		trap "" TERM
		while :; do sleep 10; done
	) &
	while :; do sleep 10; done
' bounded-tree "$tree_dir"
tree_rc=$?
set -e
[ "$tree_rc" -eq 124 ] || {
	printf 'TERM-resistant process tree returned %s instead of 124\n' "$tree_rc" >&2
	exit 1
}
tree_pgid="$(cat "${tree_dir}/leader.pid")"
session_is_gone "$tree_pgid" || {
	printf 'timed-out process group %s is still running\n' "$tree_pgid" >&2
	exit 1
}

abort_dir="${temp_dir}/abort"
mkdir "$abort_dir"
# Dollars are intentionally expanded by the child shell.
# shellcheck disable=SC2016
run_bounded 30 1 /bin/sh -c '
	trap "" TERM
	printf "%s\n" "$$" >"$1/leader.pid"
	while :; do sleep 10; done
' bounded-abort "$abort_dir" &
runner_pid=$!
ready_wait=5
while [ ! -s "${abort_dir}/leader.pid" ] && [ "$ready_wait" -gt 0 ]; do
	sleep 1
	ready_wait=$((ready_wait - 1))
done
[ -s "${abort_dir}/leader.pid" ] || {
	/bin/kill -KILL "$runner_pid" 2>/dev/null || true
	printf 'interruption fixture did not start\n' >&2
	exit 1
}
abort_pgid="$(cat "${abort_dir}/leader.pid")"
helper_pid="$(awk '{ print $4 }' "/proc/${abort_pgid}/stat" 2>/dev/null || true)"
case "$helper_pid" in
	''|*[!0-9]*)
		/bin/kill -KILL "$runner_pid" 2>/dev/null || true
		printf 'unable to identify the bounded runner process\n' >&2
		exit 1
		;;
esac
/bin/kill -TERM "$helper_pid"
set +e
wait "$runner_pid"
abort_rc=$?
set -e
[ "$abort_rc" -eq 125 ] || {
	printf 'interrupted runner returned %s instead of 125\n' "$abort_rc" >&2
	exit 1
}
session_is_gone "$abort_pgid" || {
	printf 'interrupted process group %s is still running\n' "$abort_pgid" >&2
	exit 1
}

find /tmp -maxdepth 1 -type f -name 'luci-app-adguardhome-bounded.*' -print 2>/dev/null |
	sort >"${temp_dir}/markers.after"
cmp -s "${temp_dir}/markers.before" "${temp_dir}/markers.after" || {
	printf 'run_bounded left a marker in /tmp\n' >&2
	exit 1
}

printf 'ok - dependency-free bounded command runner\n'
