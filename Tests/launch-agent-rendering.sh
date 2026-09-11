#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
fixture=$(/usr/bin/mktemp -d -t launchstation-render-contract)
# Retain the small generated fixture for evidence; no user service is touched.
TEMPLATE="$ROOT/Resources/com.jakemawson.launchstation.service.plist"
temporary_agent="$fixture/rendered.plist"
APP_PATH="$fixture/Applications/Launch Station.app"
HOME="$fixture/User & Spaces"
LOG_DIRECTORY="$HOME/Library/Logs/Launch Station"
LABEL="com.jakemawson.launchstation.service"
fail() { print -u2 -- "$*"; exit 1; }

# Execute the exact production rendering block with fixture-only paths. This catches
# valid-but-wrong plist roots, escaped JSON comparisons, and array index insertion.
render_block=$(/usr/bin/sed -n '/^# BEGIN RENDERED_SERVICE_CONTRACT$/,/^# END RENDERED_SERVICE_CONTRACT$/p' "$ROOT/scripts/configure-homebrew-user.sh")
[[ -n "$render_block" ]] || fail "Missing production render block"
eval "$render_block"
[[ "$(/usr/bin/plutil -extract Label raw -o - "$temporary_agent")" == "$LABEL" ]] || fail "Lost dictionary root"
[[ "$(/usr/bin/plutil -extract ProgramArguments raw -expect array -o - "$temporary_agent")" == 1 ]] || fail "Duplicated daemon argument"
[[ "$(/usr/bin/plutil -extract KeepAlive raw -expect bool -o - "$temporary_agent")" == true ]] || fail "Missing automatic restart"
# Rendering repeatedly must keep one argument and the complete dictionary.
eval "$render_block"
[[ "$(/usr/bin/plutil -extract ProgramArguments raw -expect array -o - "$temporary_agent")" == 1 ]] || fail "Repeated rendering duplicated arguments"
print -- "LaunchAgent rendering contracts PASS: $temporary_agent"
