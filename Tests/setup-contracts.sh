#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PACKAGE="$ROOT/scripts/package-app.sh"
INSTALLER="$ROOT/scripts/install.sh"
UPGRADER="$ROOT/scripts/upgrade-installed-app.sh"
VERIFIER="$ROOT/scripts/verify-release-app.sh"
VERIFIER_CORE="$ROOT/scripts/release-verifier-core.zsh"
VERIFIER_FIXTURE="$ROOT/Tests/verify-release-app-fixture.zsh"
POLICY_LIBRARY="$ROOT/scripts/release-trust-policy.zsh"
TRUST_POLICY="$ROOT/Resources/ReleaseTrustPolicy.plist"
MOCK_CODESIGN="$ROOT/Tests/fixtures/mock-release-codesign.sh"
MOCK_SPCTL="$ROOT/Tests/fixtures/mock-release-spctl.sh"
RELEASE_PROVENANCE="$ROOT/Tests/fixtures/release-build-provenance.plist"
RELEASE_TRUST_POLICY_FIXTURE="$ROOT/Tests/fixtures/release-trust-policy.plist"
PROCESS_SUPERVISOR="$ROOT/Sources/LauncherDaemon/ProcessSupervisor.swift"
ARTIFACTS=""

fail() {
  print -u2 -- "Setup contract failure: $*"
  exit 1
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ -n "$ARTIFACTS" && -d "$ARTIFACTS" && ! -L "$ARTIFACTS" ]]; then
    if [[ "${CODEX_LAUNCHER_KEEP_SETUP_CONTRACT_ARTIFACTS:-0}" == 1 ]]; then
      print -u2 -- "Retained setup-contract artifacts: $ARTIFACTS"
    else
      /bin/rm -rf -- "$ARTIFACTS"
    fi
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_regular_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || fail "missing regular file: $path"
}

require_match() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  /usr/bin/grep -E -q -- "$pattern" "$path" || fail "$description ($path)"
}

require_no_match() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if /usr/bin/grep -E -q -- "$pattern" "$path"; then
    fail "$description ($path)"
  fi
}

first_match_line() {
  local path="$1"
  local pattern="$2"
  local result
  result=$(/usr/bin/grep -n -E -- "$pattern" "$path" | /usr/bin/head -n 1 || true)
  [[ -n "$result" ]] || return 1
  print -- "${result%%:*}"
}

require_before() {
  local path="$1"
  local earlier_pattern="$2"
  local later_pattern="$3"
  local description="$4"
  local earlier_line
  local later_line
  earlier_line=$(first_match_line "$path" "$earlier_pattern") || fail "missing earlier contract anchor for $description"
  later_line=$(first_match_line "$path" "$later_pattern") || fail "missing later contract anchor for $description"
  (( earlier_line < later_line )) || fail "$description (line $earlier_line must precede line $later_line)"
}

expect_rejected() {
  local description="$1"
  local output="$2"
  shift 2
  set +e
  "$@" > "$output" 2>&1
  local exit_status=$?
  set -e
  (( exit_status != 0 )) || fail "$description was accepted"
  /usr/bin/grep -E -i -q 'ad.?hoc|development|developer id|notariz|signature|timestamp|release' "$output" || \
    fail "$description was rejected without a release-verification reason"
}

expect_command_rejected() {
  local description="$1"
  local output="$2"
  shift 2
  set +e
  "$@" > "$output" 2>&1
  local exit_status=$?
  set -e
  (( exit_status != 0 )) || fail "$description was accepted"
}

for script in "$PACKAGE" "$INSTALLER" "$UPGRADER" "$VERIFIER" "$VERIFIER_CORE" "$VERIFIER_FIXTURE" "$POLICY_LIBRARY" "$MOCK_CODESIGN" "$MOCK_SPCTL"; do
  require_regular_file "$script"
  /bin/zsh -n "$script" || fail "shell syntax check failed: $script"
done
require_regular_file "$RELEASE_PROVENANCE"
/usr/bin/plutil -lint "$RELEASE_PROVENANCE" >/dev/null || fail 'release provenance fixture is not a valid plist'
require_regular_file "$RELEASE_TRUST_POLICY_FIXTURE"
/usr/bin/plutil -lint "$RELEASE_TRUST_POLICY_FIXTURE" >/dev/null || fail 'release trust-policy fixture is not a valid plist'
require_regular_file "$TRUST_POLICY"
/usr/bin/plutil -lint "$TRUST_POLICY" >/dev/null || fail 'source release trust policy is not a valid plist'
require_regular_file "$PROCESS_SUPERVISOR"

# Release packaging must deliberately select a development or distributable mode.
require_match "$PACKAGE" '(^|[^[:alnum:]_])(development|dev)([^[:alnum:]_]|$)' \
  'package script does not expose a development-artifact mode'
require_match "$PACKAGE" '(^|[^[:alnum:]_])(release|distribution)([^[:alnum:]_]|$)' \
  'package script does not expose a distributable release mode'
require_match "$PACKAGE" '(--mode|PACKAGE_MODE|BUILD_MODE|PACKAGE_KIND)' \
  'package mode selection is not configurable'
require_match "$PACKAGE" 'ReleaseTrustPolicy[.]plist' \
  'package script does not load the source-controlled release trust policy'
require_match "$PACKAGE" 'release_trust_policy_load' \
  'package script does not validate the source-controlled release trust policy'
require_match "$PACKAGE" 'unsupported: release trust is pinned' \
  'package script does not reject caller-supplied trust-root options'
require_match "$PACKAGE" 'Developer ID Application' \
  'package script does not require a Developer ID release identity'
require_match "$PACKAGE" 'verify-release-app[.]sh' \
  'release packaging does not invoke the shared release verifier'
require_match "$PACKAGE" 'BuildProvenance[.]plist' \
  'package script does not emit release build provenance'

# The public verifier has no caller-controlled tool/policy override; test doubles
# are reachable only through the harness stored under Tests/.
require_match "$VERIFIER" 'unsupported by the public verifier' \
  'public release verifier does not reject caller-controlled tool/policy overrides'
require_match "$VERIFIER" '/usr/bin/codesign' \
  'public release verifier does not pin the production codesign tool'
require_match "$VERIFIER" '/usr/sbin/spctl' \
  'public release verifier does not pin the production Gatekeeper tool'
require_match "$VERIFIER" 'release_verifier_verify' \
  'public release verifier does not delegate to the fixed verifier core'
require_no_match "$VERIFIER" 'TEST_TOOLS=|TEST_POLICY=|REQUESTED_CODESIGN=|REQUESTED_SPCTL=' \
  'public release verifier still exposes a caller-controlled test mode'
require_match "$VERIFIER_FIXTURE" 'Tests/|test-only|Test-only' \
  'fixture verifier is not explicitly isolated as test-only'
require_match "$VERIFIER_FIXTURE" 'release_verifier_verify.*test' \
  'fixture verifier does not select the test-only core mode'
require_match "$VERIFIER" 'ReleaseTrustPolicy[.]plist' \
  'release verifier does not load the fixed source-controlled trust policy'
require_match "$VERIFIER_CORE" 'release_trust_policy_load' \
  'release verifier does not validate the fixed source-controlled trust policy'
require_match "$VERIFIER" 'unsupported by the public verifier' \
  'release verifier does not reject caller-supplied trust-root options'
require_no_match "$VERIFIER" 'TEAM_ID="\$2"|PUBLISHER="\$2"|TEST_POLICY=' \
  'release verifier still accepts Team ID or publisher from command arguments'
require_match "$POLICY_LIBRARY" 'Developer ID Application' \
  'release verifier does not require a Developer ID authority'
require_match "$VERIFIER_CORE" 'TeamIdentifier' \
  'release verifier does not require the expected Team Identifier'
require_match "$VERIFIER_CORE" 'provenance_mode.*==.*release' \
  'release verifier does not reject non-release/ad-hoc provenance'
require_match "$VERIFIER_CORE" '(Notarized Developer ID|notariz|spctl)' \
  'release verifier does not verify Gatekeeper/notarization evidence'
require_match "$VERIFIER_CORE" 'BuildProvenance[.]plist' \
  'release verifier does not verify package build provenance'
require_match "$VERIFIER_CORE" 'PackageVersion' \
  'release verifier does not bind package provenance to the app version'
require_match "$VERIFIER_CORE" '/usr/bin/cmp[[:space:]]+-s[[:space:]]+"\$policy_path"[[:space:]]+"\$bundled_policy"' \
  'release verifier does not bind the signed candidate policy to the local trust anchor'
require_match "$VERIFIER_CORE" '"\$codesign_tool"[[:space:]]+--verify[[:space:]]+--deep[[:space:]]+--strict[[:space:]]+--verbose=2[[:space:]]+"\$app"' \
  'release verifier has a weak codesign verification invocation'
require_match "$VERIFIER_CORE" '"\$codesign_tool"[[:space:]]+-d[[:space:]]+--verbose=4[[:space:]]+"\$app"' \
  'release verifier has a malformed codesign inspection invocation'
require_match "$VERIFIER_CORE" '"\$spctl_tool"[[:space:]]+--assess[[:space:]]+--type[[:space:]]+execute[[:space:]]+--verbose=4[[:space:]]+"\$app"' \
  'release verifier has a weak Gatekeeper assessment invocation'
require_match "$VERIFIER_CORE" 'timestamp_value.*:l.*==.*"none"' \
  'release verifier does not explicitly reject an absent secure timestamp'
require_match "$MOCK_CODESIGN" '"\$1"[[:space:]]+==[[:space:]]+"--verify"' \
  'mock codesign does not assert the verification mode'
require_match "$MOCK_CODESIGN" '"\$2"[[:space:]]+==[[:space:]]+"--deep"' \
  'mock codesign does not assert deep nested verification'
require_match "$MOCK_CODESIGN" '"\$3"[[:space:]]+==[[:space:]]+"--strict"' \
  'mock codesign does not assert strict verification'
require_match "$MOCK_CODESIGN" '"\$5"[[:space:]]+==[[:space:]]+"\$expected_app"' \
  'mock codesign does not assert its exact app target'
require_match "$MOCK_SPCTL" '"\$1"[[:space:]]+!=[[:space:]]+"--assess"' \
  'mock spctl does not assert assessment mode'
require_match "$MOCK_SPCTL" '"\$5"[[:space:]]+!=[[:space:]]+"\$expected_app"' \
  'mock spctl does not assert its exact app target'

# Fresh installation must be user-scoped and prove the daemon survived bootstrap before commit.
require_match "$INSTALLER" '--destination' \
  'fresh installer has no explicit destination option'
require_match "$INSTALLER" 'ReleaseTrustPolicy[.]plist' \
  'fresh installer does not use the source-controlled release trust policy'
require_match "$INSTALLER" 'release_trust_policy_load' \
  'fresh installer does not validate the source-controlled release trust policy'
require_match "$INSTALLER" 'unsupported: the source-controlled release trust policy pins' \
  'fresh installer does not reject caller-supplied trust-root options'
require_match "$INSTALLER" 'HOME/Applications|\$HOME/Applications' \
  'fresh installer has no user Applications fallback'
require_match "$INSTALLER" 'CURRENT_UID=.*id[[:space:]]+-u' \
  'fresh installer does not obtain the invoking user identity'
require_match "$INSTALLER" 'CURRENT_UID.*(==|=).*"0"' \
  'fresh installer does not explicitly reject root execution'
require_match "$INSTALLER" '(SUDO_USER|without sudo|must not be run with sudo)' \
  'fresh installer does not explicitly reject sudo execution'
require_match "$INSTALLER" 'service[.]json' \
  'fresh installer has no daemon metadata health gate'
require_match "$INSTALLER" '(metadata_pid.*launchd_pid|launchd_pid.*metadata_pid)' \
  'fresh installer does not match launchd and daemon metadata PIDs'
require_match "$INSTALLER" '(metadata_version.*(source_version|expected_version)|(source_version|expected_version).*metadata_version)' \
  'fresh installer does not match daemon metadata and source versions'
require_match "$INSTALLER" 'doctor[[:space:]]+--json' \
  'fresh installer does not run daemon doctor after bootstrap'
require_match "$INSTALLER" 'verify-release-app[.]sh' \
  'fresh installer does not invoke release verification'
require_before "$INSTALLER" 'kickstart' 'doctor[[:space:]]+--json' \
  'fresh installer doctor must run after launchd kickstart'
require_before "$INSTALLER" 'doctor[[:space:]]+--json' 'INSTALL_COMPLETE=1' \
  'fresh installer must not commit before daemon doctor succeeds'

# Upgrades must apply the same trusted-release requirement and not revert to a fixed path.
require_match "$UPGRADER" 'verify-release-app[.]sh' \
  'upgrader does not invoke release verification'
require_match "$UPGRADER" 'ReleaseTrustPolicy[.]plist' \
  'upgrader does not use the source-controlled release trust policy'
require_match "$UPGRADER" 'release_trust_policy_load' \
  'upgrader does not validate the source-controlled release trust policy'
require_match "$UPGRADER" 'unsupported: the source-controlled release trust policy pins' \
  'upgrader does not reject caller-supplied trust-root options'
require_match "$UPGRADER" 'verify_release_app[[:space:]]+"\$SOURCE_APP"' \
  'upgrader does not verify the replacement source bundle against release policy'
require_match "$UPGRADER" 'verify_release_app[[:space:]]+"\$STAGED_APP"' \
  'upgrader does not reverify the staged replacement bundle against release policy'
require_before "$UPGRADER" '"\$SWAP_BINARY" swap "\$STAGED_APP" "\$DEST_APP"' \
  'verify_release_app[[:space:]]+"\$DEST_APP"' \
  'upgrader must verify the final installed replacement after the atomic swap'
require_match "$UPGRADER" 'ProgramArguments[.]0' \
  'upgrader does not derive the installed app from the LaunchAgent contract'
require_match "$UPGRADER" 'Contents/Helpers/codex-launcherd' \
  'upgrader does not validate the exact daemon helper suffix'
require_match "$UPGRADER" 'CURRENT_APP_OWNER_UID' \
  'upgrader does not identify a root-owned legacy application'
require_match "$UPGRADER" 'CURRENT_APP.*==.*"/Applications/Codex Launcher[.]app"' \
  'upgrader does not restrict legacy relocation to the canonical system Applications path'
require_match "$UPGRADER" 'DEST_APP=.*HOME/Applications/Codex Launcher[.]app' \
  'upgrader has no per-user destination for a root-owned legacy application'
require_match "$UPGRADER" '"\$SWAP_BINARY" install "\$STAGED_APP" "\$DEST_APP"' \
  'upgrader does not atomically install the relocated replacement without replacing the legacy app'
require_match "$UPGRADER" 'swap-file "\$STAGED_LAUNCH_AGENT" "\$LAUNCH_AGENT"' \
  'upgrader does not atomically retarget the preserved per-user LaunchAgent'
require_match "$UPGRADER" 'retarget_cli_link "\$previous_cli_target" "\$INSTALLED_CLI"' \
  'upgrader does not retarget the exact per-user CLI link during relocation'
require_match "$UPGRADER" '"\$SWAP_BINARY" install "\$DEST_APP" "\$STAGED_APP"' \
  'upgrader does not roll a failed relocation back without touching the root-owned legacy app'
require_match "$UPGRADER" 'reconciled_app_transition_state|directory_matches_identity' \
  'upgrader does not reconcile app identity after an interruptible atomic transition'
require_match "$UPGRADER" 'reconciled_launch_agent_transition_state|regular_file_matches_identity' \
  'upgrader does not reconcile LaunchAgent identity after an interruptible atomic transition'
require_match "$UPGRADER" 'reconciled_cli_link_transition_state' \
  'upgrader does not reconcile CLI-link state after an interruptible atomic transition'
require_before "$UPGRADER" 'app_transition_started=1' '"\$SWAP_BINARY" install "\$STAGED_APP" "\$DEST_APP"' \
  'relocated app transition intent must be recorded before its atomic install'
require_before "$UPGRADER" 'launch_agent_transition_started=1' 'verify_launch_agent_contract "\$LAUNCH_AGENT" "\$DEST_APP/Contents/Helpers/codex-launcherd"' \
  'LaunchAgent transition intent must be recorded before validating its forward replacement'
require_before "$UPGRADER" 'cli_link_transition_started=1' 'retarget_cli_link "\$previous_cli_target" "\$INSTALLED_CLI"' \
  'CLI-link transition intent must be recorded before retargeting'

# The daemon may be installed outside /Applications, so its runner must follow the
# daemon/app bundle it actually started from rather than a global fixed bundle path.
require_no_match "$PROCESS_SUPERVISOR" '/Applications/Codex Launcher[.]app' \
  'ProcessSupervisor still hard-codes the system Applications bundle path'
require_match "$PROCESS_SUPERVISOR" 'Contents/Helpers/codex-launcher-runner' \
  'ProcessSupervisor does not derive the runner from an enclosing app bundle'
require_match "$PROCESS_SUPERVISOR" 'Bundle[.]main[.]executableURL' \
  'ProcessSupervisor does not use its running daemon bundle as a runner candidate'
require_match "$PROCESS_SUPERVISOR" 'pathExtension[.]lowercased\(\)[[:space:]]*==[[:space:]]*"app"' \
  'ProcessSupervisor does not walk from the daemon executable to its enclosing app bundle'

# Exercise the verifier against a throwaway app and test-only signing/Gatekeeper doubles.
ARTIFACTS=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-launcher-setup-contracts.XXXXXX")
# macOS commonly exposes TMPDIR through /var, which is itself a system symlink to
# /private/var. The release-policy loader deliberately rejects *any* symlink path
# component, so canonicalize this test-only throwaway directory before passing its
# policy file to the real verifier core.
ARTIFACTS="$(cd -P -- "$ARTIFACTS" && /bin/pwd)"
APP="$ARTIFACTS/Codex Launcher.app"
TEST_CODESIGN="$ARTIFACTS/mock-codesign"
TEST_SPCTL="$ARTIFACTS/mock-spctl"
TEST_POLICY="$ARTIFACTS/release-trust-policy.plist"
/bin/mkdir -p "$APP/Contents/Resources"
/bin/cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$RELEASE_PROVENANCE" "$APP/Contents/Resources/BuildProvenance.plist"
/bin/cp "$RELEASE_TRUST_POLICY_FIXTURE" "$TEST_POLICY"
/bin/cp "$TEST_POLICY" "$APP/Contents/Resources/ReleaseTrustPolicy.plist"
/bin/cp "$MOCK_CODESIGN" "$TEST_CODESIGN"
/bin/cp "$MOCK_SPCTL" "$TEST_SPCTL"
/bin/chmod 0700 "$TEST_CODESIGN" "$TEST_SPCTL"

run_verifier() {
  env \
    MOCK_RELEASE_SIGNATURE="$1" \
    MOCK_RELEASE_NOTARIZATION="$2" \
    /bin/zsh "$VERIFIER_FIXTURE" \
      --app "$APP" \
      --codesign "$TEST_CODESIGN" \
      --spctl "$TEST_SPCTL" \
      --policy "$TEST_POLICY"
}

run_verifier trusted notarized > "$ARTIFACTS/trusted-release.txt" 2>&1 || \
  fail 'trusted Developer ID/notarized release fixture was rejected'
expect_rejected 'ad-hoc release fixture' "$ARTIFACTS/adhoc.txt" \
  run_verifier adhoc notarized
/usr/bin/plutil -replace BuildMode -string development "$APP/Contents/Resources/BuildProvenance.plist"
expect_rejected 'development build-provenance fixture' "$ARTIFACTS/development-provenance.txt" \
  run_verifier trusted notarized
/bin/cp "$RELEASE_PROVENANCE" "$APP/Contents/Resources/BuildProvenance.plist"
expect_rejected 'development-signed release fixture' "$ARTIFACTS/development.txt" \
  run_verifier development notarized
expect_rejected 'trusted identity without a secure timestamp' "$ARTIFACTS/no-timestamp.txt" \
  run_verifier trusted-no-timestamp notarized
expect_rejected 'non-notarized release fixture' "$ARTIFACTS/not-notarized.txt" \
  run_verifier trusted developer-id

/usr/bin/plutil -replace Publisher -string 'Different Publisher' "$APP/Contents/Resources/ReleaseTrustPolicy.plist"
expect_rejected 'candidate-supplied release trust policy mismatch' "$ARTIFACTS/policy-mismatch.txt" \
  run_verifier trusted notarized
/bin/cp "$TEST_POLICY" "$APP/Contents/Resources/ReleaseTrustPolicy.plist"

expect_rejected 'public verifier test-tool override' "$ARTIFACTS/unguarded-test-tools.txt" \
  /bin/zsh "$VERIFIER" \
    --app "$APP" \
    --mode release \
    --codesign "$TEST_CODESIGN" \
    --spctl "$TEST_SPCTL" \
    --test-tools
/usr/bin/grep -E -i -q 'unsupported|public verifier|fixed' "$ARTIFACTS/unguarded-test-tools.txt" || \
  fail 'public verifier did not explain that test/tool overrides are unavailable'

expect_rejected 'caller-supplied verifier Team ID' "$ARTIFACTS/caller-team-id.txt" \
  /bin/zsh "$VERIFIER" \
    --app "$APP" \
    --team-id ABCDE12345

expect_command_rejected 'mock codesign weak verification invocation' "$ARTIFACTS/mock-codesign-weak.txt" \
  env MOCK_RELEASE_EXPECTED_APP="$APP" "$TEST_CODESIGN" --verify "$APP"
expect_command_rejected 'mock codesign wrong app target' "$ARTIFACTS/mock-codesign-wrong-target.txt" \
  env MOCK_RELEASE_EXPECTED_APP="$APP" "$TEST_CODESIGN" --verify --deep --strict --verbose=2 "$ARTIFACTS/other.app"
expect_command_rejected 'mock spctl weak assessment invocation' "$ARTIFACTS/mock-spctl-weak.txt" \
  env MOCK_RELEASE_EXPECTED_APP="$APP" "$TEST_SPCTL" --assess "$APP"
expect_command_rejected 'mock spctl wrong app target' "$ARTIFACTS/mock-spctl-wrong-target.txt" \
  env MOCK_RELEASE_EXPECTED_APP="$APP" "$TEST_SPCTL" --assess --type execute --verbose=4 "$ARTIFACTS/other.app"

print 'Setup contract tests PASS'
