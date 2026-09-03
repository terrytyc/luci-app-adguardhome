# Expand shared Makefile helpers into self-contained installed scripts.
function read_helper(path, name, line, copying, complete, body) {
	while ((getline line < path) > 0) {
		if (line == "define AdGuardHome/" name) { copying = 1; continue }
		if (copying && line == "endef") { complete = 1; break }
		if (copying) {
			gsub(/\$\$/, "$", line)
			body = body line "\n"
		}
	}
	close(path)
	if (!complete || body == "") { failed = 1; exit 1 }
	return body
}
/^# @include / {
	name = $3
	if (++markers[name] != 1) { failed = 1; exit 1 }
	if (name == "run-bounded")
		printf "%s", read_helper(helper_dir "/run-bounded.mk", "RunBounded")
	else if (name == "private-files")
		printf "%s", read_helper(helper_dir "/private-files.mk", "PrivateFiles")
	else if (name == "upgrade-policy")
		printf "%s", read_helper(helper_dir "/upgrade-policy.mk", "UpgradePolicy")
	else if (name == "keep-active-config")
		printf "%s", read_helper(helper_dir "/keep-active-config.mk", "KeepActiveConfig")
	else { failed = 1; exit 1 }
	next
}
{ print }
END { if (failed || markers["run-bounded"] != 1) exit 1 }
