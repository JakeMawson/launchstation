#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE

ROOT="${0:A:h:h}"
LAUNCH="${LAUNCH_BINARY:-$ROOT/.build/debug/launch}"
DAEMON="${DAEMON_BINARY:-$ROOT/.build/debug/codex-launcherd}"
RUNNER="${RUNNER_BINARY:-$ROOT/.build/debug/codex-launcher-runner}"
CODEX_PORT="${CODEX_PORT_EXECUTABLE:-$HOME/bin/codex-port}"
FAKE_XCRUN="$ROOT/Tests/fixtures/fake-xcrun.sh"
FAKE_OPEN="$ROOT/Tests/fixtures/fake-simulator-open.sh"
STAMP="${CODEX_LAUNCHER_SIM_TEST_STAMP:-$(date +%s)-$$}"
STATE_DIR="${CODEX_LAUNCHER_SIM_STATE_DIR:-/tmp/codex-launcher-simulator-state-$STAMP}"
PROJECT="${CODEX_LAUNCHER_SIM_PROJECT:-/tmp/codex-launcher-simulator-project-$STAMP}"
ARTIFACTS="${CODEX_LAUNCHER_SIM_ARTIFACTS:-/tmp/codex-launcher-simulator-artifacts-$STAMP}"
NAME="codex-launcher-simulator-$STAMP"
SIM_LOG="$ARTIFACTS/simulator-commands.log"
EXPECTED_LOG="$ARTIFACTS/expected-simulator-commands.log"
MODE_FILE="$ARTIFACTS/fake-simulator-mode.txt"
HANG_PARENT_PID="$ARTIFACTS/hanging-helper-parent.pid"
HANG_CHILD_PID="$ARTIFACTS/hanging-helper-child.pid"
FAKE_APP="$PROJECT/build/Fake.app"
DAEMON_RECORD="$ARTIFACTS/daemon-run.json"
DAEMON_CLOSE="$ARTIFACTS/daemon-close.json"
daemon_id=""

fail() {
  print -u2 "Simulator orchestration failure: $1"
  exit 1
}

for executable in "$LAUNCH" "$DAEMON" "$RUNNER" "$CODEX_PORT" "$FAKE_XCRUN" "$FAKE_OPEN"; do
  [[ -x "$executable" ]] || fail "required executable is unavailable: $executable"
done

mkdir -p "$STATE_DIR" "$PROJECT" "$ARTIFACTS" "$FAKE_APP"
print -r -- large > "$MODE_FILE"

close_daemon() {
  [[ -n "$daemon_id" ]] || return 0
  if "$CODEX_PORT" close \
      --id "$daemon_id" \
      --reason "Simulator orchestration integration test completed" \
      > "$DAEMON_CLOSE" 2> "$ARTIFACTS/daemon-close-error.txt"; then
    daemon_id=""
    return 0
  fi
  return 1
}

trap 'close_daemon || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$CODEX_PORT" run \
  --title "Codex Launcher fake Simulator $STAMP" \
  --description "Isolated fake Simulator orchestration integration test; never invokes real xcrun or Simulator." \
  --workdir "$ROOT" \
  --port auto \
  --host 127.0.0.1 \
  --ttl 20m \
  -- /usr/bin/env \
    "CODEX_LAUNCHER_STATE_DIR=$STATE_DIR" \
    "CODEX_LAUNCHER_RUNNER=$RUNNER" \
    "CODEX_PORT_EXECUTABLE=$CODEX_PORT" \
    "CODEX_LAUNCHER_XCRUN=$FAKE_XCRUN" \
    "CODEX_LAUNCHER_SIMULATOR_OPEN=$FAKE_OPEN" \
    "CODEX_LAUNCHER_FAKE_SIM_LOG=$SIM_LOG" \
    "CODEX_LAUNCHER_FAKE_SIM_MODE_FILE=$MODE_FILE" \
    "CODEX_LAUNCHER_FAKE_SIM_PARENT_PID=$HANG_PARENT_PID" \
    "CODEX_LAUNCHER_FAKE_SIM_CHILD_PID=$HANG_CHILD_PID" \
    "CODEX_LAUNCHER_HELPER_TIMEOUT_SECONDS=0.5" \
    "$DAEMON" \
  > "$DAEMON_RECORD"

daemon_id=$(/usr/bin/plutil -extract id raw -o - "$DAEMON_RECORD" 2>/dev/null || true)
[[ -n "$daemon_id" ]] || fail "codex-port returned no managed daemon ID"

daemon_ready=0
for attempt in {1..120}; do
  if [[ -f "$STATE_DIR/service.json" ]]; then
    endpoint=$(/usr/bin/plutil -extract endpoint raw -o - "$STATE_DIR/service.json" 2>/dev/null || true)
    token=$(/usr/bin/plutil -extract token raw -o - "$STATE_DIR/service.json" 2>/dev/null || true)
    if [[ -n "$endpoint" && -n "$token" ]] && \
       /usr/bin/curl -fsS -H "Authorization: Bearer $token" "$endpoint/v1/health" >/dev/null 2>&1; then
      daemon_ready=1
      break
    fi
  fi
  /bin/sleep 0.05
done
[[ "$daemon_ready" == 1 ]] || fail "temporary launcher daemon did not become healthy"

export CODEX_LAUNCHER_STATE_DIR="$STATE_DIR"
"$LAUNCH" init "$PROJECT" --project-name "Fake Simulator $STAMP" --json > "$ARTIFACTS/project.json"
"$LAUNCH" create "$NAME" "Verify shutdown-device Simulator orchestration without real Simulator mutation" \
  --directory "$PROJECT" \
  --tag ios --tag simulator --tag integration \
  --type ios \
  --open simulator \
  --env CODEX_SIMULATOR_DEVICE=FAKE-SHUTDOWN-UDID \
  --env "CODEX_SIMULATOR_APP_PATH=$FAKE_APP" \
  --env CODEX_SIMULATOR_BUNDLE_ID=com.example.Fake \
  --env 'CODEX_SIMULATOR_APP_ARGUMENTS=["--demo","safe arg","--mode=test"]' \
  -- /usr/bin/env \
  > "$ARTIFACTS/created.txt"

"$LAUNCH" "$NAME" --json > "$ARTIFACTS/session.json"
session_state=""
for attempt in {1..100}; do
  "$LAUNCH" details "$NAME" --json > "$ARTIFACTS/details.json"
  session_state=$(/usr/bin/plutil -extract lastSession.state raw -o - "$ARTIFACTS/details.json" 2>/dev/null || true)
  [[ "$session_state" == exited || "$session_state" == failed || "$session_state" == orphaned ]] && break
  /bin/sleep 0.05
done
[[ "$session_state" == exited ]] || fail "launcher session ended in state '$session_state'"

run_state=$(/usr/bin/plutil -extract lastSession.actionRuns.0.state raw -o - "$ARTIFACTS/details.json")
run_manager=$(/usr/bin/plutil -extract lastSession.actionRuns.0.manager raw -o - "$ARTIFACTS/details.json")
run_exit=$(/usr/bin/plutil -extract lastSession.actionRuns.0.exitCode raw -o - "$ARTIFACTS/details.json")
run_simulator_udid=$(/usr/bin/plutil -extract lastSession.actionRuns.0.simulatorUDID raw -o - "$ARTIFACTS/details.json")
run_simulator_name=$(/usr/bin/plutil -extract lastSession.actionRuns.0.simulatorName raw -o - "$ARTIFACTS/details.json")
last_error=$(/usr/bin/plutil -extract lastSession.lastError raw -o - "$ARTIFACTS/details.json" 2>/dev/null || true)
[[ "$run_state" == exited ]] || fail "host command action ended in state '$run_state'"
[[ "$run_manager" == processGroup ]] || fail "host command used unexpected manager '$run_manager'"
[[ "$run_exit" == 0 ]] || fail "host command returned exit code '$run_exit'"
[[ "$run_simulator_udid" == FAKE-SHUTDOWN-UDID ]] \
  || fail "structured action run Simulator UDID was '$run_simulator_udid'"
[[ "$run_simulator_name" == "iPhone 16 Pro" ]] \
  || fail "structured action run Simulator name was '$run_simulator_name'"
[[ -z "$last_error" ]] || fail "session reported an error: $last_error"

"$LAUNCH" logs "$NAME" > "$ARTIFACTS/launcher-logs.txt"
/usr/bin/grep -Fqx 'CODEX_SIMULATOR_UDID=FAKE-SHUTDOWN-UDID' "$ARTIFACTS/launcher-logs.txt" \
  || fail "selected Simulator UDID was not exposed to the host command"
/usr/bin/grep -Fqx 'CODEX_SIMULATOR_NAME=iPhone 16 Pro' "$ARTIFACTS/launcher-logs.txt" \
  || fail "selected Simulator name was not exposed to the host command"

/usr/bin/python3 - "$EXPECTED_LOG" "$FAKE_APP" <<'PY'
from pathlib import Path
import sys

output_path, app_path = sys.argv[1:]
commands = [
    "simctl list devices available --json",
    "simctl boot FAKE-SHUTDOWN-UDID",
    "simctl bootstatus FAKE-SHUTDOWN-UDID -b",
    "open -a Simulator --args -CurrentDeviceUDID FAKE-SHUTDOWN-UDID",
    f"simctl install FAKE-SHUTDOWN-UDID {app_path}",
    r"simctl launch FAKE-SHUTDOWN-UDID com.example.Fake --demo safe\ arg --mode=test",
]
Path(output_path).write_text("\n".join(commands) + "\n", encoding="utf-8")
PY

[[ -f "$SIM_LOG" ]] || fail "fake Simulator command log was not created"
if ! /usr/bin/cmp -s "$EXPECTED_LOG" "$SIM_LOG"; then
  /usr/bin/diff -u "$EXPECTED_LOG" "$SIM_LOG" >&2 || true
  fail "Simulator commands, ordering, selected UDID, or bundle arguments differed"
fi

# A helper that ignores TERM and forks a pipe-holding descendant must time out without
# deadlocking the daemon. Only the exact direct helper PID is signalled; closing the bounded
# capture pipes causes the unowned fixture descendant to observe BrokenPipe and exit itself.
TIMEOUT_NAME="$NAME-timeout"
print -r -- hang-descendant > "$MODE_FILE"
"$LAUNCH" create "$TIMEOUT_NAME" "Verify helper timeout with inherited descendant pipes" \
  --directory "$PROJECT" \
  --tag ios --tag timeout --tag integration \
  --type ios \
  --open simulator \
  -- /usr/bin/true \
  > "$ARTIFACTS/timeout-created.txt"

SECONDS=0
"$LAUNCH" "$TIMEOUT_NAME" --json > "$ARTIFACTS/timeout-session.json"
timeout_elapsed=$SECONDS
(( timeout_elapsed < 10 )) || fail "hanging helper took ${timeout_elapsed}s instead of returning within the bounded timeout"
"$LAUNCH" details "$TIMEOUT_NAME" --json > "$ARTIFACTS/timeout-details.json"
timeout_state=$(/usr/bin/plutil -extract lastSession.state raw -o - "$ARTIFACTS/timeout-details.json" 2>/dev/null || true)
timeout_error=$(/usr/bin/plutil -extract lastSession.lastError raw -o - "$ARTIFACTS/timeout-details.json" 2>/dev/null || true)
[[ "$timeout_state" == failed ]] || fail "helper timeout session ended in state '$timeout_state'"
[[ "$timeout_error" == *"Launcher helper command timed out"* ]] \
  || fail "helper timeout error did not identify the bounded command timeout"
[[ -f "$HANG_PARENT_PID" ]] || fail "hanging helper did not publish its direct PID"
[[ -f "$HANG_CHILD_PID" ]] || fail "hanging helper did not publish its pipe-holding descendant PID"
hanging_parent="$(<"$HANG_PARENT_PID")"
hanging_child="$(<"$HANG_CHILD_PID")"
if /bin/kill -0 "$hanging_parent" 2>/dev/null; then
  fail "exact timed-out helper PID $hanging_parent remained alive after SIGTERM/SIGKILL escalation"
fi
descendant_exited=0
for attempt in {1..200}; do
  if ! /bin/kill -0 "$hanging_child" 2>/dev/null; then
    descendant_exited=1
    break
  fi
  /bin/sleep 0.01
done
[[ "$descendant_exited" == 1 ]] \
  || fail "pipe-holding fixture descendant $hanging_child did not exit after bounded capture closed"

close_daemon || fail "temporary managed daemon could not be closed"
stopped=$(/usr/bin/plutil -extract result.stopped raw -o - "$DAEMON_CLOSE" 2>/dev/null || true)
[[ "$stopped" == true ]] || fail "codex-port did not confirm daemon termination"
trap - EXIT INT TERM

print "SIMULATOR ORCHESTRATION PASS"
print "Device: FAKE-SHUTDOWN-UDID (iPhone 16 Pro)"
print "Order: list -> boot -> bootstatus -> open -> install -> launch"
print "Helper capture: 512 KiB stderr drained; exact-PID timeout returned with descendant-held pipes"
print "Artifacts: $ARTIFACTS"
