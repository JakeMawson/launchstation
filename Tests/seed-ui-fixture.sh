#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
LAUNCH="${LAUNCH_BINARY:-$ROOT/dist/Codex Launcher.app/Contents/Resources/bin/launch}"
PROJECT="${CODEX_LAUNCHER_UI_PROJECT:-/tmp/codex-launcher-uiqa-project-20260717}"

: "${CODEX_LAUNCHER_STATE_DIR:?Set CODEX_LAUNCHER_STATE_DIR for the UI QA daemon}"
export CODEX_LAUNCHER_STATE_DIR
mkdir -p "$PROJECT"

"$LAUNCH" init "$PROJECT" --project-name "Launch Systems Lab"

"$LAUNCH" create "Full stack preview" "Launch the product frontend, API worker, and local data service as one exact session." \
  --directory "$PROJECT" \
  --run-details "The frontend receives a fresh managed port; supporting services remain private process groups." \
  --tag web --tag compound --tag verified \
  --action-name frontend --action-description "Product preview server" \
  --type process --port auto --url 'http://${HOST}:${PORT}/' --health 'http://${HOST}:${PORT}/' \
  -- python3 -m http.server '${PORT}'
"$LAUNCH" action add "Full stack preview" api "Local API worker" \
  -- /bin/sh -c 'while :; do sleep 1; done'
"$LAUNCH" action add "Full stack preview" database "Local development data service" \
  -- /bin/sh -c 'while :; do sleep 1; done'

"$LAUNCH" create "Expo mobile lab" "Start the Expo development server with managed port ownership and device-safe lifecycle rules." \
  --directory "$PROJECT" --tag expo --tag ios --tag mobile \
  --run-details "Expo host mode is adapted to localhost; existing Simulator devices are never shut down." \
  --action-name metro --action-description "Expo Metro bundler" \
  --type ios --port auto --open simulator -- npx expo start

"$LAUNCH" create "Xcode workspace" "Open Xcode as an exact application session without claiming an existing instance." \
  --directory "$PROJECT" --tag macos --tag app \
  --action-name xcode --action-description "Native application target" \
  --type app --open application --app-bundle-id com.apple.dt.Xcode -- /Applications/Xcode_16.app

"$LAUNCH" create "Documentation server" "Serve generated project documentation on a fresh non-conflicting local port." \
  --directory "$PROJECT" --tag docs --tag python \
  --action-name docs --action-description "Static documentation preview" \
  --type process --port auto --url 'http://${HOST}:${PORT}/' --health 'http://${HOST}:${PORT}/' \
  -- python3 -m http.server '${PORT}'

"$LAUNCH" "Full stack preview" --json
