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
cleanup() {
	rm -f -- "$test_file"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Exercise the exact private parser functions from the production rpcd source.
# The complete rpcd module cannot be evaluated in a host-side unit test because
# it imports router-only ucode modules, so extract only this dependency-closed
# parser block and append the fixtures below.
{
	awk '
		/^function yaml_simple_scalar\(value\)/ { copying = 1 }
		copying && /^function password_info\(\)/ { exit }
		copying { print }
	' "$source_file"

	cat <<'UCODE_TESTS'
const OLD_HASH = '$2y$10$vHRcARdPCieYG3RXWomV5evDYN.Nj/edtwEkQgQJZcK6z7qTLaIc6';
const NEW_HASH = '$2b$10$vHRcARdPCieYG3RXWomV5evDYN.Nj/edtwEkQgQJZcK6z7qTLaIc7';

function fail(name, detail) {
	warn(`not ok - ${name}: ${detail}\n`);
	exit(1);
}

function expect_rejected(name, content) {
	if (admin_password_record(content) != null)
		fail(name, 'ambiguous or unsupported YAML was accepted');
	print(`ok - ${name}\n`);
}

function expect_replacement(name, content, expected_prefix, expected_content) {
	let record = admin_password_record(content);
	if (!record)
		fail(name, 'supported YAML was rejected');
	if (record.password_prefix != expected_prefix)
		fail(name, `replacement prefix was '${record.password_prefix}'`);

	record.lines[record.password_line] = `${record.password_prefix}${NEW_HASH}`;
	let replaced = join('\n', record.lines);
	if (replaced != expected_content)
		fail(name, 'password replacement did not preserve the YAML sequence shape');
	print(`ok - ${name}\n`);
}

expect_replacement(
	'canonical admin entry',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n`,
	'    password: ',
	`users:\n  - name: admin\n    password: ${NEW_HASH}\n`
);

expect_replacement(
	'quoted admin name',
	`users:\n  - name: "admin"\n    password: '${OLD_HASH}'\n`,
	'    password: ',
	`users:\n  - name: "admin"\n    password: ${NEW_HASH}\n`
);

expect_rejected(
	'quoted admin name with significant spaces',
	`users:\n  - name: " admin "\n    password: ${OLD_HASH}\n`
);

expect_replacement(
	'password-first inline sequence entry',
	`users:\n  - password: ${OLD_HASH}\n    name: admin\n`,
	'  - password: ',
	`users:\n  - password: ${NEW_HASH}\n    name: admin\n`
);

expect_replacement(
	'dash-only sequence entry',
	`users:\n  -\n    password: ${OLD_HASH}\n    name: admin\n`,
	'    password: ',
	`users:\n  -\n    password: ${NEW_HASH}\n    name: admin\n`
);

expect_rejected(
	'duplicate name field',
	`users:\n  - name: admin\n    name: admin\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'duplicate password field',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'duplicate admin entries',
	`users:\n  - name: admin\n    password: ${OLD_HASH}\n  - name: admin\n    password: ${OLD_HASH}\n`
);

expect_rejected(
	'block scalar password',
	`users:\n  - name: admin\n    password: |\n      ${OLD_HASH}\n`
);

print('password YAML parser fixture tests passed\n');
UCODE_TESTS
} >"$test_file"

run_ucode -S "$test_file"
