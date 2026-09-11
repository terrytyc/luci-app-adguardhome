#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
temporary=$(mktemp -d /tmp/adguardhome-release-test.XXXXXX)
trap 'rm -rf -- "$temporary"' EXIT
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

workflow=$repo/.github/workflows/publish-feed.yml
selection=$(awk '
 /name: Select current/ { selected=1 }
 selected && /run: \|/ { active=1; next }
 active && /      - name:/ { exit }
 active { sub(/^          /, ""); print }
' "$workflow")
check_selection() {
	local requested=$1 tags=$2 expected=$3
	: >"$temporary/output"
	REQUESTED_TAG=$requested TEST_TAGS=$tags GITHUB_REPOSITORY=test/project \
		GITHUB_OUTPUT=$temporary/output SELECTION="$selection" bash -c '
		gh() { printf "%s\n" "$TEST_TAGS"; }
		eval "$SELECTION"
	'
	[[ $(<"$temporary/output") == "$expected" ]] || die "release selection: $requested"
}
check_selection v3.0.0-r1 $'v3.0.0-r2\nv3.0.0-r1' ''
check_selection v3.0.0-r2 $'v3.0.0-r2\nv3.0.0-r1' 'current=v3.0.0-r2'
check_selection '' $'v3.0.0-r2\nv3.0.0-r1' 'current=v3.0.0-r2'
check_selection '' v3.0.0-r1 'current=v3.0.0-r1'
check_selection v3.0.0-r10 $'v3.0.0-r9\nv3.0.0-r2\nv3.0.0-r10' 'current=v3.0.0-r10'
check_selection '' $'v3.0.0-r9\nv3.0.0-r10\nv3.1.0-r1' 'current=v3.1.0-r1'
check_selection v3.0.0-r9 $'v3.0.0-r9\nv3.0.0-r10' ''
[[ $(grep -Fc "if: steps.releases.outputs.current != ''" "$workflow") == 6 ]] || die 'build steps must skip old releases'
grep -Fq "if: needs.build.outputs.current != ''" "$workflow" || die 'deploy must skip old releases'
! grep -Fq 'inputs.tag' "$workflow" || die 'manual publication must use the latest release'
! grep -qi previous "$workflow" || die 'publication must not retain an unindexed previous release'
grep -Fq 'ref: ${{ steps.tests.outputs.head_sha }}' "$workflow" ||
	die 'publication checkout is not bound to the tested commit'
! grep -Fq 'ref: ${{ steps.releases.outputs.current }}' "$workflow" ||
	die 'publication must not resolve a movable tag after the test gate'
grep -Fq 'persist-credentials: false' "$workflow" || die 'release checkout must not retain write credentials'
! grep -Fq 'gh release download' "$workflow" || die 'signed feed must not trust independently uploaded release APKs'
grep -Fq 'TEST_RUN_ID: ${{ steps.tests.outputs.run_id }}' "$workflow" ||
	die 'feed download is not bound to the passing test run'
grep -Fq 'TEST_ARTIFACT_ATTEMPT: ${{ steps.tests.outputs.artifact_attempt }}' "$workflow" ||
	die 'feed download is not bound to the full-job artifact attempt'
grep -Fq 'gh run download "$TEST_RUN_ID" --repo "$GITHUB_REPOSITORY"' "$workflow" ||
	die 'feed does not download the passing run artifact'
grep -Fq -- '--name "release-apks-$TEST_ARTIFACT_ATTEMPT" --dir release/current' "$workflow" ||
	die 'feed does not select the passing attempt artifact'
download=$(awk '
 /name: Download verified CI APKs/ { selected=1 }
 selected && /run: \|/ { active=1; next }
 active && /      - name:/ { exit }
 active { sub(/^          /, ""); print }
' "$workflow")
mkdir "$temporary/download"
(cd "$temporary/download" && TEST_RUN_ID=123 TEST_ARTIFACT_ATTEMPT=7 \
	GITHUB_REPOSITORY=test/project CALLS="$temporary/download-call" DOWNLOAD="$download" bash -c '
	gh() { printf "%s\n" "$*" >"$CALLS"; }
	eval "$DOWNLOAD"
')
[[ $(<"$temporary/download-call") == \
	'run download 123 --repo test/project --name release-apks-7 --dir release/current' ]] ||
	die 'feed artifact download escaped the passing run identity'
! grep -Eq 'uses: [^ ]+@v[0-9]' "$workflow" || die 'publication actions must use immutable commits'
[[ $(grep -Ec 'uses: [^ ]+@[0-9a-f]{40}( |$)' "$workflow") == 4 ]] ||
	die 'publication action pins are missing'
grep -Fq 'alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40' "$workflow" ||
	die 'feed container is not pinned by digest'
grep -Fq 'apk add --no-cache openssl=3.5.8-r0' "$workflow" ||
	die 'feed OpenSSL dependency is not pinned'
[[ $(grep -Fc 'permissions:' "$workflow") == 3 ]] || die 'workflow permissions are not job-scoped'
grep -Fq 'branches: [main]' "$repo/.github/workflows/test.yml" || die 'tests must run on main pushes'
grep -Fq '  pull_request:' "$repo/.github/workflows/test.yml" || die 'tests must run on pull requests'
! grep -Eq '^ +tags:' "$repo/.github/workflows/test.yml" || die 'release tags must not duplicate commit tests'
! grep -REq 'uses: [^ ]+@v[0-9]' "$repo/.github/workflows" ||
	die 'workflow actions must use immutable commits'
! grep -Fq "if: github.event_name != 'pull_request'" "$repo/.github/workflows/test.yml" ||
	die 'full tests must run on pull requests'
grep -Fq 'bash scripts/prepare-test-sdk.sh "$RUNNER_TEMP/openwrt-sdk" "$GITHUB_WORKSPACE"' \
	"$repo/.github/workflows/test.yml" || die 'CI does not prepare a real OpenWrt SDK'
grep -Fq 'NO_DEPS=1 JOBS=2 bash scripts/build-apk.sh' "$repo/.github/workflows/test.yml" ||
	die 'CI does not build and verify real APKs'
grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' \
	"$repo/.github/workflows/test.yml" || die 'CI artifact upload is not pinned'
grep -Fq "if: github.event_name == 'push'" "$repo/.github/workflows/test.yml" ||
	die 'release artifacts must come from main push tests'
grep -Fq 'name: release-apks-${{ github.run_attempt }}' "$repo/.github/workflows/test.yml" ||
	die 'release artifact name does not distinguish rerun attempts'
grep -Fq 'path: ${{ runner.temp }}/real-apks/*.apk' "$repo/.github/workflows/test.yml" ||
	die 'CI does not upload its verified APKs'
grep -Eq '^LUCI_DEPENDS:=.*\+dnsmasq .*\+firewall4 ' "$repo/luci-app-adguardhome/Makefile" ||
	die 'runtime DNS dependencies are incomplete'
grep -Fq 'openwrt-sdk-25.12.0-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst' \
	"$repo/scripts/prepare-test-sdk.sh" || die 'test SDK URL is not pinned'
grep -Fq '9f371906ce6d2f95418f69fac06df58bf9df0ffc4abed6206c30f1b547fcfc12' \
	"$repo/scripts/prepare-test-sdk.sh" || die 'test SDK checksum is not pinned'

gate=$(awk '
 /name: Require passing tests/ { selected=1 }
 selected && /run: \|/ { active=1; next }
 active && /      - name:/ { exit }
 active { sub(/^          /, ""); print }
' "$workflow")
[[ -n $gate ]] || die 'release commit test gate is missing'
for outcome in success failure pending empty commit-error runs-error invalid-commit empty-commit \
	invalid-run invalid-attempt invalid-run-sha mismatched-run-sha extra-run \
	full-missing full-skipped full-failure invalid-full-attempt extra-full jobs-error \
	partial-rerun; do
	gate_rc=0
	: >"$temporary/gate-output"
	OUTCOME=$outcome GATE="$gate" CURRENT_TAG=v3.0.0-r2 \
		GITHUB_REPOSITORY=test/project GITHUB_OUTPUT="$temporary/gate-output" bash -c '
		gh() {
			[[ $1 == api ]] || return 9
			if [[ $2 == "repos/test/project/actions/runs/123/jobs?filter=all&per_page=100" ]]; then
				case "$OUTCOME" in
					jobs-error) return 7 ;;
					full-missing) return 0 ;;
					full-skipped) printf "skipped 1\n" ;;
					full-failure) printf "failure 1\n" ;;
					invalid-full-attempt) printf "success invalid\n" ;;
					extra-full) printf "success 1 extra\n" ;;
					partial-rerun) printf "success 1\n" ;;
					*) printf "success 1\n" ;;
				esac
				return
			fi
			case "$2" in
				repos/test/project/commits/v3.0.0-r2)
					[[ $OUTCOME != commit-error ]] || return 7
					[[ $OUTCOME != empty-commit ]] || return 0
					if [[ $OUTCOME == invalid-commit ]]; then printf "not-a-sha\n"
					else printf "%040d\n" 1; fi ;;
				"repos/test/project/actions/workflows/test.yml/runs?head_sha=$(printf "%040d" 1)&event=push&per_page=1")
					[[ $OUTCOME != runs-error ]] || return 7
					case "$OUTCOME" in
						failure|pending|empty) return 0 ;;
						invalid-run) printf "not-a-run-id 1 %040d\n" 1 ;;
						invalid-attempt) printf "123 not-an-attempt %040d\n" 1 ;;
						invalid-run-sha) printf "123 1 not-a-sha\n" ;;
						mismatched-run-sha) printf "123 1 %040d\n" 2 ;;
						extra-run) printf "123 1 %040d extra\n" 1 ;;
						partial-rerun) printf "123 2 %040d\n" 1 ;;
						*) printf "123 1 %040d\n" 1 ;;
					esac ;;
				*) return 9 ;;
			esac
		}
		eval "$GATE"
	' >"$temporary/gate.log" 2>&1 || gate_rc=$?
	if [[ $outcome == success || $outcome == partial-rerun ]]; then
		[[ $gate_rc == 0 ]] || die 'passing release commit tests were rejected'
		expected_run_attempt=1
		[[ $outcome != partial-rerun ]] || expected_run_attempt=2
		[[ $(<"$temporary/gate-output") == \
			$(printf 'run_id=123\nrun_attempt=%s\nartifact_attempt=1\nhead_sha=%040d' \
				"$expected_run_attempt" 1) ]] ||
			die 'passing test run provenance was not exported'
	else
		[[ $gate_rc != 0 ]] || die "release commit gate accepted $outcome"
		[[ ! -s $temporary/gate-output ]] || die "failed gate exported $outcome"
	fi
done

fixture=$temporary/repo
sdk=$temporary/sdk
bin=$temporary/bin
package_dir=$fixture/luci-app-adguardhome
package_link=$sdk/package/feeds/local/luci-app-adguardhome
mkdir -p "$fixture/scripts" "$package_dir/root" "$bin" \
	"$sdk/feeds/base/feeds/local" "$sdk/staging_dir/host/bin"
ln -s feeds/base "$sdk/package"
cp "$repo/scripts/build-apk.sh" "$repo/scripts/verify-apk.sh" "$fixture/scripts/"
printf 'PKG_VERSION:=3.0.0\nPKG_RELEASE:=1\n' >"$package_dir/Makefile"
printf 'committed\n' >"$package_dir/root/marker"
git -C "$fixture" init -q
git -C "$fixture" config user.name Test
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" add .
git -C "$fixture" commit -qm r1
git -C "$fixture" tag v3.0.0-r1
printf 'PKG_VERSION:=3.0.0\nPKG_RELEASE:=2\n' >"$package_dir/Makefile"
git -C "$fixture" commit -qam r2
printf 'PKG_VERSION:=99.0.0\nPKG_RELEASE:=9\n' >"$package_dir/Makefile"
printf 'uncommitted\n' >"$package_dir/root/marker"
printf 'must not ship\n' >"$package_dir/root/untracked"
printf 'CONFIG_TARGET_ARCH_PACKAGES="x86_64"\n' >"$sdk/.config"
ln -s "$package_dir" "$package_link"

cat >"$bin/make" <<'SH'
#!/usr/bin/env bash
set -eu
sdk=$2
pkg=$sdk/package/feeds/local/luci-app-adguardhome
[[ -d $pkg && ! -L $pkg ]]
[[ $(<"$pkg/root/marker") == committed ]]
[[ ! -e $pkg/root/untracked ]]
[[ -z ${FAIL_BUILD:-} ]] || exit 7
[[ -z ${HANGUP_BUILD:-} ]] || { kill -HUP "$PPID"; exit 0; }
[[ " $* " == *' package/luci-app-adguardhome/compile '* ]] || exit 0
version=3.0.0-r$(sed -n 's/^PKG_RELEASE:=//p' "$pkg/Makefile")
out=$sdk/bin/packages/x86_64/local
mkdir -p "$out"
origin=$(readlink -f "$pkg")
origin=${origin#"$sdk/"}
for name in luci-app-adguardhome luci-i18n-adguardhome-zh-cn; do
	{
		printf 'info:\n  name: %s\n  version: %s\n  arch: noarch\n  origin: %s\n  depends:\n' "$name" "$version" "$origin"
		if [[ $name == luci-app-adguardhome ]]; then
			printf '    - adguardhome>=0.107.76-r1\n    - dnsmasq\n    - firewall4\n'
			hooks='pre-install post-install pre-deinstall post-deinstall pre-upgrade post-upgrade'
		else
			printf '    - luci-app-adguardhome\n'
			hooks='pre-install pre-upgrade'
		fi
		printf 'scripts:\n'
		for hook in $hooks; do
			printf '  %s: |\n    #!/bin/sh\n' "$hook"
			case "$hook" in
				pre-install|pre-upgrade)
					printf '    pending_uci_changes="$(uci -q changes 2>/dev/null)"\n'
					[[ $name != luci-app-adguardhome ]] || printf '    run_bounded 180 5 /etc/init.d/AdGuardHome stop\n' ;;
				post-install|post-upgrade)
					printf '    default_postinst\n    # AdGuard Home initialization failed; installed files were kept for repair.\n    /etc/init.d/rpcd reload\n' ;;
				pre-deinstall)
					printf '%s\n' \
						'    default_prerm' \
						"    trap 'rollback_yaml_maintenance' 0" \
						'    run_bounded 180 5 env LUCI_ADGUARDHOME_PRERM_PHASE=bounded /etc/init.d/AdGuardHome stop >/dev/null 2>&1 || exit 1' \
						'    trap - 0 HUP INT TERM'
					;;
				post-deinstall) printf '    # verified AdGuard Home removal state\n' ;;
			esac
		done
		printf '# data block\n# payload-version: %s\n' "$version"
		printf '# payload-conffile: /etc/AdGuardHome/AdGuardHome.yaml\n# payload-conffile: /root/.luci-app-adguardhome/\n'
	} >"$out/$name-$version.apk"
done
[[ -z ${BAD_CORE_DEPENDENCY:-} ]] || sed -i 's/adguardhome>=0.107.76-r1/adguardhome/' "$out/luci-app-adguardhome-$version.apk"
SH
cat >"$sdk/staging_dir/host/bin/apk" <<'SH'
#!/bin/sh
set -eu
case "$1" in
	verify) [ "$2" = --allow-untrusted ] && [ -f "$3" ] ;;
	adbdump)
		[ "$2" = --format ] && [ "$3" = yaml ]
		cat "$4" ;;
	extract)
		[ "$2" = --allow-untrusted ] && [ "$3" = --destination ] && [ -d "$4" ]
		case "$5" in
			*/luci-app-adguardhome-*)
				mkdir -p "$4/lib/apk/packages" "$4/usr/share/luci-app-adguardhome"
				if grep -q '^# payload-conffile: ' "$5"; then
					sed -n 's/^# payload-conffile: //p' "$5" >"$4/lib/apk/packages/luci-app-adguardhome.conffiles"
				fi
				sed -n 's/^# payload-version: //p' "$5" >"$4/usr/share/luci-app-adguardhome/version" ;;
		esac ;;
	mkndx)
		[ "$2" = --allow-untrusted ] && [ "$3" = --sign-key ] && [ -f "$4" ] && [ "$5" = --output ]
		printf '%s\n' "${7##*/}" "${8##*/}" >"$6" ;;
	--keys-dir) [ -f "$2/public-key.pem" ] && [ "$3" = verify ] && [ -s "$4" ] ;;
	*) exit 9 ;;
esac
SH
chmod +x "$bin/make" "$sdk/staging_dir/host/bin/apk"
build_tmp=$temporary/build-tmp
mkdir "$build_tmp"
export SDK=$sdk JOBS=1 PATH="$bin:$PATH" SOURCE_REF=HEAD TMPDIR=$build_tmp
script=$fixture/scripts/build-apk.sh
assert_build_tmp_clean() {
	! compgen -G "$build_tmp/luci-app-adguardhome-build.*" >/dev/null ||
		die 'build temporary directory was not cleaned'
}
for destination in first second; do
	OUTPUT_DIR=$temporary/$destination bash "$script"
	[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after success'
	assert_build_tmp_clean
done
for artifact in "$temporary/first/"*; do
	cmp "$artifact" "$temporary/second/${artifact##*/}"
done
archive=$temporary/first/luci-app-adguardhome-3.0.0-r2.tar.gz
[[ $(tar -xOf "$archive" luci-app-adguardhome/root/marker) == committed ]] || die 'dirty file shipped'
tar -tzf "$archive" >"$temporary/archive.list"
! grep -q untracked "$temporary/archive.list" || die 'untracked file shipped'
SOURCE_REF=v3.0.0-r1 OUTPUT_DIR=$temporary/tag bash "$script"
[[ -f $temporary/tag/luci-app-adguardhome-3.0.0-r1.apk ]] || die 'tag build used working-tree version'
assert_build_tmp_clean
if FAIL_BUILD=1 bash "$script"; then die 'build failure was ignored'; fi
[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after failure'
assert_build_tmp_clean
hangup_rc=0
HANGUP_BUILD=1 bash "$script" || hangup_rc=$?
[[ $hangup_rc == 129 ]] || die 'HUP did not stop the build with its signal status'
[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after HUP'
assert_build_tmp_clean

expect_failure() {
	local reason=$1
	shift
	if "$@" >"$temporary/failure.log" 2>&1; then die "accepted invalid input: $reason"; fi
	grep -Fq "$reason" "$temporary/failure.log" || {
		cat "$temporary/failure.log" >&2
		die "failed for the wrong reason: $reason"
	}
}
apk=$sdk/staging_dir/host/bin/apk
main_name=luci-app-adguardhome-3.0.0-r2.apk
i18n_name=luci-i18n-adguardhome-zh-cn-3.0.0-r2.apk
bad_count=0
check_apk_failure() {
	local package=$1 reason=$2 edit=$3 target=$main_name
	[[ $package != i18n ]] || target=$i18n_name
	bad_count=$((bad_count + 1))
	bad_dir=$temporary/bad-$bad_count
	mkdir "$bad_dir"
	cp "$temporary/first/"*.apk "$bad_dir/"
	sed -i "$edit" "$bad_dir/$target"
	expect_failure "$reason" sh "$repo/scripts/verify-apk.sh" "$apk" 3.0.0-r2 \
		"$bad_dir/$main_name" "$bad_dir/$i18n_name"
}
check_apk_failure main 'APK name mismatch' 's/^  name: .*/  name: unrelated/'
check_apk_failure main 'APK version mismatch' 's/^  version: .*/  version: 3.0.0-r1/'
check_apk_failure i18n 'APK version mismatch' 's/^  version: .*/  version: 3.0.0-r1/'
check_apk_failure main 'APK is not noarch' 's/^  arch: .*/  arch: x86_64/'
check_apk_failure main 'versioned adguardhome dependency' 's/adguardhome>=0.107.76-r1/adguardhome/'
check_apk_failure main 'versioned adguardhome dependency' 's/adguardhome>=0.107.76-r1/adguardhome>=0.107.0-r1/'
check_apk_failure main 'dnsmasq dependency' '/^    - dnsmasq$/d'
check_apk_failure main 'firewall4 dependency' '/^    - firewall4$/d'
check_apk_failure i18n 'luci-app-adguardhome dependency' '/^    - luci-app-adguardhome$/d'
check_apk_failure main 'conffile manifest is missing' '/^# payload-conffile:/d'
check_apk_failure main 'does not preserve its active YAML' '\|^# payload-conffile: /etc/AdGuardHome/AdGuardHome.yaml$|d'
check_apk_failure main 'does not preserve its private snapshot directory' '\|^# payload-conffile: /root/.luci-app-adguardhome/$|d'
check_apk_failure main 'embedded version does not match' 's/^# payload-version: .*/# payload-version: 3.0.0-r1/'
expect_failure 'APK filename does not match' sh "$repo/scripts/verify-apk.sh" "$apk" 3.0.0-r1 \
	"$temporary/first/$main_name" "$temporary/first/$i18n_name"
for hook in pre-install post-install pre-deinstall post-deinstall pre-upgrade post-upgrade; do
	check_apk_failure main "missing its $hook hook" "/^  $hook: |$/d"
done
check_apk_failure main 'empty post-install hook' '/^  post-install: |$/,/^  [-a-z]*: |$/{ /^    /d; }'
for hook in pre-install pre-upgrade; do
	check_apk_failure i18n "missing its $hook hook" "/^  $hook: |$/d"
	check_apk_failure main "$hook UCI guard no longer checks all default deltas" "/^  $hook: |$/,/^  [-a-z]*: |$/{ /pending_uci_changes=/d; }"
	check_apk_failure i18n "$hook UCI guard no longer checks all default deltas" "/^  $hook: |$/,/^  [-a-z]*: |$/{ /pending_uci_changes=/d; }"
	check_apk_failure main "$hook lost safe coordinator stop" "/^  $hook: |$/,/^  [-a-z]*: |$/{ /run_bounded /d; }"
done
for hook in post-install post-upgrade; do
	check_apk_failure main "$hook lost the platform installation hook" "/^  $hook: |$/,/^  [-a-z]*: |$/{ /default_postinst/d; }"
	check_apk_failure main "$hook lost initialization validation" "/^  $hook: |$/,/^  [-a-z]*: |$/{ /initialization failed/d; }"
	check_apk_failure main "$hook lost RPC reload" "/^  $hook: |$/,/^  [-a-z]*: |$/{ /rpcd reload/d; }"
done
check_apk_failure main 'platform removal hook' '/default_prerm/d'
check_apk_failure main 'safe coordinator stop' \
	'\|run_bounded 180 5 env LUCI_ADGUARDHOME_PRERM_PHASE=bounded|d'
check_apk_failure main 'cleanup ordering is incomplete' "/trap 'rollback_yaml_maintenance' 0/d"
check_apk_failure main 'may restart a service' \
	'/^    default_prerm$/a\    /etc/init.d/AdGuardHome start'
check_apk_failure main 'does not clean up around its verified stop' \
	'/^    default_prerm$/d; /^    trap - 0 HUP INT TERM$/i\    default_prerm'
check_apk_failure main 'verified cleanup state' '/verified AdGuard Home removal state/d'
expect_failure 'versioned adguardhome dependency' env BAD_CORE_DEPENDENCY=1 \
	OUTPUT_DIR="$temporary/rejected-build" bash "$script"
[[ ! -e $temporary/rejected-build ]] || die 'invalid build was published'
[[ $(readlink "$package_link") == "$package_dir" ]] || die 'SDK link not restored after APK verification failure'
assert_build_tmp_clean

# The key is disposable; the real openssl checks run, while the fake APK tool
# records the release pair entering the index without requiring an SDK.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
	-out "$temporary/private-key.pem" >/dev/null 2>&1
openssl pkey -in "$temporary/private-key.pem" -pubout \
	-out "$temporary/public-key.pem" >/dev/null 2>&1
APK_SIGNING_KEY_B64=$(base64 <"$temporary/private-key.pem" | tr -d '\n')
export APK_SIGNING_KEY_B64
publish=$repo/scripts/publish-feed.sh
sh "$publish" "$apk" "$temporary/public-key.pem" v3.0.0-r2 "$temporary/first" "$temporary/feed"
[[ $(<"$temporary/feed/packages.adb") == "$main_name"$'\n'"$i18n_name" ]] || die 'feed indexed the wrong release pair'
[[ -f $temporary/feed/$main_name && -f $temporary/feed/$i18n_name ]] || die 'current feed pair is missing'
[[ $(find "$temporary/feed" -maxdepth 1 -type f -name '*.apk' | wc -l) == 2 ]] ||
	die 'feed retained APKs outside the current release'
expect_failure 'current APK version does not match its release tag' sh "$publish" "$apk" \
	"$temporary/public-key.pem" v3.0.0-r1 "$temporary/first" "$temporary/rejected-current"
expect_failure 'Usage:' sh "$publish" "$apk" "$temporary/public-key.pem" v3.0.0-r2 \
	"$temporary/first" "$temporary/rejected-history" v3.0.0-r1 "$temporary/tag"
check_apk_failure main 'pre-upgrade UCI guard no longer checks all default deltas' '/^  pre-upgrade: |$/,/^  [-a-z]*: |$/{ /pending_uci_changes=/d; }'
expect_failure 'pre-upgrade UCI guard no longer checks all default deltas' sh "$publish" "$apk" \
	"$temporary/public-key.pem" v3.0.0-r2 "$bad_dir" "$temporary/rejected-hook"
for rejected in current history hook; do
	[[ ! -e $temporary/rejected-$rejected ]] || die "invalid $rejected feed was published"
done
printf 'release selection, pinned build inputs, APK contracts, current signed feed and SDK cleanup tests passed\n'
