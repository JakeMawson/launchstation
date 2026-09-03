#!/bin/zsh
set -euo pipefail

umask 022

ROOT="${0:A:h:h}"
BUILD_PATH="${BUILD_PATH:-$ROOT/.build}"
SKILL_ROOT="$ROOT/Skills/codex-launcher"
RELEASE_TRUST_POLICY="$ROOT/Resources/ReleaseTrustPolicy.plist"
RELEASE_POLICY_LIBRARY="$ROOT/scripts/release-trust-policy.zsh"
BUILD_MODE="${CODEX_LAUNCHER_PACKAGE_MODE:-development}"
SIGNING_IDENTITY="${CODEX_LAUNCHER_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${CODEX_LAUNCHER_NOTARY_PROFILE:-}"

usage() {
  cat <<'EOF'
Usage:
  scripts/package-app.sh [--development | --release] [release options]

Development mode is the default. It creates an explicitly marked, ad-hoc signed
bundle under dist/development/ and is intentionally rejected by the release
verifier and release installers.

Release mode creates a notarized Developer ID distribution under dist/release/.
It never falls back to ad-hoc signing. The exact publisher and Team ID are read
only from the source-controlled Resources/ReleaseTrustPolicy.plist; do not pass
them on the command line. Supply the remaining release inputs either as options
or environment variables:

  --release
  --signing-identity "Developer ID Application: <policy publisher> (<policy team ID>)"
  --notary-profile KEYCHAIN_PROFILE

Environment aliases:
  CODEX_LAUNCHER_SIGNING_IDENTITY
  CODEX_LAUNCHER_NOTARY_PROFILE

The checked-in trust policy is intentionally unconfigured until its release
owner records the actual certificate identity in a reviewed source change.
Release packaging then refuses an identity that does not exactly match it.

Set OUTPUT_ROOT to choose a fresh output directory and BUILD_PATH to choose the
Swift build scratch directory. Packaging deliberately refuses to overwrite an
existing app or archive.
EOF
}

fail() {
  print -u2 -- "Package refused: $*"
  exit 2
}

require_value() {
  local option="$1"
  (($# >= 2)) || fail "$option requires a value"
}

while (($# > 0)); do
  case "$1" in
    --development)
      BUILD_MODE="development"
      shift
      ;;
    --release)
      BUILD_MODE="release"
      shift
      ;;
    --signing-identity)
      require_value "$@"
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      require_value "$@"
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --team-id|--publisher|--policy)
      fail "$1 is unsupported: release trust is pinned by Resources/ReleaseTrustPolicy.plist, not caller-supplied arguments"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

case "$BUILD_MODE" in
  development|release) ;;
  *) fail "package mode must be development or release, found: $BUILD_MODE" ;;
esac

if [[ -n "${OUTPUT_ROOT:-}" ]]; then
  OUTPUT_ROOT="${OUTPUT_ROOT:a}"
elif [[ "$BUILD_MODE" == "release" ]]; then
  OUTPUT_ROOT="$ROOT/dist/release"
else
  OUTPUT_ROOT="$ROOT/dist/development"
fi
BUNDLE="$OUTPUT_ROOT/Codex Launcher.app"

for required in SKILL.md agents/openai.yaml VERSION; do
  [[ -f "$SKILL_ROOT/$required" && ! -L "$SKILL_ROOT/$required" ]] || {
    print -u2 "Invalid bundled skill source: $SKILL_ROOT/$required must be a regular non-symlink file"
    exit 2
  }
done
[[ -f "$RELEASE_TRUST_POLICY" && ! -L "$RELEASE_TRUST_POLICY" ]] || {
  print -u2 "Invalid release trust policy source: $RELEASE_TRUST_POLICY must be a regular non-symlink file"
  exit 2
}
skill_version=$(/usr/bin/tr -d '[:space:]' < "$SKILL_ROOT/VERSION")
app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")
[[ "$skill_version" == "$app_version" ]] || {
  print -u2 "Bundled skill version $skill_version does not match app version $app_version"
  exit 2
}
[[ "$(/usr/bin/sed -n '1p' "$SKILL_ROOT/SKILL.md")" == "---" ]] || {
  print -u2 "Bundled SKILL.md is missing YAML frontmatter"
  exit 2
}
/usr/bin/grep -qx 'name: codex-launcher' "$SKILL_ROOT/SKILL.md" || {
  print -u2 "Bundled SKILL.md has the wrong skill name"
  exit 2
}
/usr/bin/grep -q '^description: .\+' "$SKILL_ROOT/SKILL.md" || {
  print -u2 "Bundled SKILL.md is missing its description"
  exit 2
}
/usr/bin/grep -qx 'interface:' "$SKILL_ROOT/agents/openai.yaml" || {
  print -u2 "Bundled agents/openai.yaml is missing interface metadata"
  exit 2
}

validate_release_configuration() {
  [[ -f "$RELEASE_POLICY_LIBRARY" && ! -L "$RELEASE_POLICY_LIBRARY" ]] || \
    fail "release trust policy loader is missing or unsafe: $RELEASE_POLICY_LIBRARY"
  source "$RELEASE_POLICY_LIBRARY"
  release_trust_policy_load "$RELEASE_TRUST_POLICY" || \
    fail "could not load the fixed release trust policy: $RELEASE_TRUST_POLICY"

  RELEASE_TEAM_ID="$RELEASE_TRUST_POLICY_TEAM_ID"
  RELEASE_PUBLISHER="$RELEASE_TRUST_POLICY_PUBLISHER"
  expected_identity="$RELEASE_TRUST_POLICY_IDENTITY"
  [[ -n "$SIGNING_IDENTITY" ]] || fail "--release requires --signing-identity; ad-hoc signing is never a release fallback"
  [[ "$SIGNING_IDENTITY" == "$expected_identity" ]] || \
    fail "--signing-identity must exactly equal the fixed release trust policy identity: $expected_identity"
  [[ -n "$NOTARY_PROFILE" && "$NOTARY_PROFILE" != *$'\n'* && "$NOTARY_PROFILE" != *$'\r'* ]] || \
    fail "--release requires a one-line --notary-profile keychain profile name"

  identity_inventory=$(/usr/bin/security find-identity -v -p codesigning 2>&1) || \
    fail "could not inspect local code-signing identities"
  if ! print -r -- "$identity_inventory" | /usr/bin/grep -Fq -- "\"$SIGNING_IDENTITY\""; then
    fail "no usable exact Developer ID Application identity is available in the active keychain for: $SIGNING_IDENTITY. Release packaging refuses ad-hoc or alternate-identity fallback. Inspect local identities with: security find-identity -v -p codesigning"
  fi

  NOTARYTOOL=$(/usr/bin/xcrun --find notarytool 2>/dev/null) || \
    fail "Xcode notarytool is unavailable; release packaging requires xcrun notarytool"
  STAPLER=$(/usr/bin/xcrun --find stapler 2>/dev/null) || \
    fail "Xcode stapler is unavailable; release packaging requires xcrun stapler"
}

if [[ "$BUILD_MODE" == "release" ]]; then
  validate_release_configuration
  NOTARY_SUBMISSION_ARCHIVE="$OUTPUT_ROOT/Codex Launcher-$app_version-notary-upload.zip"
  DISTRIBUTION_ARCHIVE="$OUTPUT_ROOT/Codex Launcher-$app_version-notarized.zip"
fi

if [[ -e "$BUNDLE" || -L "$BUNDLE" ]]; then
  print -u2 "Refusing to replace existing bundle: $BUNDLE"
  print -u2 "Choose a fresh OUTPUT_ROOT or remove it only with explicit authorization."
  exit 2
fi
if [[ "$BUILD_MODE" == "release" ]]; then
  [[ ! -e "$NOTARY_SUBMISSION_ARCHIVE" && ! -L "$NOTARY_SUBMISSION_ARCHIVE" ]] || \
    fail "refusing to replace existing notarization submission archive: $NOTARY_SUBMISSION_ARCHIVE"
  [[ ! -e "$DISTRIBUTION_ARCHIVE" && ! -L "$DISTRIBUTION_ARCHIVE" ]] || \
    fail "refusing to replace existing notarized distribution archive: $DISTRIBUTION_ARCHIVE"
fi

/usr/bin/env CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/codex-launcher-clang-cache}" \
  SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/tmp/codex-launcher-swift-cache}" \
  /usr/bin/xcrun swift build -c release --jobs 2 --scratch-path "$BUILD_PATH"

/bin/mkdir -p "$BUNDLE/Contents/MacOS"
/bin/mkdir -p "$BUNDLE/Contents/Helpers"
/bin/mkdir -p "$BUNDLE/Contents/Resources/bin"
/bin/mkdir -p "$BUNDLE/Contents/Resources/Skills"

/bin/cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
/bin/cp "$RELEASE_TRUST_POLICY" "$BUNDLE/Contents/Resources/ReleaseTrustPolicy.plist"
/bin/cp "$BUILD_PATH/release/CodexLauncher" "$BUNDLE/Contents/MacOS/CodexLauncher"
/bin/cp "$BUILD_PATH/release/codex-launcherd" "$BUNDLE/Contents/Helpers/codex-launcherd"
/bin/cp "$BUILD_PATH/release/codex-launcher-runner" "$BUNDLE/Contents/Helpers/codex-launcher-runner"
/bin/cp "$BUILD_PATH/release/launch" "$BUNDLE/Contents/Resources/bin/launch"
/usr/bin/ditto "$SKILL_ROOT" "$BUNDLE/Contents/Resources/Skills/codex-launcher"

/bin/chmod 0755 "$BUNDLE/Contents/MacOS/CodexLauncher"
/bin/chmod 0755 "$BUNDLE/Contents/Helpers/codex-launcherd"
/bin/chmod 0755 "$BUNDLE/Contents/Helpers/codex-launcher-runner"
/bin/chmod 0755 "$BUNDLE/Contents/Resources/bin/launch"
/bin/chmod 0644 "$BUNDLE/Contents/Resources/ReleaseTrustPolicy.plist"
/bin/chmod 0644 "$BUNDLE/Contents/Resources/Skills/codex-launcher/SKILL.md"
/bin/chmod 0644 "$BUNDLE/Contents/Resources/Skills/codex-launcher/VERSION"
/bin/chmod 0644 "$BUNDLE/Contents/Resources/Skills/codex-launcher/agents/openai.yaml"

PROVENANCE="$BUNDLE/Contents/Resources/BuildProvenance.plist"
if [[ "$BUILD_MODE" == "release" ]]; then
  provenance_team="$RELEASE_TEAM_ID"
  provenance_publisher="$RELEASE_PUBLISHER"
  provenance_identity="$SIGNING_IDENTITY"
else
  provenance_team="ADHOC"
  provenance_publisher="Local developer build"
  provenance_identity="-"
fi
/usr/bin/plutil -create xml1 "$PROVENANCE"
/usr/bin/plutil -insert BuildMode -string "$BUILD_MODE" "$PROVENANCE"
/usr/bin/plutil -insert PackageVersion -string "$app_version" "$PROVENANCE"
/usr/bin/plutil -insert TeamIdentifier -string "$provenance_team" "$PROVENANCE"
/usr/bin/plutil -insert Publisher -string "$provenance_publisher" "$PROVENANCE"
/usr/bin/plutil -insert SigningIdentity -string "$provenance_identity" "$PROVENANCE"
/usr/bin/plutil -lint "$PROVENANCE" >/dev/null
/bin/chmod 0644 "$PROVENANCE"

typeset -a SIGNABLES
SIGNABLES=(
  "$BUNDLE/Contents/MacOS/CodexLauncher"
  "$BUNDLE/Contents/Helpers/codex-launcherd"
  "$BUNDLE/Contents/Helpers/codex-launcher-runner"
  "$BUNDLE/Contents/Resources/bin/launch"
)

if [[ "$BUILD_MODE" == "release" ]]; then
  for signable in "${SIGNABLES[@]}"; do
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$signable"
  done
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$BUNDLE"
else
  for signable in "${SIGNABLES[@]}"; do
    /usr/bin/codesign --force --sign - "$signable"
  done
  /usr/bin/codesign --force --sign - "$BUNDLE"
fi
/usr/bin/codesign --verify --deep --strict "$BUNDLE"

if [[ "$BUILD_MODE" == "release" ]]; then
  # Keep the submitted archive as a build artifact. This avoids an implicit cleanup
  # deletion and makes the notarization input auditable alongside the final archive.
  /usr/bin/ditto -c -k --keepParent "$BUNDLE" "$NOTARY_SUBMISSION_ARCHIVE"
  "$NOTARYTOOL" submit "$NOTARY_SUBMISSION_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  "$STAPLER" staple "$BUNDLE"
  "$STAPLER" validate "$BUNDLE"
  /bin/zsh "$ROOT/scripts/verify-release-app.sh" \
    --app "$BUNDLE"
  /usr/bin/ditto -c -k --keepParent "$BUNDLE" "$DISTRIBUTION_ARCHIVE"
  print "Notarized release bundle: $BUNDLE"
  print "Notarization submission archive retained: $NOTARY_SUBMISSION_ARCHIVE"
  print "Notarized distribution archive: $DISTRIBUTION_ARCHIVE"
else
  print "Developer-only ad-hoc bundle: $BUNDLE"
  print -u2 "This bundle is intentionally rejected by scripts/verify-release-app.sh and release installers."
fi
