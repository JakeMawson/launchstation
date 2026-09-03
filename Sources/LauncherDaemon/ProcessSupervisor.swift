import AppKit
import Darwin
import Foundation
import LauncherCore

public enum ProcessSupervisorError: LocalizedError {
    case unsupportedAction(String)
    case runnerUnavailable(String)
    case runnerHandshakeFailed(String)
    case managedCommandFailed(command: String, status: Int32, output: String)
    case invalidManagedResponse(String)
    case unableToReadProcessIdentity(Int32)
    case applicationUnavailable(String)
    case applicationLaunchFailed(String)
    case invalidURL(String)
    case reservedEnvironmentVariable(String)
    case simulatorUnavailable(String)
    case simulatorCommandFailed(command: String, status: Int32, output: String)
    case invalidSimulatorConfiguration(String)
    case helperCommandTimedOut(command: String, output: String)
    case invalidSessionOpenOption(String)
    case sessionOpenUnavailable(String)
    case expoOpenFailed(status: Int, output: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAction(let reason): return "Unsupported launch action: \(reason)"
        case .runnerUnavailable(let path): return "Launcher runner is unavailable: \(path)"
        case .runnerHandshakeFailed(let reason): return "Launcher runner did not become manageable: \(reason)"
        case .managedCommandFailed(let command, let status, let output):
            return "Managed command failed (\(status)): \(command)\n\(output)"
        case .invalidManagedResponse(let response): return "Invalid managed-service response: \(response)"
        case .unableToReadProcessIdentity(let pid): return "Unable to read exact birth identity for PID \(pid)."
        case .applicationUnavailable(let target): return "Application is unavailable: \(target)"
        case .applicationLaunchFailed(let reason): return "Application launch failed: \(reason)"
        case .invalidURL(let value): return "Invalid URL or file target: \(value)"
        case .reservedEnvironmentVariable(let name):
            return "\(name) is owned by the launcher port manager and cannot be configured or inherited by an action."
        case .simulatorUnavailable(let reason): return "No usable iOS Simulator device is available: \(reason)"
        case .simulatorCommandFailed(let command, let status, let output):
            return "Simulator command failed (\(status)): \(command)\n\(output)"
        case .invalidSimulatorConfiguration(let reason): return "Invalid Simulator configuration: \(reason)"
        case .helperCommandTimedOut(let command, let output):
            return "Launcher helper command timed out: \(command)\n\(output)"
        case .invalidSessionOpenOption(let optionID):
            return "The requested session open option is invalid or no longer belongs to this session: \(optionID)"
        case .sessionOpenUnavailable(let reason):
            return "The requested session target is no longer available: \(reason)"
        case .expoOpenFailed(let status, let output):
            let suffix = output.isEmpty ? "" : "\n\(output)"
            return "Expo rejected the open request (HTTP \(status)).\(suffix)"
        }
    }
}

public struct ProcessBirthIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedSeconds: UInt64
    public var startedMicroseconds: UInt64

    public init?(pid: Int32) {
        var info = proc_bsdinfo()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        self.pid = pid
        self.startedSeconds = info.pbi_start_tvsec
        self.startedMicroseconds = info.pbi_start_tvusec
    }

    public var serialized: String {
        "\(pid):\(startedSeconds):\(startedMicroseconds)"
    }

    public static func matches(pid: Int32, serialized: String?) -> Bool {
        guard let serialized, let current = ProcessBirthIdentity(pid: pid) else { return false }
        return current.serialized == serialized
    }
}

private struct RunnerLaunchSpecification: Codable, Sendable {
    var schemaVersion: Int
    var runID: UUID
    var workingDirectory: String
    var executable: String?
    var arguments: [String]
    var shellCommand: String?
    var environment: [String: String]
    var portEnvironmentVariable: String?
    var hostEnvironmentVariable: String?
    var statusPath: String
    var acknowledgementPath: String?
}

private struct RunnerStatus: Codable, Sendable {
    var schemaVersion: Int
    var runID: UUID
    var pid: Int32
    var processGroupID: Int32
    var pidStartIdentity: String
    var startedAt: Date
}

private struct RunnerAcknowledgement: Codable, Sendable {
    var schemaVersion: Int
    var runID: UUID
    var pid: Int32
    var pidStartIdentity: String
}

private struct CodexPortRecord: Decodable, Sendable {
    var id: String
    var port: Int
    var host: String
    var pid: Int32
    var pgid: Int32?
    var pidStartIdentity: String?
    var logPath: String
    var live: Bool?

    enum CodingKeys: String, CodingKey {
        case id, port, host, pid, pgid, live
        case pidStartIdentity = "pid_start_identity"
        case logPath = "log_path"
    }
}

private struct CommandResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private struct BoundedCommandOutput: Sendable {
    var retained: Data
    var totalBytes: Int

    func rendered(streamName: String) -> String {
        var value = String(decoding: retained, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if totalBytes > retained.count {
            let marker = "[\(streamName) truncated by Launch Station: retained first \(retained.count) of \(totalBytes) bytes]"
            value = value.isEmpty ? marker : value + "\n" + marker
        }
        return value
    }
}

private final class PipeDrainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// Expo control requests must stay on the exact loopback origin derived from the stored
/// action run. Refusing redirects prevents a local response from forwarding the daemon's
/// POST to an unrelated URL.
private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct SimulatorDeviceList: Decodable, Sendable {
    var devices: [String: [SimulatorDevice]]
}

private struct SimulatorDevice: Decodable, Sendable {
    var udid: String
    var name: String
    var state: String
    var isAvailable: Bool?
}

private struct SelectedSimulator: Sendable {
    var udid: String
    var name: String
    var wasAlreadyBooted: Bool

    var summary: String {
        let boot = wasAlreadyBooted ? "reused while already booted" : "booted"
        return "Simulator \(name) (\(udid)) was \(boot) and opened; it is not owned or shut down by CLOSE."
    }
}

public actor ProcessSupervisor {
    public typealias UpdateHandler = @Sendable (ActionRunRecord) -> Void
    public typealias RegistrationHandler = @Sendable (ActionRunRecord) async throws -> Void

    private let runtimeDirectory: URL
    private let configuredRunnerURL: URL?
    private let codexPortURL: URL
    private let xcrunURL: URL
    private let simulatorOpenURL: URL
    private let helperCommandTimeoutSeconds: TimeInterval
    private let monitorQueue = DispatchQueue(label: "com.launchstation.process-monitor", qos: .utility)
    private var records: [UUID: ActionRunRecord] = [:]
    private var handlers: [UUID: UpdateHandler] = [:]
    private var monitors: [UUID: DispatchSourceProcess] = [:]
    private var nativeProcesses: [UUID: Process] = [:]

    public init(
        runtimeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Launch Station", isDirectory: true),
        runnerExecutableURL: URL? = nil,
        codexPortExecutableURL: URL? = nil,
        xcrunExecutableURL: URL? = nil,
        simulatorOpenExecutableURL: URL? = nil,
        helperCommandTimeoutSeconds: TimeInterval? = nil
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.configuredRunnerURL = runnerExecutableURL
        self.codexPortURL = codexPortExecutableURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/codex-port")
        let environment = ProcessInfo.processInfo.environment
        let environmentTimeout = environment["LAUNCH_STATION_HELPER_TIMEOUT_SECONDS"].flatMap(Double.init)
        let selectedTimeout = helperCommandTimeoutSeconds ?? environmentTimeout ?? 120
        self.helperCommandTimeoutSeconds = selectedTimeout.isFinite && selectedTimeout > 0
            ? min(selectedTimeout, 600)
            : 120
        self.xcrunURL = xcrunExecutableURL
            ?? environment["LAUNCH_STATION_XCRUN"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/usr/bin/xcrun")
        self.simulatorOpenURL = simulatorOpenExecutableURL
            ?? environment["LAUNCH_STATION_SIMULATOR_OPEN"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/usr/bin/open")
    }

    @discardableResult
    public func launch(
        action: LaunchAction,
        project: ProjectRecord,
        sessionID: UUID,
        runtimeArguments: [String] = [],
        onRegister: @escaping RegistrationHandler,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ActionRunRecord {
        try validateEnvironmentOwnership(action)
        if !runtimeArguments.isEmpty, !action.allowsRuntimeArguments {
            throw ProcessSupervisorError.unsupportedAction("\(action.name) does not allow runtime arguments")
        }
        let workingDirectory = try LauncherValidation.resolvedWorkingDirectory(action: action, project: project)
        let acceptedRuntimeArguments = runtimeArguments
        if action.runner == .url, (!action.arguments.isEmpty || !acceptedRuntimeArguments.isEmpty) {
            throw ProcessSupervisorError.unsupportedAction("URL/file actions do not accept stored or runtime arguments")
        }
        let simulator = (action.runner == .ios || action.openTarget == .simulator)
            ? try await prepareSimulator(action: action, workingDirectory: workingDirectory)
            : nil

        switch action.runner {
        case .app:
            return try await launchApplication(
                action: action,
                runtimeArguments: acceptedRuntimeArguments,
                simulator: simulator,
                onUpdate: onUpdate
            )
        case .url:
            return try launchURL(action: action, simulator: simulator, onUpdate: onUpdate)
        case .process, .shell, .ios:
            if action.port.mode != .none {
                return try await launchWithCodexPort(
                    action: action,
                    project: project,
                    sessionID: sessionID,
                    workingDirectory: workingDirectory,
                    runtimeArguments: acceptedRuntimeArguments,
                    simulator: simulator,
                    onUpdate: onUpdate
                )
            }
            return try await launchProcessGroup(
                action: action,
                sessionID: sessionID,
                workingDirectory: workingDirectory,
                runtimeArguments: acceptedRuntimeArguments,
                simulator: simulator,
                onRegister: onRegister,
                onUpdate: onUpdate
            )
        }
    }

    @discardableResult
    public func recover(
        _ record: ActionRunRecord,
        releaseUnacknowledgedRunner: Bool = true,
        onUpdate: @escaping UpdateHandler
    ) async -> ActionRunRecord {
        guard record.state == .starting || record.state == .running || record.state == .stopping else {
            return record
        }

        switch record.manager {
        case .fireAndForget:
            return record
        case .codexPort:
            guard let managerID = record.managerID else {
                return terminalized(record, state: .orphaned, message: "Managed port run has no manager ID.")
            }
            do {
                let managed = try await codexPortRecords().first { $0.id == managerID }
                guard let managed else {
                    if let pid = record.pid, ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) {
                        return terminalized(record, state: .orphaned, message: "Process is live but codex-port no longer owns it.")
                    }
                    return terminalized(record, state: .exited, message: "Managed port process is no longer active.")
                }
                guard managed.live == true else {
                    return terminalized(record, state: .orphaned, message: "codex-port no longer reports manager \(managerID) as live; the process was not adopted.")
                }
                guard let recordedPID = record.pid, recordedPID == managed.pid else {
                    return terminalized(record, state: .orphaned, message: "codex-port reports a different PID for manager \(managerID); the replacement process was not adopted.")
                }
                guard ProcessBirthIdentity.matches(pid: managed.pid, serialized: record.pidStartIdentity) else {
                    if ProcessBirthIdentity(pid: managed.pid) != nil {
                        return terminalized(record, state: .orphaned, message: "codex-port PID birth identity changed; the reused PID was not adopted.")
                    }
                    return terminalized(record, state: .exited, message: "The codex-port process ended during recovery.")
                }
                if let reportedGroup = managed.pgid,
                   let recordedGroup = record.processGroupID,
                   reportedGroup != recordedGroup {
                    return terminalized(record, state: .orphaned, message: "codex-port reports a different process group; no lifecycle ownership was assumed.")
                }
                var recovered = record
                recovered.host = managed.host
                recovered.port = managed.port
                recovered.logPath = managed.logPath
                recovered.state = .running
                recovered.message = "Recovered live codex-port manager \(managerID) after corroborating its exact recorded PID birth identity."
                track(recovered, process: nil, onUpdate: onUpdate)
                return recovered
            } catch {
                return terminalized(record, state: .orphaned, message: "Unable to prove live codex-port ownership: \(error.localizedDescription)")
            }
        case .processGroup:
            guard let pid = record.pid else {
                return terminalized(record, state: .orphaned, message: "Run has no PID to recover.")
            }
            if ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) {
                var recovered = record
                recovered.state = .running
                recovered.message = "Recovered exact process identity after daemon restart."
                track(recovered, process: nil, onUpdate: onUpdate)
                if releaseUnacknowledgedRunner {
                    do {
                        if try releaseRecoveredRunnerIfNeeded(recovered) {
                            recovered.message = "Recovered the durably registered runner and released its pending start gate."
                            records[recovered.id] = recovered
                        }
                    } catch {
                        recovered.message = "Recovered the durably registered runner, but its pending start gate could not be released: \(error.localizedDescription)"
                        records[recovered.id] = recovered
                    }
                }
                return recovered
            }
            if ProcessBirthIdentity(pid: pid) != nil {
                return terminalized(record, state: .orphaned, message: "PID was reused; the new process was not adopted.")
            }
            return terminalized(record, state: .exited, message: "Process ended while the daemon was unavailable.")
        case .application:
            guard let pid = record.pid else {
                return terminalized(record, state: .orphaned, message: "Run has no PID to recover.")
            }
            if ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) {
                var recovered = record
                recovered.state = .running
                recovered.message = "Recovered exact process identity after daemon restart."
                track(recovered, process: nil, onUpdate: onUpdate)
                return recovered
            }
            if ProcessBirthIdentity(pid: pid) != nil {
                return terminalized(record, state: .orphaned, message: "PID was reused; the new process was not adopted.")
            }
            return terminalized(record, state: .exited, message: "Process ended while the daemon was unavailable.")
        }
    }

    @discardableResult
    public func stop(
        _ original: ActionRunRecord,
        timeoutSeconds: Int,
        onUpdate: UpdateHandler? = nil
    ) async -> ActionRunRecord {
        guard original.state == .starting || original.state == .running || original.state == .stopping else {
            return original
        }
        let handler = onUpdate ?? handlers[original.id]
        var stopping = records[original.id] ?? original
        stopping.state = .stopping
        stopping.message = "Stopping exact launcher-owned process."
        records[stopping.id] = stopping
        handler?(stopping)

        let result: ActionRunRecord
        switch stopping.manager {
        case .processGroup:
            result = await stopProcessGroup(stopping, timeoutSeconds: timeoutSeconds)
        case .codexPort:
            result = await stopCodexPort(stopping)
        case .application:
            result = await stopApplication(stopping, timeoutSeconds: timeoutSeconds)
        case .fireAndForget:
            result = terminalized(stopping, state: .exited, message: "The target was opened without claiming another process.")
        }
        finishTracking(result)
        handler?(result)
        return result
    }

    public func renewCodexPort(_ record: ActionRunRecord, lease: String) async throws {
        guard record.manager == .codexPort, let managerID = record.managerID else {
            throw ProcessSupervisorError.unsupportedAction("only codex-port runs have renewable leases")
        }
        let result = try await execute(
            executable: codexPortURL,
                arguments: ["renew", "--id", managerID, "--ttl", lease, "--reason", "Launch Station still owns and monitors this run"]
        )
        guard result.status == 0 else {
            throw ProcessSupervisorError.managedCommandFailed(
                command: "codex-port renew",
                status: result.status,
                output: result.combinedOutput
            )
        }
    }

    public func isExactProcessAlive(_ record: ActionRunRecord) -> Bool {
        guard let pid = record.pid else { return false }
        return ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity)
    }

    /// Returns only separately managed services whose current PID, process group, and birth
    /// identity still corroborate codex-port's live registry. Listener discovery remains the
    /// external monitor's responsibility, so an empty listener PID list intentionally means
    /// "correlate by the exact managed process group" rather than "match every listener".
    public func liveCodexPortCorrelations() async throws -> [ExternalCodexPortCorrelation] {
        try await codexPortRecords().compactMap { record in
            guard record.live == true,
                  let processGroupID = record.pgid,
                  let pidStartIdentity = record.pidStartIdentity,
                  ProcessBirthIdentity.matches(pid: record.pid, serialized: pidStartIdentity),
                  getpgid(record.pid) == processGroupID else {
                return nil
            }
            return ExternalCodexPortCorrelation(
                managerID: record.id,
                pid: record.pid,
                processGroupID: processGroupID,
                pidStartIdentity: pidStartIdentity,
                listenerPIDs: []
            )
        }
    }

    /// Pure, non-launching option derivation. This does not inspect processes, call Expo,
    /// focus an app, open a browser, or interact with Simulator.
    public func sessionOpenOptions(for session: SessionRecord) -> [SessionOpenOption] {
        SessionOpenOptionDeriver.options(for: session)
    }

    /// Performs Expo's documented non-launching GET probe for an already-derived platform
    /// option. The URL and platform are reconstructed from the stored session; callers can
    /// submit only the opaque option identifier.
    public func probeExpoOpenOption(
        optionID: String,
        in session: SessionRecord
    ) async throws -> SessionOpenProbeResult {
        let context = try storedOpenContext(optionID: optionID, session: session)
        guard context.option.kind.expoPlatform != nil,
              let action = context.action,
              SessionOpenOptionDeriver.isExpoAction(action),
              let url = SessionOpenOptionDeriver.expoControlURL(
                endpointURL: context.run.endpointURL,
                kind: context.option.kind
              ) else {
            throw ProcessSupervisorError.invalidSessionOpenOption(optionID)
        }
        try requireExactOpenOwner(context.run)
        let response = try await performExpoControlRequest(url: url, method: "GET")
        let available = (200..<300).contains(response.status)
        let message = response.output.isEmpty
            ? "Expo probe returned HTTP \(response.status)."
            : response.output
        return SessionOpenProbeResult(
            optionID: context.option.id,
            kind: context.option.kind,
            available: available,
            statusCode: response.status,
            message: message
        )
    }

    /// Opens or focuses one server-derived target from a stored session. No execution target
    /// is accepted from the client, and every target is reconstructed and revalidated here.
    public func openSessionOption(
        optionID: String,
        in session: SessionRecord
    ) async throws -> SessionOpenResult {
        let context = try storedOpenContext(optionID: optionID, session: session)
        let message: String

        switch context.option.kind {
        case .browser:
            try requireExactOpenOwner(context.run)
            guard let url = SessionOpenOptionDeriver.validatedHTTPURL(context.run.endpointURL) else {
                throw ProcessSupervisorError.invalidSessionOpenOption(optionID)
            }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else {
                throw ProcessSupervisorError.sessionOpenUnavailable("the stored browser endpoint could not be opened")
            }
            message = "Opened the stored endpoint in the default browser."

        case .application:
            guard context.run.manager == .application,
                  let pid = context.run.pid,
                  context.run.pidStartIdentity != nil else {
                throw ProcessSupervisorError.invalidSessionOpenOption(optionID)
            }
            let activated = await MainActor.run { () -> Bool in
                guard ProcessBirthIdentity.matches(
                    pid: pid,
                    serialized: context.run.pidStartIdentity
                ), let application = NSRunningApplication(processIdentifier: pid) else {
                    return false
                }
                return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            guard activated else {
                throw ProcessSupervisorError.sessionOpenUnavailable(
                    "the exact application PID/birth identity is no longer live"
                )
            }
            message = "Focused the exact running application instance."

        case .simulator:
            try requireExactOpenOwner(context.run)
            message = try await focusStoredSimulator(for: context.run)

        case .expoIOS, .expoAndroid, .expoWeb:
            try requireExactOpenOwner(context.run)
            guard let action = context.action,
                  SessionOpenOptionDeriver.isExpoAction(action),
                  let platform = context.option.kind.expoPlatform,
                  let url = SessionOpenOptionDeriver.expoControlURL(
                    endpointURL: context.run.endpointURL,
                    kind: context.option.kind
                  ) else {
                throw ProcessSupervisorError.invalidSessionOpenOption(optionID)
            }
            let response = try await performExpoControlRequest(url: url, method: "POST")
            guard (200..<300).contains(response.status) else {
                throw ProcessSupervisorError.expoOpenFailed(
                    status: response.status,
                    output: response.output
                )
            }
            message = "Asked the already-running Expo server to open \(platform)."
        }

        return SessionOpenResult(
            optionID: context.option.id,
            kind: context.option.kind,
            message: message
        )
    }

    private func launchProcessGroup(
        action: LaunchAction,
        sessionID: UUID,
        workingDirectory: String,
        runtimeArguments: [String],
        simulator: SelectedSimulator?,
        onRegister: @escaping RegistrationHandler,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ActionRunRecord {
        let runID = UUID()
        let paths = try prepareRunPaths(sessionID: sessionID, runID: runID, actionName: action.name)
        let runnerURL = try runnerExecutableURL()
        let specification = makeSpecification(
            runID: runID,
            action: action,
            workingDirectory: workingDirectory,
            runtimeArguments: runtimeArguments,
            simulator: simulator,
            statusPath: paths.status.path,
            acknowledgementPath: paths.acknowledgement.path
        )
        try writeSpecification(specification, to: paths.specification)

        FileManager.default.createFile(atPath: paths.log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: paths.log)
        let process = Process()
        process.executableURL = runnerURL
        process.arguments = ["--spec", paths.specification.path]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw error
        }
        try? logHandle.close()

        let status = try await waitForRunnerStatus(
            at: paths.status,
            runID: runID,
            process: process,
            timeoutSeconds: 3
        )
        let message = simulator.map { $0.summary + " Only the exact command process group is owned." }
        let record = ActionRunRecord(
            id: runID,
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .processGroup,
            managerID: "runner:\(runID.uuidString)",
            pid: status.pid,
            processGroupID: status.processGroupID,
            pidStartIdentity: status.pidStartIdentity,
            endpointURL: LauncherValidation.renderedStaticEndpoint(for: action),
            simulatorUDID: simulator?.udid,
            simulatorName: simulator?.name,
            logPath: paths.log.path,
            startedAt: status.startedAt,
            message: message
        )

        // The runner has published a verified PID/PGID/birth identity but remains blocked at its
        // start gate. Do not arm callbacks or release the command until the daemon's sole writer
        // has durably registered that exact lifecycle owner.
        do {
            try await onRegister(record)
        } catch {
            await terminateUnreleasedRunner(status, process: process)
            throw error
        }

        // Registration may be deliberately slow (for example, SQLite contention). Re-prove the
        // same still-gated owner after that await so a dead/reused PID or changed PGID can never be
        // armed or acknowledged from stale pre-registration evidence.
        guard isVerifiedRunner(status, process: process) else {
            var failed = record
            failed.state = ProcessBirthIdentity(pid: status.pid) == nil ? .failed : .orphaned
            failed.endedAt = Date()
            failed.message = failed.state == .failed
                ? "The verified runner exited before durable registration could release its start gate."
                : "The runner identity changed before start-gate release; no process group was signalled or adopted."
            records[failed.id] = failed
            return failed
        }
        track(record, process: process, onUpdate: onUpdate)
        do {
            try writeAcknowledgement(
                RunnerAcknowledgement(
                    schemaVersion: 1,
                    runID: runID,
                    pid: status.pid,
                    pidStartIdentity: status.pidStartIdentity
                ),
                to: paths.acknowledgement
            )
        } catch {
            if ProcessBirthIdentity.matches(pid: status.pid, serialized: status.pidStartIdentity) {
                _ = kill(-status.processGroupID, SIGKILL)
            }
            var failed = record
            failed.state = .failed
            failed.endedAt = Date()
            failed.message = "Unable to release the verified runner start gate: \(error.localizedDescription)"
            finishTracking(failed)
            onUpdate(failed)
            return failed
        }
        if !process.isRunning {
            observedExit(runID: runID)
            return records[runID] ?? record
        }
        return record
    }

    private func launchWithCodexPort(
        action: LaunchAction,
        project: ProjectRecord,
        sessionID: UUID,
        workingDirectory: String,
        runtimeArguments: [String],
        simulator: SelectedSimulator?,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ActionRunRecord {
        guard FileManager.default.isExecutableFile(atPath: codexPortURL.path) else {
            throw ProcessSupervisorError.runnerUnavailable(codexPortURL.path)
        }
        let runID = UUID()
        let paths = try prepareRunPaths(sessionID: sessionID, runID: runID, actionName: action.name)
        let runnerURL = try runnerExecutableURL()
        let specification = makeSpecification(
            runID: runID,
            action: action,
            workingDirectory: workingDirectory,
            runtimeArguments: runtimeArguments,
            simulator: simulator,
            statusPath: paths.status.path,
            acknowledgementPath: nil
        )
        try writeSpecification(specification, to: paths.specification)

        let portArgument: String
        switch action.port.mode {
        case .automatic: portArgument = "auto"
        case .fixed:
            guard let fixed = action.port.fixedPort else {
                throw ProcessSupervisorError.unsupportedAction("fixed port action has no port")
            }
            portArgument = String(fixed)
        case .none:
            throw ProcessSupervisorError.unsupportedAction("codex-port launch requested without a port")
        }

        let title = "\(project.displayName): \(action.name)"
        let managedHost = isExpoAction(action) ? "localhost" : "127.0.0.1"
        let result = try await execute(
            executable: codexPortURL,
            arguments: [
                "run",
                "--title", title,
                "--description", action.description,
                "--workdir", workingDirectory,
                "--port", portArgument,
                "--host", managedHost,
                "--ttl", action.port.lease,
                "--",
                runnerURL.path,
                "--spec", paths.specification.path,
            ]
        )
        guard result.status == 0 else {
            throw ProcessSupervisorError.managedCommandFailed(
                command: "codex-port run",
                status: result.status,
                output: result.combinedOutput
            )
        }
        guard let data = result.stdout.data(using: .utf8),
              let managed = try? JSONDecoder().decode(CodexPortRecord.self, from: data) else {
            throw ProcessSupervisorError.invalidManagedResponse(result.combinedOutput)
        }
        guard let exactIdentity = ProcessBirthIdentity(pid: managed.pid) else {
            // Do not throw away the only useful evidence by reducing this to an opaque PID
            // validation error. The command may already have written a concrete project failure
            // (for example, a missing runtime dependency) before this exact-ownership guard
            // declines to adopt the manager. Inspect once, preserve the bounded evidence with the
            // failed run, then deliberately close only the manager we just created.
            let listedManager = try? await codexPortRecords().first { $0.id == managed.id }
            let managerReportedLive = listedManager?.live == true && listedManager?.pid == managed.pid
            let processStarted = FileManager.default.fileExists(atPath: paths.status.path)
            let logText = readRunLogTail(path: managed.logPath)
            let diagnosis = LaunchFailureDiagnoser.diagnose(
                LaunchFailureDiagnosisInput(
                    launcherMessage: ProcessSupervisorError.unableToReadProcessIdentity(managed.pid).localizedDescription,
                    logText: logText,
                    processStarted: processStarted,
                    managerReportedLive: managerReportedLive,
                    identityReadableAfterFailure: false,
                    launcherRequestedCleanup: managerReportedLive
                )
            )
            if managerReportedLive {
                _ = try? await execute(
                    executable: codexPortURL,
                    arguments: ["close", "--id", managed.id, "--reason", "Launcher could not validate process birth identity"]
                )
            }
            return ActionRunRecord(
                id: runID,
                actionID: action.id,
                actionName: action.name,
                state: .failed,
                manager: .codexPort,
                managerID: managed.id,
                pid: managed.pid,
                processGroupID: managed.pgid ?? managed.pid,
                host: managed.host,
                port: managed.port,
                endpointURL: renderedEndpoint(action: action, host: managed.host, port: managed.port),
                simulatorUDID: simulator?.udid,
                simulatorName: simulator?.name,
                logPath: managed.logPath,
                endedAt: Date(),
                message: diagnosis.summary,
                failureDiagnosis: diagnosis
            )
        }

        let endpoint = renderedEndpoint(action: action, host: managed.host, port: managed.port)
        let lifecycleMessage: String
        if let simulator {
            lifecycleMessage = "Lifecycle is owned by codex-port manager \(managed.id). \(simulator.summary)"
        } else {
            lifecycleMessage = "Lifecycle is owned by codex-port manager \(managed.id)."
        }
        let record = ActionRunRecord(
            id: runID,
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .codexPort,
            managerID: managed.id,
            pid: managed.pid,
            processGroupID: managed.pgid ?? managed.pid,
            pidStartIdentity: exactIdentity.serialized,
            host: managed.host,
            port: managed.port,
            endpointURL: endpoint,
            simulatorUDID: simulator?.udid,
            simulatorName: simulator?.name,
            logPath: managed.logPath,
            message: lifecycleMessage
        )
        track(record, process: nil, onUpdate: onUpdate)
        onUpdate(record)
        return record
    }

    private func launchApplication(
        action: LaunchAction,
        runtimeArguments: [String],
        simulator: SelectedSimulator?,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ActionRunRecord {
        guard let target = action.executable else {
            throw ProcessSupervisorError.applicationUnavailable(action.name)
        }
        let configuredBundleIdentifier = ApplicationIdentityPolicy.nonemptyIdentifier(action.appBundleIdentifier)
        let applicationURL = try resolveApplicationURL(
            target: target,
            bundleIdentifier: configuredBundleIdentifier
        )
        let resolvedBundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        let verifiedBundleIdentifier: String?
        do {
            verifiedBundleIdentifier = try ApplicationIdentityPolicy.verifiedBundleIdentifier(
                configured: configuredBundleIdentifier,
                resolvedFromBundle: resolvedBundleIdentifier
            )
        } catch {
            throw ProcessSupervisorError.applicationLaunchFailed(error.localizedDescription)
        }
        let existingPIDs = Set(
            verifiedBundleIdentifier.map {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
            } ?? []
        )

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = action.arguments + runtimeArguments
        configuration.environment = applicationEnvironment(for: action)
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: ProcessSupervisorError.applicationLaunchFailed(error.localizedDescription))
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: ProcessSupervisorError.applicationLaunchFailed("LaunchServices returned no application."))
                }
            }
        }
        let pid = application.processIdentifier
        guard let identity = ProcessBirthIdentity(pid: pid) else {
            throw ProcessSupervisorError.unableToReadProcessIdentity(pid)
        }
        let ownsDistinctInstance = ApplicationIdentityPolicy.provesDistinctOwnership(
            verifiedBundleIdentifier: verifiedBundleIdentifier,
            launchedBundleIdentifier: application.bundleIdentifier,
            launchedPID: pid,
            preexistingPIDs: existingPIDs
        )
        let ownership = ownsDistinctInstance ? "owned" : "reused"
        let bundleIdentifier = verifiedBundleIdentifier
            ?? ApplicationIdentityPolicy.nonemptyIdentifier(application.bundleIdentifier)
            ?? "unverified"
        let argumentMessage = configuration.arguments.isEmpty
            ? nil
            : "Forwarded \(configuration.arguments.count) argument(s) through LaunchServices."
        let lifecycleMessage = ownsDistinctInstance
            ? "Launcher owns this exact application instance."
            : "Distinct application ownership could not be proven or LaunchServices reused a pre-existing application; CLOSE will not terminate it."
        let record = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .application,
            managerID: "app:\(ownership):\(pid):\(bundleIdentifier)",
            pid: pid,
            processGroupID: nil,
            pidStartIdentity: identity.serialized,
            endpointURL: LauncherValidation.renderedStaticEndpoint(for: action),
            simulatorUDID: simulator?.udid,
            simulatorName: simulator?.name,
            message: [lifecycleMessage, argumentMessage, simulator?.summary]
                .compactMap { $0 }
                .joined(separator: " ")
        )
        track(record, process: nil, onUpdate: onUpdate)
        onUpdate(record)
        return record
    }

    private func launchURL(action: LaunchAction, simulator: SelectedSimulator?, onUpdate: @escaping UpdateHandler) throws -> ActionRunRecord {
        guard let target = action.executable else { throw ProcessSupervisorError.invalidURL(action.name) }
        let expanded = NSString(string: target).expandingTildeInPath
        let url: URL
        if let parsed = URL(string: target), parsed.scheme != nil {
            url = parsed
        } else {
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard NSWorkspace.shared.open(url) else { throw ProcessSupervisorError.invalidURL(target) }
        let now = Date()
        let record = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .exited,
            manager: .fireAndForget,
            managerID: "open:\(url.absoluteString)",
            simulatorUDID: simulator?.udid,
            simulatorName: simulator?.name,
            startedAt: now,
            endedAt: now,
            exitCode: 0,
            message: ["Target opened without claiming or terminating another application.", simulator?.summary]
                .compactMap { $0 }
                .joined(separator: " ")
        )
        onUpdate(record)
        return record
    }

    private func stopProcessGroup(_ record: ActionRunRecord, timeoutSeconds: Int) async -> ActionRunRecord {
        guard let pid = record.pid, let group = record.processGroupID else {
            return terminalized(record, state: .orphaned, message: "Process-group run lacks PID or PGID.")
        }
        guard ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) else {
            if ProcessBirthIdentity(pid: pid) == nil {
                return terminalized(record, state: .exited, message: "Process already exited.")
            }
            return terminalized(record, state: .orphaned, message: "PID birth identity changed; refusing to signal the new process.")
        }

        let total = max(1, timeoutSeconds)
        if kill(-group, SIGINT) != 0, errno != ESRCH {
            return terminalized(record, state: .orphaned, message: "Unable to send SIGINT to the verified process group (errno \(errno)).")
        }
        if await waitUntilIdentityEnds(record, seconds: max(1, total / 3)) {
            return terminalized(record, state: .exited, message: "Process group exited after SIGINT.")
        }
        guard ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) else {
            return terminalized(record, state: .exited, message: "Process group exited while stopping.")
        }
        _ = kill(-group, SIGTERM)
        if await waitUntilIdentityEnds(record, seconds: max(1, total / 2)) {
            return terminalized(record, state: .exited, message: "Process group exited after SIGTERM.")
        }
        guard ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) else {
            return terminalized(record, state: .exited, message: "Process group exited while stopping.")
        }
        _ = kill(-group, SIGKILL)
        if await waitUntilIdentityEnds(record, seconds: 2) {
            return terminalized(record, state: .exited, message: "Process group required SIGKILL.")
        }
        return terminalized(record, state: .orphaned, message: "Verified process group remained live after SIGKILL.")
    }

    private func stopCodexPort(_ record: ActionRunRecord) async -> ActionRunRecord {
        guard let managerID = record.managerID else {
            return terminalized(record, state: .orphaned, message: "codex-port run has no manager ID.")
        }
        do {
            let result = try await execute(
                executable: codexPortURL,
                arguments: ["close", "--id", managerID, "--reason", "Closed from Launch Station"]
            )
            if result.status == 0 {
                return terminalized(record, state: .exited, message: "Closed through codex-port manager \(managerID).")
            }
            if let pid = record.pid, !ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity), ProcessBirthIdentity(pid: pid) == nil {
                return terminalized(record, state: .exited, message: "Managed process had already exited.")
            }
            return terminalized(
                record,
                state: .orphaned,
                message: "codex-port refused to close the run; no direct signal was sent. \(result.combinedOutput)"
            )
        } catch {
            return terminalized(record, state: .orphaned, message: "codex-port close failed; no direct signal was sent. \(error.localizedDescription)")
        }
    }

    private func stopApplication(_ record: ActionRunRecord, timeoutSeconds: Int) async -> ActionRunRecord {
        guard let managerID = record.managerID, !managerID.hasPrefix("app:reused:") else {
            return terminalized(record, state: .orphaned, message: "Pre-existing application was not terminated.")
        }
        guard managerID.hasPrefix("app:owned:"), let pid = record.pid else {
            return terminalized(record, state: .orphaned, message: "Application ownership cannot be proven.")
        }
        guard ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) else {
            if ProcessBirthIdentity(pid: pid) == nil {
                return terminalized(record, state: .exited, message: "Application already exited.")
            }
            return terminalized(record, state: .orphaned, message: "Application PID was reused; refusing to terminate it.")
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return terminalized(record, state: .exited, message: "Application already exited.")
        }
        guard application.terminate() else {
            return terminalized(record, state: .orphaned, message: "Application refused a normal terminate request; force termination is intentionally not automatic.")
        }
        if await waitUntilIdentityEnds(record, seconds: max(1, timeoutSeconds)) {
            return terminalized(record, state: .exited, message: "Application terminated normally.")
        }
        return terminalized(record, state: .orphaned, message: "Application is still live; force termination requires a separate explicit action.")
    }

    private func makeSpecification(
        runID: UUID,
        action: LaunchAction,
        workingDirectory: String,
        runtimeArguments: [String],
        simulator: SelectedSimulator?,
        statusPath: String,
        acknowledgementPath: String?
    ) -> RunnerLaunchSpecification {
        var environment = configuredEnvironment(for: action)
        if let simulator {
            environment["CODEX_SIMULATOR_UDID"] = simulator.udid
            environment["CODEX_SIMULATOR_NAME"] = simulator.name
        }
        let suppliedArguments = action.arguments + runtimeArguments
        let arguments: [String]
        let shellCommand: String?
        if action.runner == .shell {
            var command = action.shellCommand
            if isExpoAction(action), let value = command {
                command = adaptedExpoShellCommand(value, action: action)
            }
            if !suppliedArguments.isEmpty, let command {
                shellCommand = ([command] + suppliedArguments.map(ShellEscaping.quote)).joined(separator: " ")
            } else {
                shellCommand = command
            }
            arguments = []
        } else {
            arguments = isExpoAction(action)
                ? adaptedExpoArguments(suppliedArguments, action: action)
                : suppliedArguments
            shellCommand = nil
        }
        return RunnerLaunchSpecification(
            schemaVersion: 1,
            runID: runID,
            workingDirectory: workingDirectory,
            executable: action.runner == .shell ? nil : action.executable,
            arguments: arguments,
            shellCommand: shellCommand,
            environment: environment,
            portEnvironmentVariable: action.port.mode == .none ? nil : action.port.environmentVariable,
            hostEnvironmentVariable: action.port.mode == .none ? nil : action.port.hostEnvironmentVariable,
            statusPath: statusPath,
            acknowledgementPath: acknowledgementPath
        )
    }

    private func validateEnvironmentOwnership(_ action: LaunchAction) throws {
        let reserved = Set(["CODEX_PORT", "CODEX_HOST", "CODEX_SERVICE_ID"])
        if let name = action.environment.keys.first(where: { reserved.contains($0) }) {
            throw ProcessSupervisorError.reservedEnvironmentVariable(name)
        }
        if let name = action.inheritedEnvironment.first(where: { reserved.contains($0) }) {
            throw ProcessSupervisorError.reservedEnvironmentVariable(name)
        }
    }

    private func configuredEnvironment(for action: LaunchAction) -> [String: String] {
        var environment: [String: String] = [:]
        let daemonEnvironment = ProcessInfo.processInfo.environment
        for name in action.inheritedEnvironment {
            if let value = daemonEnvironment[name] { environment[name] = value }
        }
        for (name, value) in action.environment {
            environment[name] = value
        }
        return environment
    }

    private func applicationEnvironment(for action: LaunchAction) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        var environment: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "SHELL": "/bin/zsh",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "PATH": Self.baselinePath(home: home),
        ]
        for (name, value) in configuredEnvironment(for: action) {
            environment[name] = value
        }
        // NSWorkspace needs no daemon-private variables. Only baseline and explicitly
        // configured/inherited values cross the LaunchServices boundary.
        return environment
    }

    private static func baselinePath(home: String) -> String {
        [
            "\(home)/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }

    private func adaptedExpoArguments(_ source: [String], action: LaunchAction) -> [String] {
        var arguments = source
        let hasHostMode = arguments.contains { value in
            value == "--localhost" || value == "--lan" || value == "--tunnel" ||
                value == "--host" || value.hasPrefix("--host=")
        }
        if !hasHostMode { arguments.append("--localhost") }
        let hasPort = arguments.contains { $0 == "--port" || $0.hasPrefix("--port=") }
        if action.port.mode != .none, !hasPort {
            arguments.append(contentsOf: ["--port", "${CODEX_PORT}"])
        }
        if action.openTarget == .simulator,
           !arguments.contains("--ios"),
           !arguments.contains("-i") {
            arguments.append("--ios")
        }
        return arguments
    }

    private func adaptedExpoShellCommand(_ source: String, action: LaunchAction) -> String {
        var additions: [String] = []
        if source.range(of: #"(^|\s)--(localhost|lan|tunnel|host)(=|\s|$)"#, options: .regularExpression) == nil {
            additions.append("--localhost")
        }
        if action.port.mode != .none,
           source.range(of: #"(^|\s)--port(=|\s|$)"#, options: .regularExpression) == nil {
            additions.append(#"--port "${CODEX_PORT}""#)
        }
        if action.openTarget == .simulator,
           source.range(of: #"(^|\s)(--ios|-i)(\s|$)"#, options: .regularExpression) == nil {
            additions.append("--ios")
        }
        return additions.isEmpty ? source : ([source] + additions).joined(separator: " ")
    }

    private func prepareSimulator(action: LaunchAction, workingDirectory: String) async throws -> SelectedSimulator {
        guard FileManager.default.isExecutableFile(atPath: xcrunURL.path) else {
            throw ProcessSupervisorError.simulatorUnavailable("xcrun is unavailable at \(xcrunURL.path)")
        }
        let listed = try await runSimulatorCommand(["simctl", "list", "devices", "available", "--json"])
        guard let data = listed.stdout.data(using: .utf8),
              let deviceList = try? JSONDecoder().decode(SimulatorDeviceList.self, from: data) else {
            throw ProcessSupervisorError.invalidSimulatorConfiguration("simctl returned invalid device JSON: \(listed.combinedOutput)")
        }

        let runtimeKeys = deviceList.devices.keys
            .filter { $0.contains(".SimRuntime.iOS-") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        let candidates = runtimeKeys.flatMap { deviceList.devices[$0] ?? [] }
            .filter { $0.isAvailable != false }
        let selector = action.environment["CODEX_SIMULATOR_DEVICE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let device: SimulatorDevice?
        if let selector, !selector.isEmpty, selector.lowercased() != "booted" {
            device = candidates.first {
                $0.udid.caseInsensitiveCompare(selector) == .orderedSame ||
                    $0.name.caseInsensitiveCompare(selector) == .orderedSame
            }
        } else if selector?.lowercased() == "booted" {
            device = candidates.first { $0.state.caseInsensitiveCompare("Booted") == .orderedSame }
        } else {
            device = candidates.first { $0.state.caseInsensitiveCompare("Booted") == .orderedSame }
                ?? candidates.first
        }
        guard let device else {
            let requested = selector.map { "requested device '\($0)' was not found" } ?? "simctl listed no available iOS devices"
            throw ProcessSupervisorError.simulatorUnavailable(requested)
        }

        let wasBooted = device.state.caseInsensitiveCompare("Booted") == .orderedSame
        if !wasBooted {
            _ = try await runSimulatorCommand(["simctl", "boot", device.udid])
        }
        _ = try await runSimulatorCommand(["simctl", "bootstatus", device.udid, "-b"])

        guard FileManager.default.isExecutableFile(atPath: simulatorOpenURL.path) else {
            throw ProcessSupervisorError.simulatorUnavailable("Simulator opener is unavailable at \(simulatorOpenURL.path)")
        }
        let opened = try await execute(
            executable: simulatorOpenURL,
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.udid]
        )
        guard opened.status == 0 else {
            throw ProcessSupervisorError.simulatorCommandFailed(
                command: "open -a Simulator --args -CurrentDeviceUDID \(device.udid)",
                status: opened.status,
                output: opened.combinedOutput
            )
        }

        var bundleIdentifier = action.environment["CODEX_SIMULATOR_BUNDLE_ID"]
        if let configuredPath = action.environment["CODEX_SIMULATOR_APP_PATH"], !configuredPath.isEmpty {
            let expanded = NSString(string: configuredPath).expandingTildeInPath
            let appURL = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: workingDirectory).appendingPathComponent(expanded)
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                throw ProcessSupervisorError.invalidSimulatorConfiguration("app bundle does not exist: \(appURL.path)")
            }
            _ = try await runSimulatorCommand(["simctl", "install", device.udid, appURL.standardizedFileURL.path])
            bundleIdentifier = bundleIdentifier ?? Bundle(url: appURL)?.bundleIdentifier
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            var launchArguments: [String] = []
            if let encoded = action.environment["CODEX_SIMULATOR_APP_ARGUMENTS"], !encoded.isEmpty {
                guard let data = encoded.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                    throw ProcessSupervisorError.invalidSimulatorConfiguration("CODEX_SIMULATOR_APP_ARGUMENTS must be a JSON string array")
                }
                launchArguments = decoded
            }
            _ = try await runSimulatorCommand(["simctl", "launch", device.udid, bundleIdentifier] + launchArguments)
        }

        return SelectedSimulator(udid: device.udid, name: device.name, wasAlreadyBooted: wasBooted)
    }

    private func runSimulatorCommand(_ arguments: [String]) async throws -> CommandResult {
        let result = try await execute(executable: xcrunURL, arguments: arguments)
        guard result.status == 0 else {
            throw ProcessSupervisorError.simulatorCommandFailed(
                command: (["xcrun"] + arguments).map(ShellEscaping.quote).joined(separator: " "),
                status: result.status,
                output: result.combinedOutput
            )
        }
        return result
    }

    private func prepareRunPaths(
        sessionID: UUID,
        runID: UUID,
        actionName: String
    ) throws -> (specification: URL, status: URL, acknowledgement: URL, log: URL) {
        let specs = runtimeDirectory.appendingPathComponent("Runner Specifications", isDirectory: true)
        let statuses = runtimeDirectory.appendingPathComponent("Runner Status", isDirectory: true)
        let acknowledgements = runtimeDirectory.appendingPathComponent("Runner Acknowledgements", isDirectory: true)
        let logs = runtimeDirectory.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true)
        for directory in [specs, statuses, acknowledgements, logs] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let slug = actionName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return (
            specs.appendingPathComponent("\(runID.uuidString).json"),
            statuses.appendingPathComponent("\(runID.uuidString).json"),
            acknowledgements.appendingPathComponent("\(runID.uuidString).json"),
            logs.appendingPathComponent("\(runID.uuidString)-\(slug).log")
        )
    }

    private func writeSpecification(_ specification: RunnerLaunchSpecification, to url: URL) throws {
        let encoder = LauncherJSON.encoder(pretty: true)
        let data = try encoder.encode(specification)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeAcknowledgement(_ acknowledgement: RunnerAcknowledgement, to url: URL) throws {
        let data = try LauncherJSON.encoder(pretty: false).encode(acknowledgement)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A daemon can terminate after durable registration but before writing the start-gate
    /// acknowledgement. The acknowledgement path is deterministic from the durable run ID, so a
    /// later daemon can safely finish that handoff after proving the same birth identity and group.
    private func releaseRecoveredRunnerIfNeeded(_ record: ActionRunRecord) throws -> Bool {
        guard record.manager == .processGroup,
              record.managerID == "runner:\(record.id.uuidString)",
              let pid = record.pid,
              let processGroupID = record.processGroupID,
              let pidStartIdentity = record.pidStartIdentity,
              processGroupID == pid,
              ProcessBirthIdentity.matches(pid: pid, serialized: pidStartIdentity),
              getpgid(pid) == processGroupID else { return false }

        let acknowledgementURL = runtimeDirectory
            .appendingPathComponent("Runner Acknowledgements", isDirectory: true)
            .appendingPathComponent("\(record.id.uuidString).json")
        guard !FileManager.default.fileExists(atPath: acknowledgementURL.path) else { return false }
        try writeAcknowledgement(
            RunnerAcknowledgement(
                schemaVersion: 1,
                runID: record.id,
                pid: pid,
                pidStartIdentity: pidStartIdentity
            ),
            to: acknowledgementURL
        )
        return true
    }

    /// Registration failure happens while the runner is still the exact group leader and before it
    /// can spawn the requested command. Kill only that corroborated group and wait briefly for the
    /// birth identity to disappear; no tracking callback is installed for an unregistered run.
    private func terminateUnreleasedRunner(_ status: RunnerStatus, process: Process) async {
        guard status.pid == process.processIdentifier,
              status.processGroupID == status.pid,
              ProcessBirthIdentity.matches(pid: status.pid, serialized: status.pidStartIdentity),
              getpgid(status.pid) == status.processGroupID else { return }
        _ = kill(-status.processGroupID, SIGKILL)

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline,
              ProcessBirthIdentity.matches(pid: status.pid, serialized: status.pidStartIdentity) {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                break
            }
        }
    }

    private func isVerifiedRunner(_ status: RunnerStatus, process: Process) -> Bool {
        process.isRunning
            && process.processIdentifier == status.pid
            && status.processGroupID == status.pid
            && ProcessBirthIdentity.matches(pid: status.pid, serialized: status.pidStartIdentity)
            && getpgid(status.pid) == status.processGroupID
    }

    private func waitForRunnerStatus(at url: URL, runID: UUID, process: Process, timeoutSeconds: Int) async throws -> RunnerStatus {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        let decoder = LauncherJSON.decoder()
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let status = try? decoder.decode(RunnerStatus.self, from: data),
               status.schemaVersion == 1,
               status.runID == runID,
               status.pid == process.processIdentifier,
               ProcessBirthIdentity.matches(pid: status.pid, serialized: status.pidStartIdentity),
               status.processGroupID == status.pid {
                return status
            }
            if !process.isRunning {
                throw ProcessSupervisorError.runnerHandshakeFailed("runner exited with status \(process.terminationStatus)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            if let identity = ProcessBirthIdentity(pid: pid), identity.pid == pid {
                let group = getpgid(pid)
                if group == pid {
                    _ = kill(-group, SIGKILL)
                } else {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
        throw ProcessSupervisorError.runnerHandshakeFailed("timed out waiting for exact PID/PGID handshake")
    }

    private func runnerExecutableURL() throws -> URL {
        let commandExecutable = CommandLine.arguments.first.flatMap { rawPath -> URL? in
            let expanded = NSString(string: rawPath).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let daemonExecutables = [Bundle.main.executableURL, commandExecutable].compactMap { $0 }
        let adjacentRunners = daemonExecutables.map {
            $0.deletingLastPathComponent().appendingPathComponent("launchstation-runner")
        }
        let bundledRunners = daemonExecutables.compactMap { executable -> URL? in
            // Normalize Bundle-provided executable URLs to an independent path-backed
            // file URL before traversing ancestors. This mirrors LauncherRuntimeVersion
            // and guarantees the walk terminates for source-built daemon executables.
            var cursor = URL(
                fileURLWithPath: executable.path,
                isDirectory: false
            ).standardizedFileURL.deletingLastPathComponent()
            while cursor.path != "/" {
                if cursor.pathExtension.lowercased() == "app" {
                    return cursor.appendingPathComponent(
                        "Contents/Helpers/launchstation-runner",
                        isDirectory: false
                    )
                }
                cursor.deleteLastPathComponent()
            }
            return nil
        }
        let candidates = [
            configuredRunnerURL,
        ].compactMap { $0 }
            + adjacentRunners
            + bundledRunners
            + [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/debug/launchstation-runner"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/release/launchstation-runner"),
            ]
        if let available = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return available
        }
        throw ProcessSupervisorError.runnerUnavailable(candidates.map(\.path).joined(separator: ", "))
    }

    private func resolveApplicationURL(target: String, bundleIdentifier: String?) throws -> URL {
        let expanded = NSString(string: target).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        if let identifier = bundleIdentifier ?? (target.contains(".") ? target : nil),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        throw ProcessSupervisorError.applicationUnavailable(target)
    }

    private func storedOpenContext(
        optionID: String,
        session: SessionRecord
    ) throws -> (option: SessionOpenOption, run: ActionRunRecord, action: LaunchAction?) {
        guard let option = SessionOpenOptionDeriver.option(id: optionID, in: session),
              option.sessionID == session.id,
              let run = session.actionRuns.first(where: { $0.id == option.actionRunID }),
              run.actionID == option.actionID,
              run.state == .running else {
            throw ProcessSupervisorError.invalidSessionOpenOption(optionID)
        }
        let action = session.actionSnapshots?.first { $0.id == run.actionID }
        return (option, run, action)
    }

    private func requireExactOpenOwner(_ record: ActionRunRecord) throws {
        guard let pid = record.pid,
              ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) else {
            throw ProcessSupervisorError.sessionOpenUnavailable(
                "the action's exact PID/birth identity is no longer live"
            )
        }
    }

    private func focusStoredSimulator(for record: ActionRunRecord) async throws -> String {
        guard let udid = record.simulatorUDID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !udid.isEmpty else {
            throw ProcessSupervisorError.invalidSessionOpenOption(
                SessionOpenOptionDeriver.optionID(actionRunID: record.id, kind: .simulator)
            )
        }
        guard FileManager.default.isExecutableFile(atPath: xcrunURL.path) else {
            throw ProcessSupervisorError.sessionOpenUnavailable("xcrun is unavailable at \(xcrunURL.path)")
        }
        let listed = try await runSimulatorCommand(["simctl", "list", "devices", "available", "--json"])
        guard let data = listed.stdout.data(using: .utf8),
              let deviceList = try? JSONDecoder().decode(SimulatorDeviceList.self, from: data) else {
            throw ProcessSupervisorError.invalidSimulatorConfiguration(
                "simctl returned invalid device JSON: \(listed.combinedOutput)"
            )
        }
        let device = deviceList.devices.values
            .flatMap { $0 }
            .first { $0.udid == udid && $0.isAvailable != false }
        guard let device else {
            throw ProcessSupervisorError.sessionOpenUnavailable(
                "Simulator device \(udid) is no longer available"
            )
        }
        guard device.state.caseInsensitiveCompare("Booted") == .orderedSame else {
            throw ProcessSupervisorError.sessionOpenUnavailable(
                "Simulator device \(udid) is no longer booted; focus will not boot or claim it"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: simulatorOpenURL.path) else {
            throw ProcessSupervisorError.sessionOpenUnavailable(
                "Simulator opener is unavailable at \(simulatorOpenURL.path)"
            )
        }
        let opened = try await execute(
            executable: simulatorOpenURL,
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        )
        guard opened.status == 0 else {
            throw ProcessSupervisorError.simulatorCommandFailed(
                command: "open -a Simulator --args -CurrentDeviceUDID \(udid)",
                status: opened.status,
                output: opened.combinedOutput
            )
        }
        return "Focused Simulator device \(device.name) (\(udid)) without claiming its lifecycle."
    }

    private func performExpoControlRequest(
        url: URL,
        method: String
    ) async throws -> (status: Int, output: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(helperCommandTimeoutSeconds, 15)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json, text/plain;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProcessSupervisorError.sessionOpenUnavailable(
                "the already-running Expo server could not be reached: \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProcessSupervisorError.sessionOpenUnavailable(
                "the Expo control endpoint returned a non-HTTP response"
            )
        }
        let retained = data.prefix(4_096)
        var output = String(decoding: retained, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if data.count > retained.count {
            let marker = "[response truncated: retained first \(retained.count) of \(data.count) bytes]"
            output = output.isEmpty ? marker : output + "\n" + marker
        }
        return (http.statusCode, output)
    }

    private func renderedEndpoint(action: LaunchAction, host: String, port: Int) -> String {
        let template = action.port.URLTemplate ?? action.healthCheckURL ?? "http://${HOST}:${PORT}"
        return template
            .replacingOccurrences(of: "${HOST}", with: host)
            .replacingOccurrences(of: "${PORT}", with: String(port))
            .replacingOccurrences(of: "{{host}}", with: host)
            .replacingOccurrences(of: "{{port}}", with: String(port))
            .replacingOccurrences(of: "{host}", with: host)
            .replacingOccurrences(of: "{port}", with: String(port))
    }

    private func isExpoAction(_ action: LaunchAction) -> Bool {
        SessionOpenOptionDeriver.isExpoAction(action)
    }

    private func track(_ record: ActionRunRecord, process: Process?, onUpdate: @escaping UpdateHandler) {
        guard let pid = record.pid else { return }
        records[record.id] = record
        handlers[record.id] = onUpdate
        if let process { nativeProcesses[record.id] = process }
        monitors[record.id]?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: monitorQueue)
        source.setEventHandler { [weak self] in
            Task { await self?.observedExit(runID: record.id) }
        }
        monitors[record.id] = source
        source.resume()
        if !ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) {
            Task { self.observedExit(runID: record.id) }
        }
    }

    private func observedExit(runID: UUID) {
        guard var record = records[runID],
              record.state == .starting || record.state == .running || record.state == .stopping else { return }
        if let pid = record.pid, ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) {
            return
        }
        let process = nativeProcesses[runID]
        let exitCode: Int32? = process.flatMap { process in
            process.isRunning ? nil : process.terminationStatus
        }
        record.state = (exitCode ?? 0) == 0 ? .exited : .failed
        record.endedAt = Date()
        record.exitCode = exitCode
        record.message = exitCode.map { "Process exited with status \($0)." } ?? "Process exited."
        let handler = handlers[runID]
        finishTracking(record)
        handler?(record)
    }

    private func finishTracking(_ record: ActionRunRecord) {
        records[record.id] = record
        monitors.removeValue(forKey: record.id)?.cancel()
        nativeProcesses.removeValue(forKey: record.id)
        handlers.removeValue(forKey: record.id)
    }

    private func terminalized(_ source: ActionRunRecord, state: ActionRunState, message: String) -> ActionRunRecord {
        var record = source
        record.state = state
        record.endedAt = Date()
        record.message = message
        return record
    }

    private func waitUntilIdentityEnds(_ record: ActionRunRecord, seconds: Int) async -> Bool {
        guard let pid = record.pid else { return true }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if !ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity)
    }

    private func codexPortRecords() async throws -> [CodexPortRecord] {
        let result = try await execute(executable: codexPortURL, arguments: ["list", "--json"])
        guard result.status == 0 else {
            throw ProcessSupervisorError.managedCommandFailed(
                command: "codex-port list --json",
                status: result.status,
                output: result.combinedOutput
            )
        }
        guard let data = result.stdout.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([CodexPortRecord].self, from: data)
        } catch {
            throw ProcessSupervisorError.invalidManagedResponse(result.combinedOutput)
        }
    }

    /// Reads only a bounded suffix from a manager-owned log. It is used for diagnosis after a
    /// launch failure; the project command is never re-run and arbitrary paths are not accepted.
    private func readRunLogTail(path: String, maximumBytes: UInt64 = 128 * 1_024) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > maximumBytes ? end - maximumBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func execute(executable: URL, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in exitSemaphore.signal() }
        try process.run()

        let pid = process.processIdentifier
        let birthIdentity = ProcessBirthIdentity(pid: pid)?.serialized
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let outputLimit = 4 * 1_024 * 1_024
        let drainControl = PipeDrainControl()
        let stdoutDescriptor = stdout.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderr.fileHandleForReading.fileDescriptor
        Self.configureNonblocking(stdoutDescriptor)
        Self.configureNonblocking(stderrDescriptor)
        let stdoutTask = Task.detached(priority: .utility) {
            Self.readBoundedOutput(
                from: stdoutDescriptor,
                limit: outputLimit,
                control: drainControl
            )
        }
        let stderrTask = Task.detached(priority: .utility) {
            Self.readBoundedOutput(
                from: stderrDescriptor,
                limit: outputLimit,
                control: drainControl
            )
        }

        var didExit = await Self.waitForExit(exitSemaphore, timeout: helperCommandTimeoutSeconds)
        let timedOut = !didExit
        if timedOut {
            if ProcessBirthIdentity.matches(pid: pid, serialized: birthIdentity) {
                _ = kill(pid, SIGTERM)
            }
            let grace = min(2, max(0.25, helperCommandTimeoutSeconds * 0.1))
            didExit = await Self.waitForExit(exitSemaphore, timeout: grace)
            if !didExit, ProcessBirthIdentity.matches(pid: pid, serialized: birthIdentity) {
                _ = kill(pid, SIGKILL)
            }
            if !didExit {
                didExit = await Self.waitForExit(exitSemaphore, timeout: 2)
            }
        }

        // Nonblocking readers drain everything already buffered by the direct helper, then stop
        // on EAGAIN. This remains bounded even if an unowned descendant inherited a write end.
        drainControl.stop()
        let capturedStdout = await stdoutTask.value
        let capturedStderr = await stderrTask.value
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        let renderedStdout = capturedStdout.rendered(streamName: "stdout")
        let renderedStderr = capturedStderr.rendered(streamName: "stderr")
        if timedOut {
            let command = ([executable.path] + arguments).map(ShellEscaping.quote).joined(separator: " ")
            let output = [renderedStdout, renderedStderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw ProcessSupervisorError.helperCommandTimedOut(
                command: command,
                output: output.isEmpty ? "No output was captured before timeout." : output
            )
        }
        return CommandResult(
            status: process.terminationStatus,
            stdout: renderedStdout,
            stderr: renderedStderr
        )
    }

    private nonisolated static func configureNonblocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private nonisolated static func readBoundedOutput(
        from descriptor: Int32,
        limit: Int,
        control: PipeDrainControl
    ) -> BoundedCommandOutput {
        var retained = Data()
        var totalBytes = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var readsAfterStop = 0
        let maximumReadsAfterStop = 8
        while true {
            if control.shouldStop, readsAfterStop >= maximumReadsAfterStop {
                break
            }
            let stopWasRequested = control.shouldStop
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                totalBytes += count
                let remaining = max(0, limit - retained.count)
                if remaining > 0 {
                    retained.append(contentsOf: buffer.prefix(min(count, remaining)))
                }
                if stopWasRequested || control.shouldStop {
                    readsAfterStop += 1
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if control.shouldStop { break }
                usleep(5_000)
                continue
            }
            break
        }
        return BoundedCommandOutput(retained: retained, totalBytes: totalBytes)
    }

    private nonisolated static func waitForExit(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + timeout) == .success
                )
            }
        }
    }
}
