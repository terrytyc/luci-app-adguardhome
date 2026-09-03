#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
init_file="${script_dir}/../root/etc/init.d/AdGuardHome"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

# shellcheck disable=SC1090
. "$script_dir/lib/function-body.sh"
scanner_body="$(function_body "$init_file" adguard_uid_process_exists)"
# Substitute only the procfs fixture root; parsing and all guards stay real.
# shellcheck disable=SC2016
scanner_body="$(printf '%s\n' "$scanner_body" |
	sed 's#/proc/\[0-9\]\*/task/\[0-9\]\*/status#"$status_root"/[0-9]*/task/[0-9]*/status#')"
eval "$scanner_body"
ADGUARD_UID=853
calls="${test_tmp}/awk-calls"
: >"$calls"
awk() {
	printf 'awk\n' >>"$calls"
	command awk "$@"
}

# Keep the previous scanner as a behavioral oracle, including first Uid line,
# exact field count and fail-closed handling when a status file still exists.
legacy_adguard_uid_process_exists() {
	local status uids
	for status in "$status_root"/[0-9]*/task/[0-9]*/status; do
		if [ ! -r "$status" ]; then
			[ ! -e "$status" ] && continue
			return 0
		fi
		uids="$(awk '$1 == "Uid:" {
			if (NF != 5) exit 2
			for (i=2; i<=5; i++) if ($i !~ /^[0-9]+$/) exit 2
			print $2, $3, $4, $5; found=1; exit }
			END { if (!found) exit 1 }' \
			"$status" 2>/dev/null)" || {
			[ ! -e "$status" ] && continue
			return 0
		}
		case " $uids " in *" ${ADGUARD_UID} "*) return 0 ;; esac
	done
	return 1
}

generation=0
new_tree() {
	generation=$((generation + 1))
	status_root="${test_tmp}/tree-${generation}"
	mkdir "$status_root"
}
status_record() {
	mkdir -p "${status_root}/$1/task/$2"
	printf '%b' "$3" >"${status_root}/$1/task/$2/status"
}
expect_result() {
	local expected="$1" reason="$2" before rc=0
	before="$(wc -l <"$calls")"
	adguard_uid_process_exists || rc=$?
	if [ "$rc" != "$expected" ]; then
		printf 'builtin UID scan mismatch (%s): expected %s, got %s\n' \
			"$reason" "$expected" "$rc" >&2
		exit 1
	fi
	[ "$(wc -l <"$calls")" = "$before" ]
	rc=0
	legacy_adguard_uid_process_exists || rc=$?
	if [ "$rc" != "$expected" ]; then
		printf 'legacy UID scan mismatch (%s): expected %s, got %s\n' \
			"$reason" "$expected" "$rc" >&2
		exit 1
	fi
}

new_tree
expect_result 1 empty-procfs
for record in \
	'Uid: 0 0 0 0\n' \
	'Name:\tother\nState:\tS (sleeping)\nUid:\t1000\t1000\t1000\t1000\n' \
	'  Uid: 1000 1000 1000 1000  \n' \
	'Uid: 1000 1000 1000 1000' \
	'Uid: 1000 1000 1000 1000\r\n' \
	'\r\vUid:\t\f1000\r\r1000\v1000\f1000\r\n' \
	'Uid: 000853 000853 000853 000853\n' \
	'Uid: 1000 1000 1000 1000\nUid: 853 853 853 853\n'; do
	new_tree
	status_record 10 10 "$record"
	expect_result 1 "$record"
done
for record in \
	'Uid: 853 0 0 0\n' \
	'Uid: 0 853 0 0\n' \
	'Uid: 0 0 853 0\n' \
	'Uid: 0 0 0 853\n' \
	'Uid:\t853\t853\t853\t853' \
	'Uid: 853 853 853 853\nUid: malformed\n' \
	'' \
	'Name: no-uid\n' \
	'Uid:\nUid: 1000 1000 1000 1000\n' \
	'Uid: 1000 1000 1000\n' \
	'Uid: 1000 1000 1000 1000 extra\n' \
	'Uid: 1000 1000 1000 1000 1000\n' \
	'Uid: -1 1000 1000 1000\n' \
	'Uid: 1000 +1 1000 1000\n' \
	'Uid: 1000 1000 x 1000\n'; do
	new_tree
	status_record 10 10 "$record"
	expect_result 0 "$record"
done

# A non-leader thread must still prevent startup.  A complete three-thread
# negative scan used to execute three AWKs; the new scanner executes none.
new_tree
status_record 10 10 'Uid: 1000 1000 1000 1000\n'
status_record 10 11 'Uid: 1000 1000 1000 1000\n'
status_record 20 20 'Uid: 1000 1000 1000 1000\n'
before="$(wc -l <"$calls")"
expect_result 1 all-threads-quiet
[ "$(wc -l <"$calls")" -eq "$((before + 3))" ]
status_record 10 11 'Uid: 1000 853 1000 1000\n'
expect_result 0 non-leader-thread

# Deterministically model metadata races, instead of requiring a non-root test
# runner or timing a process exit.  Only the two filesystem predicates change.
legacy_body="$(function_body "$0" legacy_adguard_uid_process_exists)"
for body in "$scanner_body" "$legacy_body"; do
	# shellcheck disable=SC2016
	eval "$(printf '%s\n' "$body" |
		sed 's#\[ ! -r "$status" \]#status_read_denied "$status"#g;
		     s#\[ ! -e "$status" \]#status_is_absent "$status"#g')"
done
status_read_denied() {
	case "$status_mode" in
		unreadable|vanished-before-open) return 0 ;;
		vanished-on-open) rm -f "$1"; return 1 ;;
		*) [ ! -r "$1" ] ;;
	esac
}
status_is_absent() {
	case "$status_mode" in
		unreadable) return 1 ;;
		vanished-before-open|vanished-after-bad-record) return 0 ;;
		*) [ ! -e "$1" ] ;;
	esac
}
for status_mode in unreadable vanished-before-open vanished-after-bad-record; do
	new_tree
	status_record 10 10 'Name: missing-uid\n'
	case "$status_mode" in unreadable) expected=0 ;; *) expected=1 ;; esac
	expect_result "$expected" "$status_mode"
done
# Each scanner gets a fresh path for the same check/open disappearance race.
status_mode=vanished-on-open
for scanner in adguard_uid_process_exists legacy_adguard_uid_process_exists; do
	new_tree
	status_record 10 10 'Uid: 853 853 853 853\n'
	rc=0
	"$scanner" 2>/dev/null || rc=$?
	[ "$rc" = 1 ]
done

printf 'ok - builtin UID thread scan, legacy field/race semantics and zero AWK execution\n'
