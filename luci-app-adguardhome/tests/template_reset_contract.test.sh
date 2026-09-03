#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
source_template="${package_dir}/root/usr/share/luci-app-adguardhome/default.yaml"
makefile="${package_dir}/Makefile"
rpc_source="${package_dir}/root/usr/share/rpcd/ucode/luci.adguardhome"
yaml_view="${package_dir}/htdocs/luci-static/resources/view/adguardhome/yaml.js"
expected_sha256=5cfed909100879796de2b9c6d5d75c855ffb2d271a814789a6db263867a9d6db

for file in "$source_template" "$makefile" "$rpc_source" "$yaml_view"; do
	if [ ! -f "$file" ] || [ -L "$file" ]; then
		printf 'required template-reset source is missing or unsafe: %s\n' "$file" >&2
		exit 1
	fi
done

# Exercise the real preparation hook with the same two Make expansion layers
# used by the SDK. Only the immutable reset template exists in the source tree.
[ ! -e "${package_dir}/root/etc/AdGuardHome/AdGuardHome.yaml" ] || {
	printf 'clean-install YAML is still maintained as a second source file\n' >&2
	exit 1
}
temporary="$(mktemp -d /tmp/luci-agh-template-build.XXXXXX)"
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
mkdir "$temporary/build"
cp -R "$package_dir/root" "$temporary/build/root"
cp -R "$package_dir/htdocs" "$temporary/build/htdocs"
{
	printf 'ADGUARDHOME_SOURCE_DIR := %s/\nPKG_BUILD_DIR := %s/build\n' \
		"$package_dir" "$temporary"
	awk '
		/^define Build\/Prepare\/luci-app-adguardhome$/ { copying = 1 }
		copying { print }
		copying && /^endef$/ { exit }
	' "$makefile"
	printf '\ndefine test_rules\nall:\n\t$(Build/Prepare/luci-app-adguardhome)\nendef\n$(eval $(test_rules))\n'
} >"$temporary/prepare.make"
make --no-print-directory -s -f "$temporary/prepare.make"
active_template="$temporary/build/root/etc/AdGuardHome/AdGuardHome.yaml"
reset_template="$temporary/build/root/usr/share/luci-app-adguardhome/default.yaml"
[ "$(busybox stat -c '%a' "$temporary/build/root/etc/AdGuardHome")" = 700 ]
[ "$(busybox stat -c '%a' "$active_template")" = 600 ]
[ "$(busybox stat -c '%a' "$reset_template")" = 644 ]
cmp -s "$source_template" "$reset_template"
cmp -s "$active_template" "$reset_template" || {
	printf 'clean-install and reset YAML templates differ\n' >&2
	exit 1
}

for file in "$active_template" "$reset_template"; do
	actual_sha256="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual_sha256" = "$expected_sha256" ] || {
		printf 'template does not match the requested frozen bytes: %s\n' "$file" >&2
		exit 1
	}
done

python3 - "$active_template" "$rpc_source" "$yaml_view" <<'PY'
import pathlib
import sys

import yaml

template_path = pathlib.Path(sys.argv[1])
rpc_path = pathlib.Path(sys.argv[2])
view_path = pathlib.Path(sys.argv[3])
template_text = template_path.read_text(encoding="utf-8")
template = yaml.safe_load(template_text)

if template["schema_version"] != 34:
    raise SystemExit("template schema version is not 34")
if template["dns"]["port"] != 53335:
    raise SystemExit("template DNS port is not 53335")
if template["http"]["address"] != "0.0.0.0:3000":
    raise SystemExit("template HTTP listener is not 0.0.0.0:3000")
if template["tls"]["enabled"] is not False:
    raise SystemExit("template TLS is not disabled")
if template["filtering"]["safe_fs_patterns"] != [
    "/tmp/lib/adguardhome/userfilters/*"
]:
    raise SystemExit("template safe_fs_patterns differs from the requested value")
if template["users"] != [{
    "name": "admin",
    "password": "$2y$10$vHRcARdPCieYG3RXWomV5evDYN.Nj/edtwEkQgQJZcK6z7qTLaIc6",
}]:
    raise SystemExit("template does not retain the requested admin/admin record")

rpc = rpc_path.read_text(encoding="utf-8")

def between(start, end):
    first = rpc.index(start)
    last = rpc.index(end, first)
    return rpc[first:last]

directory_guard = between(
    "function safe_template_directory(",
    "function read_template()",
)
for fragment in (
    "function safe_template_directory(path, shared_ancestor)",
    "metadata?.type == 'directory'",
    "metadata.uid == 0",
    "metadata.gid == 0",
    "shared_ancestor === true",
    "!metadata.perm?.group_write",
    "!metadata.perm?.other_write",
):
    if fragment not in directory_guard:
        raise SystemExit(f"template directory guard omits: {fragment}")

reader = between("function read_template()", "function read_config(configuration)")
for fragment in (
    "for (let directory in [ '/usr', '/usr/share' ])",
    "safe_template_directory(directory, true)",
    "safe_template_directory(TEMPLATE_DIRECTORY, false)",
    "before.uid != 0",
    "before.gid != 0",
    "before.mode != 0o644",
    "before.nlink != 1",
    "same_inode(before, opened)",
    "same_inode(before, after)",
    "opened.mode == 0o644",
    "opened.nlink == 1",
    "after.mode == 0o644",
    "after.nlink == 1",
):
    if fragment not in reader:
        raise SystemExit(f"packaged template reader omits: {fragment}")

for forbidden in ("template_for_path", "TEMPLATE_FILTER_PATTERN", "TEMPLATE_WORK_DIR"):
    if forbidden in rpc:
        raise SystemExit(f"reset backend still rewrites packaged template content: {forbidden}")
reset_backend = between("function reset_yaml(expected_hash)", "function yaml_config_values(")
if reset_backend.count("let content = read_template();") != 1:
    raise SystemExit("reset_yaml does not read the packaged template directly")
if "return { content };" not in reset_backend:
    raise SystemExit("reset_yaml does not return the packaged template to the editor")
if "sha256(content)" in reset_backend:
    raise SystemExit("reset_yaml still computes an unused template revision")
if "yaml.sha256 != expected_hash" not in reset_backend:
    raise SystemExit("reset_yaml no longer checks the active YAML revision")
for forbidden in ("update_yaml(", "write(", "yaml_update_job"):
    if forbidden in reset_backend:
        raise SystemExit(f"reset_yaml still applies the template directly: {forbidden}")

view = view_path.read_text(encoding="utf-8")
reset_start = view.index("\tasync resetYaml() {")
reset_end = view.index("\n\tasync waitForYamlUpdate(", reset_start)
reset_view = view[reset_start:reset_end]
for required in (
    "const template = await callResetYaml(this.yamlHash);",
    "this.yamlEditor.value = template.content;",
):
    if required not in reset_view:
        raise SystemExit(f"template editor flow omits: {required}")
for forbidden in (
    "callSetYaml(",
    "waitForYamlUpdate(",
    "operation.start()",
    "reloadYaml()",
    "invalidateYamlEditor()",
):
    if forbidden in reset_view:
        raise SystemExit(f"template button still applies or discards editor state: {forbidden}")
PY

printf 'ok - single-source YAML build, installed permissions and reset safety contract\n'
