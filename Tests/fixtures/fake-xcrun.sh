#!/bin/zsh
set -euo pipefail

: "${LAUNCH_STATION_FAKE_SIM_LOG:?Set LAUNCH_STATION_FAKE_SIM_LOG}"
quoted=()
for argument in "$@"; do
  quoted+=("${(q)argument}")
done
print -r -- "${(j: :)quoted}" >> "$LAUNCH_STATION_FAKE_SIM_LOG"

if [[ "$*" == "simctl list devices available --json" ]]; then
  mode=normal
  if [[ -n "${LAUNCH_STATION_FAKE_SIM_MODE_FILE:-}" && -f "$LAUNCH_STATION_FAKE_SIM_MODE_FILE" ]]; then
    mode="$(<"$LAUNCH_STATION_FAKE_SIM_MODE_FILE")"
  fi
  if [[ "$mode" == large ]]; then
    exec /usr/bin/python3 - <<'PY'
import sys

sys.stderr.write("large-stderr:" + ("x" * (512 * 1024)) + "\n")
print('{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"udid":"FAKE-SHUTDOWN-UDID","name":"iPhone 16 Pro","state":"Shutdown","isAvailable":true},{"udid":"FAKE-BOOTED-UDID","name":"iPhone 15","state":"Booted","isAvailable":true}]}}')
PY
  fi
  if [[ "$mode" == hang-descendant ]]; then
    : "${LAUNCH_STATION_FAKE_SIM_PARENT_PID:?Set LAUNCH_STATION_FAKE_SIM_PARENT_PID}"
    : "${LAUNCH_STATION_FAKE_SIM_CHILD_PID:?Set LAUNCH_STATION_FAKE_SIM_CHILD_PID}"
    exec /usr/bin/python3 - "$LAUNCH_STATION_FAKE_SIM_PARENT_PID" "$LAUNCH_STATION_FAKE_SIM_CHILD_PID" <<'PY'
import os
from pathlib import Path
import signal
import sys
import time

parent_path, child_path = map(Path, sys.argv[1:])
parent_path.write_text(str(os.getpid()), encoding="utf-8")
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = os.fork()
if child == 0:
    child_path.write_text(str(os.getpid()), encoding="utf-8")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        try:
            os.write(2, b".")
        except BrokenPipeError:
            os._exit(0)
        time.sleep(0.01)

sys.stderr.write("helper-parent-waiting\n")
sys.stderr.flush()
while True:
    time.sleep(1)
PY
  fi
  print -r -- '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-5":[{"udid":"FAKE-SHUTDOWN-UDID","name":"iPhone 16 Pro","state":"Shutdown","isAvailable":true},{"udid":"FAKE-BOOTED-UDID","name":"iPhone 15","state":"Booted","isAvailable":true}]}}'
fi
