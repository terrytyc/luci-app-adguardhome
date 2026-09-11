# Read the same self-contained init that is installed by the package build.
init_source() {
	local helper_dir="${1%/root/etc/init.d/AdGuardHome}/scripts"
	awk -v helper_dir="$helper_dir" -f "$helper_dir/expand-helpers.awk" "$1"
}

# Extract one multiline shell function without sourcing the production script.
# Callers own shell options, fixtures, mocks and any target-shell re-execution.
function_body() {
	local body source="$1"
	case "$source" in
		*/root/etc/init.d/AdGuardHome)
			body="$(init_source "$source")" || return 1
			;;
		*) body="$(cat "$source")" || return 1 ;;
	esac
	awk -v function_name="$2" '
		$0 == function_name "() {" || $0 == function_name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' <<EOF
$body
EOF
}
