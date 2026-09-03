#!/bin/zsh
set -euo pipefail

: "${LAUNCH_STATION_FAKE_SIM_LOG:?Set LAUNCH_STATION_FAKE_SIM_LOG}"
quoted=()
for argument in "$@"; do
  quoted+=("${(q)argument}")
done
print -r -- "open ${(j: :)quoted}" >> "$LAUNCH_STATION_FAKE_SIM_LOG"
