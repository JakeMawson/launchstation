import AppKit
import Darwin
import Foundation
import LauncherCore

private struct SyncRequest: Codable { var repair: Bool }
private struct DeleteActionRequest: Codable { var expectedRevision: Int }
private struct LogResponse: Codable { var text: String }

private struct DeleteAuthorization: Sendable {
    var token: String
    var launcherRevision: Int
    var expiresAt: Date
}

private struct SkillUninstallAuthorization: Sendable {
    var intent: LauncherSkillUninstallIntent
}

private struct StopAttempt: Sendable {
    var record: ActionRunRecord
    var performed: Bool
}

private enum LaunchControlFlow: Error {
    case stopRequested
}

private enum ServiceFailure: LocalizedError {
    case badRequest(String)
    case notFound(String)
    case conflict(String)
    case precondition(String)

    var errorDescription: String? {
        switch self {
        case .badRequest(let message), .notFound(let message), .conflict(let message), .precondition(let message):
            return message
        }
    }
}

actor LauncherService {
    private static let upgradeReservationLifetime: TimeInterval = 120
    private static let skillUninstallIntentLifetime: TimeInterval = 120
    private static let skillStatusCacheLifetime: TimeInterval = 30

    private let store: SQLiteStore
    private let supervisor: ProcessSupervisor
    private let skillManager: LauncherSkillManager?
    /// These objects deliberately retain only in-memory observations and confirmation
    /// capabilities. A daemon restart invalidates both rather than persisting authority.
    private let externalMonitor: ExternalProcessMonitor
    private let externalController: ExternalProcessController
    private let daemonPID: Int32
    private let serviceVersion: String
    private let startedAt = Date()
    private var endpoint = "http://127.0.0.1:0"
    private var deleteAuthorizations: [UUID: DeleteAuthorization] = [:]
    private var skillUninstallAuthorizations: [String: SkillUninstallAuthorization] = [:]
    private var sessionsBeingLaunched = Set<UUID>()
    private var stopRequestedSessions = Set<UUID>()
    private var runStopsInFlight = Set<UUID>()
    private var launchCompletionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var leaseRenewalTasks: [UUID: Task<Void, Never>] = [:]
    /// Reserves the one primary slot while an atomic launcher-level relaunch is in flight.
    private var relaunchingLauncherIDs = Set<UUID>()
    /// Additional instances are independently relaunchable by exact session identity.
    private var relaunchingSessionIDs = Set<UUID>()
    private var upgradeMaintenanceReservation: UpgradeMaintenanceReservation?
    private var cachedSkillStatus: (status: LauncherSkillStatus, expiresAt: Date)?
    private var skillStatusRefreshTask: Task<LauncherSkillStatus, Error>?

    init(
        store: SQLiteStore,
        supervisor: ProcessSupervisor,
        skillManager: LauncherSkillManager? = nil,
        serviceVersion: String = LauncherRuntimeVersion.current()
    ) {
        self.store = store
        self.supervisor = supervisor
        self.skillManager = skillManager
        self.serviceVersion = serviceVersion
        let monitor = ExternalProcessMonitor(excludedPIDs: [getpid()])
        self.externalMonitor = monitor
        self.externalController = ExternalProcessController(observations: monitor)
        self.daemonPID = getpid()
    }

    func setEndpoint(_ endpoint: String) {
        self.endpoint = endpoint
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            return try await route(request)
        } catch {
            return response(for: error, requestID: request.requestID)
        }
    }

    func recoverActiveSessions() async {
        guard let active = try? store.listSessions(activeOnly: true) else { return }
        for stored in active {
            var session = stored.record
            let sessionID = session.id
            let shouldResumeStopping = session.state == .stopping
            if shouldResumeStopping {
                stopRequestedSessions.insert(sessionID)
            }
            for index in session.actionRuns.indices {
                let runID = session.actionRuns[index].id
                let recovered = await supervisor.recover(
                    session.actionRuns[index],
                    releaseUnacknowledgedRunner: !shouldResumeStopping
                ) { [weak self] update in
                    Task { await self?.applySupervisorUpdate(sessionID: sessionID, update: update) }
                }
                session.actionRuns[index] = recovered
                if !shouldResumeStopping,
                   recovered.manager == .codexPort, recovered.state == .running,
                   let action = session.actionSnapshots?.first(where: { $0.id == recovered.actionID }) {
                    beginLeaseRenewal(for: recovered, action: action, sessionID: sessionID)
                }
                if recovered.id != runID { session.actionRuns[index].id = runID }
            }
            session.state = derivedState(for: session)
            if !session.isActive { session.endedAt = session.endedAt ?? Date() }
            _ = try? store.updateSession(session, expectedRevision: stored.storeRevision)
            if shouldResumeStopping {
                _ = try? await stopSession(id: sessionID)
            }
        }
    }

    /// Rebuilds generated mirrors after an interrupted catalog mutation and repairs drift that
    /// happened while the daemon was offline. Inspection runs even for a missing directory so a
    /// formerly synced record becomes drifted; an unavailable write target is left for an explicit
    /// later `launch sync --repair` rather than blocking boot.
    func reconcileProjectManifests() {
        guard let projects = try? store.listProjects() else { return }
        for project in projects {
            do {
                let inspection = try store.checkManifest(projectID: project.id)
                if project.manifestSyncState != .synced || !inspection.inSync {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDirectory),
                          isDirectory.boolValue,
                          FileManager.default.isWritableFile(atPath: project.directory) else { continue }
                    _ = try store.repairManifest(projectID: project.id)
                }
            } catch {
                // A project mirror is recoverable metadata. Keep the daemon available and leave
                // the stored sync state as evidence for a later explicit repair.
                continue
            }
        }
    }

    /// Reconciles renewal loops for live codex-port runs. Each loop renews at one quarter of its own
    /// configured TTL (capped at five minutes), so a short accepted lease cannot expire while
    /// waiting for a global fixed cadence and a just-started manager gets time to become verifiable.
    func ensureManagedPortLeaseRenewals() {
        guard let active = try? store.listSessions(activeOnly: true) else { return }
        for stored in active where stored.record.state != .stopping {
            let session = stored.record
            let actions: [LaunchAction]
            if let snapshots = session.actionSnapshots {
                actions = snapshots
            } else {
                actions = (try? store.launcher(id: session.launcherID))?.actions ?? []
            }
            for run in session.actionRuns
                where run.manager == .codexPort && (run.state == .starting || run.state == .running) {
                guard leaseRenewalTasks[run.id] == nil,
                      let action = actions.first(where: { $0.id == run.actionID }) else { continue }
                beginLeaseRenewal(for: run, action: action, sessionID: session.id)
            }
        }
    }

    private func prepareUpgrade(now: Date = Date()) throws -> UpgradeMaintenanceReservation {
        guard currentUpgradeReservation(now: now) == nil else {
            throw ServiceFailure.conflict(
                "An app upgrade reservation is already active. Cancel it with its exact reservation or wait for it to expire."
            )
        }

        let activeSessions = try store.listSessions(activeOnly: true).map(\.record)
        let lifecycleInFlight = !sessionsBeingLaunched.isEmpty
            || !relaunchingLauncherIDs.isEmpty
            || !relaunchingSessionIDs.isEmpty
            || !runStopsInFlight.isEmpty
        guard activeSessions.isEmpty, !lifecycleInFlight else {
            let count = activeSessions.count
            let sessionSummary = count == 1 ? "1 active session" : "\(count) active sessions"
            throw ServiceFailure.conflict(
                "Upgrade preparation requires a fully idle launcher service; found \(sessionSummary) or an in-flight lifecycle operation. Close all sessions and retry."
            )
        }

        let reservation = UpgradeMaintenanceReservation(
            reservationToken: UUID().uuidString.lowercased(),
            expiresAt: now.addingTimeInterval(Self.upgradeReservationLifetime)
        )
        upgradeMaintenanceReservation = reservation
        return reservation
    }

    private func cancelUpgrade(reservationToken: String, now: Date = Date()) throws {
        guard !reservationToken.isEmpty else {
            throw ServiceFailure.badRequest("An upgrade reservation token is required.")
        }
        guard let reservation = currentUpgradeReservation(now: now) else {
            throw ServiceFailure.conflict("No active app upgrade reservation exists.")
        }
        guard reservation.reservationToken == reservationToken else {
            // Never echo either cancellation capability into an API error or daemon log.
            throw ServiceFailure.conflict("The app upgrade reservation did not match the active reservation.")
        }
        upgradeMaintenanceReservation = nil
    }

    private func requireMutationsAvailable(now: Date = Date()) throws {
        guard let reservation = currentUpgradeReservation(now: now) else { return }
        let expiry = ISO8601DateFormatter().string(from: reservation.expiresAt)
        throw ServiceFailure.conflict(
            "Launcher mutations are paused for an app upgrade until \(expiry). Retry after the service restarts or cancel the exact reservation."
        )
    }

    private func currentUpgradeReservation(now: Date) -> UpgradeMaintenanceReservation? {
        guard let reservation = upgradeMaintenanceReservation else { return nil }
        guard reservation.expiresAt > now else {
            upgradeMaintenanceReservation = nil
            return nil
        }
        return reservation
    }

    /// Host detection performs strict code-signature validation and limited CLI probes. Keep it
    /// off the service actor so catalogue/session/listener requests stay responsive, and retain a
    /// short cache because availability cannot usefully change every polling tick.
    private func launcherSkillStatus() async throws -> LauncherSkillStatus {
        let now = Date()
        if let cachedSkillStatus, cachedSkillStatus.expiresAt > now {
            return cachedSkillStatus.status
        }
        if let skillStatusRefreshTask {
            return try await skillStatusRefreshTask.value
        }
        let manager = try requireSkillManager()
        let refreshTask = Task.detached(priority: .utility) {
            var status = try manager.status()
            status.hosts = status.hosts.map { hostStatus in
                var enriched = hostStatus
                let inspection = manager.inspectUninstall(host: hostStatus.host)
                enriched.managementState = inspection.state
                enriched.canUninstall = inspection.state == .receiptProven
                enriched.preservedCount = inspection.preservedRelativePaths.count
                enriched.managementMessage = inspection.message
                return enriched
            }
            return status
        }
        skillStatusRefreshTask = refreshTask
        do {
            let status = try await refreshTask.value
            cachedSkillStatus = (status, Date().addingTimeInterval(Self.skillStatusCacheLifetime))
            skillStatusRefreshTask = nil
            return status
        } catch {
            skillStatusRefreshTask = nil
            throw error
        }
    }

    private func launcherSkillHostStatus(_ host: LauncherSkillHost) async throws -> LauncherSkillHostStatus {
        guard let status = try await launcherSkillStatus().hosts.first(where: { $0.host == host }) else {
            throw ServiceFailure.notFound("Skill host status was not found.")
        }
        return status
    }

    private func absoluteSkillPaths(root: String, relativePaths: [String]) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        return relativePaths.map {
            rootURL.appendingPathComponent($0, isDirectory: false).standardizedFileURL.path
        }
    }

    private func prepareSkillUninstall(
        _ request: LauncherSkillUninstallIntentRequest,
        now: Date = Date()
    ) throws -> LauncherSkillUninstallIntent {
        skillUninstallAuthorizations = skillUninstallAuthorizations.filter {
            $0.value.intent.expiresAt > now
        }
        let manager = try requireSkillManager()
        let plan = manager.uninstallPlan(host: request.host)
        guard plan.canUninstall, let binding = plan.binding else {
            throw ServiceFailure.conflict(plan.inspection.message)
        }
        let removablePaths = absoluteSkillPaths(
            root: binding.destinationPath,
            relativePaths: plan.removableRelativePaths
        )
        let preservedPaths = absoluteSkillPaths(
            root: binding.destinationPath,
            relativePaths: plan.inspection.preservedRelativePaths
        )
        let token = UUID().uuidString.lowercased()
        let intent = LauncherSkillUninstallIntent(
            token: token,
            expiresAt: now.addingTimeInterval(Self.skillUninstallIntentLifetime),
            host: request.host,
            affectedSurfaces: LauncherSkillSurface.allCases,
            sharedInstallationPath: binding.destinationPath,
            installedVersion: plan.inspection.installedVersion,
            binding: binding,
            removablePaths: removablePaths,
            preservedPaths: preservedPaths,
            confirmationText: "uninstall \(request.host.rawValue) shared skill",
            message: "This removes only receipt-proven Launcher-managed files from the shared Desktop/CLI skill destination."
        )
        skillUninstallAuthorizations[token] = SkillUninstallAuthorization(intent: intent)
        return intent
    }

    private func consumeSkillUninstall(
        _ request: LauncherSkillUninstallRequest,
        now: Date = Date()
    ) async throws -> LauncherSkillUninstallResponse {
        guard !request.token.isEmpty else {
            throw ServiceFailure.badRequest("A skill uninstall intent token is required.")
        }
        skillUninstallAuthorizations = skillUninstallAuthorizations.filter {
            $0.value.intent.expiresAt > now
        }
        guard let authorization = skillUninstallAuthorizations[request.token] else {
            throw ServiceFailure.conflict("The skill uninstall intent is missing, expired, or already consumed.")
        }
        let intent = authorization.intent
        guard request.host == intent.host,
              request.binding == intent.binding,
              request.confirmationText == intent.confirmationText else {
            // Never echo the capability or either binding into errors or logs.
            throw ServiceFailure.conflict("The skill uninstall request did not match its exact intent.")
        }
        let manager = try requireSkillManager()
        let freshPlan = manager.uninstallPlan(host: request.host)
        guard freshPlan.binding == request.binding,
              absoluteSkillPaths(
                root: request.binding.destinationPath,
                relativePaths: freshPlan.removableRelativePaths
              ) == intent.removablePaths,
              absoluteSkillPaths(
                root: request.binding.destinationPath,
                relativePaths: freshPlan.inspection.preservedRelativePaths
              ) == intent.preservedPaths else {
            throw ServiceFailure.conflict("The skill destination changed after uninstall confirmation was prepared.")
        }
        // Consume the capability before invoking the filesystem transaction. A failed attempt
        // requires a fresh inspection and confirmation rather than replaying a deletion token.
        skillUninstallAuthorizations.removeValue(forKey: request.token)
        let result = try manager.uninstall(host: request.host, expected: request.binding)
        return LauncherSkillUninstallResponse(
            result: result,
            status: try await launcherSkillHostStatus(request.host)
        )
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let components = request.path.split(separator: "/").map(String.init)
        guard components.first == "v1" else { throw ServiceFailure.notFound("API route was not found.") }

        if request.method == "GET", components == ["v1", "health"] {
            return .json(serviceStatus())
        }
        if request.method == "GET", components == ["v1", "snapshot"] {
            return .json(CatalogSnapshot(
                launchers: try store.launcherDetails(),
                projects: try store.listProjects(),
                service: serviceStatus()
            ))
        }
        if request.method == "GET", components == ["v1", "external-processes"] {
            return .json(try await externalProcessSnapshot(fresh: false))
        }
        if request.method == "GET", components == ["v1", "external-processes", "refresh"] {
            return .json(try await externalProcessSnapshot(fresh: true))
        }
        if request.method == "GET", components.count == 4,
           components[1] == "external-processes", components[3] == "draft" {
            let observationID = try uuid(components[2], entity: "external process observation")
            guard let draft = await externalMonitor.draftProposal(id: observationID) else {
                throw ServiceFailure.notFound("External process observation was not found in the current in-memory snapshot.")
            }
            return .json(draft)
        }
        if request.method == "POST", components == ["v1", "maintenance", "upgrade", "prepare"] {
            return .json(try prepareUpgrade(), status: 201)
        }
        if request.method == "POST", components == ["v1", "maintenance", "upgrade", "cancel"] {
            let body: UpgradeMaintenanceCancelRequest = try decode(request)
            try cancelUpgrade(reservationToken: body.reservationToken)
            return .json(EmptyResponse())
        }

        // GET routes remain available for health/status inspection while an upgrade is pending.
        // Every other route must pass this actor-isolated gate before it can mutate catalog or
        // lifecycle state. The lifecycle methods repeat the guard at their own entry so an actor
        // reentrancy point between routing and execution cannot escape the reservation.
        if request.method != "GET" {
            try requireMutationsAvailable()
        }
        if request.method == "POST", components.count == 4,
           components[1] == "external-processes", components[3] == "close-intent" {
            let observationID = try uuid(components[2], entity: "external process observation")
            let intent = try await externalController.makeCloseIntent(
                observationID: observationID,
                correlation: try await externalCorrelation()
            )
            return .json(intent, status: 201)
        }
        if request.method == "POST", components.count == 4,
           components[1] == "external-processes", components[3] == "close" {
            let observationID = try uuid(components[2], entity: "external process observation")
            let body: ExternalCloseRequest = try decode(request)
            guard body.observationID == observationID else {
                throw ServiceFailure.badRequest("The close request must target the observation ID in its path.")
            }
            return .json(try await externalController.close(
                body,
                correlation: try await externalCorrelation()
            ))
        }
        if request.method == "GET", components == ["v1", "skills", "status"] {
            return .json(try await launcherSkillStatus())
        }
        if request.method == "GET", components == ["v1", "skills", "source"] {
            return .json(try requireSkillManager().source())
        }
        if request.method == "POST", components == ["v1", "skills", "install"] {
            let body: LauncherSkillInstallRequest = try decode(request)
            let manager = try requireSkillManager()
            return .json(try manager.install(host: body.host))
        }
        if request.method == "POST", components == ["v1", "skills", "uninstall-intent"] {
            let body: LauncherSkillUninstallIntentRequest = try decode(request)
            return .json(try prepareSkillUninstall(body), status: 201)
        }
        if request.method == "POST", components == ["v1", "skills", "uninstall"] {
            let body: LauncherSkillUninstallRequest = try decode(request)
            return .json(try await consumeSkillUninstall(body))
        }
        if request.method == "GET", components == ["v1", "projects"] {
            return .json(try store.listProjects())
        }
        if request.method == "POST", components == ["v1", "projects", "init"] {
            let body: ProjectInitRequest = try decode(request)
            return .json(try initializeProject(body), status: 201)
        }
        if request.method == "PATCH", components.count == 3, components[1] == "projects" {
            let projectID = try uuid(components[2], entity: "project")
            let body: ProjectPatchRequest = try decode(request)
            try requireIfMatch(request, expected: body.expectedRevision)
            return .json(try updateProject(id: projectID, patch: body))
        }
        if request.method == "GET", components == ["v1", "projects", "resolve"] {
            guard let directory = request.query["directory"], !directory.isEmpty else {
                throw ServiceFailure.badRequest("directory query parameter is required.")
            }
            return .json(try resolveProject(directory: directory))
        }
        if request.method == "POST", components.count == 4, components[1] == "projects", components[3] == "sync" {
            let projectID = try uuid(components[2], entity: "project")
            let body: SyncRequest = try decode(request)
            let result = body.repair ? try store.repairManifest(projectID: projectID) : try store.checkManifest(projectID: projectID)
            return .json(result)
        }

        if request.method == "GET", components == ["v1", "launchers"] {
            return .json(try store.launcherDetails(query: request.query["q"]))
        }
        if request.method == "POST", components == ["v1", "launchers"] {
            let body: LauncherCreateRequest = try decode(request)
            return .json(try createLauncher(body), status: 201)
        }
        if request.method == "GET", components.count == 4, components[1] == "launchers", components[2] == "by-name" {
            // HTTPServer already supplies URLComponents.path, which is decoded exactly once.
            // Decoding again corrupts literal percent sequences such as a launcher named `%2F`.
            let name = components[3]
            guard let launcher = try store.launcher(named: name), let detail = try store.launcherDetail(id: launcher.id) else {
                throw ServiceFailure.notFound("Launcher was not found: \(name)")
            }
            return .json(detail)
        }
        if components.count >= 3, components[1] == "launchers" {
            let launcherID = try uuid(components[2], entity: "launcher")
            if request.method == "GET", components.count == 3 {
                return .json(try requireLauncherDetail(id: launcherID))
            }
            if request.method == "PATCH", components.count == 3 {
                let body: LauncherPatchRequest = try decode(request)
                try requireIfMatch(request, expected: body.expectedRevision)
                return .json(try updateLauncher(id: launcherID, patch: body))
            }
            if request.method == "DELETE", components.count == 3 {
                let body: DeleteRequest = try decode(request)
                try requireIfMatch(request, expected: body.expectedRevision)
                try deleteLauncher(id: launcherID, request: body)
                return .json(EmptyResponse())
            }
            if request.method == "POST", components.count == 4, components[3] == "delete-intent" {
                return .json(try makeDeleteIntent(id: launcherID))
            }
            if request.method == "POST", components.count == 4, components[3] == "sessions" {
                let body: SessionStartRequest = try decode(request)
                let reusesPrimary: Bool
                if body.mode == .reusePrimary {
                    reusesPrimary = try requireLauncherDetail(id: launcherID).primaryActiveSession != nil
                } else {
                    reusesPrimary = false
                }
                let session = try await startLauncher(id: launcherID, request: body)
                return .json(session, status: reusesPrimary ? 200 : 201)
            }
            if request.method == "POST", components.count == 4, components[3] == "relaunch" {
                let body: SessionRelaunchRequest = try decode(request)
                return .json(try await relaunchLauncher(id: launcherID, request: body), status: 201)
            }
            if request.method == "POST", components.count == 4, components[3] == "actions" {
                let body: ActionCreateRequest = try decode(request)
                try requireIfMatch(request, expected: body.expectedRevision)
                return .json(try addAction(launcherID: launcherID, request: body), status: 201)
            }
            if components.count == 5, components[3] == "actions" {
                let actionID = try uuid(components[4], entity: "action")
                if request.method == "PATCH" {
                    let body: ActionPatchRequest = try decode(request)
                    try requireIfMatch(request, expected: body.expectedRevision)
                    return .json(try updateAction(launcherID: launcherID, actionID: actionID, request: body))
                }
                if request.method == "DELETE" {
                    let body: DeleteActionRequest = try decode(request)
                    try requireIfMatch(request, expected: body.expectedRevision)
                    return .json(try deleteAction(launcherID: launcherID, actionID: actionID, expectedRevision: body.expectedRevision))
                }
            }
        }

        if request.method == "GET", components == ["v1", "history", "sessions"] {
            let launcherID = try request.query["launcherID"].map { try uuid($0, entity: "launcher") }
            let state: SessionState?
            if let rawState = request.query["state"] {
                guard let parsed = SessionState(rawValue: rawState) else {
                    throw ServiceFailure.badRequest("Invalid session history state: \(rawState)")
                }
                state = parsed
            } else {
                state = nil
            }
            let role: SessionLaunchRole?
            if let rawRole = request.query["role"] {
                guard let parsed = SessionLaunchRole(rawValue: rawRole) else {
                    throw ServiceFailure.badRequest("Invalid session history role: \(rawRole)")
                }
                role = parsed
            } else {
                role = nil
            }
            let limit: Int
            if let rawLimit = request.query["limit"] {
                guard let parsed = Int(rawLimit) else {
                    throw ServiceFailure.badRequest("Session history limit must be an integer.")
                }
                limit = parsed
            } else {
                limit = 50
            }
            return .json(try store.sessionHistory(
                launcherID: launcherID,
                state: state,
                role: role,
                limit: limit,
                cursor: request.query["cursor"]
            ))
        }

        if request.method == "GET", components == ["v1", "sessions"] {
            let activeOnly = request.query["active"] == "true"
            return .json(try store.listSessions(activeOnly: activeOnly).map(\.record))
        }
        if request.method == "GET", components.count == 3, components[1] == "sessions" {
            let sessionID = try uuid(components[2], entity: "session")
            guard let session = try store.session(id: sessionID)?.record else {
                throw ServiceFailure.notFound("Session was not found: \(sessionID.uuidString)")
            }
            return .json(session)
        }
        if components.count == 4, components[1] == "sessions" {
            let sessionID = try uuid(components[2], entity: "session")
            if request.method == "GET", components[3] == "open-options" {
                return .json(try await sessionOpenOptions(id: sessionID))
            }
            if request.method == "POST", components[3] == "open" {
                let body: SessionOpenRequest = try decode(request)
                return .json(try await openSessionOption(id: sessionID, optionID: body.optionID))
            }
            if request.method == "POST", components[3] == "open-probe" {
                let body: SessionOpenRequest = try decode(request)
                return .json(try await probeSessionOpenOption(id: sessionID, optionID: body.optionID))
            }
            if request.method == "POST", components[3] == "stop" {
                return .json(try await stopSession(id: sessionID))
            }
            if request.method == "POST", components[3] == "relaunch" {
                let body: SessionRelaunchRequest = try decode(request)
                return .json(try await relaunchSession(id: sessionID, request: body), status: 201)
            }
            if request.method == "GET", components[3] == "logs" {
                return .json(try sessionLogs(id: sessionID))
            }
        }

        throw ServiceFailure.notFound("API route was not found.")
    }

    private func externalProcessSnapshot(fresh: Bool) async throws -> ExternalProcessSnapshot {
        if !fresh,
           let cached = await externalMonitor.cachedSnapshot(),
           !cached.isStale {
            return cached
        }
        return await externalMonitor.refresh(correlation: try await externalCorrelation())
    }

    /// The correlation input is rebuilt for every fresh scan and confirmation. In particular, a
    /// temporary codex-port inspection failure must fail closed instead of reclassifying a
    /// separately managed service as a directly signalable external process.
    private func externalCorrelation() async throws -> ExternalCorrelationInput {
        let sessions = try store.listSessions(activeOnly: true).map(\.record)
        let launcherRuns = sessions.flatMap { session in
            session.actionRuns.map { run in
                ExternalLauncherRunCorrelation(
                    launcherID: session.launcherID,
                    sessionID: session.id,
                    actionRunID: run.id,
                    pid: run.pid,
                    processGroupID: run.processGroupID,
                    pidStartIdentity: run.pidStartIdentity,
                    managerID: run.manager == .codexPort ? run.managerID : nil
                )
            }
        }
        return ExternalCorrelationInput(
            launcherRuns: launcherRuns,
            codexPortRuns: try await supervisor.liveCodexPortCorrelations(),
            protectedPIDs: [daemonPID]
        )
    }

    private func sessionOpenOptions(id: UUID) async throws -> [SessionOpenOption] {
        let session = try requireSessionRecord(id: id)
        return await supervisor.sessionOpenOptions(for: session)
    }

    private func openSessionOption(id: UUID, optionID: String) async throws -> SessionOpenResult {
        let session = try requireSessionRecord(id: id)
        return try await supervisor.openSessionOption(optionID: optionID, in: session)
    }

    private func probeSessionOpenOption(id: UUID, optionID: String) async throws -> SessionOpenProbeResult {
        let session = try requireSessionRecord(id: id)
        return try await supervisor.probeExpoOpenOption(optionID: optionID, in: session)
    }

    private func initializeProject(_ request: ProjectInitRequest) throws -> ProjectRecord {
        let canonical = try LauncherValidation.canonicalDirectory(request.directory)
        if let existing = try store.project(directory: canonical) {
            return bestEffortRepairManifest(projectID: existing.id) ?? existing
        }
        let manifestURL = URL(fileURLWithPath: canonical, isDirectory: true)
            .appendingPathComponent(MarkdownRenderer.fileName, isDirectory: false)
        let manifestEntryExists = FileManager.default.fileExists(atPath: manifestURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: manifestURL.path)) != nil
        if manifestEntryExists {
            throw ServiceFailure.conflict(
                "Initialization refused because \(MarkdownRenderer.fileName) already exists and is not owned by a registered Launch Station project. Move or rename that file, then retry."
            )
        }
        let fallbackName = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent
        let displayName = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try store.createProject(ProjectRecord(
            displayName: (displayName?.isEmpty == false ? displayName! : fallbackName),
            directory: canonical
        ))
        return bestEffortRepairManifest(projectID: project.id) ?? project
    }

    private func updateProject(id: UUID, patch: ProjectPatchRequest) throws -> ProjectRecord {
        guard var project = try store.project(id: id) else {
            throw ServiceFailure.notFound("Project was not found: \(id.uuidString)")
        }
        project.displayName = patch.displayName
        let updated = try store.updateProject(project, expectedRevision: patch.expectedRevision)
        return bestEffortRepairManifest(projectID: updated.id) ?? updated
    }

    private func resolveProject(directory: String) throws -> ProjectRecord {
        let canonical = try LauncherValidation.canonicalDirectory(directory)
        if let exact = try store.project(directory: canonical) { return exact }
        if let containing = try store.listProjects()
            .filter({ canonical.hasPrefix($0.directory + "/") })
            .max(by: { $0.directory.count < $1.directory.count }) {
            return containing
        }
        throw ServiceFailure.notFound("No initialized launcher project contains \(canonical). Run `launch init` there first.")
    }

    private func createLauncher(_ request: LauncherCreateRequest) throws -> LauncherDetail {
        guard try store.project(id: request.projectID) != nil else {
            throw ServiceFailure.notFound("Project was not found: \(request.projectID.uuidString)")
        }
        let launcher = try store.createLauncher(LauncherRecord(
            projectID: request.projectID,
            name: request.name,
            normalizedName: LauncherValidation.normalizeName(request.name),
            description: request.description,
            runDetails: request.runDetails,
            tags: request.tags,
            actions: [request.primaryAction],
            primaryActionID: request.primaryAction.id
        ))
        // The catalog mutation is already committed and the store marked this project pending.
        // Mirror repair is best effort here; startup/maintenance reconciliation will retry it.
        _ = bestEffortRepairManifest(projectID: launcher.projectID)
        return try requireLauncherDetail(id: launcher.id)
    }

    private func updateLauncher(id: UUID, patch: LauncherPatchRequest) throws -> LauncherDetail {
        guard var launcher = try store.launcher(id: id) else { throw ServiceFailure.notFound("Launcher was not found: \(id.uuidString)") }
        if let name = patch.name { launcher.name = name }
        if let description = patch.description { launcher.description = description }
        if patch.clearRunDetails { launcher.runDetails = nil }
        else if let runDetails = patch.runDetails { launcher.runDetails = runDetails }
        var tags = patch.replaceTags ?? launcher.tags
        tags.append(contentsOf: patch.addTags)
        let removals = Set(patch.removeTags.map(LauncherValidation.normalizeName))
        launcher.tags = LauncherValidation.normalizedTags(tags.filter { !removals.contains(LauncherValidation.normalizeName($0)) })
        if let primary = patch.primaryAction {
            guard let index = launcher.actions.firstIndex(where: { $0.id == primary.id }) else {
                throw ServiceFailure.badRequest("Action patch must retain the ID of an existing action on this launcher.")
            }
            launcher.actions[index] = primary
        }
        if let primaryActionID = patch.primaryActionID {
            guard launcher.actions.contains(where: { $0.id == primaryActionID }) else {
                throw ServiceFailure.badRequest("Primary action ID does not identify an action on this launcher.")
            }
            launcher.primaryActionID = primaryActionID
        }
        let updated = try store.updateLauncher(launcher, expectedRevision: patch.expectedRevision)
        _ = bestEffortRepairManifest(projectID: updated.projectID)
        return try requireLauncherDetail(id: updated.id)
    }

    private func addAction(launcherID: UUID, request: ActionCreateRequest) throws -> LauncherDetail {
        guard var launcher = try store.launcher(id: launcherID) else { throw ServiceFailure.notFound("Launcher was not found: \(launcherID.uuidString)") }
        guard !launcher.actions.contains(where: { $0.id == request.action.id }) else {
            throw ServiceFailure.conflict("An action with that ID already exists.")
        }
        launcher.actions.append(request.action)
        let updated = try store.updateLauncher(launcher, expectedRevision: request.expectedRevision)
        _ = bestEffortRepairManifest(projectID: updated.projectID)
        return try requireLauncherDetail(id: updated.id)
    }

    private func updateAction(launcherID: UUID, actionID: UUID, request: ActionPatchRequest) throws -> LauncherDetail {
        guard request.action.id == actionID else { throw ServiceFailure.badRequest("Action ID in the body does not match the route.") }
        guard var launcher = try store.launcher(id: launcherID),
              let index = launcher.actions.firstIndex(where: { $0.id == actionID }) else {
            throw ServiceFailure.notFound("Action was not found: \(actionID.uuidString)")
        }
        launcher.actions[index] = request.action
        let updated = try store.updateLauncher(launcher, expectedRevision: request.expectedRevision)
        _ = bestEffortRepairManifest(projectID: updated.projectID)
        return try requireLauncherDetail(id: updated.id)
    }

    private func deleteAction(launcherID: UUID, actionID: UUID, expectedRevision: Int) throws -> LauncherDetail {
        guard var launcher = try store.launcher(id: launcherID),
              launcher.actions.contains(where: { $0.id == actionID }) else {
            throw ServiceFailure.notFound("Action was not found: \(actionID.uuidString)")
        }
        guard launcher.actions.count > 1 else { throw ServiceFailure.conflict("A launcher must retain at least one action.") }
        launcher.actions.removeAll { $0.id == actionID }
        if launcher.primaryActionID == actionID, let replacement = launcher.sortedActions.first {
            launcher.primaryActionID = replacement.id
        }
        let updated = try store.updateLauncher(launcher, expectedRevision: expectedRevision)
        _ = bestEffortRepairManifest(projectID: updated.projectID)
        return try requireLauncherDetail(id: updated.id)
    }

    private func makeDeleteIntent(id: UUID) throws -> DeleteIntent {
        let detail = try requireLauncherDetail(id: id)
        guard detail.activeSessions.isEmpty else {
            throw ServiceFailure.conflict("Close all active sessions before deleting this launcher shortcut.")
        }
        let authorization = DeleteAuthorization(
            token: UUID().uuidString.lowercased() + UUID().uuidString.lowercased(),
            launcherRevision: detail.launcher.revision,
            expiresAt: Date().addingTimeInterval(300)
        )
        deleteAuthorizations[id] = authorization
        return DeleteIntent(token: authorization.token, expiresAt: authorization.expiresAt, launcher: detail)
    }

    private func deleteLauncher(id: UUID, request: DeleteRequest) throws {
        guard let authorization = deleteAuthorizations[id],
              authorization.token == request.intentToken,
              authorization.expiresAt > Date(),
              authorization.launcherRevision == request.expectedRevision else {
            throw ServiceFailure.precondition("Deletion confirmation expired or no longer matches the current launcher revision. Retrieve the details and confirm again.")
        }
        let detail = try requireLauncherDetail(id: id)
        guard detail.launcher.revision == request.expectedRevision else {
            throw ServiceFailure.precondition("Launcher changed after confirmation. Retrieve the current details before deleting it.")
        }
        try store.deleteLauncher(id: id, expectedRevision: request.expectedRevision)
        deleteAuthorizations.removeValue(forKey: id)
        _ = bestEffortRepairManifest(projectID: detail.project.id)
    }

    private func bestEffortRepairManifest(projectID: UUID) -> ProjectRecord? {
        if let repaired = try? store.repairManifest(projectID: projectID) {
            return repaired.project
        }
        // If writing failed after a committed mutation, record observable drift when inspection is
        // still possible. Otherwise the store's existing pending state remains the explicit truth.
        return try? store.checkManifest(projectID: projectID).project
    }

    private func startLauncher(
        id: UUID,
        request: SessionStartRequest,
        permitsRelaunchReservation: Bool = false
    ) async throws -> SessionRecord {
        try requireMutationsAvailable()
        if request.mode == .reusePrimary,
           !permitsRelaunchReservation,
           relaunchingLauncherIDs.contains(id) {
            throw ServiceFailure.conflict("A relaunch is already closing and restarting this launcher's primary session.")
        }
        let detail = try requireLauncherDetail(id: id)
        if let expectedRevision = request.expectedLauncherRevision,
           detail.launcher.revision != expectedRevision {
            throw ServiceFailure.conflict(
                "The launcher definition changed before start. Retrieve its current commands and confirm again."
            )
        }
        if request.mode == .reusePrimary, let existing = detail.primaryActiveSession { return existing }
        var session = SessionRecord(
            launcherID: detail.launcher.id,
            launcherName: detail.launcher.name,
            launcherRevision: detail.launcher.revision,
            launchRole: request.mode.launchRole,
            projectSnapshot: SessionProjectSnapshot(project: detail.project),
            runtimeArguments: request.runtimeArguments,
            actionSnapshots: detail.launcher.sortedActions,
            state: .starting
        )
        var stored = try store.createSession(session)
        sessionsBeingLaunched.insert(session.id)
        stopRequestedSessions.remove(session.id)
        let sessionID = session.id
        defer { completeLaunchTracking(sessionID: sessionID) }

        for action in detail.launcher.sortedActions {
            do {
                try requireLaunchContinuation(sessionID: sessionID)
                let runtimeArguments = action.id == detail.launcher.primaryActionID ? request.runtimeArguments : []
                var effectiveAction = action
                effectiveAction.environment.merge(
                    linkedActionEnvironment(session: session, launcher: detail.launcher),
                    uniquingKeysWith: { configured, _ in configured }
                )
                var run = try await supervisor.launch(
                    action: effectiveAction,
                    project: detail.project,
                    sessionID: session.id,
                    runtimeArguments: runtimeArguments,
                    onRegister: { [weak self] initialRun in
                        guard let self else { throw CancellationError() }
                        try await self.registerInitialRun(sessionID: sessionID, run: initialRun)
                    }
                ) { [weak self] update in
                    Task { await self?.applySupervisorUpdate(sessionID: sessionID, update: update) }
                }

                // `supervisor.launch` is an actor hop and may take long enough for CLOSE to run.
                // Never allow the newly visible exact process to escape that earlier stop intent.
                if stopRequestedSessions.contains(sessionID) {
                    return try await cancelLaunch(sessionID: sessionID, currentRun: run, action: action)
                }
                stored = try upsert(run: run, sessionID: sessionID)
                session = stored.record
                if run.manager == .codexPort {
                    beginLeaseRenewal(for: run, action: action, sessionID: sessionID)
                }

                // A supervisor may already have established that the command failed before it
                // returns (for example, an interpreter reports a missing module immediately).
                // Do not spend the readiness timeout probing an endpoint that cannot become
                // ready: that leaves the parent session visibly `starting` and obscures the
                // terminal project diagnosis. The required-action branch below will preserve
                // the original failure and settle the session as failed straight away.
                if (run.state == .starting || run.state == .running),
                   let healthTemplate = action.healthCheckURL {
                    do {
                        try await waitUntilReady(
                            template: healthTemplate,
                            run: run,
                            timeoutSeconds: action.readyTimeoutSeconds,
                            sessionID: sessionID
                        )
                    } catch LaunchControlFlow.stopRequested {
                        return try await cancelLaunch(sessionID: sessionID, currentRun: run, action: action)
                    } catch {
                        if stopRequestedSessions.contains(sessionID) {
                            return try await cancelLaunch(sessionID: sessionID, currentRun: run, action: action)
                        }
                        let attempt = try await stopExactRun(
                            run,
                            sessionID: sessionID,
                            timeoutSeconds: action.stopTimeoutSeconds
                        )
                        run = attempt.record
                        if stopRequestedSessions.contains(sessionID) {
                            return try await finishCancelledLaunch(sessionID: sessionID)
                        }
                        run.state = .failed
                        run.message = "Readiness check failed: \(error.localizedDescription)"
                        run.endedAt = Date()
                        stored = try upsert(run: run, sessionID: sessionID)
                        session = stored.record
                    }
                }

                try requireLaunchContinuation(sessionID: sessionID)

                if run.state == .failed || run.state == .orphaned {
                    if action.required {
                        session.lastError = run.message ?? "Required action \(action.name) failed."
                        stored = try await stopStartedRuns(in: session, projectLauncher: detail.launcher, finalState: .failed)
                        if stopRequestedSessions.contains(sessionID) {
                            return try await finishCancelledLaunch(sessionID: sessionID)
                        }
                        completeLaunchTracking(sessionID: session.id)
                        stopRequestedSessions.remove(session.id)
                        return stored.record
                    }
                } else if (request.openRequested && action.id == detail.launcher.primaryActionID) || action.openTarget == .browser {
                    if let endpoint = run.endpointURL, let url = URL(string: endpoint) {
                        _ = await MainActor.run { NSWorkspace.shared.open(url) }
                        try requireLaunchContinuation(sessionID: sessionID)
                    }
                }
            } catch LaunchControlFlow.stopRequested {
                return try await cancelLaunch(sessionID: sessionID, currentRun: nil, action: action)
            } catch {
                if stopRequestedSessions.contains(sessionID) {
                    return try await cancelLaunch(sessionID: sessionID, currentRun: nil, action: action)
                }
                let now = Date()
                let diagnosis = LaunchFailureDiagnoser.diagnose(
                    LaunchFailureDiagnosisInput(launcherMessage: error.localizedDescription)
                )
                let failed = ActionRunRecord(
                    actionID: action.id,
                    actionName: action.name,
                    state: .failed,
                    manager: .fireAndForget,
                    startedAt: now,
                    endedAt: now,
                    message: diagnosis.summary,
                    failureDiagnosis: diagnosis
                )
                stored = try upsert(run: failed, sessionID: session.id)
                session = stored.record
                if action.required {
                    session.lastError = "Required action \(action.name) failed: \(diagnosis.summary)"
                    stored = try await stopStartedRuns(in: session, projectLauncher: detail.launcher, finalState: .failed)
                    if stopRequestedSessions.contains(sessionID) {
                        return try await finishCancelledLaunch(sessionID: sessionID)
                    }
                    completeLaunchTracking(sessionID: session.id)
                    stopRequestedSessions.remove(session.id)
                    return stored.record
                }
            }
        }

        completeLaunchTracking(sessionID: session.id)
        if stopRequestedSessions.contains(session.id) {
            return try await finishCancelledLaunch(sessionID: session.id)
        }
        guard let latest = try store.session(id: session.id) else { throw ServiceFailure.notFound("Session disappeared while launching.") }
        session = latest.record
        session.state = derivedState(for: session)
        if !session.isActive { session.endedAt = Date() }
        return try store.updateSession(session, expectedRevision: latest.storeRevision).record
    }

    private func relaunchLauncher(id: UUID, request: SessionRelaunchRequest) async throws -> SessionRelaunchResult {
        try requireMutationsAvailable()
        guard !relaunchingLauncherIDs.contains(id) else {
            throw ServiceFailure.conflict("A relaunch is already in progress for this launcher.")
        }
        let initial = try requireLauncherDetail(id: id)
        if let expectedRevision = request.expectedLauncherRevision,
           initial.launcher.revision != expectedRevision {
            throw ServiceFailure.conflict(
                "The launcher definition changed before relaunch. Retrieve its current commands and confirm again."
            )
        }
        guard request.expectedSessionID == nil || !request.requireIdle else {
            throw ServiceFailure.badRequest("Relaunch cannot require both a specific active session and an idle launcher.")
        }
        let initialPrimary = initial.primaryActiveSession
        if request.requireIdle, initialPrimary != nil {
            throw ServiceFailure.conflict(
                "The launcher's primary session was no longer idle when relaunch began. Retrieve current status before choosing whether to close that exact session."
            )
        }
        if let expectedSessionID = request.expectedSessionID,
           initialPrimary?.id != expectedSessionID {
            throw ServiceFailure.conflict(
                "The active primary session changed before relaunch. Retrieve current status and confirm the new exact session."
            )
        }
        if initialPrimary?.state == .stopping {
            throw ServiceFailure.conflict("The active primary session is already closing. Wait for it to finish before relaunching.")
        }

        relaunchingLauncherIDs.insert(id)
        defer { relaunchingLauncherIDs.remove(id) }

        var previousSession: SessionRecord?
        if let active = initialPrimary {
            let stopped = try await stopSession(id: active.id)
            previousSession = stopped
            try requireSafelyStopped(stopped)
        }

        let latest = try requireLauncherDetail(id: id)
        guard latest.primaryActiveSession == nil else {
            throw ServiceFailure.conflict("A new active primary session appeared before relaunch could start its replacement.")
        }
        guard latest.launcher.revision == initial.launcher.revision else {
            throw ServiceFailure.conflict(
                "The launcher definition changed while its previous session was closing. The replacement was not started; retrieve and confirm the new commands."
            )
        }
        let session = try await startLauncher(
            id: id,
            request: request.startRequest(mode: .reusePrimary),
            permitsRelaunchReservation: true
        )
        return SessionRelaunchResult(previousSession: previousSession, session: session)
    }

    private func relaunchSession(id: UUID, request: SessionRelaunchRequest) async throws -> SessionRelaunchResult {
        try requireMutationsAvailable()
        guard request.expectedSessionID == nil || request.expectedSessionID == id else {
            throw ServiceFailure.conflict("The expected session does not match the exact relaunch route.")
        }
        guard !request.requireIdle else {
            throw ServiceFailure.badRequest("An exact session relaunch cannot require an idle launcher.")
        }
        guard let stored = try store.session(id: id) else {
            throw ServiceFailure.notFound("Session was not found: \(id.uuidString)")
        }
        let initialSession = stored.record
        guard initialSession.isActive else {
            throw ServiceFailure.conflict("The exact session is no longer active and cannot be relaunched in place.")
        }
        if initialSession.launchRole == .primary {
            var primaryRequest = request
            primaryRequest.expectedSessionID = id
            return try await relaunchLauncher(id: initialSession.launcherID, request: primaryRequest)
        }
        guard initialSession.state != .stopping else {
            throw ServiceFailure.conflict("The exact additional session is already closing.")
        }
        guard !relaunchingSessionIDs.contains(id) else {
            throw ServiceFailure.conflict("A relaunch is already in progress for this exact session.")
        }

        let initialDetail = try requireLauncherDetail(id: initialSession.launcherID)
        if let expectedRevision = request.expectedLauncherRevision,
           initialDetail.launcher.revision != expectedRevision {
            throw ServiceFailure.conflict(
                "The launcher definition changed before relaunch. Retrieve its current commands and confirm again."
            )
        }

        relaunchingSessionIDs.insert(id)
        defer { relaunchingSessionIDs.remove(id) }

        let stopped = try await stopSession(id: id)
        try requireSafelyStopped(stopped)

        let latestDetail = try requireLauncherDetail(id: initialSession.launcherID)
        guard latestDetail.launcher.revision == initialDetail.launcher.revision else {
            throw ServiceFailure.conflict(
                "The launcher definition changed while the exact additional session was closing. The replacement was not started."
            )
        }
        let replacement = try await startLauncher(
            id: initialSession.launcherID,
            request: request.startRequest(mode: .newInstance)
        )
        return SessionRelaunchResult(previousSession: stopped, session: replacement)
    }

    private func requireSafelyStopped(_ session: SessionRecord) throws {
        guard !session.isActive else {
            throw ServiceFailure.conflict("The exact active session has not fully closed, so a replacement was not started.")
        }
        guard session.state != .orphaned,
              !session.actionRuns.contains(where: { $0.state == .orphaned }) else {
            throw ServiceFailure.conflict(
                "The previous session became orphaned and cannot be proven closed. Resolve its exact ownership before starting a replacement."
            )
        }
    }

    private func stopStartedRuns(in source: SessionRecord, projectLauncher: LauncherRecord, finalState: SessionState) async throws -> StoredSessionRecord {
        let sessionID = source.id
        let policies = Dictionary(uniqueKeysWithValues: projectLauncher.actions.map { ($0.id, $0.stopTimeoutSeconds) })
        for original in source.actionRuns.reversed() where isActive(original.state) {
            _ = try await stopExactRun(
                original,
                sessionID: sessionID,
                timeoutSeconds: policies[original.actionID] ?? 8
            )
        }
        guard let current = try store.session(id: sessionID) else {
            throw ServiceFailure.notFound("Session was not found: \(sessionID.uuidString)")
        }
        var session = current.record
        session.state = finalState
        session.endedAt = Date()
        return try store.updateSession(session, expectedRevision: current.storeRevision)
    }

    private func stopSession(id: UUID) async throws -> SessionRecord {
        try requireMutationsAvailable()
        guard let stored = try store.session(id: id) else { throw ServiceFailure.notFound("Session was not found: \(id.uuidString)") }
        guard stored.record.isActive else { return stored.record }
        stopRequestedSessions.insert(id)
        cancelLeaseRenewals(for: stored.record)
        var session = stored.record
        session.state = .stopping
        session.endedAt = nil
        var current = try store.updateSession(session, expectedRevision: stored.storeRevision)
        let snapshots: [LaunchAction]
        if let saved = session.actionSnapshots {
            snapshots = saved
        } else {
            snapshots = try store.launcher(id: session.launcherID)?.actions ?? []
        }
        let policies = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.stopTimeoutSeconds) })
        try await stopVisibleRuns(sessionID: id, policies: policies)
        if sessionsBeingLaunched.contains(id) {
            await waitForLaunchCompletion(sessionID: id)
        }
        // An action may have become visible after the first pass while its supervisor launch was
        // in flight. The launch task normally closes it itself; this second pass is the exact-owner
        // safety net before CLOSE returns.
        try await stopVisibleRuns(sessionID: id, policies: policies)
        if let latest = try store.session(id: id) { current = latest; session = latest.record }
        let stillActive = session.actionRuns.contains(where: { isActive($0.state) })
        if sessionsBeingLaunched.contains(id) || stillActive {
            session.state = .stopping
            session.endedAt = nil
        } else {
            session.state = session.actionRuns.contains(where: { $0.state == .orphaned }) ? .orphaned : .exited
            session.endedAt = Date()
        }
        let updated = try store.updateSession(session, expectedRevision: current.storeRevision).record
        if !updated.isActive {
            stopRequestedSessions.remove(id)
        }
        return updated
    }

    private func cancelLaunch(sessionID: UUID, currentRun: ActionRunRecord?, action: LaunchAction) async throws -> SessionRecord {
        if let currentRun {
            _ = try await stopExactRun(
                currentRun,
                sessionID: sessionID,
                timeoutSeconds: action.stopTimeoutSeconds
            )
        }
        return try await finishCancelledLaunch(sessionID: sessionID)
    }

    private func finishCancelledLaunch(sessionID: UUID) async throws -> SessionRecord {
        completeLaunchTracking(sessionID: sessionID)
        guard let current = try store.session(id: sessionID) else {
            throw ServiceFailure.notFound("Session was not found: \(sessionID.uuidString)")
        }
        var session = current.record
        let stillActive = session.actionRuns.contains(where: { isActive($0.state) })
        if stillActive {
            session.state = .stopping
            session.endedAt = nil
        } else {
            session.state = session.actionRuns.contains(where: { $0.state == .orphaned }) ? .orphaned : .exited
            session.endedAt = Date()
        }
        let updated = try store.updateSession(session, expectedRevision: current.storeRevision).record
        if !updated.isActive {
            stopRequestedSessions.remove(sessionID)
        }
        return updated
    }

    private func stopVisibleRuns(sessionID: UUID, policies: [UUID: Int]) async throws {
        guard let session = try store.session(id: sessionID)?.record else {
            throw ServiceFailure.notFound("Session was not found: \(sessionID.uuidString)")
        }
        for original in session.actionRuns.reversed() where isActive(original.state) {
            _ = try await stopExactRun(
                original,
                sessionID: sessionID,
                timeoutSeconds: policies[original.actionID] ?? 8
            )
        }
    }

    private func completeLaunchTracking(sessionID: UUID) {
        guard sessionsBeingLaunched.remove(sessionID) != nil else { return }
        let waiters = launchCompletionWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForLaunchCompletion(sessionID: UUID) async {
        guard sessionsBeingLaunched.contains(sessionID) else { return }
        await withCheckedContinuation { continuation in
            if sessionsBeingLaunched.contains(sessionID) {
                launchCompletionWaiters[sessionID, default: []].append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func beginLeaseRenewal(for run: ActionRunRecord, action: LaunchAction, sessionID: UUID) {
        guard run.manager == .codexPort,
              run.state == .starting || run.state == .running,
              !stopRequestedSessions.contains(sessionID),
              leaseRenewalTasks[run.id] == nil else { return }

        let delay = renewalDelayNanoseconds(for: action.port.lease)
        let runID = run.id
        let lease = action.port.lease
        leaseRenewalTasks[runID] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }
                guard await self.renewManagedPortLease(
                    sessionID: sessionID,
                    runID: runID,
                    lease: lease
                ) else { break }
            }
            await self.leaseRenewalFinished(runID: runID)
        }
    }

    private func renewManagedPortLease(sessionID: UUID, runID: UUID, lease: String) async -> Bool {
        guard let run = renewableRun(sessionID: sessionID, runID: runID) else { return false }
        do {
            try await supervisor.renewCodexPort(run, lease: lease)
        } catch {
            // codex-port treats failed live-identity verification as ownership loss and may
            // archive the record. Never pile retries onto an unproven manager identity.
            return false
        }
        return renewableRun(sessionID: sessionID, runID: runID) != nil
    }

    private func renewableRun(sessionID: UUID, runID: UUID) -> ActionRunRecord? {
        guard !stopRequestedSessions.contains(sessionID),
              let session = try? store.session(id: sessionID)?.record,
              session.isActive,
              session.state != .stopping,
              let run = session.actionRuns.first(where: { $0.id == runID }),
              run.manager == .codexPort,
              run.state == .starting || run.state == .running else { return nil }
        return run
    }

    private func leaseRenewalFinished(runID: UUID) {
        leaseRenewalTasks.removeValue(forKey: runID)
    }

    private func cancelLeaseRenewals(for session: SessionRecord) {
        for run in session.actionRuns {
            leaseRenewalTasks.removeValue(forKey: run.id)?.cancel()
        }
    }

    private func renewalDelayNanoseconds(for lease: String) -> UInt64 {
        let seconds = leaseDurationSeconds(lease).map { min(max($0 * 0.25, 0.25), 300) } ?? 5
        return UInt64(seconds * 1_000_000_000)
    }

    private func leaseDurationSeconds(_ lease: String) -> TimeInterval? {
        let value = lease.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seconds = Double(value), seconds > 0 { return seconds }
        let units: [(suffix: String, multiplier: Double)] = [
            ("s", 1), ("m", 60), ("h", 3_600), ("d", 86_400),
        ]
        for unit in units where value.hasSuffix(unit.suffix) {
            let number = value.dropLast(unit.suffix.count)
            guard let amount = Double(number), amount > 0 else { return nil }
            return amount * unit.multiplier
        }
        return nil
    }

    /// Claims one exact run ID before awaiting the supervisor. This prevents the launch task and
    /// a concurrent CLOSE request from both trying to stop the same process while still allowing
    /// either side to finish the session from the supervisor callback.
    private func stopExactRun(
        _ proposed: ActionRunRecord,
        sessionID: UUID,
        timeoutSeconds: Int
    ) async throws -> StopAttempt {
        let latest = try store.session(id: sessionID)?.record.actionRuns.first(where: { $0.id == proposed.id }) ?? proposed
        guard isActive(latest.state) else { return StopAttempt(record: latest, performed: false) }
        guard !runStopsInFlight.contains(latest.id) else { return StopAttempt(record: latest, performed: false) }

        runStopsInFlight.insert(latest.id)
        let stopped = await supervisor.stop(latest, timeoutSeconds: timeoutSeconds) { [weak self] update in
            Task { await self?.applySupervisorUpdate(sessionID: sessionID, update: update) }
        }
        runStopsInFlight.remove(latest.id)
        let persisted = try upsert(run: stopped, sessionID: sessionID)
        let record = persisted.record.actionRuns.first(where: { $0.id == stopped.id }) ?? stopped
        return StopAttempt(record: record, performed: true)
    }

    private func applySupervisorUpdate(sessionID: UUID, update: ActionRunRecord) {
        _ = try? upsert(run: update, sessionID: sessionID)
    }

    /// Called by the supervisor while a verified non-port runner is still blocked at its start
    /// gate. Returning is the durability boundary that authorizes the acknowledgement and command
    /// release; throwing leaves the runner unacknowledged and makes the supervisor kill its exact
    /// process group.
    private func registerInitialRun(sessionID: UUID, run: ActionRunRecord) throws {
        try requireLaunchContinuation(sessionID: sessionID)
        let stored = try upsert(run: run, sessionID: sessionID)
        guard let registered = stored.record.actionRuns.first(where: { $0.id == run.id }),
              registered.pid == run.pid,
              registered.processGroupID == run.processGroupID,
              registered.pidStartIdentity == run.pidStartIdentity,
              registered.state == .starting || registered.state == .running else {
            throw ServiceFailure.conflict("The verified runner was not durably registered as an active exact process group.")
        }
    }

    private func upsert(run: ActionRunRecord, sessionID: UUID) throws -> StoredSessionRecord {
        guard let current = try store.session(id: sessionID) else { throw ServiceFailure.notFound("Session was not found: \(sessionID.uuidString)") }
        var session = current.record
        var accepted = run
        if let index = session.actionRuns.firstIndex(where: { $0.id == run.id }) {
            accepted = monotonicRunUpdate(
                existing: session.actionRuns[index],
                incoming: run,
                sessionID: sessionID
            )
            session.actionRuns[index] = accepted
        } else {
            if stopRequestedSessions.contains(sessionID), isActive(accepted.state) {
                accepted.state = .stopping
            }
            session.actionRuns.append(accepted)
        }
        session.state = derivedState(for: session)
        if !session.isActive { session.endedAt = session.endedAt ?? Date() }
        if accepted.state == .failed { session.lastError = accepted.message }
        if isTerminal(accepted.state) {
            leaseRenewalTasks.removeValue(forKey: accepted.id)?.cancel()
        }
        let updated = try store.updateSession(session, expectedRevision: current.storeRevision)
        if !updated.record.isActive, !sessionsBeingLaunched.contains(sessionID) {
            stopRequestedSessions.remove(sessionID)
        }
        return updated
    }

    /// Supervisor updates originate from multiple queues. Persist only forward lifecycle motion so
    /// a delayed `.running`/`.stopping` callback can never resurrect a terminal exact run.
    private func monotonicRunUpdate(
        existing: ActionRunRecord,
        incoming: ActionRunRecord,
        sessionID: UUID
    ) -> ActionRunRecord {
        if isTerminal(existing.state) { return existing }
        if existing.state == .stopping, incoming.state == .starting || incoming.state == .running {
            return existing
        }

        var candidate = incoming
        if stopRequestedSessions.contains(sessionID), candidate.state == .failed {
            candidate.state = .exited
            candidate.message = "Process exited during the requested shutdown."
        }
        if stopRequestedSessions.contains(sessionID), isActive(candidate.state), candidate.state != .stopping {
            candidate.state = .stopping
        }
        if runStateRank(candidate.state) < runStateRank(existing.state) {
            return existing
        }
        return candidate
    }

    private func runStateRank(_ state: ActionRunState) -> Int {
        switch state {
        case .starting: return 0
        case .running: return 1
        case .stopping: return 2
        case .exited, .failed, .orphaned: return 3
        }
    }

    private func isTerminal(_ state: ActionRunState) -> Bool {
        state == .exited || state == .failed || state == .orphaned
    }

    private func derivedState(for session: SessionRecord) -> SessionState {
        let states = session.actionRuns.map(\.state)
        if stopRequestedSessions.contains(session.id),
           sessionsBeingLaunched.contains(session.id) || states.contains(where: isActive) {
            return .stopping
        }
        if states.contains(.stopping) { return .stopping }
        // A compound launcher is not running until every ordered action has had its launch and
        // readiness phase. Earlier live actions must therefore remain represented as `starting`.
        if sessionsBeingLaunched.contains(session.id) { return .starting }
        if states.contains(where: isActive) {
            return states.contains(.failed) || states.contains(.orphaned) ? .partial : (states.contains(.starting) ? .starting : .running)
        }
        if states.contains(.failed) { return .failed }
        if states.contains(.orphaned) { return .orphaned }
        return .exited
    }

    private func isActive(_ state: ActionRunState) -> Bool {
        state == .starting || state == .running || state == .stopping
    }

    private func requireLaunchContinuation(sessionID: UUID) throws {
        if stopRequestedSessions.contains(sessionID) {
            throw LaunchControlFlow.stopRequested
        }
    }

    private func waitUntilReady(
        template: String,
        run: ActionRunRecord,
        timeoutSeconds: Int,
        sessionID: UUID
    ) async throws {
        try requireLaunchContinuation(sessionID: sessionID)
        let rendered = render(template: template, host: run.host, port: run.port)
        guard let url = URL(string: rendered), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ServiceFailure.badRequest("Health-check URL is invalid after port substitution: \(rendered)")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var lastMessage = "no response"
        while Date() < deadline {
            try requireLaunchContinuation(sessionID: sessionID)
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 1.5
                let (_, response) = try await URLSession.shared.data(for: request)
                try requireLaunchContinuation(sessionID: sessionID)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) { return }
                lastMessage = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "non-HTTP response"
            } catch LaunchControlFlow.stopRequested {
                throw LaunchControlFlow.stopRequested
            } catch {
                try requireLaunchContinuation(sessionID: sessionID)
                lastMessage = error.localizedDescription
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            try requireLaunchContinuation(sessionID: sessionID)
        }
        throw ServiceFailure.conflict("Timed out waiting for \(rendered): \(lastMessage)")
    }

    private func render(template: String, host: String?, port: Int?) -> String {
        let host = host ?? "127.0.0.1"
        let port = port.map(String.init) ?? ""
        return template
            .replacingOccurrences(of: "${HOST}", with: host)
            .replacingOccurrences(of: "${PORT}", with: port)
            .replacingOccurrences(of: "{{host}}", with: host)
            .replacingOccurrences(of: "{{port}}", with: port)
            .replacingOccurrences(of: "{host}", with: host)
            .replacingOccurrences(of: "{port}", with: port)
    }

    private func linkedActionEnvironment(
        session: SessionRecord,
        launcher: LauncherRecord
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for run in session.actionRuns where run.state == .running {
            guard let action = launcher.actions.first(where: { $0.id == run.actionID }) else { continue }
            let base = LauncherValidation.linkedActionEnvironmentBase(for: action)
            if let host = run.host { environment["\(base)_HOST"] = host }
            if let port = run.port { environment["\(base)_PORT"] = String(port) }
            if let endpoint = run.endpointURL { environment["\(base)_URL"] = endpoint }
        }
        return environment
    }

    private func sessionLogs(id: UUID) throws -> SessionLogResponse {
        guard let session = try store.session(id: id)?.record else { throw ServiceFailure.notFound("Session was not found: \(id.uuidString)") }
        var sections: [String] = []
        var diagnoses: [LaunchFailureDiagnosis] = []
        for run in session.actionRuns {
            var body = run.message ?? "No log was produced."
            if let path = run.logPath, FileManager.default.fileExists(atPath: path) {
                body = (try? tail(path: path, maximumBytes: 512 * 1024)) ?? body
            }
            if let diagnosis = run.failureDiagnosis {
                diagnoses.append(diagnosis)
            } else if run.state == .failed || run.state == .orphaned {
                diagnoses.append(
                    LaunchFailureDiagnoser.diagnose(
                        LaunchFailureDiagnosisInput(
                            launcherMessage: run.message,
                            logText: body,
                            processStarted: run.pid != nil,
                            launcherRequestedCleanup: false
                        )
                    )
                )
            }
            sections.append("== \(run.actionName) [\(run.state.rawValue)] ==\n\(body)")
        }
        return SessionLogResponse(
            text: sections.isEmpty ? "No action logs are available." : sections.joined(separator: "\n\n"),
            diagnoses: diagnoses
        )
    }

    private func tail(path: String, maximumBytes: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > maximumBytes ? end - maximumBytes : 0)
        return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    }

    private func requireLauncherDetail(id: UUID) throws -> LauncherDetail {
        guard let detail = try store.launcherDetail(id: id) else { throw ServiceFailure.notFound("Launcher was not found: \(id.uuidString)") }
        return detail
    }

    private func requireSessionRecord(id: UUID) throws -> SessionRecord {
        guard let session = try store.session(id: id)?.record else {
            throw ServiceFailure.notFound("Session was not found: \(id.uuidString)")
        }
        return session
    }

    private func requireSkillManager() throws -> LauncherSkillManager {
        guard let skillManager else {
            throw LauncherSkillError.bundledSkillUnavailable("the daemon could not locate its signed skill resources.")
        }
        return skillManager
    }

    private func serviceStatus() -> ServiceStatus {
        ServiceStatus(version: serviceVersion, pid: getpid(), startedAt: startedAt, endpoint: endpoint)
    }

    private func decode<T: Decodable>(_ request: HTTPRequest) throws -> T {
        guard !request.body.isEmpty else { throw ServiceFailure.badRequest("JSON request body is required.") }
        do { return try LauncherJSON.decoder().decode(T.self, from: request.body) }
        catch { throw ServiceFailure.badRequest("Invalid JSON request: \(error.localizedDescription)") }
    }

    private func uuid(_ raw: String, entity: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else { throw ServiceFailure.badRequest("Invalid \(entity) ID: \(raw)") }
        return value
    }

    private func requireIfMatch(_ request: HTTPRequest, expected: Int) throws {
        guard let raw = request.headers["if-match"], let supplied = Int(raw), supplied == expected else {
            throw ServiceFailure.precondition("If-Match must equal the expected revision in the request body.")
        }
    }

    private func response(for error: Error, requestID: String) -> HTTPResponse {
        if let failure = error as? ServiceFailure {
            switch failure {
            case .badRequest: return .error(status: 400, code: "bad_request", message: failure.localizedDescription, requestID: requestID)
            case .notFound: return .error(status: 404, code: "not_found", message: failure.localizedDescription, requestID: requestID)
            case .conflict: return .error(status: 409, code: "conflict", message: failure.localizedDescription, requestID: requestID)
            case .precondition: return .error(status: 412, code: "stale_revision", message: failure.localizedDescription, requestID: requestID)
            }
        }
        if let sqlite = error as? SQLiteStoreError {
            switch sqlite {
            case .notFound: return .error(status: 404, code: "not_found", message: sqlite.localizedDescription, requestID: requestID)
            case .duplicateLauncherName, .duplicateProjectDirectory, .launcherHasActiveSessions,
                 .projectHasLaunchers, .primarySessionAlreadyActive:
                return .error(status: 409, code: "conflict", message: sqlite.localizedDescription, requestID: requestID)
            case .staleRevision:
                return .error(status: 412, code: "stale_revision", message: sqlite.localizedDescription, requestID: requestID)
            case .validation, .immutableField:
                return .error(status: 422, code: "validation_failed", message: sqlite.localizedDescription, requestID: requestID)
            default:
                return .error(status: 500, code: "database_error", message: sqlite.localizedDescription, requestID: requestID)
            }
        }
        if error is LauncherValidationError {
            return .error(status: 422, code: "validation_failed", message: error.localizedDescription, requestID: requestID)
        }
        if let external = error as? ExternalProcessControlError {
            switch external {
            case .notFound:
                return .error(status: 404, code: "external_process_not_found", message: external.localizedDescription, requestID: requestID)
            case .notClosable, .confirmationRequired, .stale:
                return .error(status: 409, code: "external_process_confirmation_required", message: external.localizedDescription, requestID: requestID)
            case .operationFailed:
                return .error(status: 500, code: "external_process_operation_failed", message: external.localizedDescription, requestID: requestID)
            }
        }
        if let inspection = error as? ExternalInspectionError {
            return .error(status: 503, code: "external_process_inspection_unavailable", message: inspection.localizedDescription, requestID: requestID)
        }
        if let supervisor = error as? ProcessSupervisorError {
            switch supervisor {
            case .invalidSessionOpenOption:
                return .error(status: 422, code: "invalid_session_open_option", message: supervisor.localizedDescription, requestID: requestID)
            case .sessionOpenUnavailable, .expoOpenFailed:
                return .error(status: 409, code: "session_open_unavailable", message: supervisor.localizedDescription, requestID: requestID)
            default:
                break
            }
        }
        if let skill = error as? LauncherSkillError {
            switch skill {
            case .hostUnavailable:
                return .error(status: 422, code: "host_unavailable", message: skill.localizedDescription, requestID: requestID)
            case .unsafeDestination:
                return .error(status: 409, code: "unsafe_destination", message: skill.localizedDescription, requestID: requestID)
            case .bundledSkillUnavailable:
                return .error(status: 503, code: "skill_bundle_unavailable", message: skill.localizedDescription, requestID: requestID)
            case .installationFailed:
                return .error(status: 500, code: "skill_install_failed", message: skill.localizedDescription, requestID: requestID)
            }
        }
        if let uninstall = error as? LauncherSkillUninstallError {
            return .error(
                status: 409,
                code: "skill_uninstall_refused",
                message: uninstall.localizedDescription,
                requestID: requestID
            )
        }
        return .error(status: 500, code: "internal_error", message: error.localizedDescription, requestID: requestID)
    }
}
