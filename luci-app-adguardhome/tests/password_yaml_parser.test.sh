#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
source_file="${1:-${script_dir}/../root/usr/share/rpcd/ucode/luci.adguardhome}"
ucode_bin="${UCODE:-ucode}"

run_ucode() {
	if [ -n "${UCODE_LOADER:-}" ]; then
		if [ -n "${UCODE_LIBRARY_PATH:-}" ]; then
			"$UCODE_LOADER" --library-path "$UCODE_LIBRARY_PATH" \
				"$ucode_bin" "$@"
		else
			"$UCODE_LOADER" "$ucode_bin" "$@"
		fi
	elif [ -n "${UCODE_LIBRARY_PATH:-}" ]; then
		LD_LIBRARY_PATH="${UCODE_LIBRARY_PATH}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
			"$ucode_bin" "$@"
	else
		"$ucode_bin" "$@"
	fi
}

[ -f "$source_file" ] || {
	printf 'password YAML parser source not found: %s\n' "$source_file" >&2
	exit 1
}

umask 077
test_file="$(mktemp "${TMPDIR:-/tmp}/password-yaml-parser.XXXXXX")"
stdout_file="${test_file}.out"
stderr_file="${test_file}.err"
cleanup() {
	rm -f -- "$test_file" "$stdout_file" "$stderr_file"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Exercise the exact private credential parser functions from the production
# rpcd source.
# The complete rpcd module cannot be evaluated in a host-side unit test because
# it imports router-only ucode modules, so extract only this dependency-closed
# parser block and append the fixtures below.
{
	cat <<'UCODE_STUBS'
const TEST_CANDIDATE = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
let mock_yaml = null;
let updated_content = null;

function read_yaml() {
	return mock_yaml;
}

function sha256(content) {
	return content == mock_yaml.content ? mock_yaml.sha256 : TEST_CANDIDATE;
}

function update_yaml(content, expected_hash) {
	updated_content = content;
	return expected_hash == mock_yaml.sha256
		? { accepted: true }
		: { error: 'unexpected revision' };
}
UCODE_STUBS

	awk '
		/^function yaml_simple_scalar\(value\)/ { copying = 1 }
		copying && /^function reset_yaml\(expected_hash\)/ { exit }
		copying { print }
	' "$source_file"

	cat <<'UCODE_TESTS'
const OLD_HASH = '$2y$10$vHRcARdPCieYG3RXWomV5evDYN.Nj/edtwEkQgQJZcK6z7qTLaIc6';
const NEW_HASH = '$2b$10$vHRcARdPCieYG3RXWomV5evDYN.Nj/edtwEkQgQJZcK6z7qTLaIc7';
const REVISION = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

function fail(name, detail) {
	warn(`not ok - ${name}: ${detail}\n`);
	exit(1);
}

function expect_rejected(name, content) {
	if (credential_record(content) != null)
		fail(name, 'ambiguous or unsupported YAML was accepted');
	print(`ok - ${name}\n`);
}

function expect_replacement(name, content, expected_username, new_username,
		new_password, expected_content) {
	let record = credential_record(content);
	if (!record)
		fail(name, 'supported YAML was rejected');
	if (record.username != expected_username)
		fail(name, `selected username was '${record.username}'`);
	if (record.record_count != 1)
		fail(name, 'single-user YAML returned an incorrect account count');

	if (new_username != null)
		record.lines[record.name_line] = `${record.name_prefix}'${new_username}'`;
	if (new_password != null)
		record.lines[record.password_line] = `${record.password_prefix}${new_password}`;
	let replaced = join('\n', record.lines);
	if (replaced != expected_content)
		fail(name, 'credential replacement did not preserve the YAML sequence shape');
	print(`ok - ${name}\n`);
}

expect_replacement(
	'canonical admin password-only update',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n`,
	'admin',
	null,
	NEW_HASH,
	`users:\n  - name: admin\n    password: ${NEW_HASH}\n`
);

expect_replacement(
	'non-admin password-only update',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'root',
	null,
	NEW_HASH,
	`users:\n  - name: root\n    password: ${NEW_HASH}\n`
);

expect_replacement(
	'username-only update preserves password',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'root',
	'terry',
	null,
	`users:\n  - name: 'terry'\n    password: ${OLD_HASH}\n`
);

expect_replacement(
	'simultaneous username and password update',
	`users:\n  - password: ${OLD_HASH}\n    name: admin\n`,
	'admin',
	'operator',
	NEW_HASH,
	`users:\n  - password: ${NEW_HASH}\n    name: 'operator'\n`
);

expect_replacement(
	'quoted non-admin username',
	`users:\n  - name: "root"\n    password: '${OLD_HASH}'\n`,
	'root',
	'operator',
	NEW_HASH,
	`users:\n  - name: 'operator'\n    password: ${NEW_HASH}\n`
);

let multi_user_record = credential_record(
	`users:\n  - name: guest\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${OLD_HASH}\n`
);
if (!multi_user_record || multi_user_record.username != 'admin' ||
		multi_user_record.record_count != 2)
	fail('multi-user account count', 'the unique admin or total account count was not returned');
print('ok - multi-user account count\n');

expect_rejected(
	'duplicate name field',
	`users:\n  - name: admin\n    name: admin\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'duplicate password field',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'multiple non-admin entries are ambiguous',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n  - name: guest\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'duplicate admin entries are ambiguous',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'unsafe username scalar',
	`users:\n  - name: "root user"\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'block scalar password',
	`users:\n  - name: admin\n    password: |\n      ${OLD_HASH}\n`
);

if (supported_username_scalar('terry@example.com') != 'terry@example.com')
	fail('safe username validation', 'a safe username was rejected');
if (supported_username_scalar('"root user"') != null ||
		supported_username_scalar('-root') != null ||
		supported_username_scalar('root#admin') != null)
	fail('safe username validation', 'an unsafe username was accepted');
print('ok - safe username validation\n');

function expect_update(name, content, username, password_hash, expected_content) {
	mock_yaml = { content, sha256: REVISION };
	updated_content = null;
	let result = update_credentials(username, password_hash, REVISION);
	if (result?.accepted != true)
		fail(name, `credential update failed: ${result?.error || 'unknown error'}`);
	if (updated_content != expected_content)
		fail(name, 'credential update produced unexpected YAML');
	if (!credential_record(updated_content))
		fail(name, 'credential update produced YAML that cannot be managed again');
	print(`ok - ${name}\n`);
}

expect_update(
	'RPC admin password-only update',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n`,
	'',
	NEW_HASH,
	`users:\n  - name: admin\n    password: ${NEW_HASH}\n`
);
expect_update(
	'RPC admin username-only update',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n`,
	'operator',
	'',
	`users:\n  - name: 'operator'\n    password: ${OLD_HASH}\n`
);
expect_update(
	'RPC admin simultaneous update',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n`,
	'operator',
	NEW_HASH,
	`users:\n  - name: 'operator'\n    password: ${NEW_HASH}\n`
);

expect_update(
	'RPC password-only update',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'',
	NEW_HASH,
	`users:\n  - name: root\n    password: ${NEW_HASH}\n`
);
expect_update(
	'RPC username-only update',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'terry',
	'',
	`users:\n  - name: 'terry'\n    password: ${OLD_HASH}\n`
);
expect_update(
	'RPC simultaneous update',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'terry',
	NEW_HASH,
	`users:\n  - name: 'terry'\n    password: ${NEW_HASH}\n`
);

expect_update(
	'RPC multi-user password-only update',
	`users:\n  - name: guest\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${OLD_HASH}\n`,
	'',
	NEW_HASH,
	`users:\n  - name: guest\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${NEW_HASH}\n`
);

expect_update(
	'YAML boolean-like username remains a string',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'true',
	'',
	`users:\n  - name: 'true'\n    password: ${OLD_HASH}\n`
);
expect_update(
	'YAML null-like username remains a string',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'null',
	'',
	`users:\n  - name: 'null'\n    password: ${OLD_HASH}\n`
);
expect_update(
	'all-numeric username remains a string',
	`users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	'12345',
	'',
	`users:\n  - name: '12345'\n    password: ${OLD_HASH}\n`
);

mock_yaml = {
	content: `users:\n  - name: root\n    password: ${OLD_HASH}\n`,
	sha256: REVISION,
};
if (!update_credentials('', '', REVISION)?.error)
	fail('empty credential update', 'an empty update was accepted');
if (!update_credentials('root user', '', REVISION)?.error)
	fail('unsafe RPC username', 'an unsafe username was accepted');
if (!update_credentials('root', '', REVISION)?.error)
	fail('unchanged RPC username', 'a no-op username update was accepted');
print('ok - RPC credential validation\n');

mock_yaml = {
	content: `users:\n  - name: guest\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${OLD_HASH}\n`,
	sha256: REVISION,
};
let duplicate_result = update_credentials('guest', '', REVISION);
if (duplicate_result?.error != 'The requested username already exists')
	fail('duplicate RPC username', 'a duplicate username was accepted');
print('ok - duplicate RPC username rejected\n');

updated_content = null;
let multi_rename = update_credentials('operator', '', REVISION);
if (multi_rename?.error !=
		'Cannot change the username while multiple YAML user accounts are configured; change only the password or use the YAML editor' ||
		updated_content != null)
	fail('multi-user username-only update', 'a multi-user username change was not rejected atomically');
print('ok - multi-user username-only update rejected\n');

updated_content = null;
multi_rename = update_credentials('operator', NEW_HASH, REVISION);
if (multi_rename?.error !=
		'Cannot change the username while multiple YAML user accounts are configured; change only the password or use the YAML editor' ||
		updated_content != null)
	fail('multi-user simultaneous update', 'a multi-user username/password change was not rejected atomically');
print('ok - multi-user simultaneous update rejected\n');

print('credential YAML parser fixture tests passed\n');
UCODE_TESTS
} >"$test_file"

if ! run_ucode -S "$test_file" >"$stdout_file" 2>"$stderr_file"; then
	cat "$stdout_file"
	cat "$stderr_file" >&2
	exit 1
fi
cat "$stdout_file"
if [ -s "$stderr_file" ]; then
	cat "$stderr_file" >&2
	exit 1
fi
