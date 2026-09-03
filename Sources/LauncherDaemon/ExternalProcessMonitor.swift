import Darwin
import Foundation
import LauncherCore

protocol ExternalProcessInspectionProviding: Sendable {
    func scanListeners(timeout: TimeInterval) async throws -> MacListenerScan
    func inspect(pid: Int32, shortCommand: String?) -> MacInspectedProcess?
}

extension MacProcessInspector: ExternalProcessInspectionProviding {}

struct SecuredExternalObservation: Sendable {
    var observation: ExternalProcessObservation
    var security: ExternalObservationSecurityContext
}

protocol ExternalObservationProviding: Sendable {
    func freshSecuredObservation(
        id: UUID,
        correlation: ExternalCorrelationInput
    ) async throws -> SecuredExternalObservation?
}

/// Ephemeral, actor-isolated inventory. It deliberately has no SQLite/file persistence and keeps
/// the daemon-only confirmation fingerprints separate from public observations.
actor ExternalProcessMonitor: ExternalObservationProviding {
    private let inspector: any ExternalProcessInspectionProviding
    private let scanTimeout: TimeInterval
    private let currentUserID: UInt32
    private let excludedPIDs: Set<Int32>
    private var observationIDsByProcessIdentity: [String: UUID] = [:]
    private var securedByID: [UUID: SecuredExternalObservation] = [:]
    private var lastSnapshot: ExternalProcessSnapshot?

    init(
        inspector: any ExternalProcessInspectionProviding = MacProcessInspector(),
        scanTimeout: TimeInterval = 2,
        excludedPIDs: Set<Int32> = []
    ) {
        self.inspector = inspector
        self.scanTimeout = max(0.1, min(scanTimeout, 10))
        self.excludedPIDs = excludedPIDs
        currentUserID = geteuid()
    }

    @discardableResult
    func refresh(correlation: ExternalCorrelationInput) async -> ExternalProcessSnapshot {
        let scannedAt = Date()
        do {
            let scan = try await inspector.scanListeners(timeout: scanTimeout)
            var nextSecured: [UUID: SecuredExternalObservation] = [:]
            var activeKeys = Set<String>()

            for listener in scan.inventory.processes {
                // The daemon's loopback API is an implementation detail, not a separately
                // started project listener. Excluding it also prevents a misleading "Add
                // Launcher" path for Launcher itself after every daemon restart.
                guard !excludedPIDs.contains(listener.pid) else { continue }
                guard let inspected = inspector.inspect(pid: listener.pid, shortCommand: listener.shortCommand) else {
                    continue
                }
                let processKey = "\(inspected.pid)|\(inspected.pidStartIdentity)"
                activeKeys.insert(processKey)
                let observationID = observationIDsByProcessIdentity[processKey] ?? UUID()
                observationIDsByProcessIdentity[processKey] = observationID

                let ownership = classify(inspected, correlation: correlation)
                let closePolicy = closePolicy(
                    for: inspected,
                    ownership: ownership,
                    protectedPIDs: Set(correlation.protectedPIDs)
                )
                let observation = ExternalProcessObservation(
                    id: observationID,
                    pid: inspected.pid,
                    pidStartIdentity: inspected.pidStartIdentity,
                    startedAt: inspected.startedAt,
                    userID: inspected.userID,
                    parentPID: inspected.parentPID,
                    processGroupID: inspected.processGroupID,
                    processGroupLeaderPID: inspected.processGroupLeaderPID,
                    processGroupLeaderStartIdentity: inspected.processGroupLeaderStartIdentity,
                    executablePath: inspected.executablePath,
                    executableIdentity: inspected.executableIdentity,
                    workingDirectory: inspected.workingDirectory,
                    command: inspected.command,
                    endpoints: listener.endpoints,
                    ownership: ownership,
                    observedAt: scannedAt,
                    canClose: closePolicy.allowed,
                    closeDisabledReason: closePolicy.reason
                )
                let security = ExternalObservationSecurityContext(
                    pid: inspected.pid,
                    pidStartIdentity: inspected.pidStartIdentity,
                    userID: inspected.userID,
                    parentPID: inspected.parentPID,
                    processGroupID: inspected.processGroupID,
                    processGroupLeaderPID: inspected.processGroupLeaderPID,
                    processGroupLeaderStartIdentity: inspected.processGroupLeaderStartIdentity,
                    listenerExecutablePath: inspected.executablePath,
                    listenerExecutableIdentity: inspected.executableIdentity,
                    listenerWorkingDirectory: inspected.workingDirectory,
                    commandDigest: inspected.commandDigest,
                    endpoints: listener.endpoints,
                    ownershipKind: ownership.kind,
                    codexPortManagerID: ownership.codexPortManagerID
                )
                nextSecured[observationID] = SecuredExternalObservation(
                    observation: observation,
                    security: security
                )
            }

            observationIDsByProcessIdentity = observationIDsByProcessIdentity.filter {
                activeKeys.contains($0.key)
            }
            securedByID = nextSecured
            let observations = nextSecured.values.map(\.observation).sorted(by: observationSort)
            let snapshot = ExternalProcessSnapshot(
                scannedAt: scannedAt,
                observations: observations,
                isComplete: scan.isComplete,
                warning: scan.warning
            )
            lastSnapshot = snapshot
            return snapshot
        } catch {
            let message = ExternalCommandRedactor
                .sanitizeDisplayText(error.localizedDescription, maximumScalars: 1_024)
                .value
            if var stale = lastSnapshot {
                stale.isComplete = false
                stale.isStale = true
                stale.warning = message
                return stale
            }
            return ExternalProcessSnapshot(
                scannedAt: scannedAt,
                observations: [],
                isComplete: false,
                isStale: true,
                warning: message
            )
        }
    }

    /// Listener discovery requires `lsof` followed by per-process identity inspection. Ten
    /// seconds remains responsive for an observed process list while preventing a continuously
    /// running launcher from rescanning the whole machine every few seconds.
    func cachedSnapshot(maximumAge: TimeInterval = 10, now: Date = Date()) -> ExternalProcessSnapshot? {
        guard var snapshot = lastSnapshot else { return nil }
        if now.timeIntervalSince(snapshot.scannedAt) > max(0, maximumAge) {
            snapshot.isStale = true
        }
        return snapshot
    }

    func observation(id: UUID) -> ExternalProcessObservation? {
        securedByID[id]?.observation
    }

    func draftProposal(id: UUID) -> ExternalLauncherDraft? {
        securedByID[id].map { ExternalLauncherDraftProposal.make(from: $0.observation) }
    }

    func freshSecuredObservation(
        id: UUID,
        correlation: ExternalCorrelationInput
    ) async throws -> SecuredExternalObservation? {
        let snapshot = await refresh(correlation: correlation)
        guard snapshot.isComplete, !snapshot.isStale else {
            throw ExternalInspectionError.commandFailed(
                snapshot.warning ?? "A fresh complete listener scan was unavailable."
            )
        }
        return securedByID[id]
    }

    private func classify(
        _ process: MacInspectedProcess,
        correlation: ExternalCorrelationInput
    ) -> ExternalProcessOwnership {
        let launcherMatches = correlation.launcherRuns.filter { candidate in
            if candidate.pid == process.pid,
               candidate.pidStartIdentity == process.pidStartIdentity {
                return true
            }
            return candidate.processGroupID == process.processGroupID
                && candidate.pid == process.processGroupLeaderPID
                && candidate.pidStartIdentity == process.processGroupLeaderStartIdentity
        }

        let codexPortMatches = correlation.codexPortRuns.filter { candidate in
            let listenerMatches = candidate.listenerPIDs.isEmpty
                || candidate.listenerPIDs.contains(process.pid)
            return listenerMatches
                && candidate.processGroupID == process.processGroupID
                && candidate.pid == process.processGroupLeaderPID
                && candidate.pidStartIdentity == process.processGroupLeaderStartIdentity
        }

        if launcherMatches.count == 1, let launcher = launcherMatches.first {
            if codexPortMatches.isEmpty
                || codexPortMatches.count == 1 && codexPortMatches.first?.managerID == launcher.managerID {
                return ExternalProcessOwnership(
                    kind: .launcherOwned,
                    launcherID: launcher.launcherID,
                    sessionID: launcher.sessionID,
                    actionRunID: launcher.actionRunID,
                    codexPortManagerID: launcher.managerID,
                    message: "This listener belongs to an exact active Launch Station session."
                )
            }
        }

        if launcherMatches.count > 1 || codexPortMatches.count > 1
            || !launcherMatches.isEmpty && !codexPortMatches.isEmpty {
            return ExternalProcessOwnership(
                kind: .ambiguous,
                message: "More than one lifecycle record matched this process; no ownership was assumed."
            )
        }

        if let managed = codexPortMatches.first {
            return ExternalProcessOwnership(
                kind: .codexPort,
                codexPortManagerID: managed.managerID,
                message: "This listener was started separately and remains owned by codex-port manager \(managed.managerID)."
            )
        }
        if !launcherMatches.isEmpty {
            return ExternalProcessOwnership(
                kind: .ambiguous,
                message: "A Launcher record partly matched, but exact lifecycle ownership could not be proven."
            )
        }
        return .external
    }

    private func closePolicy(
        for process: MacInspectedProcess,
        ownership: ExternalProcessOwnership,
        protectedPIDs: Set<Int32>
    ) -> (allowed: Bool, reason: String?) {
        if process.pid <= 1 || protectedPIDs.contains(process.pid)
            || process.processGroupLeaderPID.map({ protectedPIDs.contains($0) }) == true {
            return (false, "This is a protected Launcher or system process.")
        }
        guard process.userID == currentUserID else {
            return (false, "Launcher will not stop a process owned by another user.")
        }
        switch ownership.kind {
        case .launcherOwned:
            return (false, "Close this process through its exact Launcher session instead.")
        case .ambiguous:
            return (false, "Lifecycle ownership is ambiguous, so Launcher will not signal this process.")
        case .codexPort:
            guard ownership.codexPortManagerID != nil else {
                return (false, "The exact codex-port manager ID is unavailable.")
            }
            return (true, nil)
        case .external:
            guard process.executableIdentity != nil else {
                return (false, "The listener executable identity could not be verified.")
            }
            return (true, nil)
        }
    }

    private func observationSort(
        _ lhs: ExternalProcessObservation,
        _ rhs: ExternalProcessObservation
    ) -> Bool {
        let leftPort = lhs.endpoints.map(\.port).min() ?? Int.max
        let rightPort = rhs.endpoints.map(\.port).min() ?? Int.max
        if leftPort != rightPort { return leftPort < rightPort }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
