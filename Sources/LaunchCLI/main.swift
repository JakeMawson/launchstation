import Darwin
import Foundation
import LauncherCore

@main
enum LaunchCommand {
    static func main() async {
        do {
            let code = try await run(Array(CommandLine.arguments.dropFirst()))
            exit(code)
        } catch let error as CLIError {
            fputs("launch: \(error.message)\n", stderr)
            exit(error.code)
        } catch let error as LauncherAPIError {
            fputs("launch: \(error.localizedDescription)\n", stderr)
            switch error {
            case .server(let status, _, _):
                if status == 404 { exit(3) }
                if status == 409 || status == 412 { exit(4) }
                if status == 422 { exit(5) }
                exit(6)
            default:
                exit(6)
            }
        } catch {
            fputs("launch: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ rawArguments: [String]) async throws -> Int32 {
        guard let first = rawArguments.first else {
            printUsage()
            return 2
        }
        if first == "--help" || first == "-h" || first == "help" {
            printUsage()
            return 0
        }

        let aliases = [
            "--init": "init", "--create": "create", "--retrieve": "details", "--details": "details",
            "--update": "update", "--delete": "delete", "--status": "status", "--close": "close", "--relaunch": "relaunch",
            "--list": "list", "--sync": "sync", "--doctor": "doctor"
        ]
        let known = Set(["init", "project", "create", "run", "relaunch", "list", "details", "retrieve", "update", "action", "delete", "status", "close", "history", "sync", "doctor", "logs", "api", "skill", "maintenance", "external", "open"])
        let command = aliases[first] ?? (known.contains(first) ? first : "run")
        let commandArguments = command == "run" && aliases[first] == nil && !known.contains(first) ? rawArguments : Array(rawArguments.dropFirst())

        switch command {
        case "init": return try await initializeProject(commandArguments)
        case "project": return try await updateProject(commandArguments)
        case "create": return try await createLauncher(commandArguments)
        case "run": return try await launch(commandArguments)
        case "relaunch": return try await relaunch(commandArguments)
        case "list": return try await list(commandArguments)
        case "details", "retrieve": return try await details(commandArguments)
        case "update": return try await update(commandArguments)
        case "action": return try await action(commandArguments)
        case "delete": return try await delete(commandArguments)
        case "status": return try await status(commandArguments)
        case "close": return try await close(commandArguments)
        case "history": return try await history(commandArguments)
        case "sync": return try await sync(commandArguments)
        case "doctor": return try await doctor(commandArguments)
        case "logs": return try await logs(commandArguments)
        case "api": return try await api(commandArguments)
        case "skill": return try await skill(commandArguments)
        case "maintenance": return try await maintenance(commandArguments)
        case "external": return try await external(commandArguments)
        case "open": return try await open(commandArguments)
        default: throw CLIError.usage("unknown command \(command)")
        }
    }

    private static func initializeProject(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        var directory = FileManager.default.currentDirectoryPath
        var name: String?
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--project-name": name = try parser.requireValue(after: value)
            case "--directory", "--dir": directory = try parser.requireValue(after: value)
            case "--json": json = true
            default:
                if !value.hasPrefix("-") && directory == FileManager.default.currentDirectoryPath { directory = value }
                else { throw CLIError.usage("unknown init argument \(value)") }
            }
        }
        let project = try await LauncherAPIClient.default.initializeProject(directory: directory, displayName: name)
        if json { try printJSON(project) }
        else {
            print("Initialized \(project.displayName)")
            print("Directory: \(project.directory)")
            print("Manifest: \(project.directory)/launch_details.md")
        }
        return 0
    }

    private static func updateProject(_ arguments: [String]) async throws -> Int32 {
        guard arguments.first == "update" else {
            throw CLIError.usage("project requires update")
        }
        var parser = Parser(Array(arguments.dropFirst()))
        var directory = FileManager.default.currentDirectoryPath
        var displayName: String?
        var expectedRevision: Int?
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--directory", "--dir": directory = try parser.requireValue(after: value)
            case "--name": displayName = try parser.requireValue(after: value)
            case "--if-revision":
                guard let value = Int(try parser.requireValue(after: value)) else {
                    throw CLIError.usage("invalid revision")
                }
                expectedRevision = value
            case "--json": json = true
            default: throw CLIError.usage("unknown project update argument \(value)")
            }
        }
        guard let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("project update requires --name")
        }
        let client = LauncherAPIClient.default
        let current = try await client.resolveProject(directory: directory)
        let updated = try await client.updateProject(
            id: current.id,
            patch: ProjectPatchRequest(
                expectedRevision: expectedRevision ?? current.revision,
                displayName: displayName
            )
        )
        if json { try printJSON(updated) }
        else { print("Updated project \(updated.displayName)") }
        return 0
    }

    private static func createLauncher(_ arguments: [String]) async throws -> Int32 {
        let split = splitAtDoubleDash(arguments)
        var parser = Parser(split.before)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("create requires NAME") }
        guard let description = parser.pop(), !description.hasPrefix("-") else { throw CLIError.usage("create requires DESCRIPTION") }
        var directory = FileManager.default.currentDirectoryPath
        // The optional third positional is descriptive launch/run context, exactly as
        // `launch --create NAME DESCRIPTION [RUN_DETAILS]` advertises. Executable content
        // must be explicit via --command or the literal argument boundary (`-- ...`).
        var runDetails: String?
        if let peek = parser.peek(), !peek.hasPrefix("-") { runDetails = parser.pop() }
        var tags: [String] = []
        var action = LaunchAction()
        var json = false
        try parseActionOptions(parser: &parser, directory: &directory, runDetails: &runDetails, tags: &tags, action: &action, json: &json)

        if !split.after.isEmpty {
            action.runner = action.runner == .shell ? .process : action.runner
            action.executable = split.after[0]
            action.arguments = Array(split.after.dropFirst())
            action.shellCommand = nil
        } else if action.runner == .shell, action.shellCommand == nil {
            throw CLIError.usage("create requires a command: use --command COMMAND or -- EXECUTABLE ARG...")
        }

        let (_, normalizedAction) = try LauncherValidation.validatedName(action.name, allowReserved: true)
        action.normalizedName = normalizedAction
        let project = try await LauncherAPIClient.default.resolveProject(directory: directory)
        let request = LauncherCreateRequest(projectID: project.id, name: name, description: description, runDetails: runDetails, tags: tags, primaryAction: action)
        let detail = try await LauncherAPIClient.default.createLauncher(request)
        if json { try printJSON(detail) }
        else {
            print("Created \(detail.launcher.name)")
            print("Project: \(detail.project.displayName)")
            print("Command: \(detail.launcher.sortedActions.first?.displayCommand ?? "—")")
            print("Run: launch \(ShellEscaping.quote(detail.launcher.name))")
        }
        return 0
    }

    private static func parseActionOptions(
        parser: inout Parser,
        directory: inout String,
        runDetails: inout String?,
        tags: inout [String],
        action: inout LaunchAction,
        json: inout Bool,
        allowProjectOptions: Bool = true
    ) throws {
        while let value = parser.pop() {
            switch value {
            case "--directory", "--dir":
                guard allowProjectOptions else { throw CLIError.usage("\(value) is only valid when creating a launcher") }
                directory = try parser.requireValue(after: value)
            case "--run-details":
                guard allowProjectOptions else { throw CLIError.usage("--run-details is only valid when creating or updating a launcher") }
                guard runDetails == nil else { throw CLIError.usage("run details were supplied more than once") }
                runDetails = try parser.requireValue(after: value)
            case "--tag":
                guard allowProjectOptions else { throw CLIError.usage("--tag is only valid when creating or updating a launcher") }
                tags.append(try parser.requireValue(after: value))
            case "--tags":
                guard allowProjectOptions else { throw CLIError.usage("--tags is only valid when creating or updating a launcher") }
                tags.append(contentsOf: try parser.requireValue(after: value).split(separator: ",").map(String.init))
            case "--action-name": action.name = try parser.requireValue(after: value)
            case "--action-description": action.description = try parser.requireValue(after: value)
            case "--cwd": action.workingDirectory = try parser.requireValue(after: value)
            case "--order":
                guard let order = Int(try parser.requireValue(after: value)) else { throw CLIError.usage("invalid action order") }
                action.order = order
            case "--type":
                guard let runner = ActionRunner(rawValue: try parser.requireValue(after: value)) else { throw CLIError.usage("invalid action type") }
                action.runner = runner
                if runner == .shell {
                    action.executable = nil
                } else {
                    action.shellCommand = nil
                }
                if runner == .url {
                    action.arguments = []
                    action.allowsRuntimeArguments = false
                }
            case "--command":
                action.shellCommand = try parser.requireValue(after: value)
                action.executable = nil
                action.runner = .shell
            case "--executable": action.executable = try parser.requireValue(after: value)
            case "--arg": action.arguments.append(try parser.requireValue(after: value))
            case "--app-bundle-id": action.appBundleIdentifier = try parser.requireValue(after: value)
            case "--port":
                let mode = try parser.requireValue(after: value)
                if mode == "none" { action.port.mode = .none }
                else if mode == "auto" || mode == "automatic" { action.port.mode = .automatic }
                else if let fixed = Int(mode) { action.port.mode = .fixed; action.port.fixedPort = fixed }
                else { throw CLIError.usage("--port must be none, auto, or a number") }
            case "--port-name": action.port.logicalName = try parser.requireValue(after: value)
            case "--port-env": action.port.environmentVariable = try parser.requireValue(after: value)
            case "--host-env": action.port.hostEnvironmentVariable = try parser.requireValue(after: value)
            case "--url": action.port.URLTemplate = try parser.requireValue(after: value)
            case "--lease": action.port.lease = try parser.requireValue(after: value)
            case "--health": action.healthCheckURL = try parser.requireValue(after: value)
            case "--open":
                guard let open = OpenTarget(rawValue: try parser.requireValue(after: value)) else { throw CLIError.usage("--open must be none, browser, application, or simulator") }
                action.openTarget = open
            case "--env":
                let pair = try parser.requireValue(after: value)
                guard let equals = pair.firstIndex(of: "=") else { throw CLIError.usage("--env requires KEY=VALUE") }
                action.environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            case "--inherit-env": action.inheritedEnvironment.append(try parser.requireValue(after: value))
            case "--ready-timeout":
                guard let timeout = Int(try parser.requireValue(after: value)) else { throw CLIError.usage("invalid ready timeout") }
                action.readyTimeoutSeconds = timeout
            case "--stop-timeout":
                guard let timeout = Int(try parser.requireValue(after: value)) else { throw CLIError.usage("invalid stop timeout") }
                action.stopTimeoutSeconds = timeout
            case "--optional": action.required = false
            case "--required": action.required = true
            case "--deny-runtime-args": action.allowsRuntimeArguments = false
            case "--allow-runtime-args": action.allowsRuntimeArguments = true
            case "--json": json = true
            default: throw CLIError.usage("unknown create/action argument \(value)")
            }
        }
    }

    /// Applies the complete mutable action surface used by both `launch update`
    /// (for the primary action) and `launch action update`.
    private static func mutateAction(option: String, parser: inout Parser, action: inout LaunchAction) throws -> Bool {
        switch option {
        case "--action-name":
            action.name = try parser.requireValue(after: option)
            action.normalizedName = LauncherValidation.normalizeName(action.name)
        case "--action-description": action.description = try parser.requireValue(after: option)
        case "--cwd": action.workingDirectory = try parser.requireValue(after: option)
        case "--order":
            guard let order = Int(try parser.requireValue(after: option)) else { throw CLIError.usage("invalid action order") }
            action.order = order
        case "--type":
            guard let runner = ActionRunner(rawValue: try parser.requireValue(after: option)) else { throw CLIError.usage("invalid action type") }
            action.runner = runner
            if runner == .shell {
                action.executable = nil
            } else {
                action.shellCommand = nil
            }
            if runner == .url {
                action.arguments = []
                action.allowsRuntimeArguments = false
            }
        case "--command":
            if action.runner != .shell { action.arguments = [] }
            action.runner = .shell
            action.shellCommand = try parser.requireValue(after: option)
            action.executable = nil
        case "--clear-command": action.shellCommand = nil
        case "--executable": action.executable = try parser.requireValue(after: option)
        case "--clear-executable": action.executable = nil
        case "--append-arg", "--arg": action.arguments.append(try parser.requireValue(after: option))
        case "--clear-args": action.arguments = []
        case "--remove-arg":
            let value = try parser.requireValue(after: option)
            action.arguments.removeAll { $0 == value }
        case "--set-arg":
            guard let index = Int(try parser.requireValue(after: option)), action.arguments.indices.contains(index) else {
                throw CLIError.usage("--set-arg requires an existing zero-based index")
            }
            action.arguments[index] = try parser.requireValue(after: option)
        case "--args-json":
            let text = try parser.requireValue(after: option)
            guard let data = text.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else {
                throw CLIError.usage("--args-json requires a JSON array of strings")
            }
            action.arguments = values
        case "--env":
            let pair = try parser.requireValue(after: option)
            guard let equals = pair.firstIndex(of: "=") else { throw CLIError.usage("--env requires KEY=VALUE") }
            action.environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        case "--remove-env": action.environment.removeValue(forKey: try parser.requireValue(after: option))
        case "--clear-env": action.environment = [:]
        case "--inherit-env":
            let name = try parser.requireValue(after: option)
            if !action.inheritedEnvironment.contains(name) { action.inheritedEnvironment.append(name) }
        case "--remove-inherit-env":
            let name = try parser.requireValue(after: option)
            action.inheritedEnvironment.removeAll { $0 == name }
        case "--clear-inherit-env": action.inheritedEnvironment = []
        case "--port":
            let mode = try parser.requireValue(after: option)
            if mode == "none" {
                action.port.mode = .none
                action.port.fixedPort = nil
            } else if mode == "auto" || mode == "automatic" {
                action.port.mode = .automatic
                action.port.fixedPort = nil
            } else if let fixed = Int(mode) {
                action.port.mode = .fixed
                action.port.fixedPort = fixed
            } else {
                throw CLIError.usage("--port must be none, auto, or a number")
            }
        case "--port-name": action.port.logicalName = try parser.requireValue(after: option)
        case "--port-env": action.port.environmentVariable = try parser.requireValue(after: option)
        case "--host-env": action.port.hostEnvironmentVariable = try parser.requireValue(after: option)
        case "--url": action.port.URLTemplate = try parser.requireValue(after: option)
        case "--clear-url": action.port.URLTemplate = nil
        case "--lease": action.port.lease = try parser.requireValue(after: option)
        case "--health": action.healthCheckURL = try parser.requireValue(after: option)
        case "--clear-health": action.healthCheckURL = nil
        case "--open":
            guard let target = OpenTarget(rawValue: try parser.requireValue(after: option)) else {
                throw CLIError.usage("--open must be none, browser, application, or simulator")
            }
            action.openTarget = target
        case "--app-bundle-id": action.appBundleIdentifier = try parser.requireValue(after: option)
        case "--clear-app-bundle-id": action.appBundleIdentifier = nil
        case "--ready-timeout":
            guard let timeout = Int(try parser.requireValue(after: option)) else { throw CLIError.usage("invalid ready timeout") }
            action.readyTimeoutSeconds = timeout
        case "--stop-timeout":
            guard let timeout = Int(try parser.requireValue(after: option)) else { throw CLIError.usage("invalid stop timeout") }
            action.stopTimeoutSeconds = timeout
        case "--optional": action.required = false
        case "--required": action.required = true
        case "--deny-runtime-args": action.allowsRuntimeArguments = false
        case "--allow-runtime-args": action.allowsRuntimeArguments = true
        default: return false
        }
        return true
    }

    private static func launch(_ arguments: [String]) async throws -> Int32 {
        let split = splitAtDoubleDash(arguments)
        var parser = Parser(split.before)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("run requires a launcher name") }
        var json = false
        var open = false
        var newInstance = false
        while let value = parser.pop() {
            switch value {
            case "--json": json = true
            case "--open": open = true
            case "--new": newInstance = true
            default: throw CLIError.usage("unknown run argument \(value)")
            }
        }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        if !newInstance, let existing = detail.primaryActiveSession {
            if json { try printJSON(existing) }
            else { printSession(existing) }
            return 0
        }
        let session = try await LauncherAPIClient.default.startLauncher(
            id: detail.launcher.id,
            runtimeArguments: split.after,
            openRequested: open,
            expectedLauncherRevision: detail.launcher.revision,
            mode: newInstance ? .newInstance : .reusePrimary
        )
        if json { try printJSON(session) }
        else { printSession(session) }
        return 0
    }

    private static func relaunch(_ arguments: [String]) async throws -> Int32 {
        let split = splitAtDoubleDash(arguments)
        var parser = Parser(split.before)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("relaunch requires a launcher name") }
        var json = false
        var open = false
        var exactSessionID: UUID?
        while let value = parser.pop() {
            switch value {
            case "--json": json = true
            case "--open": open = true
            case "--session":
                guard exactSessionID == nil,
                      let rawID = parser.pop(),
                      let parsedID = UUID(uuidString: rawID) else {
                    throw CLIError.usage("--session requires one valid session UUID")
                }
                exactSessionID = parsedID
            default: throw CLIError.usage("unknown relaunch argument \(value)")
            }
        }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        let result: SessionRelaunchResult
        if let exactSessionID {
            let session = try await LauncherAPIClient.default.sessionRecord(id: exactSessionID)
            guard session.launcherID == detail.launcher.id else {
                throw CLIError.conflict("session \(exactSessionID.uuidString) does not belong to \(name)")
            }
            guard session.isActive else {
                throw CLIError.conflict("session \(exactSessionID.uuidString) is no longer active")
            }
            result = try await LauncherAPIClient.default.relaunchSession(
                id: exactSessionID,
                runtimeArguments: split.after,
                openRequested: open,
                expectedLauncherRevision: detail.launcher.revision
            )
        } else {
            let primary = detail.primaryActiveSession
            result = try await LauncherAPIClient.default.relaunchLauncher(
                id: detail.launcher.id,
                runtimeArguments: split.after,
                openRequested: open,
                expectedSessionID: primary?.id,
                requireIdle: primary == nil,
                expectedLauncherRevision: detail.launcher.revision
            )
        }
        if json {
            try printJSON(result)
        } else {
            if let previous = result.previousSession {
                print("Closed exact session \(previous.id.uuidString).")
            } else {
                print("No active session needed closing.")
            }
            printSession(result.session)
        }
        return 0
    }

    private static func list(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        var query: String?
        var json = false
        var tag: String?
        var state: SessionState?
        var directory: String?
        while let value = parser.pop() {
            switch value {
            case "--json": json = true
            case "--tag": tag = try parser.requireValue(after: value)
            case "--state":
                let requested = try parser.requireValue(after: value)
                guard let parsed = SessionState(rawValue: requested) else {
                    throw CLIError.usage("invalid session state \(requested)")
                }
                state = parsed
            case "--directory", "--dir": directory = try parser.requireValue(after: value)
            default:
                if !value.hasPrefix("-") && query == nil { query = value }
                else { throw CLIError.usage("unknown list argument \(value)") }
            }
        }
        var values = try await LauncherAPIClient.default.listLaunchers(query: query)
        if let directory {
            let project = try await LauncherAPIClient.default.resolveProject(directory: directory)
            values = values.filter { $0.project.id == project.id }
        }
        if let tag { values = values.filter { $0.launcher.tags.contains(where: { LauncherValidation.normalizeName($0) == LauncherValidation.normalizeName(tag) }) } }
        if let state {
            values = values.filter {
                $0.activeSessions.contains(where: { $0.state == state }) || $0.lastSession?.state == state
            }
        }
        if json { try printJSON(values) }
        else if values.isEmpty { print("No launchers found.") }
        else {
            for value in values {
                let state: String
                if value.activeSessions.isEmpty {
                    state = "idle"
                } else if value.activeSessions.count == 1 {
                    state = value.activeSessions[0].state.rawValue
                } else {
                    let primaryState = value.primaryActiveSession?.state.rawValue
                        ?? value.activeSessions[0].state.rawValue
                    state = "\(primaryState)+\(value.activeSessions.count - 1)"
                }
                let tags = value.launcher.tags.isEmpty ? "" : "  [\(value.launcher.tags.joined(separator: ", "))]"
                print("\(state.padding(toLength: 9, withPad: " ", startingAt: 0)) \(value.launcher.name)\(tags)")
                print("           \(value.launcher.description)")
            }
        }
        return 0
    }

    private static func details(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("details requires a launcher name") }
        var json = false
        while let value = parser.pop() {
            if value == "--json" { json = true } else { throw CLIError.usage("unknown details argument \(value)") }
        }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        if json { try printJSON(detail) } else { printDetail(detail) }
        return 0
    }

    private static func update(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("update requires a launcher name") }
        let current = try await LauncherAPIClient.default.launcher(named: name)
        var expected = current.launcher.revision
        var newName: String?
        var description: String?
        var runDetails: String?
        var clearRunDetails = false
        var replaceTags: [String]?
        var addTags: [String] = []
        var removeTags: [String] = []
        var primary = current.launcher.actions.first(where: { $0.id == current.launcher.primaryActionID })
        var requestedPrimaryActionID: UUID?
        var changedPrimary = false
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--name": newName = try parser.requireValue(after: value)
            case "--description": description = try parser.requireValue(after: value)
            case "--run-details": runDetails = try parser.requireValue(after: value)
            case "--clear-run-details": clearRunDetails = true
            case "--tags": replaceTags = try parser.requireValue(after: value).split(separator: ",").map(String.init)
            case "--clear-tags": replaceTags = []
            case "--add-tag": addTags.append(try parser.requireValue(after: value))
            case "--remove-tag": removeTags.append(try parser.requireValue(after: value))
            case "--primary-action":
                guard !changedPrimary else {
                    throw CLIError.usage("--primary-action must appear before action mutation options")
                }
                let requestedName = try parser.requireValue(after: value)
                let normalized = LauncherValidation.normalizeName(requestedName)
                guard let selected = current.launcher.actions.first(where: {
                    LauncherValidation.normalizeName($0.name) == normalized
                }) else {
                    throw CLIError.notFound("action \(requestedName) was not found")
                }
                primary = selected
                requestedPrimaryActionID = selected.id
            case "--if-revision":
                guard let value = Int(try parser.requireValue(after: value)) else { throw CLIError.usage("invalid revision") }
                expected = value
            case "--json": json = true
            default:
                guard var action = primary, try mutateAction(option: value, parser: &parser, action: &action) else {
                    throw CLIError.usage("unknown update argument \(value)")
                }
                primary = action
                changedPrimary = true
            }
        }
        let patch = LauncherPatchRequest(
            expectedRevision: expected,
            name: newName,
            description: description,
            runDetails: runDetails,
            clearRunDetails: clearRunDetails,
            replaceTags: replaceTags,
            addTags: addTags,
            removeTags: removeTags,
            primaryAction: changedPrimary ? primary : nil,
            primaryActionID: requestedPrimaryActionID
        )
        let updated = try await LauncherAPIClient.default.updateLauncher(id: current.launcher.id, patch: patch)
        if json { try printJSON(updated) } else { printDetail(updated) }
        return 0
    }

    private static func action(_ arguments: [String]) async throws -> Int32 {
        guard let verb = arguments.first else { throw CLIError.usage("action requires add, update, or delete") }
        switch verb {
        case "add": return try await addAction(Array(arguments.dropFirst()))
        case "update": return try await updateAction(Array(arguments.dropFirst()))
        case "delete": return try await deleteAction(Array(arguments.dropFirst()))
        default: throw CLIError.usage("unknown action command \(verb)")
        }
    }

    private static func addAction(_ arguments: [String]) async throws -> Int32 {
        let split = splitAtDoubleDash(arguments)
        var parser = Parser(split.before)
        guard let launcherName = parser.pop(), let actionName = parser.pop(), let actionDescription = parser.pop() else {
            throw CLIError.usage("action add requires LAUNCHER ACTION DESCRIPTION")
        }
        let detail = try await LauncherAPIClient.default.launcher(named: launcherName)
        var directory = detail.project.directory
        var ignoredRunDetails: String?
        var ignoredTags: [String] = []
        var json = false
        let nextOrder = (detail.launcher.actions.map(\.order).max() ?? -1) + 1
        var newAction = LaunchAction(name: actionName, normalizedName: LauncherValidation.normalizeName(actionName), description: actionDescription, order: nextOrder)
        try parseActionOptions(
            parser: &parser,
            directory: &directory,
            runDetails: &ignoredRunDetails,
            tags: &ignoredTags,
            action: &newAction,
            json: &json,
            allowProjectOptions: false
        )
        if !split.after.isEmpty {
            if newAction.runner == .shell { newAction.runner = .process }
            newAction.executable = split.after[0]
            newAction.arguments = Array(split.after.dropFirst())
            newAction.shellCommand = nil
        }
        if newAction.runner == .shell, newAction.shellCommand == nil {
            throw CLIError.usage("action add requires a command: use --command COMMAND or -- EXECUTABLE ARG...")
        }
        let request = ActionCreateRequest(expectedRevision: detail.launcher.revision, action: newAction)
        let updated = try await LauncherAPIClient.default.addAction(launcherID: detail.launcher.id, requestBody: request)
        if json { try printJSON(updated) } else { printDetail(updated) }
        return 0
    }

    private static func updateAction(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let launcherName = parser.pop(), let actionName = parser.pop() else { throw CLIError.usage("action update requires LAUNCHER ACTION") }
        let detail = try await LauncherAPIClient.default.launcher(named: launcherName)
        guard var existing = detail.launcher.actions.first(where: { LauncherValidation.normalizeName($0.name) == LauncherValidation.normalizeName(actionName) }) else {
            throw CLIError.notFound("action \(actionName) was not found")
        }
        var expected = detail.launcher.revision
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--name": existing.name = try parser.requireValue(after: value); existing.normalizedName = LauncherValidation.normalizeName(existing.name)
            case "--description": existing.description = try parser.requireValue(after: value)
            case "--if-revision":
                guard let revision = Int(try parser.requireValue(after: value)) else {
                    throw CLIError.usage("invalid revision")
                }
                expected = revision
            case "--json": json = true
            default:
                guard try mutateAction(option: value, parser: &parser, action: &existing) else {
                    throw CLIError.usage("unknown action update argument \(value)")
                }
            }
        }
        let updated = try await LauncherAPIClient.default.updateAction(launcherID: detail.launcher.id, actionID: existing.id, requestBody: ActionPatchRequest(expectedRevision: expected, action: existing))
        if json { try printJSON(updated) } else { printDetail(updated) }
        return 0
    }

    private static func deleteAction(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let launcherName = parser.pop(), let actionName = parser.pop() else { throw CLIError.usage("action delete requires LAUNCHER ACTION") }
        let detail = try await LauncherAPIClient.default.launcher(named: launcherName)
        guard let action = detail.launcher.actions.first(where: { LauncherValidation.normalizeName($0.name) == LauncherValidation.normalizeName(actionName) }) else {
            throw CLIError.notFound("action \(actionName) was not found")
        }
        var yes = false
        var explicitRevision: Int?
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--yes": yes = true
            case "--if-revision":
                guard let revision = Int(try parser.requireValue(after: value)) else {
                    throw CLIError.usage("invalid revision")
                }
                explicitRevision = revision
            case "--json": json = true
            default: throw CLIError.usage("unknown action delete argument \(value)")
            }
        }
        if yes, explicitRevision == nil {
            throw CLIError.confirmation("--yes requires --if-revision \(detail.launcher.revision)")
        }
        if !yes {
            guard isatty(STDIN_FILENO) == 1 else { throw CLIError.confirmation("non-interactive action deletion requires --yes --if-revision") }
            print("Delete action \(action.name) from \(detail.launcher.name)?")
            print("Command: \(action.displayCommand)")
            print("Type the exact action name to confirm:", terminator: " ")
            guard readLine() == action.name else { throw CLIError.confirmation("cancelled") }
            explicitRevision = detail.launcher.revision
        }
        let updated = try await LauncherAPIClient.default.deleteAction(
            launcherID: detail.launcher.id,
            actionID: action.id,
            expectedRevision: explicitRevision!
        )
        if json { try printJSON(updated) } else { printDetail(updated) }
        return 0
    }

    private static func delete(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("delete requires a launcher name") }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        var yes = false
        var explicitRevision: Int?
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--yes": yes = true
            case "--if-revision":
                guard let revision = Int(try parser.requireValue(after: value)) else {
                    throw CLIError.usage("invalid revision")
                }
                explicitRevision = revision
            case "--json": json = true
            default: throw CLIError.usage("unknown delete argument \(value)")
            }
        }
        if yes && explicitRevision == nil { throw CLIError.confirmation("--yes requires --if-revision \(detail.launcher.revision)") }
        let intent = try await LauncherAPIClient.default.deleteIntent(launcherID: detail.launcher.id)
        if !yes {
            guard isatty(STDIN_FILENO) == 1 else { throw CLIError.confirmation("non-interactive deletion requires --yes --if-revision \(detail.launcher.revision)") }
            printDeleteIntent(intent)
            guard readLine() == intent.launcher.launcher.name else { throw CLIError.confirmation("cancelled") }
            explicitRevision = intent.launcher.launcher.revision
        }
        let response = try await LauncherAPIClient.default.deleteLauncher(id: detail.launcher.id, requestBody: DeleteRequest(expectedRevision: explicitRevision!, intentToken: intent.token))
        if json {
            try printJSON(response)
        } else {
            print("Deleted launch shortcut \(detail.launcher.name). Source files were not deleted; launch_details.md was regenerated or marked for repair if its directory was unavailable.")
        }
        return 0
    }

    private static func status(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        var name: String?
        var json = false
        while let value = parser.pop() {
            if value == "--json" { json = true }
            else if !value.hasPrefix("-") && name == nil { name = value }
            else { throw CLIError.usage("unknown status argument \(value)") }
        }
        if let name {
            let detail = try await LauncherAPIClient.default.launcher(named: name)
            if json { try printJSON(detail) } else { printDetail(detail) }
        } else {
            let sessions = try await LauncherAPIClient.default.sessions(activeOnly: true)
            if json { try printJSON(sessions) }
            else if sessions.isEmpty { print("No active sessions.") }
            else { sessions.forEach(printSession) }
        }
        return 0
    }

    private static func close(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("close requires a launcher name") }
        var json = false
        var exactSessionID: UUID?
        while let value = parser.pop() {
            if value == "--json" {
                json = true
            } else if value == "--session" {
                guard exactSessionID == nil,
                      let rawID = parser.pop(),
                      let parsedID = UUID(uuidString: rawID) else {
                    throw CLIError.usage("--session requires one valid session UUID")
                }
                exactSessionID = parsedID
            } else {
                throw CLIError.usage("unknown close argument \(value)")
            }
        }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        let session: SessionRecord
        if let exactSessionID {
            let exact = try await LauncherAPIClient.default.sessionRecord(id: exactSessionID)
            guard exact.launcherID == detail.launcher.id else {
                throw CLIError.conflict("session \(exactSessionID.uuidString) does not belong to \(name)")
            }
            guard exact.isActive else {
                throw CLIError.conflict("session \(exactSessionID.uuidString) is no longer active")
            }
            session = exact
        } else {
            guard let primary = detail.primaryActiveSession else {
                let suffix = detail.activeSessions.isEmpty
                    ? ""
                    : "; use --session UUID to close an additional instance"
                throw CLIError.conflict("\(name) has no active primary session\(suffix)")
            }
            session = primary
        }
        let stopped = try await LauncherAPIClient.default.stopSession(id: session.id)
        if json { try printJSON(stopped) } else { printSession(stopped) }
        return 0
    }

    private static func external(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        let subcommand = parser.pop() ?? "list"
        var json = false

        switch subcommand {
        case "list":
            var fresh = false
            while let value = parser.pop() {
                switch value {
                case "--refresh": fresh = true
                case "--json": json = true
                default: throw CLIError.usage("unknown external list argument \(value)")
                }
            }
            let snapshot = try await LauncherAPIClient.default.externalProcessSnapshot(fresh: fresh)
            if json {
                try printJSON(snapshot)
            } else if snapshot.observations.isEmpty {
                print(snapshot.isStale ? "No current external-process inventory is available." : "No listening external processes were observed.")
            } else {
                print("External listeners observed at \(format(snapshot.scannedAt))\(snapshot.isStale ? " (stale)" : ""):")
                for observation in snapshot.observations {
                    print("\(observation.id.uuidString) · PID \(observation.pid) · \(observation.endpoints.map(\.displayValue).joined(separator: ", "))")
                    print("  \(observation.ownership.kind.rawValue): \(observation.command.displayCommand)")
                    if !observation.canClose, let reason = observation.closeDisabledReason {
                        print("  Close unavailable: \(reason)")
                    }
                }
            }
            if let warning = snapshot.warning { print("Warning: \(warning)") }
            return 0

        case "draft":
            guard let rawID = parser.pop(), let observationID = UUID(uuidString: rawID) else {
                throw CLIError.usage("external draft requires one external observation UUID")
            }
            while let value = parser.pop() {
                if value == "--json" { json = true }
                else { throw CLIError.usage("unknown external draft argument \(value)") }
            }
            _ = try await LauncherAPIClient.default.externalProcessSnapshot(fresh: true)
            let draft = try await LauncherAPIClient.default.externalLauncherDraft(observationID: observationID)
            if json {
                try printJSON(draft)
            } else {
                print("Draft proposal for \(draft.sourceObservationID.uuidString)")
                print("Name: \(draft.name)")
                print("Directory: \(draft.projectDirectory.isEmpty ? "(choose before saving)" : draft.projectDirectory)")
                print("Command: \(draft.displayCommand)")
                print("Blockers: \(draft.blockers.isEmpty ? "none" : draft.blockers.map(\.rawValue).joined(separator: ", "))")
            }
            return 0

        case "close":
            guard let rawID = parser.pop(), let observationID = UUID(uuidString: rawID) else {
                throw CLIError.usage("external close requires one external observation UUID")
            }
            while let value = parser.pop() {
                if value == "--json" {
                    throw CLIError.usage("external close is intentionally interactive and does not support --json")
                }
                throw CLIError.usage("unknown external close argument \(value)")
            }
            guard isatty(STDIN_FILENO) == 1 else {
                throw CLIError.confirmation("external close requires an interactive terminal so the exact confirmation can be typed")
            }
            let intent = try await LauncherAPIClient.default.makeExternalCloseIntent(observationID: observationID)
            printExternalCloseIntent(intent)
            guard readLine() == intent.confirmationText else {
                throw CLIError.confirmation("cancelled; no external process was signalled")
            }
            let result = try await LauncherAPIClient.default.closeExternalProcess(
                ExternalCloseRequest(
                    observationID: intent.observationID,
                    intentToken: intent.token,
                    confirmationText: intent.confirmationText
                )
            )
            print(result.message)
            return 0

        default:
            throw CLIError.usage("external requires list, draft, or close")
        }
    }

    private static func open(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let name = parser.pop(), !name.hasPrefix("-") else {
            throw CLIError.usage("open requires a launcher name")
        }
        var exactSessionID: UUID?
        var optionID: String?
        var probe = false
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--session":
                guard exactSessionID == nil,
                      let rawID = parser.pop(),
                      let parsedID = UUID(uuidString: rawID) else {
                    throw CLIError.usage("--session requires one valid session UUID")
                }
                exactSessionID = parsedID
            case "--option":
                guard optionID == nil else { throw CLIError.usage("--option may be supplied once") }
                optionID = try parser.requireValue(after: value)
            case "--probe": probe = true
            case "--json": json = true
            default: throw CLIError.usage("unknown open argument \(value)")
            }
        }
        guard !probe || optionID != nil else {
            throw CLIError.usage("--probe requires one server-derived --option ID")
        }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        let session: SessionRecord
        if let exactSessionID {
            let exact = try await LauncherAPIClient.default.sessionRecord(id: exactSessionID)
            guard exact.launcherID == detail.launcher.id else {
                throw CLIError.conflict("session \(exactSessionID.uuidString) does not belong to \(name)")
            }
            session = exact
        } else {
            guard let primary = detail.primaryActiveSession else {
                throw CLIError.conflict("\(name) has no active primary session; use --session UUID for an additional instance")
            }
            session = primary
        }

        guard let optionID else {
            let options = try await LauncherAPIClient.default.sessionOpenOptions(sessionID: session.id)
            if json { try printJSON(options) }
            else if options.isEmpty { print("No open/focus options are currently available for this exact session.") }
            else {
                for option in options {
                    print("\(option.id) · \(option.label)\(option.detail.map { " — \($0)" } ?? "")")
                }
            }
            return 0
        }

        if probe {
            let result = try await LauncherAPIClient.default.probeSessionOpenOption(sessionID: session.id, optionID: optionID)
            if json { try printJSON(result) }
            else { print(result.message) }
        } else {
            let result = try await LauncherAPIClient.default.openSessionOption(sessionID: session.id, optionID: optionID)
            if json { try printJSON(result) }
            else { print(result.message) }
        }
        return 0
    }

    private static func history(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        var launcherName: String?
        var state: SessionState?
        var role: SessionLaunchRole?
        var limit = 50
        var cursor: String?
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--json": json = true
            case "--state":
                let raw = try parser.requireValue(after: value)
                guard let parsed = SessionState(rawValue: raw) else {
                    throw CLIError.usage("invalid session history state \(raw)")
                }
                state = parsed
            case "--role":
                let raw = try parser.requireValue(after: value)
                guard let parsed = SessionLaunchRole(rawValue: raw) else {
                    throw CLIError.usage("history role must be primary or additional")
                }
                role = parsed
            case "--limit":
                let raw = try parser.requireValue(after: value)
                guard let parsed = Int(raw), (1...200).contains(parsed) else {
                    throw CLIError.usage("history limit must be between 1 and 200")
                }
                limit = parsed
            case "--cursor": cursor = try parser.requireValue(after: value)
            default:
                if !value.hasPrefix("-"), launcherName == nil { launcherName = value }
                else { throw CLIError.usage("unknown history argument \(value)") }
            }
        }
        let launcherID: UUID?
        if let launcherName {
            let detail = try await LauncherAPIClient.default.launcher(named: launcherName)
            launcherID = detail.launcher.id
        } else {
            launcherID = nil
        }
        let page = try await LauncherAPIClient.default.sessionHistory(
            launcherID: launcherID,
            state: state,
            role: role,
            limit: limit,
            cursor: cursor
        )
        if json {
            try printJSON(page)
        } else if page.sessions.isEmpty {
            print("No launch history matched.")
        } else {
            page.sessions.forEach(printSession)
            if let nextCursor = page.nextCursor {
                print("Next cursor: \(nextCursor)")
            }
        }
        return 0
    }

    private static func skill(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        let subcommand = parser.pop() ?? "status"
        var json = false

        switch subcommand {
        case "status":
            while let value = parser.pop() {
                if value == "--json" { json = true }
                else { throw CLIError.usage("unknown skill status argument \(value)") }
            }
            let status = try await LauncherAPIClient.default.launcherSkillStatus()
            if json { try printJSON(status) }
            else {
                print("\(status.skillName) skill \(status.version)")
                for host in status.hosts {
                    print("\(host.host.displayName): \(host.state.rawValue) — \(host.message)")
                    for surface in host.surfaces {
                        let state = surface.available ? "available" : "unavailable"
                        print("  \(surface.surface.displayName): \(state) — \(surface.message)")
                    }
                }
            }
            return 0

        case "install":
            guard let rawHost = parser.pop(), let host = LauncherSkillHost(rawValue: rawHost) else {
                throw CLIError.usage("skill install requires codex or claude-code")
            }
            while let value = parser.pop() {
                if value == "--json" { json = true }
                else { throw CLIError.usage("unknown skill install argument \(value)") }
            }
            let result = try await LauncherAPIClient.default.installLauncherSkill(for: host)
            if json { try printJSON(result) }
            else { print(result.message) }
            return 0

        case "source":
            while let value = parser.pop() {
                if value == "--json" { json = true }
                else { throw CLIError.usage("unknown skill source argument \(value)") }
            }
            let source = try await LauncherAPIClient.default.launcherSkillSource()
            if json { try printJSON(source) }
            else { print(source.contents, terminator: source.contents.hasSuffix("\n") ? "" : "\n") }
            return 0

        case "uninstall":
            guard let rawHost = parser.pop(), let host = LauncherSkillHost(rawValue: rawHost) else {
                throw CLIError.usage("skill uninstall requires codex or claude-code")
            }
            while let value = parser.pop() {
                if value == "--json" {
                    throw CLIError.usage("skill uninstall is intentionally interactive and does not support --json")
                } else {
                    throw CLIError.usage("unknown skill uninstall argument \(value)")
                }
            }
            guard isatty(STDIN_FILENO) == 1 else {
                throw CLIError.confirmation("skill uninstall requires an interactive terminal so the exact confirmation can be typed")
            }
            let intent = try await LauncherAPIClient.default.prepareLauncherSkillUninstall(for: host)
            printSkillUninstallIntent(intent)
            guard readLine() == intent.confirmationText else {
                throw CLIError.confirmation("cancelled; no skill files were removed")
            }
            let response = try await LauncherAPIClient.default.uninstallLauncherSkill(
                intent: intent,
                confirmationText: intent.confirmationText
            )
            print(response.result.message)
            return 0

        default:
            throw CLIError.usage("skill requires status, install, uninstall, or source")
        }
    }

    private static func maintenance(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let subcommand = parser.pop() else {
            throw CLIError.usage("maintenance requires prepare-upgrade or cancel-upgrade")
        }
        var json = false

        switch subcommand {
        case "prepare-upgrade":
            while let value = parser.pop() {
                if value == "--json" { json = true }
                else { throw CLIError.usage("unknown maintenance prepare-upgrade argument \(value)") }
            }
            let reservation = try await LauncherAPIClient.default.prepareUpgrade()
            if json {
                try printJSON(reservation)
            } else {
                print("Launcher is idle and reserved for app upgrade until \(format(reservation.expiresAt)).")
                print("Use --json to receive the cancellation reservation for installer automation.")
            }
            return 0

        case "cancel-upgrade":
            guard let reservationToken = parser.pop(), !reservationToken.hasPrefix("-") else {
                throw CLIError.usage("maintenance cancel-upgrade requires the exact reservation token")
            }
            while let value = parser.pop() {
                if value == "--json" { json = true }
                else { throw CLIError.usage("unknown maintenance cancel-upgrade argument \(value)") }
            }
            let response = try await LauncherAPIClient.default.cancelUpgrade(
                reservationToken: reservationToken
            )
            if json { try printJSON(response) }
            else { print("Cancelled the exact app upgrade reservation.") }
            return 0

        default:
            throw CLIError.usage("maintenance requires prepare-upgrade or cancel-upgrade")
        }
    }

    private static func sync(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        var directory = FileManager.default.currentDirectoryPath
        var repair = false
        var json = false
        while let value = parser.pop() {
            switch value {
            case "--repair": repair = true
            case "--check": repair = false
            case "--json": json = true
            default:
                if !value.hasPrefix("-") && directory == FileManager.default.currentDirectoryPath { directory = value }
                else { throw CLIError.usage("unknown sync argument \(value)") }
            }
        }
        let project = try await LauncherAPIClient.default.resolveProject(directory: directory)
        let result = try await LauncherAPIClient.default.syncProject(id: project.id, repair: repair)
        if json { try printJSON(result) }
        else {
            print(result.message)
            print("Path: \(result.path)")
            print("Expected: \(result.expectedHash)")
            if let actual = result.actualHash { print("Actual: \(actual)") }
        }
        return result.inSync || result.repaired ? 0 : 4
    }

    private static func doctor(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        var directory = FileManager.default.currentDirectoryPath
        var json = false
        while let value = parser.pop() {
            if value == "--json" { json = true }
            else if !value.hasPrefix("-") && directory == FileManager.default.currentDirectoryPath { directory = value }
            else { throw CLIError.usage("unknown doctor argument \(value)") }
        }
        let health = try await LauncherAPIClient.default.health()
        let project = try? await LauncherAPIClient.default.resolveProject(directory: directory)
        let compatibilityIssue = LauncherCompatibility.incompatibilityReason(for: health)
        let report = DoctorReport(
            health: health,
            compatible: compatibilityIssue == nil,
            compatibilityMessage: compatibilityIssue ?? "service supports this CLI",
            project: project,
            commandPath: CommandLine.arguments[0],
            metadataPath: LauncherPaths.serviceMetadataURL.path
        )
        if json { try printJSON(report) }
        else {
            let state = compatibilityIssue == nil ? "healthy and compatible" : "healthy but incompatible"
            print("Service: \(state) (version \(health.version), PID \(health.pid), schema \(health.schemaVersion))")
            if let compatibilityIssue { print("Compatibility: \(compatibilityIssue)") }
            print("Endpoint: \(health.endpoint)")
            print("CLI: \(report.commandPath)")
            if let project { print("Project: \(project.displayName) — \(project.directory)") }
            else { print("Project: current directory is not initialized") }
        }
        return compatibilityIssue == nil ? 0 : 6
    }

    private static func logs(_ arguments: [String]) async throws -> Int32 {
        var parser = Parser(arguments)
        guard let name = parser.pop(), !name.hasPrefix("-") else { throw CLIError.usage("logs requires a launcher name") }
        var exactSessionID: UUID?
        while let value = parser.pop() {
            if value == "--session" {
                guard exactSessionID == nil,
                      let rawID = parser.pop(),
                      let parsedID = UUID(uuidString: rawID) else {
                    throw CLIError.usage("--session requires one valid session UUID")
                }
                exactSessionID = parsedID
            } else {
                throw CLIError.usage("unknown logs argument \(value)")
            }
        }
        let detail = try await LauncherAPIClient.default.launcher(named: name)
        let session: SessionRecord
        if let exactSessionID {
            let exact = try await LauncherAPIClient.default.sessionRecord(id: exactSessionID)
            guard exact.launcherID == detail.launcher.id else {
                throw CLIError.conflict("session \(exactSessionID.uuidString) does not belong to \(name)")
            }
            session = exact
        } else {
            guard let selected = detail.primaryActiveSession ?? detail.activeSession ?? detail.lastSession else {
                throw CLIError.notFound("no session logs exist for \(name)")
            }
            session = selected
        }
        print(try await LauncherAPIClient.default.logText(sessionID: session.id))
        return 0
    }

    private static func api(_ arguments: [String]) async throws -> Int32 {
        guard arguments.first == "endpoint" else { throw CLIError.usage("api requires endpoint") }
        let endpoint = try await LauncherAPIClient.default.apiEndpoint()
        if arguments.contains("--json") { try printJSON(["endpoint": endpoint]) }
        else { print(endpoint) }
        return 0
    }

    private static func printDetail(_ detail: LauncherDetail) {
        print(detail.launcher.name)
        print(detail.launcher.description)
        print("Project: \(detail.project.displayName) — \(detail.project.directory)")
        print("Revision: \(detail.launcher.revision)")
        print("Tags: \(detail.launcher.tags.isEmpty ? "—" : detail.launcher.tags.joined(separator: ", "))")
        if let runDetails = detail.launcher.runDetails { print("Run details: \(runDetails)") }
        for action in detail.launcher.sortedActions {
            print("Action \(action.name) [\(action.runner.rawValue)]")
            print("  Directory: \(action.workingDirectory)")
            print("  Command: \(action.displayCommand)")
            if action.port.mode != .none { print("  Port: \(action.port.mode.rawValue) (\(action.port.logicalName))") }
        }
        if !detail.activeSessions.isEmpty {
            print("Active sessions: \(detail.activeSessions.count)")
            detail.activeSessions.forEach(printSession)
        } else if let last = detail.lastSession {
            print("Last session: \(last.state.rawValue) at \(format(last.endedAt ?? last.startedAt))")
        } else {
            print("Status: idle")
        }
    }

    private static func printSession(_ session: SessionRecord) {
        let ended = session.endedAt.map { " → \(format($0))" } ?? ""
        print("\(session.launcherName): \(session.state.rawValue) · \(session.launchRole.rawValue) [\(session.id.uuidString)]")
        print("  Time: \(format(session.startedAt))\(ended)")
        for action in session.actionRuns {
            let target = action.endpointURL ?? action.port.map { "127.0.0.1:\($0)" } ?? action.pid.map { "PID \($0)" } ?? "—"
            print("  \(action.actionName): \(action.state.rawValue) — \(target)")
        }
        if let error = session.lastError { print("  Error: \(error)") }
    }

    private static func printDeleteIntent(_ intent: DeleteIntent) {
        let detail = intent.launcher
        print("Delete this launch shortcut only?\n")
        print("Name: \(detail.launcher.name)")
        print("Description: \(detail.launcher.description)")
        print("Project: \(detail.project.displayName) — \(detail.project.directory)")
        print("Revision: \(detail.launcher.revision)")
        print("Tags: \(detail.launcher.tags.isEmpty ? "—" : detail.launcher.tags.joined(separator: ", "))")
        print("Actions:")
        for action in detail.launcher.sortedActions { print("  \(action.name): \(action.displayCommand)") }
        print("\nProject files will not be deleted.")
        print("Running processes will not be stopped.")
        print("\nConfirm that this launch method is no longer valid/up to date and")
        print("delete only the shortcut. Type the exact name:", terminator: " ")
    }

    private static func printExternalCloseIntent(_ intent: ExternalCloseIntent) {
        print("Close this externally observed listener?\n")
        print("PID: \(intent.pid)")
        print("Started: \(format(intent.startedAt))")
        print("Ports: \(intent.endpoints.map(\.displayValue).joined(separator: ", "))")
        print("Owner: \(intent.ownership.kind.rawValue)")
        print("Command: \(intent.command)")
        print("\n\(intent.warning)")
        print("Exact confirmation: \(intent.confirmationText)")
        print("Type the exact confirmation to continue:", terminator: " ")
    }

    private static func printSkillUninstallIntent(_ intent: LauncherSkillUninstallIntent) {
        print("Remove this Launcher-managed skill installation?\n")
        print("Host: \(intent.host.displayName)")
        print("Destination: \(intent.sharedInstallationPath)")
        print("Installed version: \(intent.installedVersion ?? "unknown")")
        print("Managed files to remove:")
        for path in intent.removablePaths { print("  \(path)") }
        if !intent.preservedPaths.isEmpty {
            print("Preserved unmanaged files:")
            for path in intent.preservedPaths { print("  \(path)") }
        }
        print("\n\(intent.message)")
        print("Exact confirmation: \(intent.confirmationText)")
        print("Type the exact confirmation to remove only the listed managed files:", terminator: " ")
    }

    private static func printUsage() {
        print("""
        Launch Station

        Usage:
          launch init [DIRECTORY] [--project-name NAME]
          launch project update --name NAME [--directory PATH] [--if-revision N]
          launch --create NAME DESCRIPTION [RUN_DETAILS] [options] [-- EXECUTABLE ARG...]
          launch NAME [--new] [--open] [-- RUNTIME_ARG...]
          launch run NAME [--new] [--open] [-- RUNTIME_ARG...]
          launch relaunch NAME [--session UUID] [--open] [-- RUNTIME_ARG...]
          launch list [QUERY] [--tag TAG] [--state STATE] [--directory PATH]
          launch details NAME [--json]
          launch update NAME [fields] [--if-revision N]
          launch action add|update|delete ...
          launch delete NAME [--yes --if-revision N]
          launch status [NAME]
          launch close NAME [--session UUID]
          launch history [NAME] [--state STATE] [--role primary|additional] [--limit N] [--cursor TOKEN]
          launch external list [--refresh] [--json]
          launch external draft OBSERVATION_UUID [--json]
          launch external close OBSERVATION_UUID
          launch open NAME [--session UUID] [--option SERVER_DERIVED_OPTION_ID] [--probe] [--json]
          launch skill status [--json]
          launch skill install codex|claude-code [--json]
          launch skill uninstall codex|claude-code
          launch skill source [--json]
          launch maintenance prepare-upgrade [--json]
          launch maintenance cancel-upgrade RESERVATION_TOKEN [--json]
          launch sync [DIRECTORY] [--check|--repair]
          launch doctor [DIRECTORY]
          launch logs NAME [--session UUID]
          launch api endpoint

        Create options:
          --directory PATH       initialized project (default: current directory)
          --run-details TEXT     descriptive notes, not executed
          --tag TAG              repeatable tag
          --cwd PATH             action working directory, relative to project by default
          --order N              explicit compound-action order

          --type TYPE            process, shell, app, url, or ios
          --command COMMAND      explicit zsh command (selects shell type)
          --executable VALUE     executable, app path, URL, or iOS target
          --arg VALUE            repeatable stored argument
          --port none|auto|N     managed TCP port policy
          --url TEMPLATE         browser URL, using ${PORT} / ${HOST}
          --open TARGET          none, browser, application, or simulator
          --env KEY=VALUE        non-secret environment value

        Lifecycle options:
          --new                  start an additional independently owned instance; ordinary launch reuses the primary
          --session UUID         close or relaunch one exact active session

        External listeners are only identified by daemon-issued observation UUIDs. External close
        always runs an interactive exact-confirmation flow and never accepts arbitrary PIDs.
        `launch open` lists server-derived options by default; --option accepts only one of those
        opaque identifiers and --probe is limited to an existing Expo option.

        Update/action update additionally support --clear-args, --remove-arg VALUE,
        --set-arg INDEX VALUE, --clear-env, --remove-env KEY, --clear-inherit-env,
        --remove-inherit-env KEY, --clear-health, --clear-url, --clear-app-bundle-id,
        --required/--optional, and --allow-runtime-args/--deny-runtime-args.
        Launcher update also supports --primary-action ACTION. Put that selector before
        action mutation options when selecting and changing an action atomically.

        Every command supports --json where applicable. Generated launch_details.md files
        are read-only mirrors; use this command or the local API to change launchers.
        """)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try LauncherJSON.encoder(pretty: true).encode(value)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func splitAtDoubleDash(_ values: [String]) -> (before: [String], after: [String]) {
        guard let index = values.firstIndex(of: "--") else { return (values, []) }
        return (Array(values[..<index]), Array(values[values.index(after: index)...]))
    }
}

private struct Parser {
    private var values: [String]
    private var index = 0

    init(_ values: [String]) { self.values = values }

    mutating func pop() -> String? {
        guard index < values.count else { return nil }
        defer { index += 1 }
        return values[index]
    }

    func peek() -> String? {
        index < values.count ? values[index] : nil
    }

    mutating func requireValue(after option: String) throws -> String {
        guard let value = pop() else { throw CLIError.usage("\(option) requires a value") }
        return value
    }
}

private struct CLIError: Error {
    var code: Int32
    var message: String

    static func usage(_ message: String) -> CLIError { CLIError(code: 2, message: message) }
    static func notFound(_ message: String) -> CLIError { CLIError(code: 3, message: message) }
    static func conflict(_ message: String) -> CLIError { CLIError(code: 4, message: message) }
    static func confirmation(_ message: String) -> CLIError { CLIError(code: 7, message: message) }
}

private struct DoctorReport: Codable {
    var health: ServiceStatus
    var compatible: Bool
    var compatibilityMessage: String
    var project: ProjectRecord?
    var commandPath: String
    var metadataPath: String
}
