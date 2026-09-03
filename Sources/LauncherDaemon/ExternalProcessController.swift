import Darwin
import Foundation
import LauncherCore

enum ExternalProcessControlError: LocalizedError, Sendable {
    case notFound(String)
    case notClosable(String)
    case confirmationRequired(String)
    case stale(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let message), .notClosable(let message), .confirmationRequired(let message),
             .stale(let message), .operationFailed(let message):
            return message
        }
    }
}

enum ExternalGracefulStopStatus: Sendable {
    case stopped
    case alreadyExited
    case identityChanged
    case stillRunning
    case signalFailed(String)
}

protocol ExternalProcessSignaling: Sendable {
    func stopExact(
        security: ExternalObservationSecurityContext,
        timeout: TimeInterval
    ) async -> ExternalGracefulStopStatus
}

enum ExternalCodexPortCloseStatus: Sendable {
    case closed
    case alreadyExited
}

protocol ExternalCodexPortClosing: Sendable {
    func closeExact(
        managerID: String,
        security: ExternalObservationSecurityContext
    ) async throws -> ExternalCodexPortCloseStatus
}

/// Stops only one freshly corroborated PID. Unlike Launcher-owned process groups, an external
/// process never receives automatic SIGKILL and this implementation never signals by name/port.
struct MacExternalProcessSignaler: ExternalProcessSignaling {
    func stopExact(
        security: ExternalObservationSecurityContext,
        timeout: TimeInterval = 6
    ) async -> ExternalGracefulStopStatus {
        switch identityState(security) {
        case .gone: return .alreadyExited
        case .changed: return .identityChanged
        case .matching: break
        }

        if kill(security.pid, SIGINT) != 0 {
            if errno == ESRCH { return .alreadyExited }
            return .signalFailed("Could not send SIGINT to the exact verified PID (errno \(errno)).")
        }
        let bounded = max(1, min(timeout, 20))
        switch await waitForIdentityChange(security, seconds: bounded * 0.5) {
        case .gone: return .stopped
        case .changed: return .identityChanged
        case .matching: break
        }

        switch identityState(security) {
        case .gone: return .stopped
        case .changed: return .identityChanged
        case .matching: break
        }
        if kill(security.pid, SIGTERM) != 0 {
            if errno == ESRCH { return .stopped }
            return .signalFailed("Could not send SIGTERM to the exact verified PID (errno \(errno)).")
        }
        switch await waitForIdentityChange(security, seconds: bounded * 0.5) {
        case .gone: return .stopped
        case .changed: return .identityChanged
        case .matching: break
        }

        switch identityState(security) {
        case .gone: return .stopped
        case .changed: return .identityChanged
        case .matching: return .stillRunning
        }
    }

    private enum IdentityState: Equatable {
        case matching
        case gone
        case changed
    }

    private func identityState(_ security: ExternalObservationSecurityContext) -> IdentityState {
        guard let current = ProcessBirthIdentity(pid: security.pid) else { return .gone }
        guard current.serialized == security.pidStartIdentity else { return .changed }
        guard getpgid(security.pid) == security.processGroupID else { return .changed }

        var info = proc_bsdinfo()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                security.pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard read == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == security.userID else {
            return .changed
        }
        guard executableIdentity(pid: security.pid) == security.listenerExecutableIdentity else {
            return .changed
        }
        return .matching
    }

    private func executableIdentity(pid: Int32) -> ExternalExecutableIdentity? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro that Swift does not import.
        let capacity = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(capacity))
        }
        guard count > 0,
              let path = buffer.withUnsafeBufferPointer({ pointer in
                  pointer.baseAddress.map { String(cString: $0) }
              }) else { return nil }
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { return nil }
        return ExternalExecutableIdentity(
            device: UInt64(bitPattern: Int64(attributes.st_dev)),
            inode: UInt64(attributes.st_ino)
        )
    }

    private func waitForIdentityChange(
        _ security: ExternalObservationSecurityContext,
        seconds: TimeInterval
    ) async -> IdentityState {
        let deadline = Date().addingTimeInterval(max(0.1, seconds))
        while Date() < deadline {
            let state = identityState(security)
            if state != .matching { return state }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return identityState(security)
            }
        }
        return identityState(security)
    }
}

/// Delegates a separately managed listener back to its exact codex-port owner. It re-reads the
/// manager registry and corroborates PID birth plus PGID before invoking `close --id`; failure
/// never falls back to direct signals.
struct MacCodexPortCloseDelegate: ExternalCodexPortClosing {
    private struct Record: Decodable, Sendable {
        var id: String
        var pid: Int32
        var pgid: Int32?
        var live: Bool?
    }

    private let executableURL: URL
    private let runner: BoundedExternalCommandRunner

    init(
        executableURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/codex-port"),
        runner: BoundedExternalCommandRunner = BoundedExternalCommandRunner()
    ) {
        self.executableURL = executableURL
        self.runner = runner
    }

    func closeExact(
        managerID: String,
        security: ExternalObservationSecurityContext
    ) async throws -> ExternalCodexPortCloseStatus {
        let executableURL = self.executableURL
        let runner = self.runner
        return try await Task.detached(priority: .utility) {
            let list = try runner.run(
                executable: executableURL,
                arguments: ["list", "--json"],
                timeout: 5
            )
            guard list.status == 0 else {
                throw ExternalProcessControlError.operationFailed(
                    "codex-port could not verify its manager registry (status \(list.status))."
                )
            }
            let records: [Record]
            do {
                records = try JSONDecoder().decode([Record].self, from: list.stdout)
            } catch {
                throw ExternalProcessControlError.operationFailed("codex-port returned an invalid manager registry.")
            }
            guard let record = records.first(where: { $0.id == managerID }) else {
                if ProcessBirthIdentity(pid: security.pid) == nil { return .alreadyExited }
                throw ExternalProcessControlError.stale("The exact codex-port manager is no longer active.")
            }
            guard record.live == true,
                  record.pgid == security.processGroupID,
                  record.pid == security.processGroupLeaderPID,
                  ProcessBirthIdentity.matches(
                    pid: record.pid,
                    serialized: security.processGroupLeaderStartIdentity
                  ) else {
                throw ExternalProcessControlError.stale(
                    "The codex-port manager identity changed after confirmation; nothing was closed."
                )
            }

            let close = try runner.run(
                executable: executableURL,
                arguments: [
                    "close", "--id", managerID,
                    "--reason", "Closed from Launch Station after exact external-process confirmation",
                ],
                timeout: 10
            )
            guard close.status == 0 else {
                throw ExternalProcessControlError.operationFailed(
                    "codex-port refused to close the exact manager (status \(close.status)); no direct signal was sent."
                )
            }
            return .closed
        }.value
    }
}

/// Holds short-lived confirmation capabilities in memory only. Both intent creation and execution
/// force a fresh listener scan. Exact security context equality is the stale/race boundary.
actor ExternalProcessController {
    private struct StoredIntent: Sendable {
        var token: String
        var observationID: UUID
        var expiresAt: Date
        var confirmationText: String
        var security: ExternalObservationSecurityContext
    }

    private let observations: any ExternalObservationProviding
    private let signaler: any ExternalProcessSignaling
    private let codexPort: any ExternalCodexPortClosing
    private let intentLifetime: TimeInterval
    private var intents: [UUID: StoredIntent] = [:]
    private var intentsInFlight = Set<UUID>()

    init(
        observations: any ExternalObservationProviding,
        signaler: any ExternalProcessSignaling = MacExternalProcessSignaler(),
        codexPort: any ExternalCodexPortClosing = MacCodexPortCloseDelegate(),
        intentLifetime: TimeInterval = 30
    ) {
        self.observations = observations
        self.signaler = signaler
        self.codexPort = codexPort
        self.intentLifetime = max(5, min(intentLifetime, 60))
    }

    func makeCloseIntent(
        observationID: UUID,
        correlation: ExternalCorrelationInput,
        now: Date = Date()
    ) async throws -> ExternalCloseIntent {
        pruneExpired(now: now)
        guard !intentsInFlight.contains(observationID) else {
            throw ExternalProcessControlError.confirmationRequired(
                "A close operation for this exact observation is already in progress."
            )
        }
        guard let secured = try await observations.freshSecuredObservation(
            id: observationID,
            correlation: correlation
        ) else {
            throw ExternalProcessControlError.notFound("The observed listener is no longer running.")
        }
        let observation = secured.observation
        guard observation.canClose else {
            throw ExternalProcessControlError.notClosable(
                observation.closeDisabledReason ?? "This listener cannot be safely closed by Launcher."
            )
        }
        guard observation.ownership.kind == .external || observation.ownership.kind == .codexPort else {
            throw ExternalProcessControlError.notClosable(
                "Use the exact Launcher session to close a Launcher-owned process."
            )
        }

        let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        let confirmation = "CLOSE \(observation.pid)"
        let expiresAt = now.addingTimeInterval(intentLifetime)
        intents[observationID] = StoredIntent(
            token: token,
            observationID: observationID,
            expiresAt: expiresAt,
            confirmationText: confirmation,
            security: secured.security
        )
        let portList = observation.endpoints.map { String($0.port) }.joined(separator: ", ")
        let warning: String
        if observation.ownership.kind == .codexPort {
            warning = "This separately started process will be closed only through its exact codex-port manager. Ports: \(portList)."
        } else {
            warning = "Launcher did not start this process. Confirmation permits graceful signals to exact PID \(observation.pid) only; SIGKILL is never automatic. Ports: \(portList)."
        }
        return ExternalCloseIntent(
            token: token,
            observationID: observationID,
            expiresAt: expiresAt,
            pid: observation.pid,
            startedAt: observation.startedAt,
            command: observation.command.displayCommand,
            endpoints: observation.endpoints,
            ownership: observation.ownership,
            warning: warning,
            confirmationText: confirmation
        )
    }

    func close(
        _ request: ExternalCloseRequest,
        correlation: ExternalCorrelationInput,
        now: Date = Date()
    ) async throws -> ExternalCloseResult {
        pruneExpired(now: now)
        guard let intent = intents[request.observationID],
              intent.observationID == request.observationID,
              intent.token == request.intentToken,
              intent.expiresAt > now else {
            throw ExternalProcessControlError.confirmationRequired(
                "The close confirmation expired or did not match. Inspect the current process and confirm again."
            )
        }
        guard request.confirmationText == intent.confirmationText else {
            throw ExternalProcessControlError.confirmationRequired(
                "Type the exact confirmation text shown for this process."
            )
        }
        guard intentsInFlight.insert(request.observationID).inserted else {
            throw ExternalProcessControlError.confirmationRequired(
                "A close operation for this exact observation is already in progress."
            )
        }
        defer {
            intentsInFlight.remove(request.observationID)
            if intents[request.observationID]?.token == request.intentToken {
                intents.removeValue(forKey: request.observationID)
            }
        }

        guard let fresh = try await observations.freshSecuredObservation(
            id: request.observationID,
            correlation: correlation
        ) else {
            return ExternalCloseResult(
                observationID: request.observationID,
                outcome: .alreadyExited,
                message: "The exact observed process had already exited; no signal was sent."
            )
        }
        guard fresh.security == intent.security,
              fresh.observation.canClose else {
            throw ExternalProcessControlError.stale(
                "The PID, executable, command context, ports, or lifecycle owner changed after confirmation; nothing was closed."
            )
        }

        switch fresh.observation.ownership.kind {
        case .codexPort:
            guard let managerID = fresh.observation.ownership.codexPortManagerID,
                  managerID == intent.security.codexPortManagerID else {
                throw ExternalProcessControlError.stale(
                    "The exact codex-port manager changed after confirmation; nothing was closed."
                )
            }
            let status = try await codexPort.closeExact(managerID: managerID, security: fresh.security)
            switch status {
            case .closed:
                return ExternalCloseResult(
                    observationID: request.observationID,
                    outcome: .delegatedToCodexPort,
                    message: "Closed the exact separately managed service through codex-port."
                )
            case .alreadyExited:
                return ExternalCloseResult(
                    observationID: request.observationID,
                    outcome: .alreadyExited,
                    message: "The exact codex-port process had already exited."
                )
            }

        case .external:
            let status = await signaler.stopExact(security: fresh.security, timeout: 6)
            switch status {
            case .stopped:
                return ExternalCloseResult(
                    observationID: request.observationID,
                    outcome: .stopped,
                    message: "The exact external PID exited after a graceful signal."
                )
            case .alreadyExited:
                return ExternalCloseResult(
                    observationID: request.observationID,
                    outcome: .alreadyExited,
                    message: "The exact external PID had already exited."
                )
            case .identityChanged:
                throw ExternalProcessControlError.stale(
                    "The PID identity changed before signaling completed; Launcher did not signal the replacement."
                )
            case .stillRunning:
                return ExternalCloseResult(
                    observationID: request.observationID,
                    outcome: .stillRunning,
                    message: "The exact PID remains live after SIGINT and SIGTERM. Force termination requires a new, separate confirmation and is not performed automatically."
                )
            case .signalFailed(let message):
                throw ExternalProcessControlError.operationFailed(
                    ExternalCommandRedactor.sanitizeDisplayText(message, maximumScalars: 1_024).value
                )
            }

        case .launcherOwned, .ambiguous:
            throw ExternalProcessControlError.stale(
                "Lifecycle ownership changed after confirmation; nothing was closed."
            )
        }
    }

    private func pruneExpired(now: Date) {
        intents = intents.filter { $0.value.expiresAt > now }
    }
}
