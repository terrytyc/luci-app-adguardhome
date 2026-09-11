#!/bin/sh

if ! (eval 'exec 189<&0 && exec 189<&-') 2>/dev/null; then
	exec busybox ash "$0" "$@"
fi
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
for name in memory_backing_identity run_locked open_integration_lock_descriptor; do
	eval "$(function_body "$init_file" "$name")"
done

# Keep the real high-FD boundary and test one actual procfs lookup before
# substituting deterministic fdinfo/mountinfo content for parser rejection tests.
tree="${test_tmp}/tree"
command mkdir "$tree"
memory_backing_identity "$tree"
[ "$MEMORY_IDENTITY_DEVICE $MEMORY_IDENTITY_INODE" = "$(stat -Lc '%d %i' "$tree")" ]
exec 188<"$tree"
memory_backing_identity /proc/self/fd/188
[ "$MEMORY_IDENTITY_DEVICE $MEMORY_IDENTITY_INODE" = "$(stat -Lc '%d %i' "$tree")" ]
exec 188<&-
exec 189<"$tree"
if memory_backing_identity "$tree"; then
	printf 'identity reader clobbered an inherited descriptor\n' >&2
	exit 1
fi
exec 189<&-
ln -s "$tree" "${test_tmp}/symlink"
if memory_backing_identity "${test_tmp}/symlink"; then
	printf 'identity reader accepted a symlink\n' >&2
	exit 1
fi
printf 'not a directory\n' >"${test_tmp}/file"
if memory_backing_identity "${test_tmp}/file"; then
	printf 'identity reader accepted a regular file\n' >&2
	exit 1
fi

fd_fixture="${test_tmp}/fdinfo"
mount_fixture="${test_tmp}/mountinfo"
calls="${test_tmp}/calls"
: >"$calls"
awk() {
	if [ "$#" = 3 ] && [ "$2" = /proc/self/fdinfo/189 ] &&
	   [ "$3" = /proc/self/mountinfo ]; then
		printf 'awk\n' >>"$calls"
		command awk "$1" "$fd_fixture" "$mount_fixture"
	else
		command awk "$@"
	fi
}
valid_fixtures() {
	printf 'pos:\t0\nflags:\t0100000\nmnt_id:\t42\nino:\t456\n' >"$fd_fixture"
	printf '42 1 8:1 / /fixture rw - ext4 /dev/fixture rw\n' >"$mount_fixture"
}
expect_identity() {
	local expected="$1" before
	before="$(wc -l <"$calls")"
	memory_backing_identity "$tree"
	[ "$MEMORY_IDENTITY_DEVICE:$MEMORY_IDENTITY_INODE" = "$expected" ]
	[ "$(wc -l <"$calls")" -eq "$((before + 1))" ]
}
reject_identity() {
	local reason="$1" before
	before="$(wc -l <"$calls")"
	if memory_backing_identity "$tree"; then
		printf 'invalid identity fixture accepted: %s\n' "$reason" >&2
		exit 1
	fi
	[ "$(wc -l <"$calls")" -eq "$((before + 1))" ]
}
valid_fixtures
expect_identity 2049:456
printf '42 1 4096:256 / /fixture rw - ext4 /dev/fixture rw\n' >"$mount_fixture"
expect_identity 17592187092992:456

for record in \
	'mnt_id: 42\nino: 456\nmnt_id: 42\n' \
	'mnt_id: 42\nino: 456\nino: 456\n' \
	'mnt_id: 42\n' \
	'ino: 456\n' \
	'mnt_id: invalid\nino: 456\n' \
	'mnt_id: 42\nino: invalid\n' \
	''; do
	valid_fixtures
	printf '%b' "$record" >"$fd_fixture"
	reject_identity fdinfo
done
valid_fixtures
printf '43 1 8:1 / /fixture rw - ext4 /dev/fixture rw\n' >"$mount_fixture"
reject_identity missing-mount
valid_fixtures
printf '42 1 8:1 / /duplicate rw - ext4 /dev/fixture rw\n' >>"$mount_fixture"
reject_identity duplicate-mount
for device in 8 invalid 8:invalid invalid:1 8::1 :1 8:; do
	valid_fixtures
	printf '42 1 %s / /fixture rw - ext4 /dev/fixture rw\n' "$device" >"$mount_fixture"
	reject_identity malformed-device
done
valid_fixtures
: >"$mount_fixture"
reject_identity empty-mountinfo

# Existing lock directories use no mkdir process.  Missing directories still
# get created, while creation/open failures must prevent the protected action.
: >"$calls"
command mkdir "${test_tmp}/existing-lock"
mkdir() {
	printf 'mkdir\n' >>"$calls"
	command mkdir "$@"
}
locked_action() { printf 'action\n' >>"$calls"; }
INTEGRATION_LOCK="${test_tmp}/existing-lock/integration.lock"
run_locked locked_action
[ "$(cat "$calls")" = action ]
INTEGRATION_LOCK="${test_tmp}/new-lock/integration.lock"
run_locked locked_action
run_locked locked_action
[ "$(grep -c '^mkdir$' "$calls")" = 1 ]
[ "$(grep -c '^action$' "$calls")" = 3 ]
INTEGRATION_LOCK="${test_tmp}/file/integration.lock"
if run_locked locked_action >/dev/null 2>&1; then
	printf 'failed lock-directory creation still ran the action\n' >&2
	exit 1
fi
[ "$(grep -c '^action$' "$calls")" = 3 ]
command mkdir "${test_tmp}/lock-is-directory"
INTEGRATION_LOCK="${test_tmp}/lock-is-directory"
if run_locked locked_action >/dev/null 2>&1; then
	printf 'failed lock descriptor open still ran the action\n' >&2
	exit 1
fi
[ "$(grep -c '^action$' "$calls")" = 3 ]

# Exercise the FD prefilter against real procfs metadata, including regular
# files, pipes, O_PATH socket nodes and a sibling's foreign listener.
socket_check="${test_tmp}/socket-check"
for name in official_socket_snapshot official_owns_socket pid_is_supervised_descendant \
	official_owns_ipv4_reachable_socket official_memory_data_mount_visible dns_port_listening; do
	function_body "$init_file" "$name" >>"$socket_check"
done
cat >>"$socket_check" <<'SH'
set -eu
own_pid="$1" foreign_pid="$2" own_port="$3" foreign_port="$4" calls="$5"
path_inode="$6"
CORE_BINARY="$(readlink "/proc/${own_pid}/exe")"
MEMORY_ACTIVE=0 redirect_mode=dnsmasq-upstream
official_pid() { printf '%s\n' "$own_pid"; }
pidof() { printf '%s %s\n' "$own_pid" "$foreign_pid"; }
readlink() { printf 'readlink\n' >>"$calls"; busybox readlink "$@"; }
: >"$calls"
official_socket_snapshot
[ "$OFFICIAL_SOCKET_PIDS" = " $own_pid" ]
set -- "/proc/${own_pid}/fd/"*
fd_count="$#"
socket_count=0
for fd do
	link="$(command readlink "$fd")"
	case "$link" in
		socket:\[*\])
			inode="${link#socket:\[}" inode="${inode%\]}"
			case "$OFFICIAL_SOCKET_INODES" in *" ${inode} "*) ;; *) exit 1 ;; esac
			socket_count=$((socket_count + 1))
			;;
	esac
done
set -- $OFFICIAL_SOCKET_INODES
[ "$#" = "$socket_count" ] && [ "$socket_count" -ge 2 ]
[ "$fd_count" -gt "$socket_count" ]
case "$OFFICIAL_SOCKET_INODES" in *" ${path_inode} "*) exit 1 ;; esac
# One executable lookup, the actual sockets, and one O_PATH node which -S
# admits but the retained socket:[inode] parser must discard.
reader_count=$((socket_count + 2))
[ "$(grep -cx readlink "$calls")" = "$reader_count" ]
dns_port="$own_port"
dns_port_listening
dns_port="$foreign_port"
if dns_port_listening; then
	printf 'foreign listener or forged regular-file target accepted\n' >&2
	exit 1
fi
[ "$(grep -cx readlink "$calls")" = "$((reader_count * 3))" ]
printf 'ok - real mixed FD scan: %s readers reduced to %s, O_PATH and foreign listener rejected\n' \
	"$fd_count" "$((reader_count - 1))"
SH
python3 - "$test_tmp" "$socket_check" <<'PY'
import json, os, subprocess, sys

directory, check = sys.argv[1:]
child = r'''
import json, os, socket, sys
tcp = socket.socket()
tcp.bind(("127.0.0.1", 0))
tcp.listen()
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(tcp.getsockname())
files = [open(sys.argv[1], "a") for _ in range(32)]
pipes = [os.pipe() for _ in range(8)]
pair = socket.socketpair()
node = socket.socket(socket.AF_UNIX)
node.bind(sys.argv[1] + ".socket")
node.close()
path_fd = os.open(sys.argv[1] + ".socket", os.O_PATH)
print(json.dumps([os.getpid(), tcp.getsockname()[1], os.fstat(tcp.fileno()).st_ino,
                  os.fstat(path_fd).st_ino]), flush=True)
sys.stdin.read()
'''
processes = []
try:
    def start(path):
        process = subprocess.Popen([sys.executable, "-c", child, path],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        processes.append(process)
        return json.loads(process.stdout.readline())
    foreign = start(os.path.join(directory, "foreign-file"))
    forged_name = "regular\n%d srwxrwxrwx 1 0 0 0 Jan 1 00:00 99\n" % foreign[2]
    own = start(os.path.join(directory, forged_name))
    subprocess.run(["busybox", "ash", check, str(own[0]), str(foreign[0]),
                    str(own[1]), str(foreign[1]), os.path.join(directory, "socket-calls"),
                    str(own[3])], check=True)
finally:
    for process in processes:
        process.communicate(timeout=5)
PY

printf 'ok - one-pass mount identity parsing, FD prefilter and existing lock-directory fast path\n'
