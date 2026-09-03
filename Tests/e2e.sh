#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE

ROOT="${0:A:h:h}"
LAUNCH="${LAUNCH_BINARY:-$ROOT/.build/debug/launch}"
STATE_DIR="${CODEX_LAUNCHER_STATE_DIR:?Set CODEX_LAUNCHER_STATE_DIR to the daemon test state directory}"
STAMP="${CODEX_LAUNCHER_E2E_STAMP:-$(date +%s)}"
PROJECT="${CODEX_LAUNCHER_E2E_PROJECT:-/tmp/codex-launcher-project-$STAMP}"
ARTIFACTS="${CODEX_LAUNCHER_E2E_ARTIFACTS:-/tmp/codex-launcher-e2e-artifacts-$STAMP}"
UNMANAGED_PROJECT="${CODEX_LAUNCHER_E2E_UNMANAGED_PROJECT:-/tmp/codex-launcher-unmanaged-project-$STAMP}"
WEB="launcher-web-$STAMP"
NATURAL="launcher-natural-$STAMP"
MUTABLE="launcher-mutable-$STAMP"
RENAMED="launcher-renamed-$STAMP"
SHELLARGS="launcher-shell-args-$STAMP"
RELAUNCHARGS="launcher-relaunch-args-$STAMP"
RACE="launcher-close-race-$STAMP"
ENCODED="launcher-literal-%2F-$STAMP"

export CODEX_LAUNCHER_STATE_DIR="$STATE_DIR"
mkdir -p "$PROJECT" "$ARTIFACTS" "$UNMANAGED_PROJECT"

web_started=0
web_additional_session_id=""
race_started=0
relaunch_args_started=0
maintenance_token=""
cleanup_active_session() {
  if [[ -n "$maintenance_token" ]]; then
    "$LAUNCH" maintenance cancel-upgrade "$maintenance_token" --json >/dev/null 2>&1 || true
  fi
  if [[ "$web_started" == 1 ]]; then
    if [[ -n "$web_additional_session_id" ]]; then
      "$LAUNCH" close "$WEB" --session "$web_additional_session_id" >/dev/null 2>&1 || true
    fi
    "$LAUNCH" close "$WEB" >/dev/null 2>&1 || true
  fi
  if [[ "$race_started" == 1 ]]; then
    "$LAUNCH" close "$RACE" >/dev/null 2>&1 || true
  fi
  if [[ "$relaunch_args_started" == 1 ]]; then
    "$LAUNCH" close "$RELAUNCHARGS" >/dev/null 2>&1 || true
  fi
}
trap cleanup_active_session EXIT

fail() {
  print -u2 "E2E failure: $1"
  exit 1
}

endpoint=$(/usr/bin/plutil -extract endpoint raw -o - "$STATE_DIR/service.json")
unauthorized=$(/usr/bin/curl -sS -o /dev/null -w '%{http_code}' "$endpoint/v1/health")
[[ "$unauthorized" == 401 ]] || fail "unauthenticated health request returned HTTP $unauthorized"

unmanaged_manifest="$UNMANAGED_PROJECT/launch_details.md"
print -rn -- 'USER OWNED LAUNCH NOTES — MUST NOT BE REPLACED' > "$unmanaged_manifest"
chmod 0640 "$unmanaged_manifest"
unmanaged_hash_before=$(/usr/bin/shasum -a 256 "$unmanaged_manifest" | /usr/bin/awk '{print $1}')
unmanaged_mode_before=$(stat -f '%Lp' "$unmanaged_manifest")
set +e
"$LAUNCH" init "$UNMANAGED_PROJECT" --project-name "Must Not Register $STAMP" > "$ARTIFACTS/unmanaged-init-conflict.txt" 2>&1
unmanaged_init_status=$?
"$LAUNCH" list --directory "$UNMANAGED_PROJECT" --json > "$ARTIFACTS/unmanaged-project-lookup.txt" 2>&1
unmanaged_lookup_status=$?
set -e
unmanaged_hash_after=$(/usr/bin/shasum -a 256 "$unmanaged_manifest" | /usr/bin/awk '{print $1}')
unmanaged_mode_after=$(stat -f '%Lp' "$unmanaged_manifest")
[[ "$unmanaged_init_status" == 4 ]] || fail "init over unmanaged launch_details.md returned exit $unmanaged_init_status instead of 4"
[[ "$unmanaged_lookup_status" == 3 ]] || fail "rejected unmanaged project was still registered"
[[ "$unmanaged_hash_after" == "$unmanaged_hash_before" ]] || fail "init changed unmanaged launch_details.md bytes"
[[ "$unmanaged_mode_after" == "$unmanaged_mode_before" ]] || fail "init changed unmanaged launch_details.md mode"
print "Fixture retained: $unmanaged_manifest" > "$ARTIFACTS/unmanaged-fixture-retained.txt"

"$LAUNCH" init "$PROJECT" --project-name "Launcher E2E $STAMP" --json > "$ARTIFACTS/project.json"
[[ -f "$PROJECT/launch_details.md" ]] || fail "project manifest was not generated"
[[ "$(stat -f '%Lp' "$PROJECT/launch_details.md")" == 444 ]] || fail "project manifest is not read-only"

"$LAUNCH" create "$WEB" "Managed Python server plus companion process" \
  --directory "$PROJECT" \
  --tag web --tag compound \
  --type process --port auto \
  --url 'http://{{host}}:{{port}}/' \
  --health 'http://{{host}}:{{port}}/' \
  --ready-timeout 15 \
  -- python3 -m http.server '${PORT}' > "$ARTIFACTS/web-created.txt"
"$LAUNCH" list --directory "$PROJECT" --json > "$ARTIFACTS/project-catalog.json"
[[ "$(/usr/bin/plutil -extract 0.launcher.name raw -o - "$ARTIFACTS/project-catalog.json")" == "$WEB" ]] || fail "project-filtered list did not return the registered launcher"

set +e
"$LAUNCH" create "  LAUNCHER-WEB-$STAMP  " "Duplicate normalized name" \
  --directory "$PROJECT" -- /usr/bin/true > "$ARTIFACTS/duplicate.txt" 2>&1
duplicate_status=$?
set -e
[[ "$duplicate_status" == 4 ]] || fail "normalized duplicate returned exit $duplicate_status instead of 4"

"$LAUNCH" create "$ENCODED" "Literal percent-encoded name round trip" \
  --directory "$PROJECT" -- /usr/bin/true > "$ARTIFACTS/encoded-created.txt"
"$LAUNCH" details "$ENCODED" --json > "$ARTIFACTS/encoded-details.json"
[[ "$(/usr/bin/plutil -extract launcher.name raw -o - "$ARTIFACTS/encoded-details.json")" == "$ENCODED" ]] || fail "literal percent-encoded launcher name was decoded twice"

"$LAUNCH" action add "$WEB" companion "Long-running companion service" \
  --env 'LINKED_MAIN_URL=${CODEX_LAUNCHER_ACTION_MAIN_URL}' \
  -- /bin/sh -c 'echo "linked-main:$LINKED_MAIN_URL"; while :; do sleep 1; done' > "$ARTIFACTS/action-added.txt"
"$LAUNCH" update "$WEB" --primary-action companion \
  --action-description "Selected companion action" > "$ARTIFACTS/primary-companion.txt"
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/primary-companion-details.json"
[[ "$(/usr/bin/plutil -extract launcher.actions.1.description raw -o - "$ARTIFACTS/primary-companion-details.json")" == "Selected companion action" ]] || fail "combined primary selection mutated the wrong action"
"$LAUNCH" update "$WEB" --primary-action main > "$ARTIFACTS/primary-main.txt"

set +e
"$LAUNCH" action update "$WEB" companion --description "Must not apply" --if-revision typo > "$ARTIFACTS/action-invalid-revision.txt" 2>&1
action_invalid_revision_status=$?
"$LAUNCH" list --state nonsense > "$ARTIFACTS/list-invalid-state.txt" 2>&1
list_invalid_state_status=$?
"$LAUNCH" action add "$WEB" invalid-options "Rejected project-only options" --tag invalid -- /usr/bin/true > "$ARTIFACTS/action-invalid-options.txt" 2>&1
action_invalid_options_status=$?
set -e
[[ "$action_invalid_revision_status" == 2 ]] || fail "malformed action revision was not rejected as usage"
[[ "$list_invalid_state_status" == 2 ]] || fail "invalid state filter was not rejected as usage"
[[ "$action_invalid_options_status" == 2 ]] || fail "action add accepted launcher-only project options"

"$LAUNCH" action add "$WEB" ios-definition "Preserve an explicitly selected iOS action type" \
  --type ios -- /usr/bin/true > "$ARTIFACTS/ios-action-added.txt"
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/ios-action-details.json"
[[ "$(/usr/bin/plutil -extract launcher.actions.2.runner raw -o - "$ARTIFACTS/ios-action-details.json")" == ios ]] || fail "action add changed an explicit iOS runner to process"
ios_action_revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$ARTIFACTS/ios-action-details.json")
"$LAUNCH" action delete "$WEB" ios-definition --yes --if-revision "$ios_action_revision" > "$ARTIFACTS/ios-action-deleted.txt"

"$LAUNCH" action add "$WEB" disposable "Disposable action for mutation tests" \
  -- /usr/bin/true > "$ARTIFACTS/disposable-added.txt"
"$LAUNCH" action update "$WEB" disposable --name disposable-renamed \
  --description "Renamed disposable action" \
  --type process --executable /usr/bin/printf \
  --clear-args --arg 'updated:%s\n' --arg value \
  --env MODE=verification --inherit-env PATH \
  --port none --open none --ready-timeout 10 --stop-timeout 5 \
  --required --deny-runtime-args --order 2 > "$ARTIFACTS/disposable-updated.txt"
set +e
"$LAUNCH" action delete "$WEB" disposable-renamed --yes --if-revision typo > "$ARTIFACTS/action-delete-invalid-revision.txt" 2>&1
action_delete_invalid_revision_status=$?
set -e
[[ "$action_delete_invalid_revision_status" == 2 ]] || fail "malformed action-delete revision was not rejected as usage"
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/disposable-delete-details.json"
disposable_revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$ARTIFACTS/disposable-delete-details.json")
"$LAUNCH" action delete "$WEB" disposable-renamed --yes --if-revision "$disposable_revision" > "$ARTIFACTS/disposable-deleted.txt"
"$LAUNCH" action add "$WEB" post-delete "Order remains unique after deletion" \
  -- /usr/bin/true > "$ARTIFACTS/post-delete-added.txt"
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/post-delete-details.json"
post_delete_revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$ARTIFACTS/post-delete-details.json")
"$LAUNCH" action delete "$WEB" post-delete --yes --if-revision "$post_delete_revision" > "$ARTIFACTS/post-delete-deleted.txt"

"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-before-update.json"
old_revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$ARTIFACTS/web-before-update.json")
"$LAUNCH" update "$WEB" --description "Verified managed server and companion" --add-tag verified > "$ARTIFACTS/web-updated.txt"
set +e
"$LAUNCH" update "$WEB" --description "Stale write must fail" --if-revision "$old_revision" > "$ARTIFACTS/stale-update.txt" 2>&1
stale_status=$?
set -e
[[ "$stale_status" == 4 ]] || fail "stale update returned exit $stale_status instead of 4"

token=$(/usr/bin/plutil -extract token raw -o - "$STATE_DIR/service.json")
web_launcher_id=$(/usr/bin/plutil -extract launcher.id raw -o - "$ARTIFACTS/web-before-update.json")
stale_start_http=$(/usr/bin/curl -sS -o "$ARTIFACTS/stale-start-response.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' \
  --data "{\"runtimeArguments\":[],\"openRequested\":false,\"expectedLauncherRevision\":$old_revision}" \
  "$endpoint/v1/launchers/$web_launcher_id/sessions")
unset token
[[ "$stale_start_http" == 409 ]] || fail "start with a stale displayed launcher revision returned HTTP $stale_start_http instead of 409"

set +e
"$LAUNCH" "$WEB" --wait > "$ARTIFACTS/run-invalid-wait.txt" 2>&1
invalid_wait_status=$?
set -e
[[ "$invalid_wait_status" == 2 ]] || fail "unsupported --wait option was silently accepted"

maintenance_json=$("$LAUNCH" maintenance prepare-upgrade --json)
maintenance_token=$(print -rn -- "$maintenance_json" | /usr/bin/plutil -extract reservationToken raw -o - -)
[[ -n "$maintenance_token" ]] || fail "upgrade maintenance preparation returned no reservation"
set +e
"$LAUNCH" "$WEB" --json > "$ARTIFACTS/maintenance-blocked-start.txt" 2>&1
maintenance_start_status=$?
"$LAUNCH" maintenance cancel-upgrade wrong-reservation-token --json > "$ARTIFACTS/maintenance-wrong-cancel.txt" 2>&1
maintenance_wrong_cancel_status=$?
set -e
[[ "$maintenance_start_status" == 4 ]] || fail "upgrade reservation did not block a new launcher session"
[[ "$maintenance_wrong_cancel_status" == 4 ]] || fail "wrong upgrade reservation token cancelled the mutation gate"
"$LAUNCH" status --json > "$ARTIFACTS/maintenance-read-status.json"
"$LAUNCH" maintenance cancel-upgrade "$maintenance_token" --json > "$ARTIFACTS/maintenance-cancelled.json"
maintenance_token=""

"$LAUNCH" "$WEB" --json > "$ARTIFACTS/web-session.json"
web_started=1
[[ "$(/usr/bin/plutil -extract state raw -o - "$ARTIFACTS/web-session.json")" == running ]] || fail "compound launcher did not become running"
set +e
"$LAUNCH" maintenance prepare-upgrade --json > "$ARTIFACTS/maintenance-active-rejected.txt" 2>&1
maintenance_active_status=$?
set -e
[[ "$maintenance_active_status" == 4 ]] || fail "upgrade preparation accepted an active launcher session"
run_count=$(/usr/bin/plutil -extract actionRuns json -o - "$ARTIFACTS/web-session.json" | /usr/bin/grep -o '"actionID"' | /usr/bin/wc -l | tr -d ' ')
[[ "$run_count" -ge 2 ]] || fail "compound launcher did not return two action runs"
web_endpoint=$(/usr/bin/plutil -extract actionRuns.0.endpointURL raw -o - "$ARTIFACTS/web-session.json")
[[ "$web_endpoint" != "$endpoint" ]] || fail "managed application reused the daemon port"
/usr/bin/curl -fsS "$web_endpoint" > "$ARTIFACTS/web-response.html"
"$LAUNCH" open "$WEB" --json > "$ARTIFACTS/web-open-options.json"
[[ "$(/usr/bin/plutil -extract 0.kind raw -o - "$ARTIFACTS/web-open-options.json")" == browser ]] \
  || fail "running HTTP session did not expose a server-derived browser option"
"$LAUNCH" external list --refresh --json > "$ARTIFACTS/external-listeners-with-managed-web.json"
web_session_id=$(/usr/bin/plutil -extract id raw -o - "$ARTIFACTS/web-session.json")
/usr/bin/python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); sid=sys.argv[2]; sys.exit(0 if any(item.get("ownership", {}).get("kind") == "launcher-owned" and item.get("ownership", {}).get("sessionID") == sid for item in data.get("observations", [])) else 1)' \
  "$ARTIFACTS/external-listeners-with-managed-web.json" "$web_session_id" \
  || fail "listener discovery did not correlate the managed web process back to its exact session"
"$LAUNCH" logs "$WEB" > "$ARTIFACTS/web-logs.txt"
/usr/bin/grep -E 'linked-main:http://(127\.0\.0\.1|localhost):[0-9]+' "$ARTIFACTS/web-logs.txt" >/dev/null \
  || fail "later compound action did not receive the earlier action endpoint environment"

"$LAUNCH" "$WEB" --new --json > "$ARTIFACTS/web-additional-session.json"
web_additional_session_id=$(/usr/bin/plutil -extract id raw -o - "$ARTIFACTS/web-additional-session.json")
[[ "$(/usr/bin/plutil -extract launchRole raw -o - "$ARTIFACTS/web-additional-session.json")" == additional ]] \
  || fail "--new did not create an additional session"
additional_endpoint=$(/usr/bin/plutil -extract actionRuns.0.endpointURL raw -o - "$ARTIFACTS/web-additional-session.json")
[[ "$additional_endpoint" != "$web_endpoint" ]] || fail "simultaneous managed instances overlapped one endpoint"
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-two-active-sessions.json"
active_session_count=$(/usr/bin/plutil -extract activeSessions json -o - "$ARTIFACTS/web-two-active-sessions.json" | /usr/bin/grep -o '"launcherID"' | /usr/bin/wc -l | tr -d ' ')
[[ "$active_session_count" == 2 ]] || fail "launcher details did not report both primary and additional sessions"
"$LAUNCH" history "$WEB" --role additional --limit 10 --json > "$ARTIFACTS/web-additional-history.json"
history_additional_id=$(/usr/bin/plutil -extract sessions.0.id raw -o - "$ARTIFACTS/web-additional-history.json")
[[ "$history_additional_id" == "$web_additional_session_id" ]] || fail "role-filtered history omitted the active additional session"

"$LAUNCH" relaunch "$WEB" --session "$web_additional_session_id" --json > "$ARTIFACTS/web-additional-relaunch.json"
replaced_additional_id=$(/usr/bin/plutil -extract previousSession.id raw -o - "$ARTIFACTS/web-additional-relaunch.json")
replacement_additional_id=$(/usr/bin/plutil -extract session.id raw -o - "$ARTIFACTS/web-additional-relaunch.json")
[[ "$replaced_additional_id" == "$web_additional_session_id" ]] || fail "exact additional relaunch replaced the wrong session"
[[ "$replacement_additional_id" != "$web_additional_session_id" ]] || fail "exact additional relaunch reused the old session identity"
[[ "$(/usr/bin/plutil -extract session.launchRole raw -o - "$ARTIFACTS/web-additional-relaunch.json")" == additional ]] \
  || fail "exact additional relaunch lost its additional role"
web_additional_session_id="$replacement_additional_id"
"$LAUNCH" close "$WEB" --session "$web_additional_session_id" --json > "$ARTIFACTS/web-additional-closed.json"
[[ "$(/usr/bin/plutil -extract state raw -o - "$ARTIFACTS/web-additional-closed.json")" == exited ]] \
  || fail "exact additional close did not reach exited"
web_additional_session_id=""
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-primary-after-additional-close.json"
[[ "$(/usr/bin/plutil -extract activeSession.id raw -o - "$ARTIFACTS/web-primary-after-additional-close.json")" == "$(/usr/bin/plutil -extract id raw -o - "$ARTIFACTS/web-session.json")" ]] \
  || fail "closing the additional session disturbed the primary session"

"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-precondition-details.json"
web_current_revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$ARTIFACTS/web-precondition-details.json")
web_current_session_id=$(/usr/bin/plutil -extract activeSession.id raw -o - "$ARTIFACTS/web-precondition-details.json")
wrong_session_id=$(/usr/bin/uuidgen)
token=$(/usr/bin/plutil -extract token raw -o - "$STATE_DIR/service.json")
idle_while_active_http=$(/usr/bin/curl -sS -o "$ARTIFACTS/relaunch-require-idle-active.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data "{\"runtimeArguments\":[],\"openRequested\":false,\"requireIdle\":true,\"expectedLauncherRevision\":$web_current_revision}" \
  "$endpoint/v1/launchers/$web_launcher_id/relaunch")
wrong_session_http=$(/usr/bin/curl -sS -o "$ARTIFACTS/relaunch-wrong-session.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data "{\"runtimeArguments\":[],\"openRequested\":false,\"expectedSessionID\":\"$wrong_session_id\",\"requireIdle\":false,\"expectedLauncherRevision\":$web_current_revision}" \
  "$endpoint/v1/launchers/$web_launcher_id/relaunch")
both_preconditions_http=$(/usr/bin/curl -sS -o "$ARTIFACTS/relaunch-both-preconditions.json" -w '%{http_code}' \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data "{\"runtimeArguments\":[],\"openRequested\":false,\"expectedSessionID\":\"$web_current_session_id\",\"requireIdle\":true,\"expectedLauncherRevision\":$web_current_revision}" \
  "$endpoint/v1/launchers/$web_launcher_id/relaunch")
unset token
[[ "$idle_while_active_http" == 409 ]] || fail "requireIdle relaunch against an active session returned HTTP $idle_while_active_http"
[[ "$wrong_session_http" == 409 ]] || fail "wrong expectedSessionID returned HTTP $wrong_session_http"
[[ "$both_preconditions_http" == 400 ]] || fail "mutually exclusive relaunch preconditions returned HTTP $both_preconditions_http"
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-after-precondition-rejections.json"
[[ "$(/usr/bin/plutil -extract activeSession.id raw -o - "$ARTIFACTS/web-after-precondition-rejections.json")" == "$web_current_session_id" ]] \
  || fail "a rejected relaunch precondition changed the exact active session"

"$LAUNCH" relaunch "$WEB" --json > "$ARTIFACTS/web-revision-race-relaunch.json" 2> "$ARTIFACTS/web-revision-race-error.txt" &
revision_race_pid=$!
revision_race_seen=0
for attempt in {1..100}; do
  "$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-revision-race-details.json" 2>/dev/null || true
  revision_race_state=$(/usr/bin/plutil -extract activeSession.state raw -o - "$ARTIFACTS/web-revision-race-details.json" 2>/dev/null || true)
  if [[ "$revision_race_state" == stopping ]]; then
    revision_race_seen=1
    break
  fi
  /bin/sleep 0.05
done
[[ "$revision_race_seen" == 1 ]] || fail "did not observe relaunch closing state for revision-race test"
"$LAUNCH" update "$WEB" --description "Revision changed while the exact session closed" > "$ARTIFACTS/web-revision-race-update.txt"
set +e
wait "$revision_race_pid"
revision_race_status=$?
set -e
[[ "$revision_race_status" == 4 ]] || fail "relaunch across a definition update returned $revision_race_status instead of conflict"
web_started=0
"$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-after-revision-race.json"
[[ "$(/usr/bin/plutil -extract lastSession.state raw -o - "$ARTIFACTS/web-after-revision-race.json")" == exited ]] \
  || fail "revision-race relaunch did not leave the old exact session terminal"

"$LAUNCH" "$WEB" --json > "$ARTIFACTS/web-session-after-revision-race.json"
web_started=1
cp "$ARTIFACTS/web-session-after-revision-race.json" "$ARTIFACTS/web-session.json"

web_session_id=$(/usr/bin/plutil -extract id raw -o - "$ARTIFACTS/web-session.json")
web_manager_id=$(/usr/bin/plutil -extract actionRuns.0.managerID raw -o - "$ARTIFACTS/web-session.json")
web_current_revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$ARTIFACTS/web-after-revision-race.json")
token=$(/usr/bin/plutil -extract token raw -o - "$STATE_DIR/service.json")
"$LAUNCH" relaunch "$WEB" --json > "$ARTIFACTS/web-relaunched.json" &
successful_relaunch_pid=$!
relaunch_reservation_seen=0
for attempt in {1..100}; do
  "$LAUNCH" details "$WEB" --json > "$ARTIFACTS/web-concurrent-relaunch-details.json" 2>/dev/null || true
  concurrent_relaunch_state=$(/usr/bin/plutil -extract activeSession.state raw -o - "$ARTIFACTS/web-concurrent-relaunch-details.json" 2>/dev/null || true)
  if [[ "$concurrent_relaunch_state" == stopping ]]; then
    relaunch_reservation_seen=1
    break
  fi
  /bin/sleep 0.05
done
[[ "$relaunch_reservation_seen" == 1 ]] || fail "did not observe the relaunch reservation before concurrent-start checks"
: > "$ARTIFACTS/concurrent-start-http-codes.txt"
for attempt in {1..8}; do
  /usr/bin/curl -sS -o "$ARTIFACTS/concurrent-start-$attempt.json" -w '%{http_code}\n' \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data "{\"runtimeArguments\":[],\"openRequested\":false,\"expectedLauncherRevision\":$web_current_revision}" \
    "$endpoint/v1/launchers/$web_launcher_id/sessions" >> "$ARTIFACTS/concurrent-start-http-codes.txt"
done
wait "$successful_relaunch_pid"
[[ "$(/usr/bin/sort -u "$ARTIFACTS/concurrent-start-http-codes.txt")" == 409 ]] \
  || fail "a concurrent start escaped the relaunch reservation"
/usr/bin/curl -fsS -H "Authorization: Bearer $token" "$endpoint/v1/sessions" > "$ARTIFACTS/sessions-after-concurrent-relaunch.json"
active_web_sessions=$(/usr/bin/python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])); active={"starting","running","partial","stopping"}; print(sum(1 for row in rows if row["launcherID"]==sys.argv[2] and row["state"] in active))' "$ARTIFACTS/sessions-after-concurrent-relaunch.json" "$web_launcher_id")
unset token
[[ "$active_web_sessions" == 1 ]] || fail "concurrent run/relaunch left $active_web_sessions active sessions"
relaunch_previous_id=$(/usr/bin/plutil -extract previousSession.id raw -o - "$ARTIFACTS/web-relaunched.json")
relaunch_previous_state=$(/usr/bin/plutil -extract previousSession.state raw -o - "$ARTIFACTS/web-relaunched.json")
relaunch_session_id=$(/usr/bin/plutil -extract session.id raw -o - "$ARTIFACTS/web-relaunched.json")
relaunch_state=$(/usr/bin/plutil -extract session.state raw -o - "$ARTIFACTS/web-relaunched.json")
relaunch_manager_id=$(/usr/bin/plutil -extract session.actionRuns.0.managerID raw -o - "$ARTIFACTS/web-relaunched.json")
relaunch_endpoint=$(/usr/bin/plutil -extract session.actionRuns.0.endpointURL raw -o - "$ARTIFACTS/web-relaunched.json")
[[ "$relaunch_previous_id" == "$web_session_id" ]] || fail "relaunch did not close the confirmed exact session"
[[ "$relaunch_previous_state" == exited ]] || fail "relaunch started before the previous session was terminal"
[[ "$relaunch_session_id" != "$web_session_id" ]] || fail "relaunch reused the prior session ID"
[[ "$relaunch_state" == running ]] || fail "relaunch replacement did not become running"
[[ "$relaunch_manager_id" != "$web_manager_id" ]] || fail "relaunch reused the prior managed lifecycle owner"
/usr/bin/curl -fsS "$relaunch_endpoint" > "$ARTIFACTS/web-relaunch-response.html"

"$LAUNCH" close "$WEB" --json > "$ARTIFACTS/web-stopped.json"
web_started=0
[[ "$(/usr/bin/plutil -extract state raw -o - "$ARTIFACTS/web-stopped.json")" == exited ]] || fail "compound launcher did not close cleanly"

"$LAUNCH" relaunch "$WEB" --json > "$ARTIFACTS/web-idle-relaunch.json"
web_started=1
idle_relaunch_id=$(/usr/bin/plutil -extract session.id raw -o - "$ARTIFACTS/web-idle-relaunch.json")
idle_relaunch_state=$(/usr/bin/plutil -extract session.state raw -o - "$ARTIFACTS/web-idle-relaunch.json")
[[ "$idle_relaunch_id" != "$relaunch_session_id" ]] || fail "idle relaunch reused an old session ID"
[[ "$idle_relaunch_state" == running ]] || fail "idle relaunch did not start normally"
"$LAUNCH" close "$WEB" --json > "$ARTIFACTS/web-idle-relaunch-stopped.json"
web_started=0

"$LAUNCH" create "$RELAUNCHARGS" "Long-running process used to verify relaunch arguments" \
  --directory "$PROJECT" -- /bin/sh -c 'printf "runtime-args:%s\n" "$*"; while :; do sleep 1; done' launcher \
  > "$ARTIFACTS/relaunch-args-created.txt"
"$LAUNCH" "$RELAUNCHARGS" --json > "$ARTIFACTS/relaunch-args-initial.json"
relaunch_args_started=1
"$LAUNCH" relaunch "$RELAUNCHARGS" --json -- alpha 'two words' > "$ARTIFACTS/relaunch-args-result.json"
runtime_log=$(/usr/bin/plutil -extract session.actionRuns.0.logPath raw -o - "$ARTIFACTS/relaunch-args-result.json")
for attempt in {1..50}; do
  /usr/bin/grep -q '^runtime-args:alpha two words$' "$runtime_log" 2>/dev/null && break
  /bin/sleep 0.05
done
runtime_line_count=$(/usr/bin/grep -c '^runtime-args:alpha two words$' "$runtime_log" || true)
[[ "$runtime_line_count" == 1 ]] || fail "relaunch runtime arguments did not reach the fresh primary exactly once"
"$LAUNCH" close "$RELAUNCHARGS" --json > "$ARTIFACTS/relaunch-args-stopped.json"
relaunch_args_started=0

"$LAUNCH" create "$NATURAL" "Short process for natural-exit monitoring" "Expected to exit naturally after one second." \
  --directory "$PROJECT" -- /bin/sh -c 'sleep 1' > "$ARTIFACTS/natural-created.txt"
"$LAUNCH" details "$NATURAL" --json > "$ARTIFACTS/natural-created-details.json"
[[ "$(/usr/bin/plutil -extract launcher.runDetails raw -o - "$ARTIFACTS/natural-created-details.json")" == "Expected to exit naturally after one second." ]] || fail "third create positional was not stored as run details"
"$LAUNCH" "$NATURAL" --json > "$ARTIFACTS/natural-session.json"
sleep 2
"$LAUNCH" details "$NATURAL" --json > "$ARTIFACTS/natural-details.json"
[[ "$(/usr/bin/plutil -extract lastSession.state raw -o - "$ARTIFACTS/natural-details.json")" == exited ]] || fail "natural process exit was not observed"

"$LAUNCH" create "$SHELLARGS" "Shell command with literal runtime arguments" \
  --directory "$PROJECT" --type shell --command '/bin/echo shell-runtime' > "$ARTIFACTS/shell-created.txt"
"$LAUNCH" "$SHELLARGS" -- alpha 'two words' > "$ARTIFACTS/shell-session.txt"
shell_state=""
for attempt in {1..50}; do
  "$LAUNCH" details "$SHELLARGS" --json > "$ARTIFACTS/shell-details.json"
  shell_state=$(/usr/bin/plutil -extract lastSession.state raw -o - "$ARTIFACTS/shell-details.json" 2>/dev/null || true)
  [[ "$shell_state" == exited ]] && break
  /bin/sleep 0.1
done
[[ "$shell_state" == exited ]] || fail "shell runtime-argument action did not exit"
"$LAUNCH" logs "$SHELLARGS" > "$ARTIFACTS/shell-logs.txt"
/usr/bin/grep -F 'shell-runtime alpha two words' "$ARTIFACTS/shell-logs.txt" >/dev/null || fail "shell runtime arguments were not appended to the stored command"

"$LAUNCH" create "$RACE" "Stop while the first compound action is still becoming ready" \
  --directory "$PROJECT" --type process --port auto \
  --health 'http://${HOST}:${PORT}/never-ready' --ready-timeout 20 \
  -- python3 -m http.server '${PORT}' > "$ARTIFACTS/race-created.txt"
race_marker="$ARTIFACTS/race-second-action-started"
"$LAUNCH" action add "$RACE" late "Must not start after CLOSE" \
  -- /usr/bin/touch "$race_marker" > "$ARTIFACTS/race-action-added.txt"
"$LAUNCH" "$RACE" --json > "$ARTIFACTS/race-start.json" 2> "$ARTIFACTS/race-start-error.txt" &
race_start_pid=$!
race_started=1
race_seen=0
for attempt in {1..100}; do
  "$LAUNCH" details "$RACE" --json > "$ARTIFACTS/race-details.json" 2>/dev/null || true
  race_state=$(/usr/bin/plutil -extract activeSession.state raw -o - "$ARTIFACTS/race-details.json" 2>/dev/null || true)
  if [[ "$race_state" == starting ]]; then
    race_seen=1
    break
  fi
  /bin/sleep 0.1
done
[[ "$race_seen" == 1 ]] || fail "did not observe compound launcher in starting state"
"$LAUNCH" close "$RACE" --json > "$ARTIFACTS/race-stopped.json"
race_started=0
set +e
wait "$race_start_pid"
race_start_status=$?
set -e
[[ ! -e "$race_marker" ]] || fail "a later compound action started after CLOSE was requested"
[[ "$(/usr/bin/plutil -extract state raw -o - "$ARTIFACTS/race-stopped.json")" == exited ]] || fail "CLOSE-during-start did not end the session"
print "$race_start_status" > "$ARTIFACTS/race-start-exit-status.txt"

"$LAUNCH" create "$MUTABLE" "Launcher used for rename and delete tests" \
  --directory "$PROJECT" -- /usr/bin/true > "$ARTIFACTS/mutable-created.txt"
"$LAUNCH" update "$MUTABLE" --name "$RENAMED" --description "Renamed shortcut" > "$ARTIFACTS/mutable-renamed.txt"
"$LAUNCH" details "$RENAMED" --json > "$ARTIFACTS/renamed-details.json"
set +e
"$LAUNCH" details "$MUTABLE" --json > "$ARTIFACTS/old-name.txt" 2>&1
old_name_status=$?
set -e
[[ "$old_name_status" == 3 ]] || fail "old launcher name still resolves after rename"

chmod 0644 "$PROJECT/launch_details.md"
set +e
"$LAUNCH" sync "$PROJECT" --check --json > "$ARTIFACTS/sync-drift.json"
sync_status=$?
set -e
[[ "$sync_status" == 4 ]] || fail "permission drift check returned exit $sync_status instead of 4"
"$LAUNCH" sync "$PROJECT" --repair --json > "$ARTIFACTS/sync-repaired.json"
[[ "$(stat -f '%Lp' "$PROJECT/launch_details.md")" == 444 ]] || fail "manifest repair did not restore mode 0444"

for name in "$WEB" "$NATURAL" "$SHELLARGS" "$RELAUNCHARGS" "$RACE" "$RENAMED" "$ENCODED"; do
  details_path="$ARTIFACTS/delete-details-${name}.json"
  "$LAUNCH" details "$name" --json > "$details_path"
  revision=$(/usr/bin/plutil -extract launcher.revision raw -o - "$details_path")
  "$LAUNCH" delete "$name" --yes --if-revision "$revision" > "$ARTIFACTS/deleted-${name}.txt"
done

"$LAUNCH" list --json > "$ARTIFACTS/final-catalog.json"
remaining=$(/usr/bin/plutil -extract 0 json -o - "$ARTIFACTS/final-catalog.json" 2>/dev/null || true)
[[ -z "$remaining" ]] || fail "test launchers remained in the active catalog"
[[ "$(stat -f '%Lp' "$PROJECT/launch_details.md")" == 444 ]] || fail "final manifest mode changed"

print "E2E PASS"
print "Project: $PROJECT"
print "Artifacts: $ARTIFACTS"
