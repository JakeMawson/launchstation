#!/bin/zsh
set -euo pipefail

# Convenience entry point for repeatable release candidates. It intentionally
# claims a new output directory for every invocation and never deletes/reuses a
# prior candidate. `package-app.sh` remains the single implementation of signing,
# notarization, stapling, and verification.

umask 022

ROOT="${0:A:h:h}"
RELEASES_ROOT="$ROOT/dist/releases"

usage() {
  cat <<'EOF'
Usage:
  scripts/package-release.sh [package-app release options]

Creates a fresh UTC-stamped output root under dist/releases/ by default, then
forwards --release and every supplied option to scripts/package-app.sh.

Set OUTPUT_ROOT to claim a different fresh directory. It must not already exist.
This wrapper never overwrites, removes, or cleans a release candidate; an empty
directory is retained even if package preflight later refuses the release.

The source-controlled Resources/ReleaseTrustPolicy.plist pins the publisher and
Team ID. Required caller-supplied release inputs are therefore only:
  --signing-identity "Developer ID Application: <policy publisher> (<policy team ID>)"
  --notary-profile KEYCHAIN_PROFILE

Those two values can alternatively be supplied through the documented
CODEX_LAUNCHER_SIGNING_IDENTITY and CODEX_LAUNCHER_NOTARY_PROFILE environment
variables. --team-id, --publisher, and policy overrides are rejected so a
candidate cannot choose the installer/verifier trust root.
EOF
}

fail() {
  print -u2 -- "Release package refused: $*"
  exit 2
}

for argument in "$@"; do
  case "$argument" in
    --help|-h)
      usage
      exit 0
      ;;
    --development)
      fail "--development is incompatible with package-release.sh; use scripts/package-app.sh for developer-only bundles"
      ;;
  esac
done

app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -expect string -o - "$ROOT/Resources/Info.plist") || \
  fail "could not read the application version"
build_version=$(/usr/bin/plutil -extract CFBundleVersion raw -expect string -o - "$ROOT/Resources/Info.plist") || \
  fail "could not read the application build"

if [[ -n "${OUTPUT_ROOT:-}" ]]; then
  RELEASE_OUTPUT_ROOT="${OUTPUT_ROOT:a}"
  [[ ! -e "$RELEASE_OUTPUT_ROOT" && ! -L "$RELEASE_OUTPUT_ROOT" ]] || \
    fail "OUTPUT_ROOT already exists and will not be reused: $RELEASE_OUTPUT_ROOT"
  /bin/mkdir -p "${RELEASE_OUTPUT_ROOT:h}"
  /bin/mkdir "$RELEASE_OUTPUT_ROOT" || \
    fail "could not atomically claim OUTPUT_ROOT: $RELEASE_OUTPUT_ROOT"
else
  /bin/mkdir -p "$RELEASES_ROOT"
  timestamp=$(/bin/date -u +%Y%m%dT%H%M%SZ)
  stem="${app_version}-${build_version}-${timestamp}"
  suffix=0
  while :; do
    if (( suffix == 0 )); then
      RELEASE_OUTPUT_ROOT="$RELEASES_ROOT/$stem"
    else
      RELEASE_OUTPUT_ROOT="$RELEASES_ROOT/$stem-$suffix"
    fi
    if /bin/mkdir "$RELEASE_OUTPUT_ROOT" 2>/dev/null; then
      break
    fi
    (( suffix += 1 ))
    (( suffix <= 999 )) || fail "could not claim a fresh release output root below: $RELEASES_ROOT"
  done
fi

print "Claimed immutable release output root: $RELEASE_OUTPUT_ROOT"
exec /usr/bin/env OUTPUT_ROOT="$RELEASE_OUTPUT_ROOT" "$ROOT/scripts/package-app.sh" --release "$@"
