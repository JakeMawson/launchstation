#!/bin/zsh
set -euo pipefail

umask 077

LABEL="com.jakemawson.launchstation.service"
EXPECTED_BUNDLE_ID="com.jakemawson.launchstation"
MODE="install"
APP_PATH=""

fail() {
  print -u2 -- "Launch Station setup refused: $*"
  exit 2
}

usage() {
  print -u2 -- "usage: configure-homebrew-user.sh [--install APP_PATH | --uninstall]"
}

while (( $# > 0 )); do
  case "$1" in
    --install)
      (( $# >= 2 )) || fail "--install requires an absolute app path"
      MODE="install"
      APP_PATH="$2"
      shift 2
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $1"
      ;;
  esac
done

CURRENT_UID=$(/usr/bin/id -u)
[[ "$CURRENT_UID" != "0" && -z "${SUDO_USER:-}" && -z "${SUDO_UID:-}" && -z "${SUDO_COMMAND:-}" ]] || \
  fail "run as the logged-in user without sudo"

DOMAIN="gui/$CURRENT_UID"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIRECTORY="$HOME/Library/Application Support/Launch Station"
LOG_DIRECTORY="$HOME/Library/Logs/Launch Station"

require_real_directory() {
  [[ -d "$1" && ! -L "$1" ]] || fail "$2 must be a real directory: $1"
}

require_regular_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "$2 must be a regular file: $1"
}

require_user_owned() {
  [[ "$(/usr/bin/stat -f '%u' "$1")" == "$CURRENT_UID" ]] || fail "$2 is not owned by the current user: $1"
}

job_is_loaded() {
  /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

if [[ "${LAUNCH_STATION_SETUP_MODE:-}" == "verify-only" ]]; then
  MODE="verify"
fi

if [[ "$MODE" == "uninstall" ]]; then
  if job_is_loaded; then
    /bin/launchctl bootout "$DOMAIN/$LABEL"
  fi
  if [[ -e "$LAUNCH_AGENT" || -L "$LAUNCH_AGENT" ]]; then
    require_regular_file "$LAUNCH_AGENT" "installed LaunchAgent"
    require_user_owned "$LAUNCH_AGENT" "installed LaunchAgent"
    [[ "$(/usr/bin/plutil -extract Label raw -expect string -o - "$LAUNCH_AGENT" 2>/dev/null)" == "$LABEL" ]] || \
      fail "installed LaunchAgent has an unexpected label"
    /bin/rm -f -- "$LAUNCH_AGENT"
  fi
  print -- "Removed the Launch Station service contract. Launcher data was preserved."
  exit 0
fi

[[ -n "$APP_PATH" && "$APP_PATH" == /* && "$APP_PATH" != *$'\n'* && "$APP_PATH" != *$'\r'* && "$APP_PATH" != *'"'* && "$APP_PATH" != *'\\'* ]] || \
  fail "--install requires a one-line absolute app path"
APP_PATH="${APP_PATH:a}"
require_real_directory "$APP_PATH" "application bundle"
require_regular_file "$APP_PATH/Contents/Info.plist" "application Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null)" == "$EXPECTED_BUNDLE_ID" ]] || \
  fail "application bundle identifier is not $EXPECTED_BUNDLE_ID"
[[ -x "$APP_PATH/Contents/Helpers/launchstationd" && ! -L "$APP_PATH/Contents/Helpers/launchstationd" ]] || \
  fail "application daemon is missing or unsafe"
/usr/bin/codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 || \
  fail "application code signature is invalid"

TEMPLATE="$APP_PATH/Contents/Resources/LaunchStationLaunchAgent.plist"
require_regular_file "$TEMPLATE" "bundled LaunchAgent template"

if [[ "$MODE" == "verify" ]]; then
  print -- "Verified Launch Station Homebrew application payload."
  exit 0
fi

require_real_directory "$HOME" "home directory"
require_user_owned "$HOME" "home directory"
require_real_directory "$HOME/Library" "Library directory"
require_real_directory "$HOME/Library/Application Support" "Application Support directory"
require_real_directory "$HOME/Library/Logs" "Logs directory"
require_real_directory "$HOME/Library/LaunchAgents" "LaunchAgents directory"

for directory in "$STATE_DIRECTORY" "$LOG_DIRECTORY"; do
  if [[ -e "$directory" || -L "$directory" ]]; then
    require_real_directory "$directory" "managed directory"
    require_user_owned "$directory" "managed directory"
  else
    /bin/mkdir -m 0700 "$directory"
  fi
done

temporary_agent="$HOME/Library/LaunchAgents/.$LABEL.$$.tmp"
[[ ! -e "$temporary_agent" && ! -L "$temporary_agent" ]] || fail "temporary LaunchAgent path already exists"
cleanup() {
  /bin/rm -f -- "$temporary_agent"
}
trap cleanup EXIT INT TERM

/bin/cp "$TEMPLATE" "$temporary_agent"
daemon_path="$APP_PATH/Contents/Helpers/launchstationd"
/usr/bin/plutil -replace ProgramArguments -json "[\"$daemon_path\"]" "$temporary_agent"
/usr/bin/plutil -replace EnvironmentVariables.PATH -string "$HOME/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin" "$temporary_agent"
/usr/bin/plutil -replace StandardOutPath -string "$LOG_DIRECTORY/service.log" "$temporary_agent"
/usr/bin/plutil -replace StandardErrorPath -string "$LOG_DIRECTORY/service-error.log" "$temporary_agent"
/bin/chmod 0600 "$temporary_agent"
/usr/bin/plutil -lint "$temporary_agent" >/dev/null

if [[ -e "$LAUNCH_AGENT" || -L "$LAUNCH_AGENT" ]]; then
  require_regular_file "$LAUNCH_AGENT" "installed LaunchAgent"
  require_user_owned "$LAUNCH_AGENT" "installed LaunchAgent"
  if /usr/bin/cmp -s "$temporary_agent" "$LAUNCH_AGENT"; then
    /bin/rm -f -- "$temporary_agent"
  else
    job_is_loaded && fail "a loaded Launch Station service uses a different app path; leave it running and reconcile it explicitly"
    /bin/mv -f "$temporary_agent" "$LAUNCH_AGENT"
  fi
else
  /bin/mv "$temporary_agent" "$LAUNCH_AGENT"
fi

trap - EXIT INT TERM
if ! job_is_loaded; then
  /bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT"
fi
/bin/launchctl kickstart "$DOMAIN/$LABEL"

# Homebrew should not return a successful install while the authenticated local
# API is still racing launchd startup. This is a read-only catalog request; it
# neither creates nor rewrites launcher records, and the client has its own
# bounded readiness/recovery policy.
LAUNCH_CLI="$APP_PATH/Contents/Resources/bin/launch"
[[ -x "$LAUNCH_CLI" && ! -L "$LAUNCH_CLI" ]] || fail "application CLI is missing or unsafe"
service_ready=false
for attempt in {1..30}; do
  if "$LAUNCH_CLI" list --json >/dev/null 2>&1; then
    service_ready=true
    break
  fi
  (( attempt < 30 )) && /bin/sleep 1
done
[[ "$service_ready" == "true" ]] || \
  fail "the Launch Station service did not become ready after installation"

print -- "Configured Launch Station for the current user. Existing launcher data was not modified."
