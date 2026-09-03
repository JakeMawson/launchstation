#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
LABEL="com.jakemawson.codex-launcher.service"
BUNDLE_ID="com.jakemawson.codex-launcher"
RELEASE_VERIFIER="$ROOT/scripts/verify-release-app.sh"
RELEASE_TRUST_POLICY="$ROOT/Resources/ReleaseTrustPolicy.plist"
RELEASE_POLICY_LIBRARY="$ROOT/scripts/release-trust-policy.zsh"

fail() {
  print -u2 "$1"
  exit "${2:-2}"
}

usage() {
  print -u2 "usage: scripts/upgrade-installed-app.sh [--allow-legacy-build-2] [ABSOLUTE_SOURCE_APP]"
}

# A root/sudo upgrade would create a root launchd job and root-owned CLI link
# rather than updating the invoking user's Launcher installation.
CURRENT_UID=$(/usr/bin/id -u)
if [[ "$CURRENT_UID" == "0" || -n "${SUDO_USER:-}" || -n "${SUDO_UID:-}" || -n "${SUDO_COMMAND:-}" ]]; then
  print -u2 "Run this upgrader as the logged-in user without sudo; it manages a per-user LaunchAgent and ~/bin/launch."
  exit 2
fi

ALLOW_LEGACY_BUILD_2=0
SOURCE_APP_ARGUMENT=""
while (( $# > 0 )); do
  case "$1" in
    --allow-legacy-build-2)
      ALLOW_LEGACY_BUILD_2=1
      shift
      ;;
    --team-id|--publisher|--policy)
      usage
      fail "$1 is unsupported: the source-controlled release trust policy pins the publisher and Team ID"
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
        exit 2
      fi
      if (( $# == 1 )); then SOURCE_APP_ARGUMENT="$1"; fi
      break
      ;;
    -*)
      usage
      fail "Unknown option: $1"
      exit 2
      ;;
    *)
      if [[ -n "$SOURCE_APP_ARGUMENT" ]]; then
        usage
        fail "only one source app path may be supplied"
        exit 2
      fi
      SOURCE_APP_ARGUMENT="$1"
      shift
      ;;
  esac
done

SOURCE_APP="${SOURCE_APP_ARGUMENT:-$ROOT/dist/release/Codex Launcher.app}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$CURRENT_UID"
DEST_APP=""
INSTALLED_CLI=""
GUI_EXECUTABLE=""
CURRENT_APP=""
CURRENT_CLI=""
RELOCATE_ROOT_OWNED_APP=0
CLI_LINK="$HOME/bin/launch"
STATE_ROOT="$HOME/Library/Application Support/Codex Launcher"
DATABASE="$STATE_ROOT/launcher.sqlite3"
TRANSACTION_ROOT="$STATE_ROOT/Upgrade Transactions"
LOCK_DIRECTORY="$TRANSACTION_ROOT/.upgrade-lock"
EXPECTED_HELPER=""
EXPECTED_STDOUT="$HOME/Library/Logs/Codex Launcher/service.log"
EXPECTED_STDERR="$HOME/Library/Logs/Codex Launcher/service-error.log"
EXPECTED_PATH="$HOME/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

require_real_directory() {
  [[ -d "$1" && ! -L "$1" ]] || fail "Required directory is missing or unsafe: $1"
}

require_regular_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "Required regular file is missing or unsafe: $1"
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

[[ "$SOURCE_APP" == /* ]] || fail "Packaged app path must be absolute: $SOURCE_APP"
SOURCE_APP="${SOURCE_APP:a}"
require_release_policy

running_gui_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/python3 -c '
import sys
executable = sys.argv[1]
for line in sys.stdin:
    value = line.strip()
    if not value:
        continue
    pid, separator, command = value.partition(" ")
    command = command.lstrip()
    if separator and (command == executable or command.startswith(executable + " ")):
        print(pid)
' "$GUI_EXECUTABLE"
}

require_real_directory "$HOME"
require_real_directory "$HOME/Library"
require_real_directory "$HOME/Library/Application Support"
require_real_directory "$HOME/Library/LaunchAgents"
require_real_directory "$HOME/bin"
require_real_directory "$STATE_ROOT"
HOME_OWNER_UID=$(/usr/bin/stat -f '%u' "$HOME") || fail "Could not identify home-directory owner: $HOME"
if [[ "$HOME_OWNER_UID" != "$CURRENT_UID" ]]; then
  fail "HOME must belong to the invoking non-root user: $HOME"
  exit 2
fi

# The installed user LaunchAgent is the single source of truth for the live
# bundle location. This keeps existing /Applications installs compatible while
# allowing a standard user to have installed the bundle in ~/Applications or
# an explicitly chosen writable app directory.
require_regular_file "$LAUNCH_AGENT"
/usr/bin/plutil -lint "$LAUNCH_AGENT" >/dev/null || fail "Existing LaunchAgent is invalid: $LAUNCH_AGENT"
launch_agent_program=$(/usr/bin/plutil -extract ProgramArguments.0 raw -expect string -o - "$LAUNCH_AGENT" 2>/dev/null) || \
  fail "Existing LaunchAgent has no safe daemon program path: $LAUNCH_AGENT"
if /usr/bin/plutil -extract ProgramArguments.1 raw -o - "$LAUNCH_AGENT" >/dev/null 2>&1; then
  fail "Existing LaunchAgent has unexpected daemon program arguments: $LAUNCH_AGENT"
fi
[[ "$launch_agent_program" != *$'\n'* && "$launch_agent_program" != *$'\r'* ]] || \
  fail "Existing LaunchAgent daemon path is malformed: $LAUNCH_AGENT"
case "$launch_agent_program" in
  /*/Contents/Helpers/codex-launcherd)
    CURRENT_APP="${launch_agent_program%/Contents/Helpers/codex-launcherd}"
    ;;
  *)
    fail "Existing LaunchAgent daemon path is not a Codex Launcher app helper: $launch_agent_program"
    ;;
esac
if ! [[ "$CURRENT_APP" != "/" && "${CURRENT_APP:t}" == *.app ]]; then
  fail "Existing LaunchAgent does not identify an app-bundle destination: $CURRENT_APP"
  exit 2
fi
require_real_directory "${CURRENT_APP:h}"
CURRENT_APP_OWNER_UID=$(/usr/bin/stat -f '%u' "$CURRENT_APP") || \
  fail "Could not identify installed application owner: $CURRENT_APP"
DEST_APP="$CURRENT_APP"
if [[ "$CURRENT_APP" == "/Applications/Codex Launcher.app" && "$CURRENT_APP_OWNER_UID" == 0 ]]; then
  # A standard user must not try to replace or remove a root-owned legacy bundle. Install the
  # trusted replacement into the invoking user's Applications directory and repoint only the
  # existing per-user LaunchAgent and CLI contract. The legacy system bundle remains untouched.
  RELOCATE_ROOT_OWNED_APP=1
  DEST_APP="$HOME/Applications/Codex Launcher.app"
elif [[ ! -w "${CURRENT_APP:h}" ]]; then
  fail "Installed application parent is not writable and is not the supported root-owned legacy location: ${CURRENT_APP:h}"
fi
CURRENT_CLI="$CURRENT_APP/Contents/Resources/bin/launch"
INSTALLED_CLI="$DEST_APP/Contents/Resources/bin/launch"
GUI_EXECUTABLE="$CURRENT_APP/Contents/MacOS/CodexLauncher"
EXPECTED_HELPER="$launch_agent_program"

if [[ -e "$TRANSACTION_ROOT" || -L "$TRANSACTION_ROOT" ]]; then
  require_real_directory "$TRANSACTION_ROOT"
else
  /bin/mkdir -m 0700 "$TRANSACTION_ROOT"
fi
/bin/chmod 0700 "$TRANSACTION_ROOT"

if ! /bin/mkdir -m 0700 "$LOCK_DIRECTORY" 2>/dev/null; then
  fail "Another Codex Launcher upgrade is active, or a prior upgrade lock needs inspection: $LOCK_DIRECTORY"
fi
lock_acquired=1
transaction="$TRANSACTION_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
/bin/mkdir -m 0700 "$transaction"
STAGED_APP="$transaction/Codex Launcher.app"
SWAP_BINARY="$transaction/atomic-directory-swap"
LEGACY_DATABASE_BACKUP="$transaction/launcher-schema-1.sqlite3"
STAGED_LAUNCH_AGENT="$transaction/$LABEL.plist"
CLI_LINK_CANDIDATE="$HOME/bin/.launch.codex-launcher-upgrade-$$"

reservation_token=""
service_booted_out=0
legacy_suspended=0
legacy_database_backup_ready=0
cli_link_existed=0
user_applications_created=0
app_transition_started=0
staged_app_identity=""
destination_app_identity=""
launch_agent_transition_started=0
staged_launch_agent_identity=""
launch_agent_identity=""
cli_link_transition_started=0

restore_legacy_database() {
  [[ "$legacy_database_backup_ready" == 1 ]] || return 0
  local restore_candidate="$transaction/launcher.sqlite3.rollback"
  /bin/cp -p "$LEGACY_DATABASE_BACKUP" "$restore_candidate" || return 1
  /bin/chmod 0600 "$restore_candidate" || return 1
  local restored_check
  restored_check=$(/usr/bin/sqlite3 -readonly "$restore_candidate" \
    'PRAGMA user_version; PRAGMA integrity_check;') || return 1
  [[ "$restored_check" == $'1\nok' ]] || return 1

  # The replacement daemon is already stopped. Its WAL/SHM sidecars belong to the migrated
  # schema-2 database and must never accompany the restored schema-1 main file.
  /bin/rm -f -- "$DATABASE-wal" "$DATABASE-shm" || return 1
  /bin/mv -f -- "$restore_candidate" "$DATABASE" || return 1
  /bin/chmod 0600 "$DATABASE" || return 1
  /bin/rm -f -- "$DATABASE-wal" "$DATABASE-shm" || return 1
}

verify_launch_agent_contract() {
  local plist="$1"
  local helper="$2"
  /usr/bin/python3 -c '
import plistlib, sys
path, label, helper, bundle_id, stdout, stderr, expected_path = sys.argv[1:]
with open(path, "rb") as stream:
    value = plistlib.load(stream)
valid = (
    value.get("Label") == label
    and value.get("ProgramArguments") == [helper]
    and value.get("AssociatedBundleIdentifiers") == [bundle_id]
    and value.get("StandardOutPath") == stdout
    and value.get("StandardErrorPath") == stderr
    and value.get("EnvironmentVariables", {}).get("PATH") == expected_path
)
if not valid:
    raise SystemExit("LaunchAgent identity or managed paths do not match Codex Launcher")
' "$plist" "$LABEL" "$helper" "$BUNDLE_ID" "$EXPECTED_STDOUT" "$EXPECTED_STDERR" "$EXPECTED_PATH"
}

retarget_cli_link() {
  local expected_target="$1"
  local replacement_target="$2"
  if [[ "$expected_target" == __absent__ ]]; then
    [[ ! -e "$CLI_LINK" && ! -L "$CLI_LINK" ]] || return 1
  else
    [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == "$expected_target" ]] || return 1
  fi

  if [[ "$replacement_target" == __absent__ ]]; then
    /bin/rm -- "$CLI_LINK"
    return
  fi

  [[ ! -e "$CLI_LINK_CANDIDATE" && ! -L "$CLI_LINK_CANDIDATE" ]] || return 1
  /bin/ln -s "$replacement_target" "$CLI_LINK_CANDIDATE" || return 1
  /bin/mv -f -- "$CLI_LINK_CANDIDATE" "$CLI_LINK" || return 1
  [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == "$replacement_target" ]]
}

# Every transition below is a single atomic rename, but a signal can be delivered after that
# rename returns and before zsh has assigned a "completed" flag. Recovery therefore identifies
# the live objects by their pre-mutation inode/device identities instead of trusting a stale
# in-memory marker. An unknown state is deliberately retained for manual recovery rather than
# guessing which bundle, LaunchAgent, or CLI link is safe to move.
directory_identity() {
  local path="$1"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  /usr/bin/stat -f '%d:%i' "$path"
}

regular_file_identity() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  /usr/bin/stat -f '%d:%i' "$path"
}

directory_matches_identity() {
  local path="$1"
  local expected_identity="$2"
  local actual_identity
  [[ -n "$expected_identity" ]] || return 1
  actual_identity=$(directory_identity "$path") || return 1
  [[ "$actual_identity" == "$expected_identity" ]] || return 1
  [[ -x "$SWAP_BINARY" ]] || return 1
  "$SWAP_BINARY" validate "$path" >/dev/null 2>&1
}

regular_file_matches_identity() {
  local path="$1"
  local expected_identity="$2"
  local actual_identity
  [[ -n "$expected_identity" ]] || return 1
  actual_identity=$(regular_file_identity "$path") || return 1
  [[ "$actual_identity" == "$expected_identity" ]]
}

reconciled_app_transition_state() {
  if [[ "$app_transition_started" != 1 ]]; then
    print -- "not-started"
    return
  fi

  if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
    if [[ ! -e "$STAGED_APP" && ! -L "$STAGED_APP" ]] && \
       directory_matches_identity "$DEST_APP" "$staged_app_identity"; then
      print -- "replacement"
    elif [[ ! -e "$DEST_APP" && ! -L "$DEST_APP" ]] && \
         directory_matches_identity "$STAGED_APP" "$staged_app_identity"; then
      print -- "original"
    else
      print -- "unknown"
    fi
    return
  fi

  if directory_matches_identity "$DEST_APP" "$staged_app_identity" && \
     directory_matches_identity "$STAGED_APP" "$destination_app_identity"; then
    print -- "replacement"
  elif directory_matches_identity "$DEST_APP" "$destination_app_identity" && \
       directory_matches_identity "$STAGED_APP" "$staged_app_identity"; then
    print -- "original"
  else
    print -- "unknown"
  fi
}

reconciled_launch_agent_transition_state() {
  if [[ "$RELOCATE_ROOT_OWNED_APP" != 1 || "$launch_agent_transition_started" != 1 ]]; then
    print -- "not-started"
  elif regular_file_matches_identity "$LAUNCH_AGENT" "$staged_launch_agent_identity" && \
       regular_file_matches_identity "$STAGED_LAUNCH_AGENT" "$launch_agent_identity"; then
    print -- "replacement"
  elif regular_file_matches_identity "$LAUNCH_AGENT" "$launch_agent_identity" && \
       regular_file_matches_identity "$STAGED_LAUNCH_AGENT" "$staged_launch_agent_identity"; then
    print -- "original"
  else
    print -- "unknown"
  fi
}

reconciled_cli_link_transition_state() {
  local target=""
  if [[ "$RELOCATE_ROOT_OWNED_APP" != 1 || "$cli_link_transition_started" != 1 ]]; then
    print -- "not-started"
    return
  fi

  if [[ -L "$CLI_LINK" ]]; then
    target=$(readlink "$CLI_LINK") || {
      print -- "unknown"
      return
    }
    if [[ "$target" == "$INSTALLED_CLI" ]]; then
      print -- "replacement"
    elif [[ "$cli_link_existed" == 1 && "$target" == "$CURRENT_CLI" ]]; then
      print -- "original"
    else
      print -- "unknown"
    fi
  elif [[ ! -e "$CLI_LINK" && ! -L "$CLI_LINK" && "$cli_link_existed" == 0 ]]; then
    print -- "original"
  else
    print -- "unknown"
  fi
}

cleanup_transaction() {
  if [[ -d "$transaction" && ! -L "$transaction" ]]; then
    /bin/rm -rf -- "$transaction" || print -u2 "Warning: retained upgrade transaction $transaction"
  fi
}

release_lock() {
  if [[ "$lock_acquired" == 1 && -d "$LOCK_DIRECTORY" && ! -L "$LOCK_DIRECTORY" ]]; then
    /bin/rmdir "$LOCK_DIRECTORY" || print -u2 "Warning: retained upgrade lock $LOCK_DIRECTORY"
    lock_acquired=0
  fi
}

recover_upgrade() {
  local exit_code=$?
  local rollback_ok=1
  local app_state
  local launch_agent_state
  local cli_link_state
  local replacement_state_seen=0
  local transitions_restored=1
  trap - EXIT INT TERM

  # A failed bootout can still have removed the job. Reconcile its live state before deciding
  # whether an in-process reservation can be cancelled or the prior service must be restarted.
  if ! /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    service_booted_out=1
  fi

  if [[ "$legacy_suspended" == 1 ]] && /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    /bin/launchctl kill SIGCONT "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    legacy_suspended=0
  fi

  # Resolve every mutation from the current filesystem state. The transition intent is set before
  # each rename, so this also covers an interruption immediately after an atomic helper returns.
  app_state=$(reconciled_app_transition_state)
  launch_agent_state=$(reconciled_launch_agent_transition_state)
  cli_link_state=$(reconciled_cli_link_transition_state)
  for state_name in app_state launch_agent_state cli_link_state; do
    case "${(P)state_name}" in
      not-started|original)
        ;;
      replacement)
        replacement_state_seen=1
        ;;
      *)
        rollback_ok=0
        print -u2 "Upgrade recovery found an unrecognized ${state_name//_/-} state; preserved transaction for manual recovery: $transaction"
        ;;
    esac
  done

  if [[ "$rollback_ok" == 1 && "$replacement_state_seen" == 1 ]]; then
    if /bin/launchctl bootout "$DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 \
      || ! /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      service_booted_out=1
      if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
        if [[ "$launch_agent_state" == replacement ]]; then
          if [[ -x "$SWAP_BINARY" ]] && \
             "$SWAP_BINARY" swap-file "$STAGED_LAUNCH_AGENT" "$LAUNCH_AGENT"; then
            launch_agent_state=$(reconciled_launch_agent_transition_state)
            if [[ "$launch_agent_state" != original ]]; then
              rollback_ok=0
              print -u2 "LaunchAgent rollback did not restore its original identity; preserved transaction for manual recovery: $transaction"
            fi
          else
            rollback_ok=0
            print -u2 "LaunchAgent rollback failed; preserved transaction for manual recovery: $transaction"
          fi
        fi
        if [[ "$rollback_ok" == 1 && "$cli_link_state" == replacement ]]; then
          prior_cli_target="$CURRENT_CLI"
          if [[ "$cli_link_existed" == 0 ]]; then prior_cli_target=__absent__; fi
          if retarget_cli_link "$INSTALLED_CLI" "$prior_cli_target"; then
            cli_link_state=$(reconciled_cli_link_transition_state)
            if [[ "$cli_link_state" != original ]]; then
              rollback_ok=0
              print -u2 "CLI-link rollback did not restore its original target; preserved transaction for manual recovery: $transaction"
            fi
          else
            rollback_ok=0
            print -u2 "CLI-link rollback failed; preserved transaction for manual recovery: $transaction"
          fi
        fi
        if [[ "$rollback_ok" == 1 && "$app_state" == replacement ]]; then
          if [[ -x "$SWAP_BINARY" ]] && "$SWAP_BINARY" install "$DEST_APP" "$STAGED_APP"; then
            app_state=$(reconciled_app_transition_state)
            if [[ "$app_state" == original ]]; then
              print -u2 "Upgrade failed; removed the relocated replacement and preserved the root-owned legacy app."
            else
              rollback_ok=0
              print -u2 "Relocated-app rollback did not restore its original identity; preserved transaction for manual recovery: $transaction"
            fi
          else
            rollback_ok=0
            print -u2 "Relocated-app rollback failed; preserved transaction for manual recovery: $transaction"
          fi
        fi
      elif [[ "$app_state" == replacement ]]; then
        if [[ -x "$SWAP_BINARY" ]] && "$SWAP_BINARY" swap "$STAGED_APP" "$DEST_APP"; then
          app_state=$(reconciled_app_transition_state)
          if [[ "$app_state" == original ]]; then
            print -u2 "Upgrade failed; restored the previous complete app bundle."
          else
            rollback_ok=0
            print -u2 "Upgrade rollback did not restore the previous bundle identity; preserved transaction for manual recovery: $transaction"
          fi
        else
          rollback_ok=0
          print -u2 "Upgrade rollback failed; preserved transaction for manual recovery: $transaction"
        fi
      fi
    else
      rollback_ok=0
      print -u2 "Upgrade rollback was not attempted because the replacement daemon could not be stopped. Preserved transaction: $transaction"
    fi
  fi

  for state_name in app_state launch_agent_state cli_link_state; do
    case "${(P)state_name}" in
      not-started|original)
        ;;
      *)
        transitions_restored=0
        ;;
    esac
  done

  if [[ "$ALLOW_LEGACY_BUILD_2" == 1 \
        && "$legacy_database_backup_ready" == 1 \
        && "$service_booted_out" == 1 \
        && "$transitions_restored" == 1 \
        && "$rollback_ok" == 1 ]]; then
    if restore_legacy_database; then
      print -u2 "Restored the pre-migration schema-1 database with the previous app bundle."
    else
      rollback_ok=0
      print -u2 "Database rollback failed; left the old daemon stopped and preserved transaction for manual recovery: $transaction"
    fi
  fi

  if [[ "$service_booted_out" == 1 && "$transitions_restored" == 1 && "$rollback_ok" == 1 ]]; then
    /bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    /bin/launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  elif [[ -n "$reservation_token" ]]; then
    "$CURRENT_CLI" maintenance cancel-upgrade "$reservation_token" --json >/dev/null 2>&1 || true
  fi

  if [[ "$rollback_ok" == 1 ]]; then cleanup_transaction; fi
  if [[ -L "$CLI_LINK_CANDIDATE" ]]; then /bin/rm -- "$CLI_LINK_CANDIDATE" || true; fi
  if [[ "$user_applications_created" == 1 ]]; then /bin/rmdir "$HOME/Applications" >/dev/null 2>&1 || true; fi
  release_lock
  exit "$exit_code"
}
trap recover_upgrade EXIT INT TERM

if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
  if [[ -e "$HOME/Applications" || -L "$HOME/Applications" ]]; then
    require_real_directory "$HOME/Applications"
  else
    /bin/mkdir -m 0755 "$HOME/Applications"
    user_applications_created=1
  fi
  USER_APPLICATIONS_OWNER_UID=$(/usr/bin/stat -f '%u' "$HOME/Applications") || \
    fail "Could not identify user Applications owner: $HOME/Applications"
  [[ "$USER_APPLICATIONS_OWNER_UID" == "$CURRENT_UID" && -w "$HOME/Applications" ]] || \
    fail "User Applications directory must belong to and be writable by the invoking user: $HOME/Applications"
  [[ ! -e "$DEST_APP" && ! -L "$DEST_APP" ]] || \
    fail "Refusing to replace an existing user application during legacy relocation: $DEST_APP"
  [[ ! -e "$CLI_LINK_CANDIDATE" && ! -L "$CLI_LINK_CANDIDATE" ]] || \
    fail "Temporary CLI-link path already exists: $CLI_LINK_CANDIDATE"

  /bin/cp -p "$LAUNCH_AGENT" "$STAGED_LAUNCH_AGENT"
  /usr/bin/plutil -replace ProgramArguments.0 -string "$DEST_APP/Contents/Helpers/codex-launcherd" \
    "$STAGED_LAUNCH_AGENT"
  /usr/bin/plutil -lint "$STAGED_LAUNCH_AGENT" >/dev/null || \
    fail "Relocated LaunchAgent staging file is invalid: $STAGED_LAUNCH_AGENT"
  verify_launch_agent_contract "$STAGED_LAUNCH_AGENT" "$DEST_APP/Contents/Helpers/codex-launcherd" || \
    fail "Relocated LaunchAgent staging contract is invalid."
  staged_launch_agent_identity=$(regular_file_identity "$STAGED_LAUNCH_AGENT") || \
    fail "Could not identify staged relocated LaunchAgent: $STAGED_LAUNCH_AGENT"
  launch_agent_identity=$(regular_file_identity "$LAUNCH_AGENT") || \
    fail "Could not identify existing LaunchAgent: $LAUNCH_AGENT"
fi

env CLANG_MODULE_CACHE_PATH=/tmp/codex-launcher-upgrade-clang-cache \
  SWIFT_MODULE_CACHE_PATH=/tmp/codex-launcher-upgrade-swift-cache \
  /usr/bin/xcrun swiftc "$ROOT/scripts/atomic-directory-swap.swift" -o "$SWAP_BINARY"

"$SWAP_BINARY" validate "$SOURCE_APP"
"$SWAP_BINARY" validate "$CURRENT_APP"

[[ -x "$CURRENT_CLI" && ! -L "$CURRENT_CLI" ]] \
  || fail "Installed CLI is missing or unsafe: $CURRENT_CLI"
[[ -x "$GUI_EXECUTABLE" && ! -L "$GUI_EXECUTABLE" ]] \
  || fail "Installed GUI executable is missing or unsafe: $GUI_EXECUTABLE"
[[ -f "$LAUNCH_AGENT" && ! -L "$LAUNCH_AGENT" ]] \
  || fail "Existing LaunchAgent not found or unsafe: $LAUNCH_AGENT"

verify_launch_agent_contract "$LAUNCH_AGENT" "$EXPECTED_HELPER" \
  || fail "LaunchAgent identity or managed paths do not match Codex Launcher."

if [[ -e "$CLI_LINK" || -L "$CLI_LINK" ]]; then
  [[ -L "$CLI_LINK" && "$(readlink "$CLI_LINK")" == "$CURRENT_CLI" ]] \
    || fail "Refusing to replace unrelated CLI path: $CLI_LINK"
  cli_link_existed=1
fi

source_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$SOURCE_APP/Contents/Info.plist")
dest_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$CURRENT_APP/Contents/Info.plist")
[[ "$source_id" == "$BUNDLE_ID" && "$dest_id" == "$BUNDLE_ID" ]] \
  || fail "Source and installed bundle identities do not match Codex Launcher."

source_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$SOURCE_APP/Contents/Info.plist")
dest_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$CURRENT_APP/Contents/Info.plist")
source_build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$SOURCE_APP/Contents/Info.plist")
dest_build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$CURRENT_APP/Contents/Info.plist")
/usr/bin/python3 -c '
import sys
def numeric(value, label):
    pieces = value.split(".")
    if not pieces or any(not piece.isdigit() for piece in pieces):
        raise SystemExit(f"{label} must be a numeric dotted version: {value}")
    return tuple(int(piece) for piece in pieces)
source_version, dest_version = numeric(sys.argv[1], "source version"), numeric(sys.argv[2], "installed version")
source_build, dest_build = numeric(sys.argv[3], "source build"), numeric(sys.argv[4], "installed build")
if source_version < dest_version or (source_version == dest_version and source_build < dest_build):
    raise SystemExit("refusing an app downgrade; package a nondecreasing version/build")
' "$source_version" "$dest_version" "$source_build" "$dest_build" \
  || fail "Source bundle version/build is older or invalid."
if [[ "$ALLOW_LEGACY_BUILD_2" == 1 ]]; then
  [[ "$dest_version" == "1.1.0" && "$dest_build" == "2" ]] \
    || fail "--allow-legacy-build-2 is restricted to the one-time signed 1.1.0 (2) migration."
fi

/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"
/usr/bin/codesign --verify --deep --strict "$CURRENT_APP"
verify_release_app "$SOURCE_APP"
[[ -f "$SOURCE_APP/Contents/Resources/Skills/codex-launcher/SKILL.md" \
   && ! -L "$SOURCE_APP/Contents/Resources/Skills/codex-launcher/SKILL.md" ]] \
  || fail "The packaged app does not contain a safe Codex Launcher skill."

/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
"$SWAP_BINARY" validate "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
verify_release_app "$STAGED_APP"
if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
  [[ "$(stat -f '%d' "$STAGED_APP")" == "$(stat -f '%d' "${DEST_APP:h}")" ]] \
    || fail "Staged app and user Applications destination are not on the same filesystem."
else
  [[ "$(stat -f '%d' "$STAGED_APP")" == "$(stat -f '%d' "$DEST_APP")" ]] \
    || fail "Staged app and installed app are not on the same filesystem."
fi
staged_app_identity=$(directory_identity "$STAGED_APP") || \
  fail "Could not identify staged application bundle: $STAGED_APP"
if [[ "$RELOCATE_ROOT_OWNED_APP" != 1 ]]; then
  destination_app_identity=$(directory_identity "$DEST_APP") || \
    fail "Could not identify installed application bundle: $DEST_APP"
fi

gui_pids="$(running_gui_pids)"
[[ -z "$gui_pids" ]] \
  || fail "Close the running Codex Launcher app before upgrading (exact PID(s): ${gui_pids//$'\n'/, })." 4

/bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 \
  || fail "The exact Codex Launcher LaunchAgent is not loaded; start it and run launch doctor before upgrading."

if [[ "$ALLOW_LEGACY_BUILD_2" == 1 ]]; then
  # Build 2 predates the actor-owned reservation endpoint. This explicitly gated migration freezes
  # the exact launchd job first, proves the process reached a stopped state, then reads the durable
  # SQLite lifecycle snapshot while no new request can execute. An uncommitted pre-session request
  # cannot have launched a child; any committed/visible lifecycle is represented by an active row.
  [[ -f "$DATABASE" && ! -L "$DATABASE" ]] || fail "Launcher database is missing or unsafe: $DATABASE"
  metadata_pid=$(/usr/bin/plutil -extract pid raw -o - "$STATE_ROOT/service.json")
  launchd_pid=$(/bin/launchctl print "$DOMAIN/$LABEL" | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
  [[ "$metadata_pid" == <-> && "$metadata_pid" == "$launchd_pid" ]] \
    || fail "The build-2 daemon PID does not match its exact launchd job."

  /bin/launchctl kill SIGSTOP "$DOMAIN/$LABEL"
  legacy_suspended=1
  stopped=0
  for _ in {1..40}; do
    process_state=$(/bin/ps -o state= -p "$metadata_pid" | /usr/bin/tr -d '[:space:]')
    if [[ "$process_state" == T* ]]; then
      stopped=1
      break
    fi
    /bin/sleep 0.05
  done
  [[ "$stopped" == 1 ]] || fail "The exact build-2 daemon could not be frozen for migration."

  schema=$(/usr/bin/sqlite3 -readonly "$DATABASE" 'PRAGMA user_version;')
  [[ "$schema" == 1 ]] || fail "The build-2 database schema is not the expected version 1."
  active_count=$(/usr/bin/sqlite3 -readonly "$DATABASE" \
    "SELECT COUNT(*) FROM sessions WHERE state IN ('starting','running','partial','stopping');")
  [[ "$active_count" == 0 ]] \
    || fail "Refusing build-2 migration while $active_count durable Launcher session(s) are active." 4

  gui_pids="$(running_gui_pids)"
  [[ -z "$gui_pids" ]] \
    || fail "Codex Launcher opened during the build-2 migration barrier (exact PID(s): ${gui_pids//$'\n'/, }). Close it and retry." 4

  # SQLite's backup API captures the complete logical schema-1 database, including committed WAL
  # content, while the exact legacy daemon remains frozen. This backup is part of the same private
  # upgrade transaction as the superseded app and is restored before the old daemon on rollback.
  /usr/bin/python3 - "$DATABASE" "$LEGACY_DATABASE_BACKUP" <<'PY'
import sqlite3
import sys
from pathlib import Path

source_path, backup_path = sys.argv[1:]
source = sqlite3.connect(Path(source_path).resolve().as_uri() + "?mode=ro", uri=True)
destination = sqlite3.connect(backup_path)
try:
    source.backup(destination)
    destination.commit()
    # The live Launcher database uses WAL. SQLite's backup API preserves that journal mode in
    # the destination header, but a brand-new read-only copy has no pre-existing WAL/SHM files and
    # therefore cannot be opened for the first integrity check. Convert the completed logical
    # backup into one standalone rollback file before closing it.
    journal_mode = destination.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
    if journal_mode.lower() != "delete":
        raise RuntimeError(f"backup journal mode remained {journal_mode}")
    destination.commit()
finally:
    destination.close()
    source.close()

for suffix in ("-wal", "-shm"):
    Path(backup_path + suffix).unlink(missing_ok=True)
PY
  /bin/chmod 0600 "$LEGACY_DATABASE_BACKUP"
  backup_check=$(/usr/bin/sqlite3 -readonly "$LEGACY_DATABASE_BACKUP" \
    'PRAGMA user_version; PRAGMA integrity_check;')
  [[ "$backup_check" == $'1\nok' ]] \
    || fail "The pre-migration schema-1 database backup failed integrity verification."
  legacy_database_backup_ready=1

  /bin/launchctl bootout "$DOMAIN" "$LAUNCH_AGENT"
  legacy_suspended=0
  service_booted_out=1
else
  # This actor-owned reservation is the normal session drain. Once returned, every non-read API
  # request receives 409 until exact cancellation, expiry, or daemon restart, so no launch can
  # enter the interval between the idle proof and launchctl bootout.
  reservation_json=$("$CURRENT_CLI" maintenance prepare-upgrade --json)
  reservation_token=$(print -rn -- "$reservation_json" | /usr/bin/plutil -extract reservationToken raw -o - -)
  [[ -n "$reservation_token" ]] || fail "The daemon returned an invalid upgrade reservation."

  gui_pids="$(running_gui_pids)"
  [[ -z "$gui_pids" ]] \
    || fail "Codex Launcher opened while the upgrade was being reserved (exact PID(s): ${gui_pids//$'\n'/, }). Close it and retry." 4

  /bin/launchctl bootout "$DOMAIN" "$LAUNCH_AGENT"
  service_booted_out=1
fi

if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
  app_transition_started=1
  "$SWAP_BINARY" install "$STAGED_APP" "$DEST_APP"
else
  app_transition_started=1
  "$SWAP_BINARY" swap "$STAGED_APP" "$DEST_APP"
fi
/usr/bin/codesign --verify --deep --strict "$DEST_APP"
# Prove the exact path that will be launched still satisfies the pinned release policy before
# bootstrapping it. This is distinct from the legacy source bundle, which is intentionally not
# required to be Developer-ID notarized and remains untouched during user-Applications migration.
verify_release_app "$DEST_APP"

if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
  launch_agent_transition_started=1
  "$SWAP_BINARY" swap-file "$STAGED_LAUNCH_AGENT" "$LAUNCH_AGENT"
  verify_launch_agent_contract "$LAUNCH_AGENT" "$DEST_APP/Contents/Helpers/codex-launcherd" || \
    fail "Relocated LaunchAgent contract did not install safely."

  previous_cli_target="$CURRENT_CLI"
  if [[ "$cli_link_existed" == 0 ]]; then previous_cli_target=__absent__; fi
  cli_link_transition_started=1
  retarget_cli_link "$previous_cli_target" "$INSTALLED_CLI" || \
    fail "Could not retarget the exact per-user CLI link to the relocated app."
elif [[ ! -e "$CLI_LINK" && ! -L "$CLI_LINK" ]]; then
  /bin/ln -s "$INSTALLED_CLI" "$CLI_LINK"
fi

/bin/launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT"
/bin/launchctl kickstart "$DOMAIN/$LABEL"
service_booted_out=0

# The previous daemon's service.json remains valid JSON until the replacement finishes its
# schema migration and atomically publishes fresh metadata. Wait for that exact replacement PID
# and packaged version before asking the new CLI to enforce its compatibility contract; otherwise
# an immediate doctor call can reject the stale schema-1 metadata and trigger a false rollback.
replacement_metadata_ready=0
for _ in {1..200}; do
  replacement_pid=$(/bin/launchctl print "$DOMAIN/$LABEL" \
    | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
  metadata_pid=$(/usr/bin/plutil -extract pid raw -o - "$STATE_ROOT/service.json" 2>/dev/null || true)
  metadata_version=$(/usr/bin/plutil -extract version raw -o - "$STATE_ROOT/service.json" 2>/dev/null || true)
  if [[ "$replacement_pid" == <-> \
        && "$metadata_pid" == "$replacement_pid" \
        && "$metadata_version" == "$source_version" ]]; then
    replacement_metadata_ready=1
    break
  fi
  /bin/sleep 0.05
done
[[ "$replacement_metadata_ready" == 1 ]] \
  || fail "The replacement daemon did not publish compatible service metadata in time."
"$INSTALLED_CLI" doctor --json >/dev/null

# The new bundle and daemon are verified. The private transaction now contains only rollback
# material (an in-place superseded bundle or the prior per-user LaunchAgent) and the compiled
# helper. Its cleanup cannot invalidate either live app path.
reservation_token=""
trap - EXIT INT TERM
cleanup_transaction
release_lock

print "Updated $DEST_APP atomically to $source_version ($source_build)"
if [[ "$RELOCATE_ROOT_OWNED_APP" == 1 ]]; then
  print "Preserved untouched legacy app: $CURRENT_APP"
fi
print "Preserved $CLI_LINK"
if [[ -L "$CLI_LINK" ]]; then print "CLI target: $(readlink "$CLI_LINK")"; fi
