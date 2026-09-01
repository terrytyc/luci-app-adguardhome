#!/bin/sh

set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
package_dir="${script_dir}/.."
active_template="${package_dir}/root/etc/AdGuardHome/AdGuardHome.yaml"
reset_template="${package_dir}/root/usr/share/luci-app-adguardhome/default.yaml"
rpc_source="${package_dir}/root/usr/share/rpcd/ucode/luci.adguardhome"
yaml_view="${package_dir}/htdocs/luci-static/resources/view/adguardhome/yaml.js"
expected_sha256=5cfed909100879796de2b9c6d5d75c855ffb2d271a814789a6db263867a9d6db

for file in "$active_template" "$reset_template" "$rpc_source" "$yaml_view"; do
	if [ ! -f "$file" ] || [ -L "$file" ]; then
		printf 'required template-reset source is missing or unsafe: %s\n' "$file" >&2
		exit 1
	fi
done

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

reader = between("function read_template()", "function template_for_path(")
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

path_adapter = between("function template_for_path(", "function read_config()")
if path_adapter.count("return read_template();") != 1:
    raise SystemExit("template_for_path does not return the packaged template exactly once")
for forbidden in ("TEMPLATE_FILTER_PATTERN", "TEMPLATE_WORK_DIR"):
    if forbidden in rpc:
        raise SystemExit(f"reset backend still rewrites packaged template content: {forbidden}")
for forbidden in ("split(content", "work_dir", "/data/userfilters/*"):
    if forbidden in path_adapter:
        raise SystemExit(f"template_for_path still rewrites packaged content: {forbidden}")

reset_backend = between("function reset_yaml(expected_hash)", "function yaml_section_value(")
if "return { content, sha256: sha256(content) };" not in reset_backend:
    raise SystemExit("reset_yaml does not return the packaged template to the editor")
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

printf 'ok - v2.4 packaged template and reset safety contract\n'
