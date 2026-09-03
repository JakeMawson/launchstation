#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ARTIFACTS="${LAUNCH_STATION_GATE_ARTIFACTS:-/tmp/launchstation-supervisor-gate-$$}"
MODULE_CACHE="${SWIFT_MODULE_CACHE_PATH:-/tmp/launchstation-swift-cache}"
CLANG_CACHE="${CLANG_MODULE_CACHE_PATH:-/tmp/launchstation-clang-cache}"

mkdir -p "$ARTIFACTS"
env CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
  xcrun swift build --package-path "$ROOT" --target LauncherCore --jobs 2 >/dev/null

BIN_PATH=$(env CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
  xcrun swift build --package-path "$ROOT" --show-bin-path)
CORE_OBJECTS=("$BIN_PATH"/LauncherCore.build/*.swift.o)
(( ${#CORE_OBJECTS[@]} > 0 )) || {
  print -u2 "ProcessSupervisor start-gate failure: LauncherCore object files were not built"
  exit 1
}

HARNESS="$ARTIFACTS/process-supervisor-start-gate-harness"
env CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE" \
  xcrun swiftc \
    -I "$BIN_PATH/Modules" \
    "$ROOT/Sources/LauncherDaemon/ProcessSupervisor.swift" \
    "$ROOT/Tests/ProcessSupervisorStartGateHarness.swift" \
    "${CORE_OBJECTS[@]}" \
    -framework AppKit -lsqlite3 \
    -o "$HARNESS"

"$HARNESS" "$ROOT/.build/debug/launchstation-runner" "$ARTIFACTS/runtime"
