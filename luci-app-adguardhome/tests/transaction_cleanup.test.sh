#!/bin/sh
set -e

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$script_dir/lib/function-body.sh"
init_file="$script_dir/../root/etc/init.d/AdGuardHome"
eval "$(init_source "$init_file")"
test_tmp="$(mktemp -d /tmp/agh-transaction-cleanup.XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT
NORMALIZER_RUNTIME_DIR="$test_tmp/runtime"
NORMALIZER_LOCK="$NORMALIZER_RUNTIME_DIR/normalizer.lock"
work_dir="$test_tmp/work"
mkdir -m 0700 "$NORMALIZER_RUNTIME_DIR" "$work_dir"
config_file="$NORMALIZER_RUNTIME_DIR/yaml-migration.abcdef"
printf 'dns:\n  port: 53335\n' >"$config_file"
chmod 0600 "$config_file"
original_hash="$(yaml_file_hash "$config_file")"

# Run the real transaction and file cleanup. Only the account/jail boundary is
# isolated; the test does not require installing a uid-853 account on the host.
eval "$(function_body "$init_file" normalize_installer_config | sed 's@/sbin/ujail@/bin/true@g')"
id() {
	case "$*" in
		'-u adguardhome'|'-g adguardhome'|'-G adguardhome') printf '853\n' ;;
		'-gn adguardhome') printf 'adguardhome\n' ;;
		'-g root') printf '0\n' ;;
		'-gn root') printf 'root\n' ;;
		*) command id "$@" ;;
	esac
}
log_error() { :; }
adguard_uid_process_exists() { [ "$failure" = busy ]; }
prepare_tls_validation_files() { TLS_CERT_REAL=""; }
check_core_config_file() { :; }
validate_managed_work_dir_namespace() { :; }
run_bounded() { shift 2; "$@"; }
mktemp() {
	local created
	created="$(command mktemp "$@")" || return 1
	printf '%s\n' "$created" >>"$test_tmp/created"
	printf '%s\n' "$created"
}
mv() {
	case "$1" in
		"${config_file}.normalized."*)
			[ "$failure" != replacement ] || return 1 ;;
	esac
	command mv "$@"
}
normalizer_rc=0
for failure in busy snapshot replacement success; do
	: >"$test_tmp/created"
	normalizer_rc=0
	(
		if [ "$failure" = snapshot ]; then
			snapshot_config_file() { return 1; }
		fi
		normalize_config "$config_file" "$work_dir"
	) || normalizer_rc=$?
	if [ "$failure" = success ]; then
		[ "$normalizer_rc" = 0 ]
	else
		[ "$normalizer_rc" = 1 ]
	fi
	[ ! -e "$NORMALIZER_LOCK" ]
	while IFS= read -r created; do
		[ ! -e "$created" ] || {
			printf 'normalizer left %s after %s\n' "$created" "$failure" >&2
			exit 1
		}
	done <"$test_tmp/created"
	[ "$(yaml_file_hash "$config_file")" = "$original_hash" ]
done

# A rejected atomic install must remove its exclusive stage inode.
stage="$work_dir/failed-stage"
if install_config_candidate_attempt "$config_file" wrong '' "$stage" ''; then
	exit 1
fi
[ ! -e "$stage" ]
[ "$(yaml_file_hash "$config_file")" = "$original_hash" ]

# Use the real atomic installer through its retry boundary. Definite failures
# must return once, remove the stage and preserve the previous active YAML.
candidate="$test_tmp/candidate.yaml"
printf 'dns:\n  port: 53336\n' >"$candidate"
chmod 0600 "$candidate"
candidate_hash="$(yaml_file_hash "$candidate")"
validate_work_dir_mount_dependency() { return 0; }
eval "$(function_body "$init_file" install_config_candidate_attempt |
	sed '1s/install_config_candidate_attempt/install_attempt_original/')"
install_config_candidate_attempt() {
	printf '%s\n' "$4" >>"$test_tmp/attempts"
	install_attempt_original "$@"
}
for failure in stale-revision permissions rename; do
	: >"$test_tmp/attempts"
	if (
		expected="$original_hash"
		case "$failure" in
			stale-revision) expected=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
			permissions) secure_config_inode() { return 1; } ;;
			rename) mv() { return 1; } ;;
		esac
		install_config_candidate "$candidate" "$expected" "$candidate_hash" ''
	); then
		exit 1
	fi
	[ "$(wc -l <"$test_tmp/attempts")" = 1 ]
	[ ! -e "${config_file}.install.$$.0" ]
	[ "$(yaml_file_hash "$config_file")" = "$original_hash" ]
done

# Occupied names, including a dangling symlink, are left untouched. Only the
# first free name enters the exclusive-create/copy/hash/rename transaction.
printf 'existing stage\n' >"${config_file}.install.$$.0"
ln -s absent "${config_file}.install.$$.1"
: >"$test_tmp/attempts"
install_config_candidate "$candidate" "$original_hash" "$candidate_hash" ''
[ "$(cat "$test_tmp/attempts")" = "${config_file}.install.$$.2" ]
[ "$(cat "${config_file}.install.$$.0")" = 'existing stage' ]
[ "$(readlink "${config_file}.install.$$.1")" = absent ]
[ ! -e "${config_file}.install.$$.2" ]
[ "$(yaml_file_hash "$config_file")" = "$candidate_hash" ]
printf 'ok - normalization and atomic YAML install preserve data and clean failed stages\n'
