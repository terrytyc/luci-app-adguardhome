# Expand the one shared shell helper into self-contained installed scripts.
BEGIN {
	while ((getline line < helper) > 0) {
		if (line == "define AdGuardHome/RunBounded") { copying = 1; continue }
		if (copying && line == "endef") { complete = 1; break }
		if (copying) {
			gsub(/\$\$/, "$", line)
			body = body line "\n"
		}
	}
	close(helper)
	if (!complete || body == "") exit 1
}
$0 == "# @include run-bounded" {
	printf "%s", body
	markers++
	next
}
{ print }
END { if (!complete || markers != 1) exit 1 }
