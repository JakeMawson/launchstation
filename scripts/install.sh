#!/bin/zsh
set -euo pipefail

umask 022

ROOT="${0:A:h:h}"
LABEL="com.jakemawson.codex-launcher.service"
LAUNCH_AGENT_TEMPLATE="$ROOT/Resources/com.jakemawson.codex-launcher.service.plist"
EXPECTED_BUNDLE_ID="com.jakemawson.codex-launcher"
EXPECTED_PATH="$HOME/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
TEMPLATE_PROGRAM="/Applications/Codex Launcher.app/Contents/Helpers/codex-launcherd"
RELEASE_VERIFIER="$ROOT/scripts/verify-release-app.sh"
RELEASE_TRUST_POLICY="$ROOT/Resources/ReleaseTrustPolicy.plist"
RELEASE_POLICY_LIBRARY="$ROOT/scripts/release-trust-policy.zsh"

SOURCE_APP_ARGUMENT=""
DESTINATION_ARGUMENT=""
CURRENT_UID=""
DOMAIN=""
DEST_APP=""
DEST_PARENT=""
DESTINATION_PARENT_NEEDS_CREATION=0
LAUNCH_AGENT=""
LAUNCH_AGENT_TMP=""
CLI_LINK=""
CLI_TARGET=""
STATE_DIR=""
RUNS_DIR=""
LOG_DIR=""
EXPECTED_PROGRAM=""
EXPECTED_STDOUT=""
EXPECTED_STDERR=""

typeset -a CREATED_DIR_PATHS
typeset -a CREATED_DIR_IDENTITIES
typeset -i INSTALL_COMPLETE=0
typeset -i DEST_CREATED=0
typeset -i LAUNCH_AGENT_CREATED=0
typeset -i CLI_CREATED=0
typeset -i BOOTSTRAPPED=0
typeset -i STATE_MODE_CHANGED=0
typeset -i RUNS_MODE_CHANGED=0
DEST_IDENTITY=""
LAUNCH_AGENT_IDENTITY=""
LAUNCH_AGENT_TMP_IDENTITY=""
CLI_IDENTITY=""
STATE_ORIGINAL_MODE=""
RUNS_ORIGINAL_MODE=""
STATE_IDENTITY=""
RUNS_IDENTITY=""

fail() {
  print -u2 -- "Install refused: $*"
  return 1
}

usage() {
  print -u2 -- "usage: scripts/install.sh [--destination ABSOLUTE_APP_PATH] [ABSOLUTE_SOURCE_APP]"
}

require_release_policy() {
  if ! [[ -f "$RELEASE_POLICY_LIBRARY" && ! -L "$RELEASE_POLICY_LIBRARY" ]]; then
    fail "Release trust policy loader is missing or unsafe: $RELEASE_POLICY_LIBRARY"
    return 1
  fi
  source "$RELEASE_POLICY_LIBRARY"
  if ! release_trust_policy_load "$RELEASE_TRUST_POLICY"; then
    fail "Could not load the fixed release trust policy: $RELEASE_TRUST_POLICY"
    return 1
  fi
  TRUSTED_RELEASE_TEAM_ID="$RELEASE_TRUST_POLICY_TEAM_ID"
  TRUSTED_RELEASE_PUBLISHER="$RELEASE_TRUST_POLICY_PUBLISHER"
  if ! [[ -f "$RELEASE_VERIFIER" && ! -L "$RELEASE_VERIFIER" ]]; then
    fail "Release verifier is missing or unsafe: $RELEASE_VERIFIER"
    return 1
  fi
}

verify_release_app() {
  local app="$1"
  if ! /bin/zsh "$RELEASE_VERIFIER" --app "$app"; then
    fail "Application bundle did not satisfy the pinned release-signing policy: $app"
    return 1
  fi
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --team-id|--publisher|--policy)
        usage
        fail "$1 is unsupported: the source-controlled release trust policy pins the publisher and Team ID"
        return 1
        ;;
      --destination)
        if (( $# < 2 )); then
          usage
          fail "--destination requires an absolute app-bundle path"
          return 1
        fi
        DESTINATION_ARGUMENT="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        if (( $# > 1 )); then
          usage
          fail "only one source app path may be supplied"
          return 1
        fi
        if (( $# == 1 )); then SOURCE_APP_ARGUMENT="$1"; fi
        break
        ;;
      -*)
        usage
        fail "Unknown option: $1"
        return 1
        ;;
      *)
        if [[ -n "$SOURCE_APP_ARGUMENT" ]]; then
          usage
          fail "only one source app path may be supplied"
          return 1
        fi
        SOURCE_APP_ARGUMENT="$1"
        shift
        ;;
    esac
  done
}

select_destination() {
  local candidate

  if [[ -n "$DESTINATION_ARGUMENT" ]]; then
    if [[ "$DESTINATION_ARGUMENT" != /* ]]; then
      fail "--destination must be an absolute app-bundle path: $DESTINATION_ARGUMENT"
      return 1
    fi
    candidate="$DESTINATION_ARGUMENT"
  elif [[ -d "/Applications" && ! -L "/Applications" && -w "/Applications" ]]; then
    candidate="/Applications/Codex Launcher.app"
  else
    candidate="$HOME/Applications/Codex Launcher.app"
    DESTINATION_PARENT_NEEDS_CREATION=1
  fi

  DEST_APP="${candidate:a}"
  if ! [[ "$DEST_APP" == /* && "$DEST_APP" != "/" && "${DEST_APP:t}" == *.app ]]; then
    fail "Destination must be an absolute .app bundle path: $DEST_APP"
    return 1
  fi
  DEST_PARENT="${DEST_APP:h}"
  CLI_TARGET="$DEST_APP/Contents/Resources/bin/launch"
  EXPECTED_PROGRAM="$DEST_APP/Contents/Helpers/codex-launcherd"
}

path_identity() {
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

require_real_directory() {
  local path="$1"
  local description="$2"
  if [[ ! -d "$path" || -L "$path" ]]; then
    fail "$description must be a real directory, not a file, symlink, or dangling symlink: $path"
  fi
}

require_regular_file() {
  local path="$1"
  local description="$2"
  if [[ ! -f "$path" || -L "$path" ]]; then
    fail "$description must be a regular non-symlink file: $path"
  fi
}

require_executable_file() {
  local path="$1"
  local description="$2"
  require_regular_file "$path" "$description"
  if [[ ! -x "$path" ]]; then
    fail "$description is not executable: $path"
  fi
}

require_absent() {
  local path="$1"
  local description="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    fail "$description already exists (including a dangling symlink): $path"
  fi
}

require_no_symlink_chain() {
  local cursor="$1"
  local description="$2"
  while [[ "$cursor" != "/" ]]; do
    if [[ -L "$cursor" ]]; then
      fail "$description contains a symlink path component: $cursor"
    fi
    cursor="${cursor:h}"
  done
}

plist_value_equals() {
  local plist="$1"
  local key_path="$2"
  local expected="$3"
  local expected_type="$4"
  local actual
  actual=$(/usr/bin/plutil -extract "$key_path" raw -expect "$expected_type" -o - "$plist" 2>/dev/null) || \
    fail "LaunchAgent is missing $key_path or it is not type $expected_type: $plist"
  if [[ "$actual" != "$expected" ]]; then
    fail "LaunchAgent $key_path is not the expected value: $plist"
  fi
}

validate_launch_agent() {
  local plist="$1"
  local expected_program="$2"
  local expected_path="$3"
  local expected_stdout="$4"
  local expected_stderr="$5"
  local printed
  local top_level_count
  local nested_key_count
  local array_item_count

  require_regular_file "$plist" "LaunchAgent plist"
  /usr/bin/plutil -lint "$plist" >/dev/null || fail "LaunchAgent plist is invalid: $plist"

  plist_value_equals "$plist" Label "$LABEL" string
  plist_value_equals "$plist" ProgramArguments.0 "$expected_program" string
  if /usr/bin/plutil -extract ProgramArguments.1 raw -o - "$plist" >/dev/null 2>&1; then
    fail "LaunchAgent has unexpected additional program arguments: $plist"
  fi
  plist_value_equals "$plist" RunAtLoad true bool
  plist_value_equals "$plist" KeepAlive.SuccessfulExit false bool
  plist_value_equals "$plist" ProcessType Background string
  plist_value_equals "$plist" EnvironmentVariables.LANG en_US.UTF-8 string
  plist_value_equals "$plist" EnvironmentVariables.PATH "$expected_path" string
  plist_value_equals "$plist" ThrottleInterval 5 integer
  plist_value_equals "$plist" AssociatedBundleIdentifiers.0 "$EXPECTED_BUNDLE_ID" string
  if /usr/bin/plutil -extract AssociatedBundleIdentifiers.1 raw -o - "$plist" >/dev/null 2>&1; then
    fail "LaunchAgent has unexpected additional associated bundle identifiers: $plist"
  fi
  plist_value_equals "$plist" StandardOutPath "$expected_stdout" string
  plist_value_equals "$plist" StandardErrorPath "$expected_stderr" string

  printed=$(/usr/bin/plutil -p "$plist") || fail "LaunchAgent could not be inspected: $plist"
  top_level_count=$(print -r -- "$printed" | /usr/bin/grep -c '^  "[^"]*" =>')
  nested_key_count=$(print -r -- "$printed" | /usr/bin/grep -c '^    "[^"]*" =>')
  array_item_count=$(print -r -- "$printed" | /usr/bin/grep -c '^    [0-9][0-9]* =>')
  if [[ "$top_level_count" != "10" || "$nested_key_count" != "3" || "$array_item_count" != "2" ]]; then
    fail "LaunchAgent contains unexpected keys or collection entries: $plist"
  fi
}

validate_app_bundle() {
  local app="$1"
  local link
  local bundle_id
  local app_version
  local skill_version

  require_real_directory "$app" "Application bundle"
  require_no_symlink_chain "$app" "Application bundle path"

  link=$(/usr/bin/find "$app" -type l -print -quit 2>/dev/null) || \
    fail "Application bundle could not be traversed safely: $app"
  if [[ -n "$link" ]]; then
    fail "Application bundle contains a symlink entry: $link"
  fi

  require_real_directory "$app/Contents" "Application Contents"
  require_real_directory "$app/Contents/MacOS" "Application executable directory"
  require_real_directory "$app/Contents/Helpers" "Application helper directory"
  require_real_directory "$app/Contents/Resources" "Application resources directory"
  require_real_directory "$app/Contents/Resources/bin" "Application CLI directory"
  require_real_directory "$app/Contents/Resources/Skills" "Application skills directory"
  require_real_directory "$app/Contents/Resources/Skills/codex-launcher" "Bundled skill directory"
  require_real_directory "$app/Contents/Resources/Skills/codex-launcher/agents" "Bundled skill agents directory"

  require_regular_file "$app/Contents/Info.plist" "Application Info.plist"
  require_executable_file "$app/Contents/MacOS/CodexLauncher" "Application executable"
  require_executable_file "$app/Contents/Helpers/codex-launcherd" "Daemon executable"
  require_executable_file "$app/Contents/Helpers/codex-launcher-runner" "Process runner executable"
  require_executable_file "$app/Contents/Resources/bin/launch" "CLI executable"
  require_regular_file "$app/Contents/Resources/ReleaseTrustPolicy.plist" "Signed release trust policy"
  require_regular_file "$app/Contents/Resources/Skills/codex-launcher/SKILL.md" "Bundled skill"
  require_regular_file "$app/Contents/Resources/Skills/codex-launcher/VERSION" "Bundled skill version"
  require_regular_file "$app/Contents/Resources/Skills/codex-launcher/agents/openai.yaml" "Bundled skill metadata"

  bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null) || \
    fail "Application bundle identifier could not be read: $app"
  if [[ "$bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    fail "Application bundle identifier must be $EXPECTED_BUNDLE_ID, found $bundle_id"
  fi

  app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist" 2>/dev/null) || \
    fail "Application version could not be read: $app"
  skill_version=$(/usr/bin/tr -d '[:space:]' < "$app/Contents/Resources/Skills/codex-launcher/VERSION") || \
    fail "Bundled skill version could not be read: $app"
  if [[ -z "$app_version" || "$skill_version" != "$app_version" ]]; then
    fail "Bundled skill version must match application version $app_version, found $skill_version"
  fi
  if [[ "$(/usr/bin/sed -n '1p' "$app/Contents/Resources/Skills/codex-launcher/SKILL.md")" != "---" ]]; then
    fail "Bundled SKILL.md is missing YAML frontmatter: $app"
  fi
  /usr/bin/grep -qx 'name: codex-launcher' "$app/Contents/Resources/Skills/codex-launcher/SKILL.md" || \
    fail "Bundled SKILL.md has the wrong skill name: $app"
  /usr/bin/grep -q '^description: .\+' "$app/Contents/Resources/Skills/codex-launcher/SKILL.md" || \
    fail "Bundled SKILL.md is missing its description: $app"
  /usr/bin/grep -qx 'interface:' "$app/Contents/Resources/Skills/codex-launcher/agents/openai.yaml" || \
    fail "Bundled skill metadata is missing interface metadata: $app"

  /usr/bin/codesign --verify --deep --strict "$app" || \
    fail "Application bundle failed strict deep signature verification: $app"
}

wait_for_fresh_service_health() {
  local expected_version="$1"
  local launchd_pid
  local metadata_pid
  local metadata_version

  # `kickstart` only proves launchd accepted the job. Do not commit a fresh
  # install until the exact replacement daemon has published its own metadata
  # and its bundled client can authenticate a compatible health check.
  for _ in {1..200}; do
    launchd_pid=$({ /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true; } \
      | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
    metadata_pid=$(/usr/bin/plutil -extract pid raw -o - "$STATE_DIR/service.json" 2>/dev/null || true)
    metadata_version=$(/usr/bin/plutil -extract version raw -o - "$STATE_DIR/service.json" 2>/dev/null || true)
    if [[ "$launchd_pid" == <-> \
          && "$metadata_pid" == "$launchd_pid" \
          && "$metadata_version" == "$expected_version" ]]; then
      if "$CLI_TARGET" doctor --json >/dev/null; then
        return 0
      fi
    fi
    /bin/sleep 0.05
  done

  fail "The LaunchAgent did not publish healthy metadata for the exact installed daemon in time"
}

ensure_directory() {
  local path="$1"
  local mode="$2"
  local description="$3"
  local parent="${path:h}"
  local identity

  if [[ -e "$path" || -L "$path" ]]; then
    require_real_directory "$path" "$description"
    return
  fi

  require_real_directory "$parent" "$description parent"
  /bin/mkdir "$path"
  /bin/chmod "$mode" "$path"
  identity=$(path_identity "$path") || fail "Could not identify created directory: $path"
  CREATED_DIR_PATHS+=("$path")
  CREATED_DIR_IDENTITIES+=("$identity")
}

remove_owned_regular_file() {
  local path="$1"
  local identity="$2"
  [[ -n "$identity" ]] || return 0
  if [[ -f "$path" && ! -L "$path" && "$(path_identity "$path")" == "$identity" ]]; then
    /bin/rm -f "$path"
  fi
}

remove_owned_tree() {
  local path="$1"
  local identity="$2"
  [[ -n "$identity" ]] || return 0
  if [[ -d "$path" && ! -L "$path" && "$(path_identity "$path")" == "$identity" ]]; then
    /bin/rm -rf "$path"
  fi
}

rollback_install() {
  local i
  local current_identity
  local runtime_can_be_removed=1

  (( INSTALL_COMPLETE == 0 )) || return 0
  set +e

  if (( BOOTSTRAPPED == 1 )) && /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    if ! /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      runtime_can_be_removed=0
      print -u2 -- "Rollback warning: the LaunchAgent could not be stopped; installed runtime files were preserved."
    fi
  fi

  if (( runtime_can_be_removed == 1 )); then
    if (( CLI_CREATED == 1 )) && [[ -L "$CLI_LINK" && "$(path_identity "$CLI_LINK")" == "$CLI_IDENTITY" && "$(/usr/bin/readlink "$CLI_LINK" 2>/dev/null)" == "$CLI_TARGET" ]]; then
      /bin/rm -f "$CLI_LINK"
    fi
    if (( LAUNCH_AGENT_CREATED == 1 )); then
      remove_owned_regular_file "$LAUNCH_AGENT" "$LAUNCH_AGENT_IDENTITY"
    fi
    if (( DEST_CREATED == 1 )); then
      remove_owned_tree "$DEST_APP" "$DEST_IDENTITY"
    fi
  fi

  remove_owned_regular_file "$LAUNCH_AGENT_TMP" "$LAUNCH_AGENT_TMP_IDENTITY"

  if (( RUNS_MODE_CHANGED == 1 )) && [[ -d "$RUNS_DIR" && ! -L "$RUNS_DIR" && "$(path_identity "$RUNS_DIR")" == "$RUNS_IDENTITY" ]]; then
    /bin/chmod "$RUNS_ORIGINAL_MODE" "$RUNS_DIR"
  fi
  if (( STATE_MODE_CHANGED == 1 )) && [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" && "$(path_identity "$STATE_DIR")" == "$STATE_IDENTITY" ]]; then
    /bin/chmod "$STATE_ORIGINAL_MODE" "$STATE_DIR"
  fi

  for (( i=${#CREATED_DIR_PATHS}; i>=1; --i )); do
    current_identity=$(path_identity "${CREATED_DIR_PATHS[i]}")
    if [[ -d "${CREATED_DIR_PATHS[i]}" && ! -L "${CREATED_DIR_PATHS[i]}" && "$current_identity" == "${CREATED_DIR_IDENTITIES[i]}" ]]; then
      /bin/rmdir "${CREATED_DIR_PATHS[i]}" >/dev/null 2>&1
    fi
  done

  print -u2 -- "Install failed. Only installer-created artifacts with matching filesystem identities were rolled back; existing data was preserved."
}

# Reject root and sudo before parsing any installer destination or touching a
# user-scoped path. A user LaunchAgent/CLI must never be installed for root.
CURRENT_UID=$(/usr/bin/id -u)
if [[ "$CURRENT_UID" == "0" || -n "${SUDO_USER:-}" || -n "${SUDO_UID:-}" || -n "${SUDO_COMMAND:-}" ]]; then
  print -u2 -- "Install refused: Run this installer as the logged-in user without sudo; it installs a per-user LaunchAgent and ~/bin/launch"
  exit 2
fi

parse_arguments "$@"
require_release_policy

# Complete read-only preflight before changing the machine.
if [[ "$HOME" != /* ]]; then
  fail "HOME must be an absolute path: $HOME"
fi
require_real_directory "$HOME" "Home directory"
require_no_symlink_chain "$HOME" "Home directory path"
HOME_OWNER_UID=$(/usr/bin/stat -f '%u' "$HOME") || fail "Could not identify home-directory owner: $HOME"
if [[ "$HOME_OWNER_UID" != "$CURRENT_UID" ]]; then
  fail "HOME must belong to the invoking non-root user: $HOME"
  exit 2
fi
require_real_directory "$HOME/Library" "User Library directory"

SOURCE_APP="${SOURCE_APP_ARGUMENT:-$ROOT/dist/release/Codex Launcher.app}"
SOURCE_APP="${SOURCE_APP:a}"
DOMAIN="gui/$CURRENT_UID"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_LINK="$HOME/bin/launch"
STATE_DIR="$HOME/Library/Application Support/Codex Launcher"
RUNS_DIR="$STATE_DIR/Runs"
LOG_DIR="$HOME/Library/Logs/Codex Launcher"
EXPECTED_PATH="$HOME/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
EXPECTED_STDOUT="$LOG_DIR/service.log"
EXPECTED_STDERR="$LOG_DIR/service-error.log"
select_destination

require_no_symlink_chain "$DEST_APP" "Destination application path"
if (( DESTINATION_PARENT_NEEDS_CREATION == 1 )); then
  if ! [[ "$DEST_PARENT" == "$HOME/Applications" && -w "$HOME" ]]; then
    fail "Fallback user Applications directory cannot be created safely: $DEST_PARENT"
    exit 2
  fi
else
  require_real_directory "$DEST_PARENT" "Destination application parent"
  [[ -w "$DEST_PARENT" ]] || fail "Destination application parent is not writable: $DEST_PARENT"
fi

require_absent "$DEST_APP" "Destination application"
require_absent "$CLI_LINK" "CLI path"
require_absent "$LAUNCH_AGENT" "LaunchAgent"
if /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  fail "LaunchAgent label is already loaded: $DOMAIN/$LABEL"
fi

validate_app_bundle "$SOURCE_APP"
verify_release_app "$SOURCE_APP"
source_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$SOURCE_APP/Contents/Info.plist" 2>/dev/null) || \
  fail "Application version could not be read: $SOURCE_APP"
if [[ -z "$source_version" ]]; then
  fail "Application version is empty: $SOURCE_APP"
  exit 2
fi
require_no_symlink_chain "$LAUNCH_AGENT_TEMPLATE" "LaunchAgent template path"
validate_launch_agent \
  "$LAUNCH_AGENT_TEMPLATE" \
  "$TEMPLATE_PROGRAM" \
  '__CODEX_LAUNCHER_HOME__/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin' \
  '__CODEX_LAUNCHER_HOME__/Library/Logs/Codex Launcher/service.log' \
  '__CODEX_LAUNCHER_HOME__/Library/Logs/Codex Launcher/service-error.log'

trap rollback_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Build only through checked, real parent directories. Missing directories are
# created one component at a time so mkdir never follows an unchecked symlink.
if (( DESTINATION_PARENT_NEEDS_CREATION == 1 )); then
  ensure_directory "$HOME/Applications" 0755 "User Applications directory"
fi
ensure_directory "$HOME/Library/Application Support" 0755 "Application Support directory"
ensure_directory "$STATE_DIR" 0700 "Launcher state directory"
ensure_directory "$RUNS_DIR" 0700 "Launcher runs directory"
ensure_directory "$HOME/Library/Logs" 0755 "User logs directory"
ensure_directory "$LOG_DIR" 0755 "Launcher log directory"
ensure_directory "$HOME/Library/LaunchAgents" 0755 "LaunchAgents directory"
ensure_directory "$HOME/bin" 0755 "User bin directory"

STATE_IDENTITY=$(path_identity "$STATE_DIR") || fail "Could not identify Launcher state directory"
STATE_ORIGINAL_MODE=$(/usr/bin/stat -f '%Lp' "$STATE_DIR")
if [[ "$STATE_ORIGINAL_MODE" != "700" ]]; then
  /bin/chmod 0700 "$STATE_DIR"
  STATE_MODE_CHANGED=1
fi
RUNS_IDENTITY=$(path_identity "$RUNS_DIR") || fail "Could not identify Launcher runs directory"
RUNS_ORIGINAL_MODE=$(/usr/bin/stat -f '%Lp' "$RUNS_DIR")
if [[ "$RUNS_ORIGINAL_MODE" != "700" ]]; then
  /bin/chmod 0700 "$RUNS_DIR"
  RUNS_MODE_CHANGED=1
fi

# Reserve the final application path with an exclusive mkdir before copying.
# This cannot merge into or replace a path that races the read-only preflight.
/bin/mkdir "$DEST_APP"
DEST_IDENTITY=$(path_identity "$DEST_APP") || fail "Could not identify installed application"
DEST_CREATED=1
/usr/bin/ditto "$SOURCE_APP" "$DEST_APP"
if [[ "$(path_identity "$DEST_APP")" != "$DEST_IDENTITY" ]]; then
  fail "Destination application identity changed while the bundle was copied"
fi
validate_app_bundle "$DEST_APP"
verify_release_app "$DEST_APP"

# Render into an exclusive temporary file, validate every supported field and
# collection shape, then hard-link it into place so a racing file is not replaced.
LAUNCH_AGENT_TMP=$(/usr/bin/mktemp "$LAUNCH_AGENT.install.XXXXXX")
LAUNCH_AGENT_TMP_IDENTITY=$(path_identity "$LAUNCH_AGENT_TMP") || fail "Could not identify staged LaunchAgent"
(
  umask 077
  /bin/cp "$LAUNCH_AGENT_TEMPLATE" "$LAUNCH_AGENT_TMP"
)
if [[ "$(path_identity "$LAUNCH_AGENT_TMP")" != "$LAUNCH_AGENT_TMP_IDENTITY" ]]; then
  fail "LaunchAgent staging file identity changed while it was rendered"
fi
/usr/bin/plutil -replace ProgramArguments.0 -string "$EXPECTED_PROGRAM" "$LAUNCH_AGENT_TMP"
/usr/bin/plutil -replace EnvironmentVariables.PATH -string "$EXPECTED_PATH" "$LAUNCH_AGENT_TMP"
/usr/bin/plutil -replace StandardOutPath -string "$EXPECTED_STDOUT" "$LAUNCH_AGENT_TMP"
/usr/bin/plutil -replace StandardErrorPath -string "$EXPECTED_STDERR" "$LAUNCH_AGENT_TMP"
/bin/chmod 0600 "$LAUNCH_AGENT_TMP"
validate_launch_agent "$LAUNCH_AGENT_TMP" "$EXPECTED_PROGRAM" "$EXPECTED_PATH" "$EXPECTED_STDOUT" "$EXPECTED_STDERR"

/bin/ln "$LAUNCH_AGENT_TMP" "$LAUNCH_AGENT"
LAUNCH_AGENT_IDENTITY=$(path_identity "$LAUNCH_AGENT") || fail "Could not identify installed LaunchAgent"
if [[ "$LAUNCH_AGENT_IDENTITY" != "$LAUNCH_AGENT_TMP_IDENTITY" ]]; then
  fail "Installed LaunchAgent identity does not match the validated staging file"
fi
LAUNCH_AGENT_CREATED=1
/bin/rm -f "$LAUNCH_AGENT_TMP"
LAUNCH_AGENT_TMP=""
LAUNCH_AGENT_TMP_IDENTITY=""
validate_launch_agent "$LAUNCH_AGENT" "$EXPECTED_PROGRAM" "$EXPECTED_PATH" "$EXPECTED_STDOUT" "$EXPECTED_STDERR"

/bin/ln -s "$CLI_TARGET" "$CLI_LINK"
CLI_IDENTITY=$(path_identity "$CLI_LINK") || fail "Could not identify installed CLI symlink"
CLI_CREATED=1
if [[ ! -L "$CLI_LINK" || "$(/usr/bin/readlink "$CLI_LINK")" != "$CLI_TARGET" ]]; then
  fail "Installed CLI symlink does not have the expected target"
fi

# Revalidate the exact on-disk launch definition immediately before launchd
# consumes it. No earlier validation is treated as sufficient after mutations.
validate_launch_agent "$LAUNCH_AGENT" "$EXPECTED_PROGRAM" "$EXPECTED_PATH" "$EXPECTED_STDOUT" "$EXPECTED_STDERR"
/bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT"
BOOTSTRAPPED=1
/bin/launchctl kickstart "$DOMAIN/$LABEL"
wait_for_fresh_service_health "$source_version"

INSTALL_COMPLETE=1
trap - EXIT INT TERM

print -- "Installed Codex Launcher.app, launch CLI, and user LaunchAgent."
print -- "Open $DEST_APP or run: launch list"
