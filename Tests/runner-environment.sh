#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE

ROOT="${0:A:h:h}"
RUNNER="${RUNNER_BINARY:-$ROOT/.build/debug/launchstation-runner}"
STAMP="${LAUNCH_STATION_RUNNER_TEST_STAMP:-$(date +%s)-$$}"
ARTIFACTS="${LAUNCH_STATION_RUNNER_TEST_ARTIFACTS:-/tmp/launchstation-runner-test-$STAMP}"
mkdir -p "$ARTIFACTS"

fail() {
  print -u2 "Runner environment failure: $1"
  exit 1
}

[[ -x "$RUNNER" ]] || fail "runner binary is unavailable: $RUNNER"

SPEC="$ARTIFACTS/spec.json"
STATUS="$ARTIFACTS/status.json"
OUTPUT="$ARTIFACTS/environment.txt"

/usr/bin/python3 - "$SPEC" "$STATUS" <<'PY'
import json
import sys

spec_path, status_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "7A76ECDB-2185-407A-B742-992F7790A1C1",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/env",
        "arguments": [],
        "environment": {
            "EXPLICIT_VALUE": "kept",
            "PORT_COPY": "${PORT}",
        },
        "portEnvironmentVariable": "PORT",
        "hostEnvironmentVariable": "HOST",
        "statusPath": status_path,
    }, handle)
PY

env LEAK_ME=must-not-cross CODEX_PORT=43123 CODEX_HOST=127.0.0.1 CODEX_SERVICE_ID=manager-only \
  "$RUNNER" --spec "$SPEC" > "$OUTPUT"

/usr/bin/grep -qx 'EXPLICIT_VALUE=kept' "$OUTPUT" || fail "explicit environment value was not preserved"
/usr/bin/grep -qx 'CODEX_PORT=43123' "$OUTPUT" || fail "manager CODEX_PORT was not preserved"
/usr/bin/grep -qx 'CODEX_HOST=127.0.0.1' "$OUTPUT" || fail "manager CODEX_HOST was not preserved"
/usr/bin/grep -qx 'PORT=43123' "$OUTPUT" || fail "configured port environment was not mapped"
/usr/bin/grep -qx 'HOST=127.0.0.1' "$OUTPUT" || fail "configured host environment was not mapped"
/usr/bin/grep -qx 'PORT_COPY=43123' "$OUTPUT" || fail "configured environment expansion did not use the managed port"
if /usr/bin/grep -q '^LEAK_ME=' "$OUTPUT"; then
  fail "an unrequested runner environment variable leaked into the child"
fi
if /usr/bin/grep -q '^CODEX_SERVICE_ID=' "$OUTPUT"; then
  fail "the manager's service identity leaked into the child"
fi
/usr/bin/grep -q '^PATH=.*/opt/homebrew/bin:.*' "$OUTPUT" || fail "baseline PATH is not Homebrew-inclusive"

UNMANAGED_SPEC="$ARTIFACTS/unmanaged.json"
/usr/bin/python3 - "$UNMANAGED_SPEC" "$ARTIFACTS/unmanaged-status.json" <<'PY'
import json
import sys

spec_path, status_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "098611D5-FC0F-4729-A4CF-85F2F3566DA6",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/env",
        "arguments": [],
        "environment": {},
        "statusPath": status_path,
    }, handle)
PY
env CODEX_PORT=43124 CODEX_HOST=127.0.0.2 CODEX_SERVICE_ID=manager-only \
  "$RUNNER" --spec "$UNMANAGED_SPEC" > "$ARTIFACTS/unmanaged-environment.txt"
if /usr/bin/grep -q '^CODEX_\(PORT\|HOST\|SERVICE_ID\)=' "$ARTIFACTS/unmanaged-environment.txt"; then
  fail "the daemon's own manager environment leaked into an unmanaged child"
fi

RELATIVE_WORKDIR="$ARTIFACTS/relative-workdir"
RELATIVE_SPEC="$ARTIFACTS/relative-spec.json"
mkdir -p "$RELATIVE_WORKDIR"
/usr/bin/python3 - "$RELATIVE_WORKDIR/relative-tool" "$RELATIVE_SPEC" "$ARTIFACTS/relative-status.json" "$RELATIVE_WORKDIR" <<'PY'
import json
import os
import sys

tool_path, spec_path, status_path, workdir = sys.argv[1:]
with open(tool_path, "w", encoding="utf-8") as handle:
    handle.write("#!/bin/sh\nprintenv RELATIVE_MARKER\n")
os.chmod(tool_path, 0o755)
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "8FA7138B-E10B-4D55-BC4F-EFD3B8AB5DA4",
        "workingDirectory": workdir,
        "executable": "./relative-tool",
        "arguments": [],
        "environment": {"RELATIVE_MARKER": "relative-ok"},
        "statusPath": status_path,
    }, handle)
PY
"$RUNNER" --spec "$RELATIVE_SPEC" > "$ARTIFACTS/relative-output.txt"
/usr/bin/grep -qx 'relative-ok' "$ARTIFACTS/relative-output.txt" \
  || fail "slash-containing relative executable did not resolve from the action working directory"

RESERVED_SPEC="$ARTIFACTS/reserved.json"
/usr/bin/python3 - "$RESERVED_SPEC" "$ARTIFACTS/reserved-status.json" <<'PY'
import json
import sys

spec_path, status_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "6C7C6D31-7636-4CD2-80BD-60651B33B925",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/true",
        "arguments": [],
        "environment": {"CODEX_PORT": "9999"},
        "statusPath": status_path,
    }, handle)
PY

set +e
"$RUNNER" --spec "$RESERVED_SPEC" > "$ARTIFACTS/reserved-output.txt" 2> "$ARTIFACTS/reserved-error.txt"
reserved_status=$?
set -e
[[ "$reserved_status" == 126 ]] || fail "reserved manager environment returned $reserved_status instead of 126"
/usr/bin/grep -q 'CODEX_PORT is owned by codex-port' "$ARTIFACTS/reserved-error.txt" || fail "reserved manager environment error was unclear"

RESERVED_SERVICE_SPEC="$ARTIFACTS/reserved-service.json"
/usr/bin/python3 - "$RESERVED_SERVICE_SPEC" "$ARTIFACTS/reserved-service-status.json" <<'PY'
import json
import sys

spec_path, status_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "AC070067-427F-4D25-B3E4-A7D1EDE21AB6",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/true",
        "arguments": [],
        "environment": {"CODEX_SERVICE_ID": "spoofed"},
        "statusPath": status_path,
    }, handle)
PY

set +e
"$RUNNER" --spec "$RESERVED_SERVICE_SPEC" > "$ARTIFACTS/reserved-service-output.txt" 2> "$ARTIFACTS/reserved-service-error.txt"
reserved_service_status=$?
set -e
[[ "$reserved_service_status" == 126 ]] || fail "reserved service identity returned $reserved_service_status instead of 126"
/usr/bin/grep -q 'CODEX_SERVICE_ID is owned by codex-port' "$ARTIFACTS/reserved-service-error.txt" || fail "reserved service identity error was unclear"

ALIAS_COLLISION_SPEC="$ARTIFACTS/alias-collision.json"
/usr/bin/python3 - "$ALIAS_COLLISION_SPEC" "$ARTIFACTS/alias-collision-status.json" <<'PY'
import json
import sys

spec_path, status_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "CB506826-867B-4C6D-9D6B-70A75A726DDA",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/true",
        "arguments": [],
        "environment": {"PORT": "9999"},
        "portEnvironmentVariable": "PORT",
        "hostEnvironmentVariable": "HOST",
        "statusPath": status_path,
    }, handle)
PY

set +e
env CODEX_PORT=43126 CODEX_HOST=127.0.0.1 \
  "$RUNNER" --spec "$ALIAS_COLLISION_SPEC" \
  > "$ARTIFACTS/alias-collision-output.txt" 2> "$ARTIFACTS/alias-collision-error.txt"
alias_collision_status=$?
set -e
[[ "$alias_collision_status" == 126 ]] || fail "managed alias collision returned $alias_collision_status instead of 126"
/usr/bin/grep -q 'Managed environment alias PORT cannot also be configured' "$ARTIFACTS/alias-collision-error.txt" \
  || fail "managed alias collision error was unclear"

DUPLICATE_ALIAS_SPEC="$ARTIFACTS/duplicate-alias.json"
/usr/bin/python3 - "$DUPLICATE_ALIAS_SPEC" "$ARTIFACTS/duplicate-alias-status.json" <<'PY'
import json
import sys

spec_path, status_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "76ECF687-264E-4F17-B902-B061034FF418",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/true",
        "arguments": [],
        "environment": {},
        "portEnvironmentVariable": "SERVICE_ADDRESS",
        "hostEnvironmentVariable": "SERVICE_ADDRESS",
        "statusPath": status_path,
    }, handle)
PY

set +e
env CODEX_PORT=43127 CODEX_HOST=127.0.0.1 \
  "$RUNNER" --spec "$DUPLICATE_ALIAS_SPEC" \
  > "$ARTIFACTS/duplicate-alias-output.txt" 2> "$ARTIFACTS/duplicate-alias-error.txt"
duplicate_alias_status=$?
set -e
[[ "$duplicate_alias_status" == 126 ]] || fail "duplicate managed aliases returned $duplicate_alias_status instead of 126"
/usr/bin/grep -q 'Managed port and host environment aliases must be distinct' "$ARTIFACTS/duplicate-alias-error.txt" \
  || fail "duplicate managed alias error was unclear"

GROUP_SPEC="$ARTIFACTS/process-group.json"
GROUP_STATUS="$ARTIFACTS/process-group-status.json"
GROUP_OUTPUT="$ARTIFACTS/child-process-group.txt"
/usr/bin/python3 - "$GROUP_SPEC" "$GROUP_STATUS" "$GROUP_OUTPUT" "$ROOT/Tests/fixtures/report-process-group.sh" <<'PY'
import json
import sys

spec_path, status_path, output_path, fixture_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "1ABEBF2D-6955-432B-BA59-C62148634601",
        "workingDirectory": "/tmp",
        "executable": fixture_path,
        "arguments": [output_path],
        "environment": {},
        "portEnvironmentVariable": "PORT",
        "hostEnvironmentVariable": "HOST",
        "statusPath": status_path,
    }, handle)
PY

env CODEX_PORT=43125 CODEX_HOST=127.0.0.1 "$RUNNER" --spec "$GROUP_SPEC"
/usr/bin/python3 - "$GROUP_STATUS" "$GROUP_OUTPUT" <<'PY'
import json
import sys

status_path, output_path = sys.argv[1:]
with open(status_path, encoding="utf-8") as handle:
    runner_group = int(json.load(handle)["processGroupID"])
with open(output_path, encoding="utf-8") as handle:
    child_group = int(handle.read().strip())
if child_group != runner_group:
    raise SystemExit(
        f"Runner environment failure: child process group {child_group} escaped runner group {runner_group}"
    )
PY

GATE_SPEC="$ARTIFACTS/start-gate.json"
GATE_STATUS="$ARTIFACTS/start-gate-status.json"
GATE_ACKNOWLEDGEMENT="$ARTIFACTS/start-gate-acknowledgement.json"
GATE_MARKER="$ARTIFACTS/start-gate-command-ran.txt"
/usr/bin/python3 - "$GATE_SPEC" "$GATE_STATUS" "$GATE_ACKNOWLEDGEMENT" "$GATE_MARKER" <<'PY'
import json
import sys

spec_path, status_path, acknowledgement_path, marker_path = sys.argv[1:]
with open(spec_path, "w", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "runID": "DB86BAE3-FA12-4BD9-A482-2D4D37FE1629",
        "workingDirectory": "/tmp",
        "executable": "/usr/bin/python3",
        "arguments": [
            "-c",
            "import pathlib, sys; pathlib.Path(sys.argv[1]).write_text('released', encoding='utf-8')",
            marker_path,
        ],
        "environment": {},
        "statusPath": status_path,
        "acknowledgementPath": acknowledgement_path,
    }, handle)
PY

gate_pid=""
cleanup_gate() {
  if [[ -n "$gate_pid" ]] && /bin/kill -0 "$gate_pid" 2>/dev/null; then
    /bin/kill -KILL "$gate_pid" 2>/dev/null || true
    wait "$gate_pid" 2>/dev/null || true
  fi
}
trap cleanup_gate EXIT

"$RUNNER" --spec "$GATE_SPEC" > "$ARTIFACTS/start-gate-output.txt" 2> "$ARTIFACTS/start-gate-error.txt" &
gate_pid=$!
gate_status_seen=0
for attempt in {1..200}; do
  if [[ -f "$GATE_STATUS" ]]; then
    gate_status_seen=1
    break
  fi
  /bin/kill -0 "$gate_pid" 2>/dev/null || break
  /bin/sleep 0.01
done
[[ "$gate_status_seen" == 1 ]] || fail "runner did not publish its exact identity before the start gate"
[[ ! -e "$GATE_MARKER" ]] || fail "fast command ran before the daemon acknowledgement"
/bin/kill -0 "$gate_pid" 2>/dev/null || fail "runner did not remain live for birth-identity validation"

/usr/bin/python3 - "$GATE_STATUS" "$GATE_ACKNOWLEDGEMENT" <<'PY'
import json
import os
import sys

status_path, acknowledgement_path = sys.argv[1:]
with open(status_path, encoding="utf-8") as handle:
    status = json.load(handle)
acknowledgement = {
    "schemaVersion": 1,
    "runID": status["runID"],
    "pid": status["pid"],
    "pidStartIdentity": status["pidStartIdentity"],
}
temporary_path = acknowledgement_path + ".tmp"
with open(temporary_path, "w", encoding="utf-8") as handle:
    json.dump(acknowledgement, handle)
os.replace(temporary_path, acknowledgement_path)
PY

set +e
wait "$gate_pid"
gate_exit=$?
set -e
gate_pid=""
[[ "$gate_exit" == 0 ]] || fail "acknowledged fast command returned $gate_exit instead of 0"
[[ "$(<"$GATE_MARKER")" == released ]] || fail "acknowledged fast command did not run"
trap - EXIT

print "RUNNER ENVIRONMENT PASS"
print "Artifacts: $ARTIFACTS"
