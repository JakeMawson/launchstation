#!/bin/zsh
# Check or explicitly synchronize a verified local development bundle with the
# installed app. This intentionally does not manage the daemon or any sessions.
set -euo pipefail

ROOT="${0:A:h:h}"
EXPECTED_BUNDLE_ID="com.jakemawson.codex-launcher"
SWAP_SOURCE="$ROOT/scripts/atomic-directory-swap.swift"
MODE="check"
DESTINATION="/Applications/Codex Launcher.app"
SOURCE_APP=""

fail() {
  print -u2 "sync-development-app: $1"
  exit "${2:-2}"
}

usage() {
  print -u2 "usage: scripts/sync-development-app.sh [--check | --sync --verified-development-bundle] [--destination ABSOLUTE_APP_PATH] ABSOLUTE_CANDIDATE_APP"
}

while (( $# > 0 )); do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --sync)
      MODE="sync"
      shift
      ;;
    --verified-development-bundle)
      VERIFIED_ACKNOWLEDGEMENT=1
      shift
      ;;
    --destination)
      (( $# >= 2 )) || fail "--destination requires an absolute app-bundle path"
      DESTINATION="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      (( $# == 1 )) || { usage; fail "supply exactly one candidate app bundle"; }
      SOURCE_APP="$1"
      break
      ;;
    -*)
      usage
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$SOURCE_APP" ]] || { usage; fail "supply exactly one candidate app bundle"; }
      SOURCE_APP="$1"
      shift
      ;;
  esac
done

[[ -n "$SOURCE_APP" ]] || { usage; fail "an explicit candidate app bundle is required"; }
[[ "$SOURCE_APP" == /* && "$DESTINATION" == /* ]] || fail "candidate and destination paths must be absolute"
[[ "$SOURCE_APP" != *$'\n'* && "$DESTINATION" != *$'\n'* ]] || fail "paths must not contain line breaks"
[[ "${SOURCE_APP:t}" == *.app && "${DESTINATION:t}" == *.app ]] || fail "candidate and destination must be .app bundles"

SOURCE_APP="${SOURCE_APP:a}"
DESTINATION="${DESTINATION:a}"
DESTINATION_PARENT="${DESTINATION:h}"

require_real_directory() {
  [[ -d "$1" && ! -L "$1" ]] || fail "required directory is missing or unsafe: $1"
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw -expect string -o - "$1" 2>/dev/null ||
    fail "missing or invalid $2 in $1"
}

sha256() {
  /usr/bin/shasum -a 256 "$1/Contents/MacOS/CodexLauncher" | /usr/bin/awk '{print $1}'
}

validate_app() {
  local app="$1"
  require_real_directory "$app"
  [[ -f "$app/Contents/Info.plist" && ! -L "$app/Contents/Info.plist" ]] ||
    fail "app bundle has no safe Info.plist: $app"
  [[ -x "$app/Contents/MacOS/CodexLauncher" && ! -L "$app/Contents/MacOS/CodexLauncher" ]] ||
    fail "app bundle has no safe CodexLauncher executable: $app"
  [[ "$(plist_value "$app/Contents/Info.plist" CFBundleIdentifier)" == "$EXPECTED_BUNDLE_ID" ]] ||
    fail "app bundle identity is not $EXPECTED_BUNDLE_ID: $app"
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 ||
    fail "code-signature verification failed: $app"
}

validate_development_candidate() {
  local provenance="$1/Contents/Resources/BuildProvenance.plist"
  validate_app "$1"
  [[ -f "$provenance" && ! -L "$provenance" ]] ||
    fail "candidate has no safe BuildProvenance.plist: $1"
  [[ "$(plist_value "$provenance" BuildMode)" == "development" ]] ||
    fail "candidate is not an explicitly development-marked bundle: $1"
}

version_relation() {
  /usr/bin/python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys

def numeric(value, label):
    parts = value.split('.')
    if not parts or any(not part.isdecimal() for part in parts):
        raise SystemExit(f"{label} must be numeric: {value}")
    return tuple(int(part) for part in parts)

candidate = (numeric(sys.argv[1], "candidate version"), numeric(sys.argv[3], "candidate build"))
installed = (numeric(sys.argv[2], "installed version"), numeric(sys.argv[4], "installed build"))
print("newer" if candidate > installed else "same" if candidate == installed else "older")
PY
}

require_real_directory "$DESTINATION_PARENT"
validate_development_candidate "$SOURCE_APP"
validate_app "$DESTINATION"

CANDIDATE_VERSION="$(plist_value "$SOURCE_APP/Contents/Info.plist" CFBundleShortVersionString)"
CANDIDATE_BUILD="$(plist_value "$SOURCE_APP/Contents/Info.plist" CFBundleVersion)"
INSTALLED_VERSION="$(plist_value "$DESTINATION/Contents/Info.plist" CFBundleShortVersionString)"
INSTALLED_BUILD="$(plist_value "$DESTINATION/Contents/Info.plist" CFBundleVersion)"
CANDIDATE_HASH="$(sha256 "$SOURCE_APP")"
INSTALLED_HASH="$(sha256 "$DESTINATION")"
RELATION="$(version_relation "$CANDIDATE_VERSION" "$INSTALLED_VERSION" "$CANDIDATE_BUILD" "$INSTALLED_BUILD")" || fail "could not compare bundle versions"

print "candidate: $SOURCE_APP — $CANDIDATE_VERSION ($CANDIDATE_BUILD) — $CANDIDATE_HASH"
print "installed: $DESTINATION — $INSTALLED_VERSION ($INSTALLED_BUILD) — $INSTALLED_HASH"

if [[ "$RELATION" == "same" && "$CANDIDATE_HASH" == "$INSTALLED_HASH" ]]; then
  print "status: CURRENT (installed app exactly matches candidate)"
  exit 0
fi

if [[ "$RELATION" != "newer" ]]; then
  fail "candidate is $RELATION but differs from the installed bundle; refuse a non-increasing build"
fi

print "status: CANDIDATE_NEWER"
if [[ "$MODE" == "check" ]]; then
  exit 0
fi

[[ "${VERIFIED_ACKNOWLEDGEMENT:-0}" == "1" ]] ||
  fail "--sync requires --verified-development-bundle after tests and package verification"
[[ -w "$DESTINATION_PARENT" ]] || fail "destination parent is not writable: $DESTINATION_PARENT"
[[ ! -L "$DESTINATION" ]] || fail "destination must not be a symlink: $DESTINATION"

STAGE_ROOT=$(/usr/bin/mktemp -d "$DESTINATION_PARENT/.Codex Launcher sync-stage.XXXXXX") ||
  fail "could not create a private staging directory in $DESTINATION_PARENT"
/bin/chmod 700 "$STAGE_ROOT"
STAGED_APP="$STAGE_ROOT/Codex Launcher.app"
BACKUP_NAME="Codex Launcher build ${INSTALLED_BUILD} backup $(/bin/date -u +%Y%m%dT%H%M%SZ).app"
BACKUP_APP="$HOME/.Trash/$BACKUP_NAME"
[[ ! -e "$BACKUP_APP" && ! -L "$BACKUP_APP" ]] || fail "refusing an occupied backup path: $BACKUP_APP"

/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
validate_development_candidate "$STAGED_APP"
[[ "$(sha256 "$STAGED_APP")" == "$CANDIDATE_HASH" ]] || fail "staged executable hash differs from candidate"

env CLANG_MODULE_CACHE_PATH=/tmp/codex-launcher-sync-clang-cache \
  SWIFT_MODULE_CACHE_PATH=/tmp/codex-launcher-sync-swift-cache \
  /usr/bin/xcrun swift "$SWAP_SOURCE" swap "$STAGED_APP" "$DESTINATION"

# The staged pathname now identifies the outgoing installed app. Preserve it;
# never remove it. Only the now-empty private staging directory is removed.
/bin/mv "$STAGED_APP" "$BACKUP_APP"
/bin/rmdir "$STAGE_ROOT"

validate_development_candidate "$DESTINATION"
[[ "$(sha256 "$DESTINATION")" == "$CANDIDATE_HASH" ]] || fail "post-sync executable hash differs from candidate"
print "status: SYNCED"
print "backup: $BACKUP_APP"
print "note: the daemon and any running sessions were intentionally not restarted"
