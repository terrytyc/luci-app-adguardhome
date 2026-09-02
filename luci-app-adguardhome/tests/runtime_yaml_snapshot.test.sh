#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

function_body() {
	awk -v name="$1" '
		$0 == name "() {" || $0 == name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' "$init_file"
}
for name in yaml_runtime_ports yaml_get_section_value load_runtime_dns_port \
	snapshot_config_file is_valid_port; do
	eval "$(function_body "$name")"
done

yaml="${test_tmp}/AdGuardHome.yaml"
calls="${test_tmp}/calls"
awk() { printf 'awk\n' >>"$calls"; command awk "$@"; }
# Frozen r5 (1c41900b) reader: compare complete success/rejection and effective
# DNS ports, not just the old awk helper.  In particular, HTTP comparison used
# ash numeric tests while DNS formatting used awk's number conversion.
legacy_load_runtime_dns_port() {
	local value address web_port directory snapshot
	if [ ! -f "$config_file" ] || [ -L "$config_file" ]; then
		log_error "Config file is unavailable while reading the DNS port: ${config_file}"
		return 1
	fi
	directory="$(mktemp -d /tmp/AdGuardHome-runtime.XXXXXX)" || return 1
	snapshot="${directory}/AdGuardHome.yaml"
	if ! snapshot_config_file "$config_file" "$snapshot" "" ""; then
		rm -rf "$directory"
		log_error "Unable to take a safe YAML snapshot: ${config_file}"
		return 1
	fi
	value="$(yaml_get_section_value dns port "$snapshot")"
	address="$(yaml_get_section_value http address "$snapshot")"
	rm -rf "$directory" || return 1
	is_valid_port "$value" || {
		log_error "Invalid or ambiguous dns.port in ${config_file}"
		return 1
	}
	dns_port="$(awk -v value="$value" 'BEGIN { printf "%d\n", value + 0 }')" || return 1
	if [ "$dns_port" -eq 53 ] 2>/dev/null && [ "$redirect_mode" != none ]; then
		log_error "DNS port 53 is only supported when DNS integration mode is none"
		return 1
	fi
	if [ -n "$address" ]; then
		case "$address" in
			*:*) web_port="${address##*:}" ;;
		esac
	fi
	if is_valid_port "$web_port" && [ "$dns_port" -eq "$web_port" ] 2>/dev/null; then
		log_error "The YAML DNS and HTTP ports must be different: ${dns_port}"
		return 1
	fi
}
reader_result() (
	# Production init has no nounset option; the frozen optional web_port is
	# intentionally untouched.  Safe capture is exercised separately below.
	set +u
	config_file="$yaml"
	redirect_mode="${2:-none}"
	dns_port=unset
	snapshot_config_file() { cp "$1" "$2"; }
	log_error() { :; }
	reader_rc=0
	"$1" || reader_rc=$?
	printf '%s:%s\n' "$reader_rc" "$dns_port"
)
ports_match() {
	local expected="$1" fixture="$2" actual legacy
	printf '%b' "$fixture" >"$yaml"
	: >"$calls"
	actual="$(yaml_runtime_ports "$yaml")"
	[ "$actual" = "$expected" ] || {
		printf 'ports mismatch: expected %s, got %s\n' "$expected" "$actual" >&2
		exit 1
	}
	[ "$(grep -c '^awk$' "$calls")" = 1 ]
	legacy="$(reader_result legacy_load_runtime_dns_port)"
	actual="$(reader_result load_runtime_dns_port)"
	[ "$actual" = "$legacy" ] || {
		printf 'runtime reader changed legacy result: %s != %s\n' "$actual" "$legacy" >&2
		exit 1
	}
}
ports_reject() {
	printf '%b' "$1" >"$yaml"
	if yaml_runtime_ports "$yaml"; then
		printf 'malformed/ambiguous DNS was accepted\n' >&2
		exit 1
	fi
	if [ "$(reader_result legacy_load_runtime_dns_port)" != "$(reader_result load_runtime_dns_port)" ]; then
		printf 'rejection fixture differs from the original reader\n' >&2
		exit 1
	fi
}
ports_match '53335 3000' 'http:\n  address: 0.0.0.0:3000\ndns:\n  port: 53335\n'
ports_match '22237 3000' 'dns: # managed\n    port: "053335" # DNS\nhttp:\n    address: "[::]:03000" # UI\n'
ports_match '43 3000' "dns:\n  port: '00053'\nhttp:\n  address: '[::1]:3000'\n"
ports_match '53335 3000' 'dns:\n    port: 1\n  port: 53335\nhttp:\n    address: 0.0.0.0:9\n  address: 0.0.0.0:3000\n'
ports_match '53335 0' 'dns:\n  port: 53335\n  nested:\n    port: 53\nhttp:\n  address: missing-port\n'
ports_match '53335 0' 'dns:\n  port: 53335\n'
ports_match '53335 0' 'dns:\n  port: 53335\nhttp:\n  address: 0.0.0.0:53335\n  address: 0.0.0.0:3000\n'
ports_match '53335 0' 'http:\n  address: 0.0.0.0:53335\ndns:\n  port: 53335\nhttp:\n  address: 0.0.0.0:3000\n'
ports_match '53335 3000' 'dns:\n # shallow comment\n    port: 53335\nhttp:\n # another comment\n    address: 0.0.0.0:3000\n'
for fixture in \
	'dns:\n  port: 0\n' \
	'dns:\n  port: 65536\n' \
	'dns:\n  port: 0100000\n' \
	'dns:\n  port: +53\n' \
	'dns:\n  port: nope\n' \
	'dns:\n  port: 53335\n  port: 53335\n' \
	'dns:\n  port: 53335\ndns:\n  port: 55353\n' \
	'dns:\n  nested:\n    port: 53335\n' \
	'dns:\n  \tnested:\n    port: 53335\n' \
	'dns:\n\tport: 53335\n' \
	'http:\n  address: 0.0.0.0:3000\n'; do
	ports_reject "$fixture"
done

full_reader_match() {
	local expected="$1" mode="$2"
	printf 'dns:\n  port: %s\nhttp:\n  address: 0.0.0.0:%s\n' "$3" "$4" >"$yaml"
	[ "$(reader_result legacy_load_runtime_dns_port "$mode")" = "$expected" ]
	[ "$(reader_result load_runtime_dns_port "$mode")" = "$expected" ]
}
full_reader_match 0:22237 none 053335 03000
full_reader_match 1:3000 none 3000 03000
full_reader_match 0:1536 none 1536 03000
full_reader_match 0:53335 none 53335 3000
full_reader_match 1:53335 none 53335 053335
full_reader_match 1:22237 none 053335 22237
full_reader_match 0:43 none 00053 3000
full_reader_match 0:43 redirect 00053 3000
full_reader_match 1:53 redirect 53 3000
full_reader_match 0:8 none 00008 3000

# The general selector remains available to editing/TLS code, including its
# unique-section/key and indentation rules.
printf 'dns:\n    port: 53335\nhttp:\n    address: "[::]:3000"\n' >"$yaml"
[ "$(yaml_get_section_value dns port "$yaml")" = 53335 ]
[ "$(yaml_get_section_value http address "$yaml")" = '[::]:3000' ]

# Exercise the actual snapshot's routing, size/identity limits and hash gate.
# Capture subprocesses are stubbed to avoid installing a uid-853 test account;
# their exact unprivileged argv and byte bound remain asserted.
MAX_YAML_SIZE=256
ADGUARD_UID=853
ADGUARD_GID=853
ROOT_PRIVATE=1
root_private_config_source() { [ "$ROOT_PRIVATE" = 1 ]; }
capture_root_file_bytes() {
	[ "$3" = 129 ] || return 1
	printf 'root-read\n' >>"$calls"
	command dd if="$1" of="$2" bs=4096 count=129 2>/dev/null
}
run_bounded() {
	[ "$1:$2" = 3:1 ] || return 1
	shift 2
	case "$1" in
		/sbin/start-stop-daemon)
			[ "$2:$3:$4:$5:$6:$7:$8:$9" = '-S:-c:853:853:-n:AGHSnapshot:-x:/bin/dd:--' ] || return 1
			shift 9
			[ "$*" = "if=$yaml bs=4096 count=129" ] || return 1
			printf 'uid-read\n' >>"$calls"
			command dd "$@" 2>/dev/null
			;;
		/bin/dd)
			printf 'fd-read\n' >>"$calls"
			"$@" 2>/dev/null
			;;
		*) return 1 ;;
	esac
}
yaml_file_hash() {
	printf 'hash\n' >>"$calls"
	sha256sum "$1" | cut -d ' ' -f 1
}
target="${test_tmp}/snapshot.yaml"
SNAPSHOT_CONFIG_HASH=stale
: >"$calls"
snapshot_config_file "$yaml" "$target" '' '' '' skip-hash
[ -z "$SNAPSHOT_CONFIG_HASH" ]
cmp -s "$yaml" "$target"
! grep -q '^hash$' "$calls"
snapshot_config_file "$yaml" "$target" '' '' ''
[ "$(grep -c '^hash$' "$calls")" = 1 ]
expected_hash="$SNAPSHOT_CONFIG_HASH"
snapshot_config_file "$yaml" "$target" "$expected_hash" '' '' skip-hash
[ "$(grep -c '^hash$' "$calls")" = 2 ]
if snapshot_config_file "$yaml" "$target" wrong '' '' skip-hash; then
	printf 'skip-hash bypassed an expected CAS digest\n' >&2
	exit 1
fi
ROOT_PRIVATE=0
snapshot_config_file "$yaml" "$target" '' '' '' skip-hash
grep -q '^uid-read$' "$calls"

exec 8<"$yaml"
snapshot_config_file "$yaml" "$target" '' 8 '' skip-hash
grep -q '^fd-read$' "$calls"
printf 'unrelated\n' >"${test_tmp}/other"
if snapshot_config_file "${test_tmp}/other" "$target" '' 8 '' skip-hash; then
	printf 'detached descriptor unexpectedly accepted\n' >&2
	exit 1
fi
exec 8<&-
ln -s "$yaml" "${test_tmp}/link"
if snapshot_config_file "${test_tmp}/link" "$target" '' '' '' skip-hash; then
	printf 'symlink candidate was accepted\n' >&2
	exit 1
fi
: >"$yaml"
if snapshot_config_file "$yaml" "$target" '' '' '' skip-hash; then
	printf 'empty YAML was accepted\n' >&2
	exit 1
fi
command dd if=/dev/zero of="$yaml" bs=257 count=1 2>/dev/null
if snapshot_config_file "$yaml" "$target" '' '' '' skip-hash; then
	printf 'oversized YAML was accepted\n' >&2
	exit 1
fi

# The complete monitor-reader path also detects port collisions and explicit
# port 53 integration restrictions without calculating a disposable hash.
ROOT_PRIVATE=1
config_file="$yaml"
redirect_mode=none
log_error() { :; }
printf 'dns:\n  port: 53335\nhttp:\n  address: 0.0.0.0:053335\n' >"$yaml"
if load_runtime_dns_port; then exit 1; fi
printf 'dns:\n  port: 53\n' >"$yaml"
load_runtime_dns_port
[ "$dns_port" = 53 ]
redirect_mode=dnsmasq-upstream
if load_runtime_dns_port; then exit 1; fi
printf 'dns:\n  port: 53335\nhttp:\n  address: 0.0.0.0:3000\n' >"$yaml"
: >"$calls"
load_runtime_dns_port
[ "$dns_port" = 53335 ]
[ "$(grep -c '^awk$' "$calls")" = 1 ]
! grep -q '^hash$' "$calls"

printf 'ok - single-pass runtime ports, bounded safe snapshots and unchanged CAS hashes\n'
