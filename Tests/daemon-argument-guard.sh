#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DAEMON="${DAEMON_BINARY:-$ROOT/.build/debug/launchstationd}"
[[ -x "$DAEMON" ]] || {
  env CLANG_MODULE_CACHE_PATH=/tmp/launchstation-daemon-guard-clang-cache \
    SWIFT_MODULE_CACHE_PATH=/tmp/launchstation-daemon-guard-swift-cache \
    xcrun swift build --package-path "$ROOT" --product launchstationd --jobs 2 >/dev/null
}

ARTIFACTS=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/launchstation-daemon-argument-guard.XXXXXX")
STATE="$ARTIFACTS/state"
/bin/mkdir "$STATE"
print -rn -- 'preserve-me' > "$STATE/sentinel"

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  /bin/rm -rf -- "$ARTIFACTS"
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

set +e
env LAUNCH_STATION_STATE_DIR="$STATE" "$DAEMON" --help > "$ARTIFACTS/output.txt" 2>&1
exit_status=$?
set -e

[[ "$exit_status" == 2 ]] || {
  print -u2 -- "daemon argument guard returned $exit_status instead of 2"
  exit 1
}
/usr/bin/grep -q 'does not accept command-line arguments' "$ARTIFACTS/output.txt" || {
  print -u2 -- "daemon argument guard did not explain the refusal"
  exit 1
}
[[ "$(<"$STATE/sentinel")" == preserve-me ]] || {
  print -u2 -- "daemon argument guard changed the existing state sentinel"
  exit 1
}
[[ "$(find "$STATE" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == 1 ]] || {
  print -u2 -- "daemon argument guard wrote shared state before refusing"
  exit 1
}

print 'DAEMON ARGUMENT GUARD PASS'
