#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
source_file="${1:-${script_dir}/../root/usr/share/rpcd/ucode/luci.adguardhome}"

[ -f "$source_file" ] || {
	printf 'RPC source not found: %s\n' "$source_file" >&2
	exit 1
}

for helper in $(sed -n 's/^function \([A-Za-z_][A-Za-z0-9_]*\)(.*/\1/p' "$source_file"); do
	awk -v helper="$helper" '
		$0 ~ "^function " helper "\\(" { definitions++; definition_line = NR; next }
		$0 ~ helper "\\(" && !first_call_line { first_call_line = NR }
		END {
			if (definitions != 1 || !first_call_line || definition_line >= first_call_line) {
				printf "%s must be declared once before its first call (definition %d, call %d)\n", helper, definition_line, first_call_line > "/dev/stderr"
				exit 1
			}
		}
	' "$source_file"
done

# JavaScript hoists declarations; native ucode binds them in source order.
# Run the actual job reader and child-exit finisher with the SDK event loop.
if [ -n "${UCODE:-}" ]; then
	test_file="$(mktemp "${TMPDIR:-/tmp}/rpc-helper-order.XXXXXX")"
	trap 'rm -f -- "$test_file"' 0
	trap 'exit 1' HUP INT TERM
	cat > "$test_file" <<'UCODE'
import * as uloop from 'uloop';
const YAML_JOB_DIRECTORY = '/jobs';
const YAML_JOB_STATE_LIMIT = 256;
const MAX_CONFIG_LENGTH = 512 * 1024;
const HASH = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const TOKEN = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
let result = null, closed = false, finished = false;
function config_path() { return null; }
function lstat(path) { return {}; }
function unlink(path) { die('Offline stage cleanup must not unlink a file'); }
function root_private_directory(metadata) { return true; }
function root_private_file(metadata) { return true; }
function readfile(path, limit) { return `pending:${HASH}:${HASH}\n`; }
function replace_yaml_job(token, content) { result = content; return true; }
function close_yaml_job_lock(lock) { closed = !!lock.file; return true; }
UCODE
	awk '
		/^function (same_inode|yaml_job_path|parse_yaml_job_state|read_yaml_job|read_yaml_job_file|yaml_stage_path|remove_yaml_stage|finish_settings_process)\(/ { capture = 1 }
		capture { print }
		capture && /^}/ { capture = 0 }
	' "$source_file" >> "$test_file"
	cat >> "$test_file" <<'UCODE'
uloop.init();
let child = uloop.process('/bin/true', [], {}, function() {
	finish_settings_process(TOKEN, HASH, HASH, {});
	finished = true;
	uloop.end();
});
if (!child) die('Unable to start native child callback check');
let timeout = uloop.timer(2000, function() { die('Native child callback did not finish'); });
uloop.run();
if (!finished || !closed || result != `indeterminate:${HASH}:${HASH}\n`)
	die('Native job callback failed to publish its result and release the lock');
if (!remove_yaml_stage(TOKEN, null) || remove_yaml_stage('../invalid', null))
	die('Offline stage cleanup must allow settings recovery while validating the token');
UCODE
	if [ -n "${UCODE_LOADER:-}" ]; then
		"$UCODE_LOADER" --library-path "${UCODE_LIBRARY_PATH:-}" "$UCODE" \
			-L "$(dirname -- "$UCODE")/../lib/ucode" "$test_file"
	else
		"$UCODE" "$test_file"
	fi
fi

printf 'ok - ucode helpers are declared before their first call\n'
