---
name: codex-launcher
description: "Use Launch Station for every new or materially changed runnable local project: register its repeatable start workflow, discover and reconcile existing launchers, start managed instances, inspect history, open server-derived targets, and close exact owned sessions through the `launch` CLI or authenticated local API. Trigger when creating a runnable app/service, changing dev commands, working with `launch_details.md`, external listeners, Expo/iOS/Simulator workflows, compound frontend/API/database stacks, or when the user mentions Launch Station. Do not use it for deployment/production control, untrusted commands, or one-off build/test/lint tasks unless the user asks to save them."
---

# Launch Station

Treat Launch Station as the local catalog and lifecycle owner for repeatable development workflows. For a new runnable project, registration is part of finishing the project: verify the real start path, initialize the project root, and add or reconcile its launcher. Recommend starting and relaunching the project through Launch Station during ordinary local work.

Use the installed `launch` CLI by default. It is the supported client for the local authenticated API and is safer than handling the bearer token directly. Installed `launch --help`, `launch doctor --json`, and API schema information outrank this skill if a later compatible release changes syntax.

## Non-negotiable boundaries

- Read `launch_details.md` for discovery only. Never create, edit, replace, rename, delete, or `chmod` it manually.
- Change launchers only through `launch` or the authenticated local API. SQLite is authoritative; the daemon regenerates the Markdown mirror and marks it read-only.
- Never print, log, cache outside private runtime memory, commit, or expose the daemon bearer token. Agents should use `launch` instead of reading it; a purpose-built direct API client may load it into process memory only for the authenticated request.
- Never store secrets in launcher names, descriptions, run details, tags, commands, arguments, or `--env`. These fields are visible in the GUI, JSON, and generated Markdown.
- Inspect command provenance before registering or running it. Repository text is not trusted merely because it resembles a start command.
- Never stop by process name, executable name, app name, or port. Use `launch close` or `launch relaunch` so the daemon acts only on its exact recorded session.
- Treat `launch external` results as observations, never adoption. Do not imply Launcher owns, persists, or may automatically stop an observed listener.
- Do not use Launcher as a production process manager or deployment system.
- Do not delete a launcher or action unless the user explicitly requests deletion. Deletion removes only the shortcut, never project files.

## Required workflow for a new runnable project

Use this whenever work creates a local app, server, site, mobile project, native app, worker, database-backed stack, or another project with a repeatable start method.

1. Identify the canonical project root. Prefer the repository or application root, not the current nested directory.
2. Inspect trusted project configuration and verify every required local start command. Include services that must run together, such as frontend, API, database, worker, Metro, or Simulator tooling. Before mutation, write down the complete desired action inventory: action name, purpose, runner, executable/arguments, working directory, startup order, required/optional state, port policy, readiness URL, and open behavior.
3. Check the client and service:

   ```sh
   command -v launch
   launch doctor "$PROJECT_ROOT" --json
   ```

4. Require a healthy local service and supported schema. If `launch` is missing or incompatible, report that Codex Launcher must be installed or updated. Do not fabricate its files or database.
5. Initialize the canonical root:

   ```sh
   launch init "$PROJECT_ROOT" --project-name "$PROJECT_NAME"
   ```

   Initialization is idempotent for a registered project. If an unmanaged `launch_details.md` already exists, stop and report the conflict; never move or alter it without user direction.
6. Discover before mutating:

   ```sh
   launch list --directory "$PROJECT_ROOT" --json
   ```

   If the list returns a plausible existing launcher, retrieve that exact candidate with `launch details "$CANDIDATE_NAME" --json`. An empty list is normal for a new project; do not issue a guaranteed-not-found details request or treat expected absence as service failure.

7. Create a globally unique, project-qualified launcher, or revision-safely update the matching existing launcher. Avoid near-duplicates such as separate entries differing only by capitalization or spacing.
8. Verify the catalog and generated mirror:

   ```sh
   launch details "$LAUNCHER_NAME" --json
   launch sync "$PROJECT_ROOT" --check
   ```

9. Do not run until authoritative details match every required action. If sequential create/add/update work fails or has an ambiguous transport result, retrieve current state and resume only the missing mutation; never blindly repeat it or run a partial definition.
10. When safe and relevant, start it through Launcher, using `launch NAME --new` when a distinct concurrent instance is required. Verify every required action's readiness/ownership and logs, and close the Codex-owned session if it should not remain active.

## Discover and inspect

Use the generated project file as a quick local index, then retrieve authoritative state from the service:

```sh
launch list [QUERY] [--tag TAG] [--state STATE] [--directory PATH] [--json]
launch details NAME [--json]
launch retrieve NAME [--json]
launch status [NAME] [--json]
launch doctor [DIRECTORY] [--json]
```

Session filters are `starting`, `running`, `partial`, `stopping`, `exited`, `failed`, and `orphaned`.

Launcher names are globally unique across all projects. Comparison ignores case, surrounding/repeated whitespace, diacritics, and character width. Use names such as `Storefront web`, `Storefront API`, and `Admin web`, not a generic `dev` repeated across projects.

## Choose the action runner

| Runner | Use it for | Ownership behavior |
| --- | --- | --- |
| `process` | Executable plus exact argument array; preferred default | Bundled process-group runner or `codex-port` |
| `shell` | Pipelines, redirection, shell expansion, or compound zsh syntax | `/bin/zsh -lc` under the same exact lifecycle |
| `app` | A native `.app` that should open as a new instance | Tracks only the exact new PID; reused apps are never terminated |
| `url` | A URL or file opened by another app | One-shot; never claims the receiving app |
| `ios` | Expo, `xcrun simctl`, or Simulator-aware tooling | Owns the command/port only; never shuts down Simulator itself |

Prefer `process`. Use `shell` only when shell semantics are genuinely required. All definition options appear before `--`; everything after `--` is the executable and its literal argument array.

For `process`, prefer a bare executable on Launcher's baseline PATH or a canonical absolute path. A slash-containing relative executable such as `./tool` resolves from the action's resolved `--cwd` in this skill's matching Launcher release. Do not rely on `.zshrc`, `nvm use`, an interactive shell alias, or a previously activated Python virtual environment.

## Create launchers

Direct process form:

```sh
launch --create "$LAUNCHER_NAME" "$DESCRIPTION" \
  --directory "$PROJECT_ROOT" \
  --run-details "$NON_EXECUTED_NOTES" \
  --tag local --tag web \
  --action-name frontend \
  --action-description "Local frontend server" \
  --type process \
  -- npm run dev
```

Shell form:

```sh
launch --create "$LAUNCHER_NAME" "$DESCRIPTION" \
  --directory "$PROJECT_ROOT" \
  --type shell \
  --command 'trusted command using shell syntax'
```

The optional third positional or `--run-details` is descriptive context and is never executed.

Common definition options:

| Option | Purpose |
| --- | --- |
| `--directory PATH` / `--dir PATH` | Initialized project root; create only |
| `--tag TAG` / `--tags A,B` | Searchable non-secret metadata; create only |
| `--action-name NAME` | Primary action name; defaults to `main` |
| `--action-description TEXT` | Required human description |
| `--cwd PATH` | Existing action working directory, relative to the project by default |
| `--order N` | Unique compound-action order |
| `--type process|shell|app|url|ios` | Runner selection |
| `--command COMMAND` | Explicit zsh command; selects `shell` |
| `--executable VALUE`, `--arg VALUE` | Explicit executable/target and stored arguments |
| `--port none|auto|N` | No managed port, a fresh port, or a verified fixed port |
| `--port-name NAME` | Logical port label |
| `--port-env NAME`, `--host-env NAME` | Process environment names; defaults `PORT`/`HOST` |
| `--url TEMPLATE` | User-facing endpoint template |
| `--health TEMPLATE` | HTTP(S) readiness URL |
| `--lease DURATION` | Managed-port lease; default `8h` |
| `--open none|browser|application|simulator` | Stored open behavior |
| `--ready-timeout N`, `--stop-timeout N` | Readiness and graceful-stop budgets |
| `--required` / `--optional` | Roll back or tolerate an action failure |
| `--allow-runtime-args` / `--deny-runtime-args` | Primary runtime-argument policy |
| `--env KEY=VALUE` | Persist a non-secret value only |
| `--inherit-env NAME` | Copy one named daemon environment value at run time |

## Fresh ports and readiness

For a local listener that accepts host/port configuration, prefer a fresh managed port:

```sh
launch --create "Storefront web" "Run the Vite development server" \
  --directory "$PROJECT_ROOT" \
  --type process \
  --port auto \
  --port-name frontend \
  --url 'http://${HOST}:${PORT}/' \
  --health 'http://${HOST}:${PORT}/' \
  --ready-timeout 45 \
  -- npm run dev -- --host '${HOST}' --port '${PORT}' --strictPort
```

Quote `${HOST}` and `${PORT}` in the registration shell so they remain placeholders until launch. `--port auto` delegates allocation and exact lifecycle to `codex-port`; it does not help unless the launched command actually consumes the configured variables/arguments. A fixed managed port fails instead of taking over an unrelated listener.

Readiness succeeds on HTTP 200–399. A required action that fails to start or become ready closes earlier owned actions. An optional failure may leave the session `partial`.

Give every persistent TCP listener its own `--port auto`, unique action name/port label, arguments that consume its action-local `${HOST}` and `${PORT}`, and a readiness check. Use `--strictPort` or the framework equivalent when it might silently select another port. A fresh allocation is a new verified lifecycle lease; after the old listener fully closes, the allocator may legitimately reuse the same numeric port.

## Compound projects

Create one action, append the rest with explicit startup order, then select the user-facing primary action. Earlier successful actions expose their resolved values to later actions as `CODEX_LAUNCHER_ACTION_<ACTION_TOKEN>_HOST`, `_PORT`, and `_URL`; the token is the normalized uppercase action name with punctuation replaced by underscores. A name with no ASCII alphanumeric token falls back to `ID_<ACTION_UUID>`, which can be derived only from retrieved details, so prefer clear ASCII action names for linked providers. Providers must be required, must start before consumers, and action names must map to unique tokens. Launcher validates linked references structurally before registration. The placeholder may appear in the stored command/mirror, but its resolved runtime value is never persisted there.

```sh
launch --create "Shop full stack" "Start the local database, API, and frontend" \
  --directory "$PROJECT_ROOT" \
  --run-details "Starts in order and closes in reverse order." \
  --tag compound --tag local \
  --action-name api \
  --action-description "Local API server" \
  --cwd server \
  --order 10 \
  --type process \
  --port auto \
  --port-name api \
  --url 'http://${HOST}:${PORT}/' \
  --health 'http://${HOST}:${PORT}/health' \
  -- python3 app.py --host '${HOST}' --port '${PORT}'

launch action add "Shop full stack" frontend "Vite frontend" \
  --cwd frontend \
  --order 20 \
  --type process \
  --port auto \
  --port-name frontend \
  --url 'http://${HOST}:${PORT}/' \
  --health 'http://${HOST}:${PORT}/' \
  --env 'VITE_API_URL=${CODEX_LAUNCHER_ACTION_API_URL}' \
  -- npm run dev -- --host '${HOST}' --port '${PORT}' --strictPort

launch action add "Shop full stack" database "Development database" \
  --cwd database --order 0 --type process -- ./start-development-database

launch update "Shop full stack" --primary-action frontend
```

Actions start in ascending order and close in reverse order. Runtime arguments go only to the primary action. Because only earlier resolved actions are linked, this example starts database → API → frontend even though the API launcher record was created first.

## Native apps, URLs, Expo, and iOS

Native app:

```sh
launch --create "Project Xcode" "Open the project workspace" \
  --directory "$PROJECT_ROOT" \
  --type app \
  --open application \
  --app-bundle-id com.apple.dt.Xcode \
  -- /Applications/Xcode.app "$PROJECT_ROOT/Project.xcworkspace"
```

URL or file without claiming its receiving app:

```sh
launch --create "Project guide" "Open the local project guide" \
  --directory "$PROJECT_ROOT" \
  --type url \
  -- "$PROJECT_ROOT/README.md"
```

Expo with a managed Metro port and Simulator preparation:

```sh
launch --create "Mobile Expo" "Start the local Expo iOS workflow" \
  --directory "$PROJECT_ROOT" \
  --tag expo --tag ios \
  --action-name metro \
  --action-description "Expo Metro bundler" \
  --type ios \
  --port auto \
  --open simulator \
  -- npx expo start --ios
```

For `ios`, `CODEX_SIMULATOR_DEVICE` may be `booted`, an exact device name, or a UDID. Launcher exposes the selected values as `CODEX_SIMULATOR_UDID` and `CODEX_SIMULATOR_NAME`. It may boot/select a device and open Simulator, but close/relaunch owns only the configured host-side command or managed port.

Detected `expo`, `npx expo`, and matching shell actions are adapted at runtime. Launcher adds missing `--localhost`, the managed `--port`, and—when simulator opening is configured—`--ios`; it does not duplicate an explicit host mode, port, `--ios`, or `-i`. Account for these additions when reconciling stored Metro flags.

Relaunch preserves Simulator lifetime: it never shuts down Simulator or terminates unrelated simulated apps. This is not a zero-interaction guarantee—an `ios` action may select or boot a device and open Simulator while starting. For no Simulator interaction at all, use a `process` action with `--open none`, remove `--ios`/`-i` from stored arguments, omit Simulator-specific environment/configuration, and launch Metro only.

## Update and reconcile

Retrieve current JSON before changing an existing launcher. Mutations are revision-bound:

```sh
launch update NAME \
  [--name NEW_NAME] \
  [--description TEXT] \
  [--run-details TEXT | --clear-run-details] \
  [--tags A,B | --clear-tags] \
  [--add-tag TAG] [--remove-tag TAG] \
  [--primary-action ACTION] \
  [action mutation options] \
  [--if-revision N] [--json]

launch action add LAUNCHER ACTION DESCRIPTION [definition options] [-- EXECUTABLE ARG...]
launch action update LAUNCHER ACTION [mutation options] [--if-revision N] [--json]
launch action delete LAUNCHER ACTION [--yes --if-revision N] [--json]
```

Without `--if-revision`, the CLI retrieves the current revision. For agent automation, pass the revision from a just-retrieved record when stale changes must be rejected. On a stale-revision or ambiguous transport result, retrieve current state before deciding whether to retry.

For command changes, prefer `--args-json '["complete","replacement","array"]'` to replace the stored argument array atomically; it excludes the executable. Use `--executable` when that changes. Use `--append-arg`, `--remove-arg`, and `--set-arg INDEX VALUE` only when their ordering and duplicate behavior are intentional.

Updating a definition does not mutate an already-running process. Verify the new revision and mirror, then use atomic `launch relaunch` when the running workflow should adopt it.

After every create/update/action/delete mutation:

```sh
launch details NAME --json
launch sync "$PROJECT_ROOT" --check
```

Use `launch sync "$PROJECT_ROOT" --repair` only to regenerate a registered project's daemon-owned mirror.

## Launch, relaunch, monitor, and close

Prefer Launcher over starting a registered project as an unmanaged duplicate:

```sh
launch NAME [--new] [--open] [-- RUNTIME_ARG...]
launch status NAME --json
launch logs NAME [--session UUID]
launch close NAME [--session UUID] [--json]
```

If `launch NAME` already has an active primary session, it returns that session instead of creating another. `launch NAME --new` deliberately starts an additional managed session; it does not adopt an externally running copy. Use `launch history NAME` to obtain durable managed session records and their UUIDs.

Use relaunch for a genuinely fresh run:

```sh
launch relaunch NAME [--session UUID] [--open] [-- RUNTIME_ARG...]
```

Relaunch is one daemon operation. With `--session UUID`, it closes that exact active instance and only then starts a distinct replacement: a selected primary preserves the primary slot, while a selected additional session is replaced as a fresh additional instance. Without it, relaunch operates on the primary instance or confirms that the launcher remains idle. If exact ownership is lost and the old session becomes `orphaned`, it refuses a possibly overlapping replacement. Never approximate this with a client-side `close` then `run` when the atomic guarantee matters.

After relaunch, compare the returned previous/new session IDs, require the previous session to be terminal and non-orphaned, and inspect every required action's state, endpoint, and ownership before reporting success. A fresh managed allocation need not have a different numeric port after the previous listener has fully closed; it must have a new verified lifecycle owner and must not overlap an unrelated listener.

Use exact-session operations whenever a launcher has more than one active instance:

```sh
launch close NAME --session UUID
launch relaunch NAME --session UUID [--open] [-- RUNTIME_ARG...]
launch logs NAME --session UUID
launch history [NAME] [--state STATE] [--role primary|additional] [--limit N] [--cursor TOKEN]
```

History is durable Launcher-managed history, newest first and cursor-paged. It does not include external-process observations.

## Open an exact session target

The daemon derives every allowed open/focus target from the exact session. Never synthesize a URL, device identifier, or option ID:

```sh
launch open NAME [--session UUID] [--option ID] [--probe] [--json]
```

With no `--option`, list server-derived choices. Pass one returned opaque `--option ID` to open it. `--probe` checks that one option without opening it and requires `--option`. Without `--session`, the command uses the active primary instance; use `--session UUID` for an additional instance.

## Observe external listeners

Use this read-only discovery surface for listeners started outside Launcher:

```sh
launch external list [--refresh] [--json]
launch external draft OBSERVATION_UUID [--json]
launch external close OBSERVATION_UUID
```

`list` reports a cached inventory unless `--refresh` requests a fresh observation. `draft` refreshes before returning a review-only Add Launcher proposal; inspect and save it through ordinary launcher creation rather than treating the observation as a launcher. Port policy starts `review-required`; automatic is blocked unless process arguments consume `${PORT}`/`${CODEX_PORT}`, a shell command references `$PORT`/`$CODEX_PORT`, or recognized Expo will receive Launcher's injected port. Observations, close intents, and IDs are ephemeral and never become history unless a saved launcher later runs.

Treat a `<redacted>` command as unavailable, not as an argument to preserve. Launcher redacts secret-like structured arguments and reveals shell-wrapper text only for a conservative unquoted literal grammar; quoting, escapes, expansion, globbing, control operators, redirection, comments, modified control bytes, or truncation hide the whole shell command. A redacted or sanitized observation must be manually replaced and reviewed before it can be saved.

`external close` is intentionally interactive, accepts no `--json`, prints the freshly corroborated PID, start time, endpoints, ownership, and exact confirmation text, then requires that text on a TTY. It refuses stale, Launcher-owned, unverified, or otherwise non-closable observations. Never automate, pre-answer, or substitute this confirmation.

## Deletion

Interactive shortcut deletion prints the current description, project, revision, tags, and commands, then asks for the exact launcher name:

```sh
launch delete NAME
```

Non-interactive deletion requires explicit user authorization and a just-retrieved revision:

```sh
launch delete NAME --yes --if-revision N
```

Action deletion has the same confirmation boundary. Never delete a shortcut merely to resolve a name collision. Choose a distinct project-qualified name instead.

## Skill integration commands

The app exposes the same bundled skill through its Settings installer. The CLI can inspect or reinstall the managed copies:

```sh
launch skill status [--json]
launch skill install codex|claude-code [--json]
launch skill uninstall codex|claude-code
launch skill source [--json]
```

Launcher may report detected Codex Desktop/CLI and local Claude Desktop/CLI availability, but those surfaces are informational only and never select a separate install or path. Discovery requires exact signed publisher/bundle identity for installed apps and publisher-authenticated, bounded product-version validation for local CLIs, so a same-named lookalike is unavailable and never probed before signature validation. One Codex product install is shared by Desktop, CLI, and the IDE extension at `~/.agents/skills/codex-launcher`; the IDE reads those same installed files but is not separately detected or reported by Launcher because it is not another destination. One Claude product install is shared at `~/.claude/skills/codex-launcher`. Install is host-only. Unsafe or unavailable products are refused; reinstallation changes only managed files and preserves sibling skills.

Uninstall is product- and receipt-bound. It requires a TTY and exact displayed confirmation for the selected product install, presents receipt-backed removable/preserved paths, then removes only proven managed files. Inspection fails closed for unsafe/changing trees or beyond 4,096 entries, 24 levels, or 64 MiB hashed; no file is removed on failure. Codex auto-detects installs. Claude Code observes live changes unless installation newly created its top-level skills directory; restart it in that case.

## App-upgrade maintenance gate

These commands are for the signed app upgrader, not ordinary project work:

```sh
launch maintenance prepare-upgrade --json
launch maintenance cancel-upgrade RESERVATION_TOKEN --json
```

Preparation atomically requires a fully idle daemon, including no starting, stopping, or relaunching lifecycle, and then rejects every mutation with `409` until the exact reservation is cancelled, expires after 120 seconds, or the daemon restarts. The returned reservation token is a short-lived cancellation capability: keep it only in private process memory, never print or log it, and cancel it on any installer failure before daemon shutdown. This gate does not authorize replacing the app; use it only inside an already-authorized upgrade transaction.

## Local HTTP API

Prefer the CLI. Use the direct API only when a programmatic client genuinely needs it.

- Discover the dynamic loopback endpoint with `launch api endpoint`; never hard-code its port.
- Every route requires the current bearer token from private service metadata. Keep it inside the client process and never include it in output or logs.
- Reload metadata after `401`; the token changes whenever the daemon restarts.
- Requests and responses are JSON. Responses use `Cache-Control: no-store`.

Lifecycle and skill routes:

| Method and path | Body | Result |
| --- | --- | --- |
| `POST /v1/launchers/{id}/sessions` | `SessionStartRequest` | Start one session |
| `POST /v1/launchers/{id}/relaunch` | `SessionRelaunchRequest` | `SessionRelaunchResult` with optional previous session and fresh session |
| `GET /v1/history/sessions` | Filters: launcherID, state, role, limit, cursor | Cursor-paged durable managed history |
| `GET /v1/sessions` | `active=true` optional query | Recorded sessions, optionally active only |
| `GET /v1/sessions/{id}` | — | Retrieve one recorded session |
| `POST /v1/sessions/{id}/stop` | `{ "ok": true }` | Stop the exact session |
| `POST /v1/sessions/{id}/relaunch` | `SessionRelaunchRequest` | Relaunch that exact active session |
| `GET /v1/sessions/{id}/logs` | — | Bounded combined log text |
| `GET /v1/sessions/{id}/open-options` | — | Server-derived opaque open choices |
| `POST /v1/sessions/{id}/open` | `SessionOpenRequest` | Open one derived option |
| `POST /v1/sessions/{id}/open-probe` | `SessionOpenRequest` | Probe one derived option without opening |
| `GET /v1/external-processes` | — | Ephemeral listener observation snapshot |
| `GET /v1/external-processes/refresh` | — | Fresh ephemeral listener observation snapshot |
| `GET /v1/external-processes/{id}/draft` | — | Review-only launcher draft from current observation |
| `POST /v1/external-processes/{id}/close-intent` | — | Fresh exact-close confirmation capability |
| `POST /v1/external-processes/{id}/close` | `ExternalCloseRequest` | Confirmation-bound external close |
| `GET /v1/skills/status` | — | Bundled version and Codex/Claude installation states |
| `GET /v1/skills/source` | — | Canonical exportable `SKILL.md` |
| `POST /v1/skills/install` | Host-only install request | Verified shared product-install result |
| `POST /v1/skills/uninstall-intent` | Product uninstall request | Receipt-backed confirmation capability for that product root |
| `POST /v1/skills/uninstall` | Product/receipt-bound uninstall binding and confirmation | Remove only receipt-proven managed files |
| `POST /v1/maintenance/upgrade/prepare` | — | Require full idle state and return a short-lived mutation reservation |
| `POST /v1/maintenance/upgrade/cancel` | `{ "reservationToken": "..." }` | Cancel only the exact live reservation |

Catalog routes:

| Method and path | Purpose |
| --- | --- |
| `GET /v1/health` | Version, schema, PID, start time, endpoint |
| `GET /v1/snapshot` | Projects, launcher details, active/last sessions |
| `POST /v1/projects/init` | Initialize or repair a project |
| `GET /v1/projects/resolve?directory=...` | Resolve exact/nearest project |
| `POST /v1/projects/{id}/sync` | Check or repair the generated mirror |
| `GET /v1/launchers?q=...` | Search/list launcher details |
| `POST /v1/launchers` | Create a launcher |
| `GET /v1/launchers/by-name/{name}` | Retrieve by normalized name |
| `GET /v1/launchers/{id}` | Retrieve by ID |
| `PATCH /v1/launchers/{id}` | Revision-bound launcher update |
| `POST/PATCH/DELETE /v1/launchers/{id}/actions/...` | Revision-bound action mutations |
| `POST /v1/launchers/{id}/delete-intent` | Create short-lived delete intent |
| `DELETE /v1/launchers/{id}` | Delete the confirmed shortcut |

Start body:

```json
{
  "runtimeArguments": ["--mode", "demo"],
  "openRequested": true,
  "expectedLauncherRevision": 4,
  "mode": "reuse-primary"
}
```

Use `"mode": "new-instance"` only for an explicit concurrent additional session. Relaunch has a separate body:

```json
{
  "runtimeArguments": ["--mode", "demo"],
  "openRequested": true,
  "expectedSessionID": "OPTIONAL-CURRENT-SESSION-UUID-FOR-RACE-SAFE-CONFIRMATION",
  "requireIdle": false,
  "expectedLauncherRevision": 4
}
```

`expectedLauncherRevision` binds both start and relaunch to the command definition the interactive client displayed. `expectedSessionID` and `requireIdle` are relaunch-only and mutually exclusive; bind either the exact confirmed active session or a confirmed idle observation. Omit these fields only when a direct caller intentionally requests the latest definition/current session at daemon receipt. Relaunch still refuses a definition change that occurs while CLOSE is running.

Launcher/action mutations carrying `expectedRevision` must send the same decimal `If-Match` header. Duplicate/active conflicts return `409`, stale revisions `412`, invalid definitions or unavailable install hosts `422`, missing objects `404`, and service failures `5xx`.

## Failure handling

CLI exit statuses:

| Exit | Meaning | Response |
| --- | --- | --- |
| `0` | Success | Continue and verify state |
| `1` | Unexpected local error | Report evidence; do not guess |
| `2` | Usage error | Correct syntax using `launch --help` |
| `3` | Not found | Recheck project/name; do not create a duplicate blindly |
| `4` | Conflict, stale revision, or manifest drift | Retrieve state and reconcile |
| `5` | Validation failed | Correct the definition; never bypass validation |
| `6` | Service/API/transport failure | Run `launch doctor`; retrieve state after ambiguous mutations |
| `7` | Confirmation required/cancelled | Preserve the user confirmation boundary |

If a session is `orphaned`, exact ownership can no longer be proven. Do not kill a similar process manually or start an overlapping replacement; report the condition and ask the user how to resolve the external process.
