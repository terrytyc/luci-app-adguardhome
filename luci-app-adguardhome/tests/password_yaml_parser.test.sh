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
let listening_ports = [];
let no_op_hashes = 0;

function web_port_listening(port) {
	for (let listening in listening_ports)
		if (listening == port)
			return true;
	return false;
}

function read_yaml() {
	return mock_yaml;
}

function sha256(content) {
	no_op_hashes++;
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
	awk '
		/^function yaml_scalar\(value\)/ { copying = 1 }
		/^function yaml_simple_scalar\(value\)/ { copying = 0 }
		/^function yaml_config_values\(content\)/ { copying = 1 }
		/^function web_port_listening\(port\)/ { copying = 0 }
		/^function config_info\(content, can_probe\)/ { copying = 1 }
		/^function overview_info\(\)/ { copying = 0 }
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
if (!update_credentials('', OLD_HASH, REVISION)?.error)
	fail('unchanged RPC password', 'a byte-identical password update was accepted');
print('ok - RPC credential validation\n');

mock_yaml = {
	content: `users:\n  - name: guest\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${OLD_HASH}\n`,
	sha256: REVISION,
};
let duplicate_result = update_credentials('guest', '', REVISION);
if (duplicate_result?.error !=
		'Cannot change the username while multiple YAML user accounts are configured; change only the password or use the YAML editor')
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

if (no_op_hashes != 0)
	fail('credential no-op comparison', 'comparing existing YAML bytes recomputed a digest');
print('credential YAML parser fixture tests passed\n');

function expect_config(name, content, ports, dns_port, scheme, host, port) {
	listening_ports = ports;
	let result = config_info(content, true);
	if (result.dns_port !== dns_port)
		fail(name, 'DNS port differs');
	if (scheme == null) {
		if (result.web != null)
			fail(name, 'ambiguous or unavailable web endpoint was exposed');
	}
	else if (result.web?.scheme !== scheme || result.web?.host !== host ||
	         result.web?.port !== port)
		fail(name, 'web endpoint differs from the expected YAML values');
	print(`ok - ${name}\n`);
}

const HTTP = 'http:\n  address: 0.0.0.0:3000\n';
const DNS = 'dns:\n  port: 53335\n';
const TLS_PATHS = '  certificate_path: /etc/ssl/cert.pem\n  private_key_path: /etc/ssl/key.pem\n';
const TLS = 'tls:\n  enabled: true\n  server_name: router.example.com\n  port_https: 1029\n';

expect_config('one-pass HTTP and dynamic DNS port', HTTP + 'dns:\n  port: 5353\n',
	[ 3000 ], 5353, 'http', null, 3000);
expect_config('DNS port 53 remains supported', HTTP + 'dns:\n  port: 53\n',
	[ 3000 ], 53, 'http', null, 3000);
expect_config('HTTP port 53 remains supported', 'http:\n  address: 0.0.0.0:53\n' + DNS,
	[ 53 ], 53335, 'http', null, 53);
expect_config('TLS file pair and configured domain', HTTP + DNS + TLS + TLS_PATHS,
	[ 3000, 1029 ], 53335, 'https', 'router.example.com', 1029);
expect_config('TLS embedded material', HTTP + DNS + TLS +
	'  certificate_chain: |\n    CERTIFICATE\n  private_key: |\n    KEY\n',
	[ 1029 ], 53335, 'https', 'router.example.com', 1029);
expect_config('incomplete explicit TLS paths forbid inline fallback', HTTP + DNS + TLS +
	'  certificate_path: /etc/ssl/cert.pem\n  certificate_chain: |\n    CERTIFICATE\n  private_key: |\n    KEY\n',
	[ 3000, 1029 ], 53335, 'http', null, 3000);
expect_config('non-listening HTTPS falls back to HTTP', HTTP + DNS + TLS + TLS_PATHS,
	[ 3000 ], 53335, 'http', null, 3000);
expect_config('forced HTTPS never falls back', HTTP + DNS + TLS + TLS_PATHS + '  force_https: true\n',
	[ 3000 ], 53335, null, null, null);
expect_config('HTTPS numeric host remains rejected', HTTP + DNS +
	'tls:\n  enabled: true\n  server_name: 127.1\n  port_https: 1029\n' + TLS_PATHS,
	[ 3000, 1029 ], 53335, 'http', null, 3000);
expect_config('loopback HTTP remains unavailable', 'http:\n  address: 127.0.0.1:3000\n' + DNS,
	[ 3000 ], 53335, null, null, null);
for (let address in [
	'127.1.2.3:3000', '[::1]:3000', '[0:0:0:0:0:0:0:1]:3000',
	'[::ffff:127.0.0.1]:3000', '[0:0:0:0:0:ffff:7f01:203]:3000',
	'[::1%lo]:3000', '[::ffff:127.0.0.1%lo]:3000',
])
	expect_config(`loopback HTTP ${address}`, `http:\n  address: "${address}"\n` + DNS,
		[ 3000 ], 53335, null, null, null);
expect_config('non-loopback IPv4-mapped HTTP remains available',
	'http:\n  address: "[::ffff:192.168.1.1]:3000"\n' + DNS,
	[ 3000 ], 53335, 'http', null, 3000);
expect_config('scoped non-loopback IPv6 HTTP remains available',
	'http:\n  address: "[fe80::1%eth0]:3000"\n' + DNS,
	[ 3000 ], 53335, 'http', null, 3000);
expect_config('IPv6 HTTP bind uses LuCI host', 'http:\n  address: "[::]:3000"\n' + DNS,
	[ 3000 ], 53335, 'http', null, 3000);
if (valid_port('1') !== 1 || valid_port('53') !== 53 ||
	valid_port('65535') !== 65535 || valid_port('0') != null ||
	valid_port('65536') != null || valid_port('-1') != null ||
	valid_port('53x') != null)
	fail('shared port validation', 'port bounds or port 53 support changed');
print('ok - shared port validation preserves port 53\n');
expect_config('duplicate DNS section stays ambiguous', HTTP + DNS + 'dns: # duplicate\n  port: 5353\n',
	[ 3000 ], null, 'http', null, 3000);
expect_config('duplicate DNS key stays ambiguous', HTTP + DNS + '  port: 5353\n',
	[ 3000 ], null, 'http', null, 3000);
expect_config('duplicate HTTP section stays ambiguous', HTTP + DNS + HTTP,
	[ 3000 ], 53335, null, null, null);
expect_config('duplicate HTTP key stays ambiguous', HTTP + '  address: 0.0.0.0:3001\n' + DNS,
	[ 3000, 3001 ], 53335, null, null, null);
expect_config('nested values cannot override direct keys',
	HTTP + DNS + '  nested:\n    port: 5353\n',
	[ 3000 ], 53335, 'http', null, 3000);
expect_config('later shallower mapping rejects earlier nested key',
	HTTP + 'dns:\n    port: 5353\n  nested: value\n',
	[ 3000 ], null, 'http', null, 3000);
expect_config('comments and quoted scalars preserve mapping depth',
	'http: # endpoint\n # explanation\n  address: "0.0.0.0:3000" # bind\n' +
	'dns: # DNS\n  # ignored: 53\n  port: "53335" # port\n',
	[ 3000 ], 53335, 'http', null, 3000);
expect_config('tab-indented key is not a supported mapping', HTTP + 'dns:\n\tport: 53335\n',
	[ 3000 ], null, 'http', null, 3000);
expect_config('invalid TLS boolean hides ambiguous endpoint', HTTP + DNS + 'tls:\n  enabled: perhaps\n',
	[ 3000 ], 53335, null, null, null);

let duplicate_tls = yaml_config_values(TLS + TLS_PATHS + TLS + TLS_PATHS);
if (yaml_section_value(duplicate_tls, 'tls', 'enabled') != null ||
		yaml_section_value(duplicate_tls, 'tls', 'certificate_path') != null)
	fail('duplicate TLS section', 'duplicate section exposed values');
let duplicate_key = yaml_config_values(TLS + TLS_PATHS + '  port_https: 1030\n');
if (yaml_section_value(duplicate_key, 'tls', 'port_https') != null)
	fail('duplicate TLS key', 'duplicate key exposed a value');
print('ok - duplicate TLS sections and keys remain ambiguous\n');
print('one-pass status YAML parser fixture tests passed\n');
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
