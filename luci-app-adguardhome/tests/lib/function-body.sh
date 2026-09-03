# Extract one multiline shell function without sourcing the production script.
# Callers own shell options, fixtures, mocks and any target-shell re-execution.
function_body() {
	awk -v function_name="$2" '
		$0 == function_name "() {" || $0 == function_name "() (" { copying = 1 }
		copying { print }
		copying && ($0 == "}" || $0 == ")") { exit }
	' "$1"
}
