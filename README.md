# Launch Station

Launch Station is a native macOS catalog and lifecycle manager for project launch commands. A Codex agent, a person at the terminal, and the SwiftUI app all use the same local API. The daemon is the only component that writes the SQLite catalog, regenerates each project's `launch_details.md`, allocates managed ports, and starts or stops processes.

The system is designed for commands such as `npm run dev`, Python servers, native `.app` bundles, Expo, iOS tooling, and compound projects with several ordered services.

## Install

```sh
brew install --cask JakeMawson/tap/launchstation
```

The Homebrew cask installs the Apple-notarized **Launch Station.app**, the `launch` CLI, and its per-user LaunchAgent. Upgrades replace only the application bundle and installation contract; they never create, rewrite, migrate, reset, or remove `~/Library/Application Support/Launch Station/launcher.sqlite3`. Uninstalling the cask also preserves the launcher catalog. See [launchstation.net](https://launchstation.net) for the product overview.

## What is included

| Component | Installed location | Responsibility |
| --- | --- | --- |
| SwiftUI app | `/Applications/Launch Station.app` when writable, otherwise `~/Applications/Launch Station.app` | Search, inspect, launch, close, monitor, open endpoints, and read logs |
| CLI | `~/bin/launch` | Scriptable project, launcher, action, session, manifest, and API operations |
| LaunchAgent daemon | `com.jakemawson.launchstation.service` | Sole database writer, API server, manifest generator, and lifecycle owner |
| Process runner | Inside the app bundle | Creates an isolated process group and reports exact PID/birth identity |
| Agent skill | Inside the app bundle | Canonical `launchstation` workflow installable for Codex or Claude Code, or exportable as `SKILL.md` |
| SQLite catalog | `~/Library/Application Support/Launch Station/launcher.sqlite3` | Durable source of truth |
| Project mirror | `<project>/launch_details.md` | Deterministic, read-only agent reference generated from SQLite |

The app and CLI never edit SQLite or `launch_details.md` directly. They send authenticated requests to the daemon over a loopback-only HTTP API.

## Requirements

- macOS 13 or newer.
- Xcode or Xcode Command Line Tools for building from source.
- A valid **Developer ID Application** certificate and a `notarytool` keychain profile for a distributable release. The checked-in `Resources/ReleaseTrustPolicy.plist` must also be configured once with that certificate's exact publisher and Team ID. Local developer builds do not need either credential, but cannot be installed through the release installer.
- `~/bin` on `PATH` to invoke the installed `launch` symlink by name.
- `~/bin/codex-port` for launch actions configured with `--port auto` or a fixed managed port.
- The runtimes used by individual launchers, such as Node.js, Python, Xcode, or Expo.

There are no third-party Swift package dependencies. The project uses SwiftUI, AppKit, Network.framework, CryptoKit, and the system SQLite library.

## Build, package, and install

Build and run the unit tests:

```sh
cd /path/to/launchstation
env CLANG_MODULE_CACHE_PATH=/tmp/launch-station-clang-cache \
  SWIFT_MODULE_CACHE_PATH=/tmp/launch-station-swift-cache \
  xcrun swift test --jobs 2
```

Create a local **development-only** bundle:

```sh
scripts/package-app.sh --development
```

The default output is `dist/development/Launch Station.app`. It has an explicit `BuildProvenance.plist` marking it as development-only and an ad-hoc signature for local testing. `scripts/install.sh`, `scripts/upgrade-installed-app.sh`, and `scripts/verify-release-app.sh` deliberately refuse it.

For a local rebuild without overwriting a prior development bundle, choose a new output root:

```sh
OUTPUT_ROOT="$PWD/dist/development-next" scripts/package-app.sh --development
```

### Keep the local Applications app current

For this repository’s own verified development builds, use the guarded sync helper after the test suite and packaging have both succeeded. It deliberately requires the exact candidate bundle; it never watches the working tree or promotes untested source changes.

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/launchstation-clang-cache \
  SWIFT_MODULE_CACHE_PATH=/tmp/launchstation-swift-cache \
  xcrun swift test --jobs 2

OUTPUT_ROOT="$PWD/dist/development-next" scripts/package-app.sh --development
scripts/sync-development-app.sh --check \
  "$PWD/dist/development-next/Launch Station.app"
scripts/sync-development-app.sh --sync --verified-development-bundle \
  "$PWD/dist/development-next/Launch Station.app"
```

`--check` is read-only: it prints the candidate and installed versions, builds, and executable hashes, then reports `CURRENT` or `CANDIDATE_NEWER`. `--sync` is deliberately explicit and accepts only a development-marked, validly signed Launch Station bundle with a strictly increasing version/build. It stages a byte-verified copy beside `/Applications/Launch Station.app`, atomically swaps the app directories, verifies the resulting hash, and keeps the outgoing application bundle in `~/.Trash` as a timestamped recovery copy. It does not change the original candidate, launcher database, skills, LaunchAgent, daemon process, or running sessions. If `/Applications` is not the installation location, use the inspected path explicitly with `--destination /absolute/path/Launch\ Station.app`.

A distributable release is a different operation. Its trust anchor is deliberately separate from the candidate bundle and its command line: `Resources/ReleaseTrustPolicy.plist` pins the exact Developer ID publisher and 10-character Team ID for the repository. The installer, upgrader, and verifier always read that file; none accepts `--team-id`, `--publisher`, or a policy override.

The checked-in policy pins `Developer ID Application: Jake Mawson (6RWK4446NQ)`, derived from the locally verified certificate inventory. A false, malformed, missing, or mismatched policy fails closed: it cannot package, verify, install, or upgrade a release.

After that one-time policy configuration, a release needs the corresponding signing identity and a preconfigured `notarytool` keychain profile:

```sh
scripts/package-release.sh \
  --signing-identity "Developer ID Application: Jake Mawson (6RWK4446NQ)" \
  --notary-profile quotawise-notary
```

`package-release.sh` claims a fresh UTC-stamped root under `dist/releases/` on every invocation and delegates to `package-app.sh --release`. It never overwrites or removes a prior candidate. A successful release root contains all of the following:

- the signed, stapled app bundle;
- the retained ZIP submitted to Apple’s notarization service; and
- the final notarized distribution ZIP.

The release path signs each executable and the bundle with hardened runtime and a secure timestamp, submits with `notarytool`, staples the ticket, validates it, and requires the policy-pinned Team ID/publisher and Gatekeeper’s `Notarized Developer ID` assessment. It copies the policy into the signed bundle and the verifier requires a byte-for-byte match against the fixed local policy, so a candidate cannot declare a different publisher. It never falls back to ad-hoc signing. You can select another fresh output root with `OUTPUT_ROOT=/absolute/new/root`; existing paths are refused rather than reused.

Before distribution or installation, independently check a release artifact:

```sh
/bin/zsh scripts/verify-release-app.sh \
  --app "/absolute/path/Launch Station.app"
```

Install the signed release as the logged-in macOS user — **never with `sudo`**:

```sh
scripts/install.sh \
  "/absolute/path/Launch Station.app"
```

The fresh installer prefers `/Applications/Launch Station.app` when the invoking user can write there. Otherwise it safely falls back to `~/Applications/Launch Station.app`. To choose a different existing writable parent explicitly:

```sh
scripts/install.sh \
  --destination "$HOME/Applications/Launch Station.app" \
  "/absolute/path/Launch Station.app"
```

The installer is intentionally fresh-install-only. It refuses root/sudo execution, existing or dangling-symlink app/CLI/LaunchAgent paths, non-release bundles, and mismatched publisher policy. It validates the exact rendered LaunchAgent, then waits for the exact launchd PID and matching daemon metadata/version and runs `launch doctor --json` before declaring success. If startup fails, it stops only its own new job and rolls back only installer-created artifacts whose filesystem identity still matches; existing data is preserved.

For an explicit in-place upgrade of an existing installation, use the separately named upgrade command:

```sh
scripts/upgrade-installed-app.sh \
  "/absolute/path/Launch Station.app"
```

The upgrader derives the existing app location from the current user’s exact LaunchAgent rather than assuming `/Applications`, so it works for both system and user Applications installations. It validates the signed/notarized **replacement** source and staged bundle against the fixed source-controlled Team ID/publisher policy while allowing a legacy ad-hoc installation to receive its first trusted upgrade. If the exact legacy bundle is root-owned at `/Applications/Launch Station.app`, the non-root upgrader leaves that bundle untouched, atomically installs the trusted replacement at `~/Applications/Launch Station.app`, and retargets only the verified per-user LaunchAgent and `~/bin/launch` link. It then verifies matching bundle/LaunchAgent identities, a nondecreasing app version/build, and an idle exact GUI; acquires a single-upgrader reservation; atomically changes the active app location; restarts and health-checks the exact LaunchAgent; and rolls back to the complete prior state on failure. The ordinary upgrade keeps the application database, logs, LaunchAgent, and CLI link in place.

The explicit `--allow-legacy-build-2` path is restricted to the one-time signed 1.1.0 build 2/schema-1 migration. It requires no active sessions, freezes the exact legacy daemon, and uses SQLite's backup API to create a private logical schema-1 snapshot, converts that snapshot to standalone DELETE-journal form, and integrity-checks it before the replacement can migrate anything. After launchd starts the replacement, the upgrader waits for service metadata identifying the exact new PID and source version before running `doctor`. If post-swap verification fails, rollback stops the replacement, restores both the old app bundle and schema-1 database, removes the migrated WAL/SHM sidecars, and only then restarts the old daemon. If either half cannot be restored safely, the old daemon stays stopped and the private transaction is retained for recovery.

The LaunchAgent template is account-neutral. During installation, the script renders the current user's app location, `~/bin`, and `~/Library/Logs/Launch Station` paths into the installed plist; no developer home path is baked into the distribution.

After installation:

```sh
launch doctor
# Open the app path printed by the installer, either /Applications/... or ~/Applications/...
```

## Quick start

Initialize a project directory. This registers its canonical path and creates the first read-only mirror:

```sh
cd /path/to/project
launch init . --project-name "My Project"
```

Register a Python documentation server on a fresh managed port:

```sh
launch --create "My Project docs" "Serve the project documentation" \
  --directory "$PWD" \
  --tag docs --tag python \
  --action-name docs \
  --action-description "Static documentation server" \
  --type process \
  --port auto \
  --url 'http://${HOST}:${PORT}/' \
  --health 'http://${HOST}:${PORT}/' \
  -- python3 -m http.server '${PORT}' --bind '${HOST}'
```

Launch it and ask the daemon to open the primary endpoint:

```sh
launch "My Project docs" --open
```

Run a distinct additional managed instance only when concurrent work is intentional:

```sh
launch "My Project docs" --new --open
```

Inspect, read logs, and close the exact active session:

```sh
launch details "My Project docs"
launch logs "My Project docs" --session SESSION_UUID
launch close "My Project docs" --session SESSION_UUID
```

Fully close its exact session and start a fresh one in a single daemon operation:

```sh
launch relaunch "My Project docs" --session SESSION_UUID --open
```

Every mutating command updates SQLite and regenerates `/path/to/project/launch_details.md`; do not edit that file yourself.

## GUI

Open the app location printed by the installer (`/Applications/Launch Station.app` when writable, otherwise `~/Applications/Launch Station.app`). The native interface provides:

- Search across launcher name, project name, project directory, and tags.
- A separate running section with a card for each managed instance, including primary/additional role, session ID, PID information, independent `OPEN`, `LOGS`, `CLOSE`, and `RELAUNCH` actions, and live `STARTING`, `RUNNING`, `CLOSING`, failure, and idle states.
- Launcher name, tags, description, run details, working directory, commands, services, ports, endpoints, session ID, and PID information.
- Optional runtime arguments for the primary action, with quote and backslash parsing.
- A prominent `LAUNCH` button plus `LAUNCH NEW`; the GUI requests that the primary endpoint be opened when one exists.
- A `CLOSE` button with confirmation listing the exact services that will be stopped.
- A confirmed `RELAUNCH` action that fully closes the selected exact session before starting a distinct one.
- A pinned `INSTALL AGENT SKILL` prompt whenever a detected coding-agent host is missing or stale.
- A native agent-skill chooser with equal square Codex, Claude Code, and Download `SKILL.md` actions.
- A permanent Agent Integration Settings page for reinstalling or exporting the skill later.
- An `OPEN` chooser with only daemon-derived targets for the selected exact session, a non-opening probe, clickable active endpoints, command copying, Finder reveal, and current/last-session logs.
- Managed Launch History, globally or per launcher, with durable cursor-paged session records; external observations never appear in this history.
- Separately started listeners inside the main Running section, clearly marked `STARTED SEPARATELY` and observed rather than adopted. Add Launcher opens a reviewable draft; it never saves a launcher or claims a process automatically. Closing an outside listener requires a fresh exact confirmation.
- Live polling every second while a session is active and every three seconds while idle.
- Light and dark appearance, reduced-motion support, and accessibility labels.

Keyboard shortcuts:

| Shortcut | Action |
| --- | --- |
| Command-F | Focus launcher search |
| Command-Return | Launch the selected idle launcher |
| Command-. | Request close for the selected active session |
| Shift-Command-Return | Request relaunch for the selected active session |
| Command-R | Refresh the catalog |

The default window is 1040 × 680 points and the supported minimum is 820 × 540.

## Agent skill integration

The app bundle carries one versioned, self-contained skill at `Contents/Resources/Skills/launchstation`. The daemon is the only installer; the GUI and CLI call its authenticated API. The same managed files are used for both supported hosts:

| Choice | Detection | Personal installation path |
| --- | --- | --- |
| Codex | Exact Codex/ChatGPT bundle ID plus OpenAI Developer ID signature, or an OpenAI-signed real `codex` that passes a bounded product-version probe in an expected executable path | `~/.agents/skills/launchstation` |
| Claude Code | Exact Claude bundle ID plus Anthropic Developer ID signature, or an Anthropic-signed real `claude` that returns the documented Claude Code version banner from `~/.local/bin`, `~/bin`, Homebrew, `/usr/local/bin`, or daemon `PATH` | `~/.claude/skills/launchstation` |
| Download `SKILL.md` | Running Launcher service | User-selected location from a native save panel |

An unavailable product remains visible but disabled; clicking it cannot create that product's configuration. Launcher reports detected Codex Desktop/CLI and local Claude Desktop/CLI availability, but those surfaces are informational only: they never select a separate install or path. One Codex product install is shared by Codex Desktop, CLI, and IDE at `~/.agents/skills/launchstation`; the IDE reads those same installed files but is not separately detected or reported by Launcher because it is not another installation destination. One Claude product install is shared by local Claude Desktop and CLI at `~/.claude/skills/launchstation`. Reinstalling stages a complete replacement of the exact `launchstation` skill folder, preserves unknown files, verifies `SKILL.md`, `agents/openai.yaml`, and `VERSION` byte-for-byte, then exposes the entire directory in one atomic filesystem commit. Staging occurs in a mode-`0700` transaction directory outside the host's scanned `skills` root. A staging or commit failure leaves the previously visible install untouched; an interruption after commit can leave only a complete old snapshot outside discovery and is safe to retry. Sibling skills and unknown files are preserved. Symlinked or otherwise unsafe destinations are blocked.

The skill tells coding agents to register every new runnable local project after verifying its real commands, recommend Launcher for ordinary local start/relaunch work, use compound actions for related services, and never edit `launch_details.md` manually. It also documents ports, readiness, native apps, Expo/iOS, revisions, deletion confirmation, API routes, failure handling, and security boundaries.

CLI access to the same integration:

```sh
launch skill status
launch skill install codex
launch skill install claude-code
launch skill uninstall codex
launch skill source > /tmp/SKILL.md
```

`launch skill source` prints the canonical standalone file; it never chooses or overwrites a destination itself. Uninstall is interactive and receipt-backed: Launcher displays the managed removable paths and preserved unknown paths, requires the exact confirmation text, then removes only receipt-proven Launcher-managed files. Inspection fails closed for symlinks, hard links, special files, traversal/identity changes, or trees beyond 4,096 entries, 24 levels, or 64 MiB of hashed content; no file is removed when inspection cannot complete. Modified, unrecognized, blocked, or changed destinations likewise produce a warning/refusal rather than broad deletion. Codex auto-detects an installed skill; Claude Code sees changes live unless installation newly created its top-level skills directory, in which case restart Claude Code.

## Core model

### Projects

A project is an initialized canonical directory. Running `launch init` again for the same directory is idempotent and repairs its generated manifest. When a command is run from a subdirectory, project resolution chooses the nearest initialized ancestor.

### Launchers

A launcher is a globally named shortcut with:

- A project, description, optional run details, and normalized tags.
- One or more ordered actions.
- Exactly one primary action; runtime arguments are passed only to that action.
- A monotonically increasing revision used for optimistic concurrency.

Launcher names are unique across the entire catalog, not merely within one project. Comparison collapses whitespace and ignores case, diacritics, and character width, so `My App`, `my app`, and a whitespace-padded equivalent collide. Names may contain at most 80 characters/240 UTF-8 bytes, may not start with `-`, contain slashes/control characters, or equal a CLI command such as `status` or `logs`.

Action names use the same normalization and must be unique within their launcher. Reserved CLI words are allowed for action names.

### Action runners

| Type | CLI value | Behavior |
| --- | --- | --- |
| Direct process | `process` | Runs an executable plus an argument array; safest for exact argument boundaries |
| Shell | `shell` | Runs a command through `/bin/zsh -lc`; useful for pipelines and shell expansion |
| Application | `app` | Opens a new native app instance when LaunchServices permits and tracks its exact PID |
| URL/file | `url` | Opens the target and completes immediately without claiming another app |
| iOS/Simulator | `ios` | Selects and prepares an exact Simulator device, then runs iOS/Expo tooling without claiming or shutting down Simulator itself |

Relative action working directories are resolved from the initialized project directory and must exist. Absolute paths and `~` are also accepted.

## Registration examples

All options must appear before `--`; everything after `--` is the executable and its literal argument array. The runner expands `${NAME}` references in direct executable arguments from the configured environment. Single quotes in the registration shell preserve those references until launch time.

### npm/Vite

```sh
launch --create "Storefront web" "Run the Vite development server" \
  --directory "$PWD" \
  --tag web --tag npm --tag vite \
  --type process \
  --port auto \
  --port-name frontend \
  --url 'http://${HOST}:${PORT}/' \
  --health 'http://${HOST}:${PORT}/' \
  --ready-timeout 45 \
  -- npm run dev -- --host '${HOST}' --port '${PORT}'
```

A quoted shell command is also supported through the explicit `--command` option:

```sh
launch --create "Storefront web shell" "Run Vite through zsh" \
  --directory "$PWD" \
  --tag web \
  --type shell \
  --command 'npm run dev -- --host "${HOST}" --port "${PORT}"' \
  --port auto \
  --url 'http://${HOST}:${PORT}/'
```

Use globally distinct names when several projects have similar tasks, for example `Storefront web` and `Admin web`.

### Python server

```sh
launch --create "Analytics server" "Run the local Python HTTP server" \
  --directory "$PWD" \
  --tag python --tag local \
  --type process \
  --port auto \
  --url 'http://${HOST}:${PORT}/' \
  --health 'http://${HOST}:${PORT}/' \
  -- python3 -m http.server '${PORT}' --bind '${HOST}'
```

For a framework that expects different environment variable names:

```sh
launch --create "Analytics API" "Run the local API" \
  --directory "$PWD" \
  --type process \
  --port auto \
  --port-env APP_PORT \
  --host-env APP_HOST \
  --url 'http://${HOST}:${PORT}/health' \
  --health 'http://${HOST}:${PORT}/health' \
  -- python3 server.py --host '${APP_HOST}' --port '${APP_PORT}'
```

`PORT` and `HOST` in URL/health templates refer to the managed endpoint. `--port-env` and `--host-env` choose the variable names passed to the process.

### Native `.app`

```sh
launch --create "Project Xcode" "Open this project's Xcode workspace" \
  --directory "$PWD" \
  --tag xcode --tag macos \
  --type app \
  --open application \
  --app-bundle-id com.apple.dt.Xcode \
  -- /Applications/Xcode.app
```

Arguments after the application target are passed through LaunchServices. The app runner requests a new application instance and records the returned PID. If LaunchServices reuses a pre-existing instance, Launch Station marks it as reused and refuses to terminate it on `CLOSE`.

To open a URL or file without owning the receiving app:

```sh
launch --create "Project guide" "Open the local project guide" \
  --directory "$PWD" \
  --type url \
  -- "$PWD/README.md"
```

URL actions are one-shot sessions and do not close the browser/editor that handled the target.

### Expo

```sh
launch --create "Mobile Expo" "Start Expo for the iOS development workflow" \
  --directory "$PWD" \
  --tag expo --tag ios --tag mobile \
  --run-details "The Metro port is managed; existing Simulator devices are never shut down." \
  --action-name metro \
  --action-description "Expo Metro bundler" \
  --type ios \
  --port auto \
  --open simulator \
  -- npx expo start --ios
```

The supervisor detects `expo`, `npx expo`, and matching shell commands. It adds missing `--localhost`, the managed `--port`, and `--ios` arguments without duplicating options already present. With `--open simulator`, it selects a device, boots it when necessary, waits for boot completion, and opens Simulator before Expo starts. Closing the launcher stops only the owned Expo/Metro command or managed port run; it never shuts down the selected device or terminates a pre-existing Simulator process.

### iOS Simulator command

```sh
launch --create "Demo iOS app" "Launch the installed app on the booted simulator" \
  --directory "$PWD" \
  --tag ios --tag simulator \
  --type ios \
  --open simulator \
  --env CODEX_SIMULATOR_DEVICE=booted \
  -- xcrun simctl launch --console booted com.example.DemoApp
```

`CODEX_SIMULATOR_DEVICE` accepts `booted`, an exact device name, or a UDID. If it is absent, the launcher chooses an already booted device first, then the newest available iOS device. The selected UDID and name are exposed to the action as `CODEX_SIMULATOR_UDID` and `CODEX_SIMULATOR_NAME`.

For a built `.app`, the simulator preparation step can also install and launch it before the configured command starts:

```sh
--env CODEX_SIMULATOR_APP_PATH="$PWD/build/Demo.app" \
--env CODEX_SIMULATOR_BUNDLE_ID=com.example.DemoApp \
--env 'CODEX_SIMULATOR_APP_ARGUMENTS=["--ui-testing","--reset-state"]'
```

The optional arguments value is a JSON string array. The launcher performs `simctl install` and `simctl launch` against the selected UDID. It tracks and closes only the configured host-side command process group; it deliberately does not shut down Simulator or terminate unrelated simulated apps.

### Compound project

Create one action, append services with explicit order, then select the user-facing primary action:

```sh
launch --create "Shop full stack" "Start database, API, and frontend" \
  --directory "$PWD" \
  --run-details "Services start in order and close in reverse order." \
  --tag compound --tag web \
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
  --env 'VITE_API_URL=${LAUNCH_STATION_ACTION_API_URL}' \
  -- npm run dev -- --host '${HOST}' --port '${PORT}' --strictPort

launch action add "Shop full stack" database "Development data service" \
  --cwd database \
  --order 0 \
  --type process \
  -- ./start-development-database

launch update "Shop full stack" --primary-action frontend
```

Actions run in ascending order and stop in reverse order. Earlier successful actions expose their resolved endpoint values to later actions as `LAUNCH_STATION_ACTION_<ACTION_TOKEN>_HOST`, `_PORT`, and `_URL`; the normalized uppercase action name supplies the token. Linked references must identify an existing earlier required provider, and action names must produce unique tokens. The example therefore starts database → API → frontend while keeping frontend primary for runtime arguments and `--open`.

If a required action fails to start or become ready, already-started actions are closed. Add `--optional` while creating an action to permit the rest of the launcher to remain active in a `partial` session.

## CLI reference

Run `launch --help` for the compact built-in synopsis. Long command names and their leading-option aliases are equivalent, such as `launch create`/`launch --create` and `launch details`/`launch --details`.

### Project and catalog

```text
launch init [DIRECTORY] [--project-name NAME] [--json]
launch list [QUERY] [--tag TAG] [--state STATE] [--directory PATH] [--json]
launch details NAME [--json]
launch retrieve NAME [--json]
launch status [NAME] [--json]
launch doctor [DIRECTORY] [--json]
```

Valid session state filters are `starting`, `running`, `partial`, `stopping`, `exited`, `failed`, and `orphaned`. API search matches launcher name, description, and tags; the GUI additionally searches project name and directory.

### Create

```text
launch create NAME DESCRIPTION [RUN_DETAILS] --command COMMAND [options]
launch --create NAME DESCRIPTION [RUN_DETAILS] [options] -- EXECUTABLE ARG...
```

The optional third positional is human-readable run context and is never executed. Executable content must be explicit: use `--command` for a zsh command or place a direct executable and literal argument array after `--`.

Create/action-definition options:

| Option | Meaning |
| --- | --- |
| `--directory PATH`, `--dir PATH` | Initialized project; defaults to current directory (launcher creation only) |
| `--run-details TEXT` | Human-readable launch notes; never executed (launcher creation only; alternative to the third positional) |
| `--tag TAG` | Add one tag; repeatable (launcher creation only) |
| `--tags A,B` | Add comma-separated tags (launcher creation only) |
| `--action-name NAME` | Primary action name; default `main` |
| `--action-description TEXT` | Action description |
| `--cwd PATH` | Action working directory relative to project or absolute |
| `--order N` | Explicit unique compound-action order |
| `--type TYPE` | `process`, `shell`, `app`, `url`, or `ios` |
| `--command COMMAND` | Set a shell command and select `shell` |
| `--executable VALUE` | Set the process executable, app/URL target, or iOS command |
| `--arg VALUE` | Append one stored argument; repeatable |
| `--app-bundle-id ID` | Native application bundle identifier |
| `--port none\|auto\|N` | No port, a fresh port, or a managed fixed port |
| `--port-name NAME` | Logical port label shown in metadata |
| `--port-env NAME` | Process port variable; default `PORT` |
| `--host-env NAME` | Process host variable; default `HOST` |
| `--url TEMPLATE` | Endpoint template |
| `--lease DURATION` | `codex-port` lease; default `8h` |
| `--health TEMPLATE` | HTTP(S) readiness endpoint |
| `--open TARGET` | `none`, `browser`, `application`, or `simulator` |
| `--env KEY=VALUE` | Persist a non-secret environment value; repeatable |
| `--inherit-env NAME` | Copy a named daemon environment value at launch time; repeatable |
| `--ready-timeout SECONDS` | Readiness timeout, 1–600; default 30 |
| `--stop-timeout SECONDS` | Graceful stop budget, 1–60; default 8 |
| `--optional` | Do not roll back the full launcher when this action fails |
| `--required` | Mark the action required (the default) |
| `--deny-runtime-args` | Do not pass run-time arguments to this action |
| `--allow-runtime-args` | Permit run-time arguments (the non-URL default) |
| `--json` | Print the complete result as JSON |

Registration validates non-empty action descriptions, existing working directories, unique action names/orders, accepted managed-port lease syntax, and absolute endpoint/health URLs after placeholder substitution. Invalid definitions are rejected before they enter the catalog.

### Run, relaunch, and close

```text
launch NAME [--new] [--open] [-- RUNTIME_ARG...]
launch run NAME [--new] [--open] [-- RUNTIME_ARG...]
launch relaunch NAME [--session UUID] [--open] [-- RUNTIME_ARG...]
launch close NAME [--session UUID] [--json]
launch logs NAME [--session UUID]
launch history [NAME] [--state STATE] [--role primary|additional] [--limit N] [--cursor TOKEN] [--json]
launch open NAME [--session UUID] [--option SERVER_DERIVED_OPTION_ID] [--probe] [--json]
```

`launch NAME` is the shortest form. Runtime arguments are appended only to the primary action when that action permits them. Direct/iOS arguments retain exact boundaries, shell arguments are safely quoted and appended exactly once, and native-app arguments are forwarded through LaunchServices. URL actions reject runtime arguments because the receiving application is intentionally not owned. If the launcher already has an active primary session, the CLI returns that session instead of starting a duplicate; `--new` creates an additional managed instance.

At creation time, `--open browser` makes an action endpoint open whenever that action starts. At run time, bare `--open` requests opening the primary action's endpoint. The GUI sends this run-time request for every launch.

`launch relaunch` is not a client-side close/run pair. One daemon request reserves the launcher, stops its exact active session to a proven terminal state, then creates a distinct session with the supplied runtime arguments and open request. `--session UUID` targets one active instance; without it, relaunch uses the primary instance or requires the launcher to remain idle. A relaunch refuses to start a replacement if the previous exact ownership becomes `orphaned`, if a confirmed `expectedSessionID` changed, or if another relaunch is already in progress. `close`, `relaunch`, and `logs` all accept the same exact-session selector, so an additional instance is never selected by name alone.

`launch history` returns durable Launcher-managed sessions, newest first, and supports cursor pagination plus launcher, state, and primary/additional-role filters. External listener observations are intentionally ephemeral and are never written into this history.

`launch open NAME` first lists the server-derived open/focus choices for the selected exact session. Supply one listed opaque option ID with `--option` to open it, or combine that option with `--probe` to validate it without opening. The CLI does not accept a caller-supplied URL, PID, device ID, or target identity.

### External listeners

```text
launch external list [--refresh] [--json]
launch external draft OBSERVATION_UUID [--json]
launch external close OBSERVATION_UUID
```

This is an observation surface, not a process-adoption surface. `list` reports external listeners known to the daemon; `--refresh` obtains a new snapshot. `draft` refreshes, then produces a review-only Add Launcher proposal. Draft port policy begins `review-required`; choosing a fresh managed port is saveable only when the reviewed process arguments explicitly consume `${PORT}`/`${CODEX_PORT}`, the shell command references `$PORT`/`$CODEX_PORT`, or the command is recognized Expo and Launcher will inject its managed `--port`. Otherwise the draft remains blocked as `managed-port-consumption-required`. Saving remains a separate explicit launcher-creation step. Observations, draft IDs, and close intents stay only in daemon memory, expire across a daemon restart, and never become durable history unless the user saves and subsequently runs a launcher.

Direct process arguments are displayed only after secret-like options, headers, assignments, URLs, and tokens are redacted. Shell-wrapper text is shown only when it uses a conservative unquoted literal grammar; quoting, escapes, expansion, globbing, control operators, redirection, comments, control bytes, or truncation hide the complete shell command. A hidden or partially redacted command can never become a runnable draft until the user replaces and reviews it.

`external close` is deliberately interactive and has no `--json` or non-interactive bypass. It re-correlates exact process identity, displays the PID, start time, endpoints, owner, and exact confirmation text, then signals only after that text is typed. Launcher refuses an observation that is stale, Launcher-owned, unverified, or otherwise unsafe to close.

### Agent skill

```text
launch skill status [--json]
launch skill install codex|claude-code [--json]
launch skill uninstall codex|claude-code
launch skill source [--json]
```

Status reports product detection, install path, current/outdated/blocked state, and managed version. Detected product surfaces are informational only: one Codex product install serves Codex Desktop, CLI, and IDE at `~/.agents/skills/launchstation`, and the IDE reads those same files but is not separately detected or reported by Launcher; one Claude product install serves local Claude Desktop and CLI at `~/.claude/skills/launchstation`. Install is a non-retried host-only mutation and refuses an unavailable product or unsafe destination. Source prints the exact standalone `SKILL.md`; the GUI uses the same source with `NSSavePanel`.

Uninstall is product- and receipt-bound: it requires a TTY and the exact confirmation text from the selected product's receipt-backed inspection, lists removable and preserved files, then removes only receipt-proven Launcher-managed files. Unsafe, modified, unrecognized, changed, or bounded-inspection failures are warning-backed refusals, not permission to remove a whole skill directory.

### Update

```text
launch update NAME \
  [--name NEW_NAME] \
  [--description TEXT] \
  [--run-details TEXT | --clear-run-details] \
  [--tags A,B | --clear-tags] \
  [--add-tag TAG] [--remove-tag TAG] \
  [--primary-action ACTION] \
  [complete primary-action mutation options] \
  [--if-revision N] [--json]
```

Without `--if-revision`, the CLI retrieves the current launcher and uses that revision. Supplying an explicit revision is useful for automation that must reject stale edits. `--primary-action` selects any existing action by name; when combined with action mutation flags, place it before those flags so the selected action is changed atomically. The action mutation surface includes `--action-name`, `--action-description`, `--cwd`, `--order`, `--type`, `--command`/`--clear-command`, `--executable`/`--clear-executable`, `--arg`/`--append-arg`, `--clear-args`, `--remove-arg`, `--set-arg INDEX VALUE`, `--args-json`, environment add/remove/clear flags, inherited-environment add/remove/clear flags, every port/URL/health/open/app-bundle field, readiness/stop timeouts, required/optional state, and runtime-argument policy. Use `launch action update` when you do not also want to select that action as primary.

### Compound actions

```text
launch action add LAUNCHER ACTION DESCRIPTION [action-definition options] [-- EXECUTABLE ARG...]
launch action update LAUNCHER ACTION [--name NAME] [--description TEXT]
  [complete action mutation options] [--if-revision N] [--json]
launch action delete LAUNCHER ACTION [--yes --if-revision N] [--json]
```

Action update accepts the same mutable action fields listed above. Environment removals use `--remove-env KEY`/`--clear-env`; inherited names use `--remove-inherit-env KEY`/`--clear-inherit-env`; nullable fields use `--clear-health`, `--clear-url`, and `--clear-app-bundle-id`. Deleting the sole remaining action is rejected. If the primary action is deleted from a multi-action launcher, the first remaining ordered action becomes primary. New actions use one greater than the current maximum order, so deleting a middle action cannot create an ordering collision.

### Delete a launcher shortcut

Interactive deletion retrieves a five-minute delete intent, prints the current name, description, project, revision, tags, and commands, then requires the exact launcher name:

```sh
launch delete "Old shortcut"
```

Non-interactive deletion must bind the operation to a known revision:

```sh
launch delete "Old shortcut" --yes --if-revision 4
```

Deletion is rejected if the launcher has an active session, its revision changed after confirmation, or the intent expired. It soft-deletes only the shortcut in the catalog and regenerates `launch_details.md`; if that mirror is temporarily unwritable, the committed catalog change remains observable as pending/drifted and reconciliation retries it. Deletion does not remove source files or stop unrelated processes.

### Manifest synchronization

```text
launch sync [DIRECTORY] [--check | --repair] [--json]
```

`--check` compares both deterministic content and mode `0444`. Drift returns exit status 4. `--repair` atomically regenerates the mirror and restores read-only permissions.

### API discovery

```text
launch api endpoint [--json]
```

The endpoint uses a dynamically selected port and changes when the daemon restarts. Never hard-code it.

### Exit statuses

| Status | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Unexpected local error |
| 2 | Command usage error |
| 3 | Not found |
| 4 | Conflict, stale revision, or manifest drift |
| 5 | Validation failed |
| 6 | Service/API/transport failure |
| 7 | Confirmation required or cancelled |

## `launch_details.md`

Every initialized project has exactly one generated file named `launch_details.md`. It is intended for agents and humans to read when they need to discover how that project is started.

The file contains:

- A generated-file warning, schema identifier `com.launchstation/launch-details-v1`, project ID, revision, and SHA-256 content hash.
- Project directory and catalog metadata.
- Launchers sorted deterministically by normalized name.
- Name, ID, description, run details, tags, revision, and ready-to-copy `launch` command for each launcher.
- Ordered actions with type, working directory, exact display command, required/optional state, runtime-argument policy, timeouts, open behavior, port policy, and readiness URL.
- Environment variable names, but not environment values.

The daemon writes it atomically with mode `0444`. SQLite remains authoritative. Agents must never remove read-only protection or edit the file manually; use `launch create`, `launch update`, `launch action ...`, `launch delete`, or the authenticated API. Use `launch sync --check` to detect missing/content/permission drift and `launch sync --repair` to restore it. On ordinary macOS filesystems this is an advisory same-user boundary rather than kernel-level per-process access control: another same-UID program could replace the file after changing directory permissions, so the daemon also records drift and reconciles manifests on startup.

Do not place secrets in launcher names, descriptions, run details, tags, command strings, or arguments: those fields are intentionally visible in the GUI, CLI JSON, and generated mirror.

## Local HTTP API

The daemon exposes HTTP/1.1 on a dynamic loopback endpoint. It accepts only `GET`, `POST`, `PATCH`, and `DELETE`, limits headers to 16 KiB and bodies to 1 MiB, sets `Cache-Control: no-store`, and requires an exact bearer token on every route.

Discover credentials for the current daemon process:

```sh
ENDPOINT="$(launch api endpoint)"
METADATA="$HOME/Library/Application Support/Launch Station/service.json"
TOKEN="$(plutil -extract token raw -o - "$METADATA")"

curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json" \
  "$ENDPOINT/v1/health"
```

`service.json` is mode `0600`, and its token is regenerated on every daemon start. Do not print, log, commit, or share it. A client receiving `401` should reload the metadata rather than reusing a cached token.

### Routes

| Method and path | Request | Result |
| --- | --- | --- |
| `GET /v1/health` | — | Service version, schema, PID, start time, endpoint |
| `GET /v1/snapshot` | — | Projects, launcher details, active/last sessions, service state |
| `GET /v1/external-processes` | — | Cached ephemeral external-listener observations |
| `GET /v1/external-processes/refresh` | — | Fresh ephemeral external-listener observations |
| `GET /v1/external-processes/{observationID}/draft` | — | Review-only Add Launcher proposal from a current observation |
| `POST /v1/external-processes/{observationID}/close-intent` | — | Exact external-close confirmation capability |
| `POST /v1/external-processes/{observationID}/close` | `ExternalCloseRequest` | Confirmation-bound external close |
| `GET /v1/projects` | — | All initialized projects |
| `POST /v1/projects/init` | `ProjectInitRequest` | Initialize or repair a project |
| `GET /v1/projects/resolve?directory=...` | — | Exact or nearest containing project |
| `POST /v1/projects/{projectID}/sync` | `{ "repair": true|false }` | Check or repair the mirror |
| `GET /v1/launchers?q=...` | — | Search/list launcher details |
| `POST /v1/launchers` | `LauncherCreateRequest` | Create a launcher |
| `GET /v1/launchers/by-name/{name}` | — | Retrieve launcher details by normalized name |
| `GET /v1/launchers/{launcherID}` | — | Retrieve launcher details by ID |
| `PATCH /v1/launchers/{launcherID}` | `LauncherPatchRequest` + `If-Match` | Revision-bound metadata/primary-action update |
| `POST /v1/launchers/{launcherID}/actions` | `ActionCreateRequest` + `If-Match` | Append an action |
| `PATCH /v1/launchers/{launcherID}/actions/{actionID}` | `ActionPatchRequest` + `If-Match` | Replace an action |
| `DELETE /v1/launchers/{launcherID}/actions/{actionID}` | `{ "expectedRevision": N }` + `If-Match` | Delete an action |
| `POST /v1/launchers/{launcherID}/sessions` | `SessionStartRequest` | Start a session |
| `POST /v1/launchers/{launcherID}/relaunch` | `SessionRelaunchRequest` | Fully close the exact active session, then start a distinct session |
| `POST /v1/launchers/{launcherID}/delete-intent` | `{ "ok": true }` | Create a five-minute delete intent |
| `DELETE /v1/launchers/{launcherID}` | `DeleteRequest` + `If-Match` | Delete the confirmed shortcut |
| `GET /v1/history/sessions` | `launcherID`, `state`, `role`, `limit`, `cursor` query filters | Cursor-paged durable managed history |
| `GET /v1/sessions` | `active=true` optional query | Recorded sessions, optionally active only |
| `GET /v1/sessions/{sessionID}` | — | Retrieve one recorded session |
| `POST /v1/sessions/{sessionID}/stop` | `{ "ok": true }` | Stop the exact active session |
| `POST /v1/sessions/{sessionID}/relaunch` | `SessionRelaunchRequest` | Relaunch one exact active session |
| `GET /v1/sessions/{sessionID}/logs` | — | Combined bounded log text |
| `GET /v1/sessions/{sessionID}/open-options` | — | Server-derived opaque open/focus choices |
| `POST /v1/sessions/{sessionID}/open` | `SessionOpenRequest` | Open one derived choice |
| `POST /v1/sessions/{sessionID}/open-probe` | `SessionOpenRequest` | Probe one derived choice without opening |
| `GET /v1/skills/status` | — | Bundled skill version and Codex/Claude host installation states |
| `GET /v1/skills/source` | — | Canonical standalone `SKILL.md` source |
| `POST /v1/skills/install` | Host-only `LauncherSkillInstallRequest` | Install/reinstall the one shared product skill |
| `POST /v1/skills/uninstall-intent` | Product `LauncherSkillUninstallIntentRequest` | Receipt-backed uninstall inspection for that product root |
| `POST /v1/skills/uninstall` | Product/receipt-bound `LauncherSkillUninstallRequest` | Consume exact confirmation and remove only managed files |

Mutating launcher/action/delete requests that carry `expectedRevision` must also send the same decimal value in `If-Match`. A mismatch returns HTTP 412. Duplicate names or active-session conflicts return 409, invalid models return 422, and missing objects return 404. External observations, draft identifiers, and close intents are in-memory capabilities rather than catalog records; refetch after a daemon restart and never represent them as durable history.

Initialize a project directly through the API:

```sh
curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"directory\":\"$PWD\",\"displayName\":\"My Project\"}" \
  "$ENDPOINT/v1/projects/init"
```

### JSON model shapes

The CLI's `--json` output is the simplest authoritative source for IDs, revisions, and complete action objects:

```sh
launch details "My Project docs" --json
launch list --json
launch status --json
```

A create request has this shape; all non-optional action and port fields are required by direct Codable clients:

```json
{
  "projectID": "PROJECT-UUID",
  "name": "My Project docs",
  "description": "Serve the project documentation",
  "runDetails": "Uses a managed local port",
  "tags": ["docs", "python"],
  "primaryAction": {
    "id": "ACTION-UUID",
    "name": "docs",
    "normalizedName": "docs",
    "description": "Static documentation server",
    "order": 0,
    "runner": "process",
    "workingDirectory": ".",
    "executable": "python3",
    "arguments": ["-m", "http.server", "${PORT}", "--bind", "${HOST}"],
    "shellCommand": null,
    "environment": {},
    "inheritedEnvironment": [],
    "port": {
      "mode": "automatic",
      "logicalName": "main",
      "fixedPort": null,
      "environmentVariable": "PORT",
      "hostEnvironmentVariable": "HOST",
      "URLTemplate": "http://${HOST}:${PORT}/",
      "lease": "8h"
    },
    "healthCheckURL": "http://${HOST}:${PORT}/",
    "openTarget": "none",
    "appBundleIdentifier": null,
    "readyTimeoutSeconds": 30,
    "stopTimeoutSeconds": 8,
    "required": true,
    "allowsRuntimeArguments": true
  }
}
```

Start request:

```json
{
  "runtimeArguments": ["--mode", "demo"],
  "openRequested": true,
  "expectedLauncherRevision": 4,
  "mode": "reuse-primary"
}
```

`mode` is `reuse-primary` for the ordinary idempotent primary slot and `new-instance` only for an explicit concurrent additional session.

Relaunch request and result:

```json
{
  "runtimeArguments": ["--mode", "demo"],
  "openRequested": true,
  "expectedSessionID": "OPTIONAL-CONFIRMED-SESSION-UUID",
  "requireIdle": false,
  "expectedLauncherRevision": 4
}
```

The result contains `previousSession` (omitted/null when idle) and the new `session`. `expectedLauncherRevision` binds start/relaunch to the displayed command definition; relaunch rechecks it after CLOSE before START. Supplying `expectedSessionID` prevents an interactive client from closing a different session that appeared after confirmation. A client that observed idle passes `requireIdle: true`, preventing a newly appeared session from being silently closed. The two session preconditions are mutually exclusive.

Launcher patch fields are `expectedRevision`, optional `name`, `description`, `runDetails`, `replaceTags`, `primaryAction`, and `primaryActionID`, plus `clearRunDetails`, `addTags`, and `removeTags`. Action create/patch requests carry `expectedRevision` and an `action`. A delete request carries `expectedRevision` and the exact `intentToken` returned by `delete-intent`.

## Ports, readiness, and environment

- `--port none` uses the bundled process-group runner directly.
- `--port auto` delegates allocation and lifecycle to `codex-port`, producing a fresh non-conflicting port.
- `--port N` asks `codex-port` to own that fixed port and fails rather than taking over an unrelated listener.
- Managed hosts default to `127.0.0.1`; detected Expo actions use `localhost`.
- The default lease is `8h`. Live `codex-port` ownership is birth-identity checked after daemon recovery, and active leases are renewed before their configured duration can expire.
- The runner maps `codex-port`'s `CODEX_PORT`/`CODEX_HOST` values into the configured action variables, defaulting to `PORT`/`HOST`.
- Direct executable paths, arguments, and configured environment values support `${VARIABLE}` substitution. Shell commands receive the variables in their zsh environment.
- A slash-containing relative process executable such as `./tool` resolves from that action's resolved working directory. Critical tools should still use a known PATH or absolute path rather than interactive shell setup.
- Later compound actions receive `LAUNCH_STATION_ACTION_<ACTION_TOKEN>_HOST`, `_PORT`, and `_URL` for earlier resolved actions. These names are runtime-owned, structurally validated, and omitted from generated manifests.
- Endpoint and health templates support `${HOST}`/`${PORT}`, `{host}`/`{port}`, and `{{host}}`/`{{port}}`.
- A readiness URL succeeds on HTTP 200–399. Required-action timeout/failure closes already-started services; optional-action failure may leave a `partial` session.

The LaunchAgent and runner use a stable baseline `PATH` containing `~/bin`, Apple system directories, `/opt/homebrew/bin`, and `/usr/local/bin`; they do not inherit the daemon's full environment. Only explicitly requested `--inherit-env` names and stored `--env` values are added. Prefer absolute executable paths for critical launchers, and remember that `--env` values are stored in SQLite. `CODEX_PORT`, `CODEX_HOST`, and `CODEX_SERVICE_ID` are reserved manager-owned names and are rejected. Environment fields can be changed through revision-bound `launch update` and `launch action update` commands.

## Lifecycle guarantees

- A launcher can have at most one active primary session plus any number of explicitly requested additional sessions. A repeated ordinary launch returns the current primary; `--new` creates another exact additional instance.
- Relaunching a selected primary reserves and preserves the primary slot across actor suspension, closes that confirmed exact primary fully, and restarts it without disturbing additional instances. Relaunching a selected additional session replaces only that exact session with a fresh additional instance. Neither path starts past an orphaned close.
- Every session snapshots its launcher revision and complete action definitions. Editing a launcher while it is running does not change what `CLOSE` owns or its stop-timeout policy.
- Non-port processes run under a tiny group leader in a new process session. The daemon records PID, process group, and PID birth identity.
- Stop escalates only against that verified process group: `SIGINT`, then `SIGTERM`, then `SIGKILL` within the configured budget. PID reuse causes an `orphaned` result rather than signaling the wrong process.
- Managed-port actions are stopped only through their exact `codex-port` manager ID. If the manager refuses, the daemon does not fall back to killing by port or name.
- Native apps are closed only when the launcher proves it owns the exact new application instance. Reused apps are left alone.
- URL/file actions never claim the receiving application.
- iOS/Expo closure owns only the command/managed-port run; it does not shut down existing Simulator devices or unrelated simulator apps.
- Natural process exit is monitored. The GUI returns from `CLOSE` to `LAUNCH` when the recorded exact process exits.
- After a daemon restart, live sessions are reconciled from exact birth identity or `codex-port` ownership. Unprovable ownership becomes `orphaned`.

## Logs and state

| Path | Contents/permissions |
| --- | --- |
| `~/Library/Application Support/Launch Station/launcher.sqlite3` | SQLite source of truth, mode `0600`, WAL enabled |
| `~/Library/Application Support/Launch Station/service.json` | Dynamic endpoint/token/PID metadata, mode `0600` |
| `~/Library/Application Support/Launch Station/Logs/<session>/` | Per-action process output, private state directory |
| `~/Library/Application Support/Launch Station/Runner Specifications/` | Private launch specifications |
| `~/Library/Application Support/Launch Station/Runner Status/` | Exact process handshake records |
| `~/Library/Logs/Launch Station/service.log` | LaunchAgent standard output |
| `~/Library/Logs/Launch Station/service-error.log` | LaunchAgent/daemon errors |

`launch logs NAME` and the GUI return the active session's logs, or the last session when idle. The API reads at most the most recent 512 KiB from each action log and labels sections by action/state.

Program output may itself contain sensitive data. State directories are mode `0700`, but operators should still configure child processes not to print secrets.

## Security model

- The listener rejects non-loopback peer addresses even though it also requires authentication.
- Every request requires a per-daemon random bearer token from a mode-`0600` metadata file.
- The database is mode `0600`; application state and run directories are mode `0700`.
- HTTP responses are not cached, and request/body sizes are bounded.
- Optimistic revisions and `If-Match` prevent stale API mutations.
- Launcher deletion requires a short-lived, revision-bound intent token and refuses active sessions.
- Stop operations use exact manager ID or PID birth identity, never process name or port alone.
- `launch_details.md` excludes environment values, but commands and arguments are visible by design.

This is a local command-execution service. Anyone who obtains the bearer token can invoke its API and create or run commands as the current user. Never expose the endpoint/token, weaken state permissions, or register untrusted command text. Use `--env` only for non-secret values; use a purpose-built secret source read by the launched program for credentials.

## Troubleshooting

### Service unavailable

```sh
launchctl print "gui/$(id -u)/com.jakemawson.launchstation.service"
launchctl kickstart "gui/$(id -u)/com.jakemawson.launchstation.service"
tail -n 100 "$HOME/Library/Logs/Launch Station/service-error.log"
```

Then retry `launch doctor`. Doctor reports both the daemon version and schema, returns success only when the service is healthy and compatible with this CLI, and returns exit 6 for an older/incompatible daemon. Safe read-only client requests make one automatic LaunchAgent kickstart/retry when metadata or transport is unavailable. A mutation may kickstart the service before its first request when metadata is absent, but the mutation itself is sent exactly once and is never transparently retried after an ambiguous transport failure; retrieve current state before deciding whether to repeat one.

### Current directory is not initialized

```sh
launch init "$PWD" --project-name "Project display name"
```

Project paths are canonicalized and symlinks resolved. Initialize the intended root, not an arbitrary child directory.

### Duplicate launcher name

Names are globally unique after normalization. Search the entire catalog and choose a project-qualified name:

```sh
launch list "web"
```

### Stale revision

Another client changed the launcher after it was read. Retrieve the current object and intentionally reapply the change:

```sh
launch details "Launcher name" --json
launch update "Launcher name" --description "Current description"
```

Do not blindly retry a destructive mutation with an old revision.

### `launch_details.md` was changed or lost

```sh
launch sync "$PWD" --check
launch sync "$PWD" --repair
```

Repair rewrites the generated mirror and mode. It does not import manual edits; SQLite is authoritative.

### Managed-port action fails before starting

```sh
test -x "$HOME/bin/codex-port"
codex-port status
launch details "Launcher name"
```

Verify that the command actually consumes the configured port variable. Check `launch logs` for a command that bound another port or failed readiness.

### Command works in Terminal but not from Launcher

The LaunchAgent does not load an interactive shell profile, but it supplies the documented stable baseline `PATH`. If a project depends on another toolchain directory, use an absolute executable path or a deliberate non-secret `PATH` action value. Confirm the registered working directory and command with `launch details`.

### Readiness timeout

The health template must render to HTTP(S), and a response must return status 200–399 before the action's timeout. Confirm host/port placeholders, change `--ready-timeout` with `launch update`/`launch action update` if startup is genuinely slow, and inspect logs.

### App shows `orphaned` after Close

This is a safety state, not permission to kill a similar process. Common causes are PID reuse, a pre-existing native app being reused, lost `codex-port` ownership, or an app refusing normal termination. Inspect the session details and logs; stop the external app through its own owner if appropriate.

### API returns 401

The daemon restarted and generated a new token, or the request reached the API without credentials. Reload both endpoint and token from the current `service.json`; do not persist the old token.

## Development verification

The core test suite covers SQLite persistence/concurrency rules and deterministic manifest rendering:

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/launchstation-clang-cache \
  SWIFT_MODULE_CACHE_PATH=/tmp/launchstation-swift-cache \
  xcrun swift test --jobs 2
```

`Tests/e2e.sh` is the isolated daemon integration harness. It verifies bearer authentication, conflict-safe project initialization (including preservation of an unmanaged `launch_details.md`), project-filtered retrieval, mode-`0444` manifests, literal percent-encoded names, normalized duplicate rejection, complete action mutation, stable action ordering after deletion, cross-action endpoint injection, compound launch/close, simultaneous primary/additional instances, exact additional relaunch/close, durable role-filtered history, server-derived Open choices, listener-to-session correlation, active and idle atomic relaunch, CLOSE during readiness without starting later actions, fresh managed lifecycle ownership, shell runtime arguments, readiness, logs, natural exits, revision conflicts, rename/delete confirmation, drift repair, and final catalog cleanup. It requires `LAUNCH_STATION_STATE_DIR` to identify the already-running isolated test daemon and accepts `LAUNCH_BINARY` to select the CLI under test.

`Tests/runner-environment.sh` exercises the minimal inherited environment, managed host/port alias validation and precedence, working-directory-relative executables, exact process-group identity, and the runner start gate. `Tests/process-supervisor-start-gate.sh` proves that a direct action remains suspended until its exact PID/birth/process-group record is durably registered and is killed without acknowledgement when registration fails. `Tests/simulator-orchestration.sh` uses fake `xcrun` and Simulator-open helpers to verify device selection, boot, install, and launch sequencing without changing a real simulator; it also exercises large helper output, bounded helper timeouts, and descendant-held pipes so helper execution cannot deadlock the daemon.

`Tests/seed-ui-fixture.sh` creates a representative UI catalog for visual QA in an isolated state directory; it also requires `LAUNCH_STATION_STATE_DIR`.
