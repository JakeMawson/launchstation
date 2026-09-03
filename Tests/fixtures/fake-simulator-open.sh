#!/bin/zsh
set -euo pipefail

: "${CODEX_LAUNCHER_FAKE_SIM_LOG:?Set CODEX_LAUNCHER_FAKE_SIM_LOG}"
quoted=()
for argument in "$@"; do
  quoted+=("${(q)argument}")
done
print -r -- "open ${(j: :)quoted}" >> "$CODEX_LAUNCHER_FAKE_SIM_LOG"
