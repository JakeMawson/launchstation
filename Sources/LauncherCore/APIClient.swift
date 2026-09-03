import Foundation

public enum LauncherAPIError: LocalizedError, Equatable {
    case serviceUnavailable(String)
    case invalidMetadata(String)
    case invalidResponse
    case server(status: Int, code: String, message: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let message): return "Launcher service unavailable: \(message)"
        case .invalidMetadata(let message): return "Invalid launcher service metadata: \(message)"
        case .invalidResponse: return "Launcher service returned an invalid response."
        case .server(_, _, let message): return message
        case .transport(let message): return "Launcher API request failed: \(message)"
        }
    }
}

public actor LauncherAPIClient {
    public static let `default` = LauncherAPIClient()

    private let metadataURL: URL
    private let session: URLSession
    private let serviceKickstarter: @Sendable () throws -> Void
    private let serviceRecoveryDelayNanoseconds: UInt64
    private let serviceReadinessRetryDelayNanoseconds: UInt64
    private let serviceReadinessMaxAttempts: Int

    private enum RequestPolicy {
        case safeRead
        case mutation
        case lifecycle

        var timeoutInterval: TimeInterval {
            switch self {
            case .safeRead:
                return 15
            case .mutation:
                return 30
            case .lifecycle:
                // A compound launch can legitimately wait through several action
                // readiness/stop windows before the daemon returns its snapshot.
                return 3_600
            }
        }

        var allowsTransportRecovery: Bool {
            self == .safeRead
        }

        static func standard(for method: String) -> RequestPolicy {
            method.uppercased() == "GET" ? .safeRead : .mutation
        }
    }

    public init(metadataURL: URL = LauncherPaths.serviceMetadataURL, session: URLSession = .shared) {
        self.metadataURL = metadataURL
        self.session = session
        self.serviceKickstarter = { try LauncherPaths.kickstartService() }
        self.serviceRecoveryDelayNanoseconds = 350_000_000
        self.serviceReadinessRetryDelayNanoseconds = 250_000_000
        self.serviceReadinessMaxAttempts = 60
    }

    init(
        metadataURL: URL,
        session: URLSession,
        serviceKickstarter: @escaping @Sendable () throws -> Void,
        serviceRecoveryDelayNanoseconds: UInt64 = 0,
        serviceReadinessRetryDelayNanoseconds: UInt64 = 0,
        serviceReadinessMaxAttempts: Int = 40
    ) {
        self.metadataURL = metadataURL
        self.session = session
        self.serviceKickstarter = serviceKickstarter
        self.serviceRecoveryDelayNanoseconds = serviceRecoveryDelayNanoseconds
        self.serviceReadinessRetryDelayNanoseconds = serviceReadinessRetryDelayNanoseconds
        self.serviceReadinessMaxAttempts = max(1, serviceReadinessMaxAttempts)
    }

    public func health() async throws -> ServiceStatus {
        try await request(method: "GET", path: "/v1/health")
    }

    /// Checks the currently published service without changing launchd state or retrying. The GUI
    /// uses this once at startup so it can distinguish an ordinary catalog load from a daemon
    /// recovery that deserves an explicit progress state.
    public func probeHealth() async throws -> ServiceStatus {
        try await request(
            method: "GET",
            path: "/v1/health",
            data: nil,
            expectedRevision: nil,
            policy: .safeRead,
            retryMetadata: false,
            retryTransport: false
        )
    }

    /// Starts the exact installed user LaunchAgent and waits for fresh authenticated health.
    /// Readiness is bounded so a missing/broken installation becomes an actionable GUI error
    /// instead of an indefinite loading state.
    public func startServiceAndWaitUntilReady() async throws -> ServiceStatus {
        try serviceKickstarter()
        var lastError: Error = LauncherAPIError.serviceUnavailable(
            "the launcher service did not become ready"
        )

        for attempt in 0..<serviceReadinessMaxAttempts {
            do {
                return try await probeHealth()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LauncherAPIError {
                if case .invalidMetadata = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }

            guard attempt + 1 < serviceReadinessMaxAttempts else { break }
            if serviceReadinessRetryDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: serviceReadinessRetryDelayNanoseconds)
            }
        }
        throw lastError
    }

    public func snapshot() async throws -> CatalogSnapshot {
        try await request(method: "GET", path: "/v1/snapshot")
    }

    /// Atomically confirms the daemon has no active or in-flight launcher lifecycle and reserves
    /// mutations long enough for an installer to terminate and replace that exact service.
    public func prepareUpgrade() async throws -> UpgradeMaintenanceReservation {
        try await request(method: "POST", path: "/v1/maintenance/upgrade/prepare")
    }

    /// Releases only the matching live upgrade reservation. Use this when installation fails
    /// before the daemon is terminated; a daemon restart clears the in-memory reservation.
    public func cancelUpgrade(reservationToken: String) async throws -> EmptyResponse {
        try await request(
            method: "POST",
            path: "/v1/maintenance/upgrade/cancel",
            body: UpgradeMaintenanceCancelRequest(reservationToken: reservationToken)
        )
    }

    public func initializeProject(directory: String, displayName: String? = nil) async throws -> ProjectRecord {
        try await request(method: "POST", path: "/v1/projects/init", body: ProjectInitRequest(directory: directory, displayName: displayName))
    }

    public func updateProject(id: UUID, patch: ProjectPatchRequest) async throws -> ProjectRecord {
        try await request(
            method: "PATCH",
            path: "/v1/projects/\(id.uuidString)",
            body: patch,
            expectedRevision: patch.expectedRevision
        )
    }

    public func projects() async throws -> [ProjectRecord] {
        try await request(method: "GET", path: "/v1/projects")
    }

    public func resolveProject(directory: String) async throws -> ProjectRecord {
        return try await request(
            method: "GET",
            path: Self.path("/v1/projects/resolve", queryName: "directory", value: directory)
        )
    }

    public func createLauncher(_ requestBody: LauncherCreateRequest) async throws -> LauncherDetail {
        try await request(method: "POST", path: "/v1/launchers", body: requestBody)
    }

    public func listLaunchers(query: String? = nil) async throws -> [LauncherDetail] {
        let path: String
        if let query, !query.isEmpty {
            path = Self.path("/v1/launchers", queryName: "q", value: query)
        } else {
            path = "/v1/launchers"
        }
        return try await request(method: "GET", path: path)
    }

    public func launcher(named name: String) async throws -> LauncherDetail {
        let encoded = Self.percentEncodeComponent(name)
        return try await request(method: "GET", path: "/v1/launchers/by-name/\(encoded)")
    }

    public func launcher(id: UUID) async throws -> LauncherDetail {
        try await request(method: "GET", path: "/v1/launchers/\(id.uuidString)")
    }

    public func updateLauncher(id: UUID, patch: LauncherPatchRequest) async throws -> LauncherDetail {
        try await request(method: "PATCH", path: "/v1/launchers/\(id.uuidString)", body: patch, expectedRevision: patch.expectedRevision)
    }

    public func addAction(launcherID: UUID, requestBody: ActionCreateRequest) async throws -> LauncherDetail {
        try await request(method: "POST", path: "/v1/launchers/\(launcherID.uuidString)/actions", body: requestBody, expectedRevision: requestBody.expectedRevision)
    }

    public func updateAction(launcherID: UUID, actionID: UUID, requestBody: ActionPatchRequest) async throws -> LauncherDetail {
        try await request(method: "PATCH", path: "/v1/launchers/\(launcherID.uuidString)/actions/\(actionID.uuidString)", body: requestBody, expectedRevision: requestBody.expectedRevision)
    }

    public func deleteAction(launcherID: UUID, actionID: UUID, expectedRevision: Int) async throws -> LauncherDetail {
        try await request(method: "DELETE", path: "/v1/launchers/\(launcherID.uuidString)/actions/\(actionID.uuidString)", body: ["expectedRevision": expectedRevision], expectedRevision: expectedRevision)
    }

    public func deleteIntent(launcherID: UUID) async throws -> DeleteIntent {
        try await request(method: "POST", path: "/v1/launchers/\(launcherID.uuidString)/delete-intent", body: EmptyResponse())
    }

    public func deleteLauncher(id: UUID, requestBody: DeleteRequest) async throws -> EmptyResponse {
        try await request(method: "DELETE", path: "/v1/launchers/\(id.uuidString)", body: requestBody, expectedRevision: requestBody.expectedRevision)
    }

    public func startLauncher(
        id: UUID,
        runtimeArguments: [String] = [],
        openRequested: Bool = false,
        expectedLauncherRevision: Int? = nil,
        mode: SessionStartMode = .reusePrimary
    ) async throws -> SessionRecord {
        try await request(
            method: "POST",
            path: "/v1/launchers/\(id.uuidString)/sessions",
            body: SessionStartRequest(
                runtimeArguments: runtimeArguments,
                openRequested: openRequested,
                expectedLauncherRevision: expectedLauncherRevision,
                mode: mode
            ),
            policy: .lifecycle
        )
    }

    public func relaunchLauncher(
        id: UUID,
        runtimeArguments: [String] = [],
        openRequested: Bool = false,
        expectedSessionID: UUID? = nil,
        requireIdle: Bool = false,
        expectedLauncherRevision: Int? = nil
    ) async throws -> SessionRelaunchResult {
        try await request(
            method: "POST",
            path: "/v1/launchers/\(id.uuidString)/relaunch",
            body: SessionRelaunchRequest(
                runtimeArguments: runtimeArguments,
                openRequested: openRequested,
                expectedSessionID: expectedSessionID,
                requireIdle: requireIdle,
                expectedLauncherRevision: expectedLauncherRevision
            ),
            policy: .lifecycle
        )
    }

    public func relaunchSession(
        id: UUID,
        runtimeArguments: [String] = [],
        openRequested: Bool = false,
        expectedLauncherRevision: Int? = nil
    ) async throws -> SessionRelaunchResult {
        try await request(
            method: "POST",
            path: "/v1/sessions/\(id.uuidString)/relaunch",
            body: SessionRelaunchRequest(
                runtimeArguments: runtimeArguments,
                openRequested: openRequested,
                expectedSessionID: id,
                requireIdle: false,
                expectedLauncherRevision: expectedLauncherRevision
            ),
            policy: .lifecycle
        )
    }

    public func stopSession(id: UUID) async throws -> SessionRecord {
        try await request(
            method: "POST",
            path: "/v1/sessions/\(id.uuidString)/stop",
            body: EmptyResponse(),
            policy: .lifecycle
        )
    }

    public func sessions(activeOnly: Bool = false) async throws -> [SessionRecord] {
        let path = activeOnly
            ? Self.path("/v1/sessions", queryName: "active", value: "true")
            : "/v1/sessions"
        return try await request(method: "GET", path: path)
    }

    public func sessionRecord(id: UUID) async throws -> SessionRecord {
        try await request(method: "GET", path: "/v1/sessions/\(id.uuidString)")
    }

    /// Returns the most recently observed external-process inventory when it is available. Use
    /// `fresh: true` before proposing a draft or beginning a confirmation-bound close flow.
    public func externalProcessSnapshot(fresh: Bool = false) async throws -> ExternalProcessSnapshot {
        try await request(
            method: "GET",
            path: fresh ? "/v1/external-processes/refresh" : "/v1/external-processes"
        )
    }

    public func externalLauncherDraft(observationID: UUID) async throws -> ExternalLauncherDraft {
        try await request(
            method: "GET",
            path: "/v1/external-processes/\(observationID.uuidString)/draft"
        )
    }

    public func makeExternalCloseIntent(observationID: UUID) async throws -> ExternalCloseIntent {
        try await request(
            method: "POST",
            path: "/v1/external-processes/\(observationID.uuidString)/close-intent",
            body: EmptyResponse()
        )
    }

    public func closeExternalProcess(_ requestBody: ExternalCloseRequest) async throws -> ExternalCloseResult {
        try await request(
            method: "POST",
            path: "/v1/external-processes/\(requestBody.observationID.uuidString)/close",
            body: requestBody
        )
    }

    public func sessionOpenOptions(sessionID: UUID) async throws -> [SessionOpenOption] {
        try await request(method: "GET", path: "/v1/sessions/\(sessionID.uuidString)/open-options")
    }

    public func openSessionOption(sessionID: UUID, optionID: String) async throws -> SessionOpenResult {
        try await request(
            method: "POST",
            path: "/v1/sessions/\(sessionID.uuidString)/open",
            body: SessionOpenRequest(optionID: optionID)
        )
    }

    public func probeSessionOpenOption(sessionID: UUID, optionID: String) async throws -> SessionOpenProbeResult {
        try await request(
            method: "POST",
            path: "/v1/sessions/\(sessionID.uuidString)/open-probe",
            body: SessionOpenRequest(optionID: optionID)
        )
    }

    public func sessionHistory(
        launcherID: UUID? = nil,
        state: SessionState? = nil,
        role: SessionLaunchRole? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> SessionHistoryPage {
        var query: [(String, String)] = [("limit", String(limit))]
        if let launcherID { query.append(("launcherID", launcherID.uuidString)) }
        if let state { query.append(("state", state.rawValue)) }
        if let role { query.append(("role", role.rawValue)) }
        if let cursor { query.append(("cursor", cursor)) }
        return try await request(
            method: "GET",
            path: Self.path("/v1/history/sessions", query: query)
        )
    }

    public func launcherSkillStatus() async throws -> LauncherSkillStatus {
        try await request(method: "GET", path: "/v1/skills/status")
    }

    public func launcherSkillSource() async throws -> LauncherSkillSource {
        try await request(method: "GET", path: "/v1/skills/source")
    }

    public func installLauncherSkill(for host: LauncherSkillHost) async throws -> LauncherSkillInstallResult {
        try await request(
            method: "POST",
            path: "/v1/skills/install",
            body: LauncherSkillInstallRequest(host: host)
        )
    }

    public func prepareLauncherSkillUninstall(for host: LauncherSkillHost) async throws -> LauncherSkillUninstallIntent {
        try await request(
            method: "POST",
            path: "/v1/skills/uninstall-intent",
            body: LauncherSkillUninstallIntentRequest(host: host)
        )
    }

    public func uninstallLauncherSkill(
        request requestBody: LauncherSkillUninstallRequest
    ) async throws -> LauncherSkillUninstallResponse {
        try await request(
            method: "POST",
            path: "/v1/skills/uninstall",
            body: requestBody
        )
    }

    public func uninstallLauncherSkill(
        intent: LauncherSkillUninstallIntent,
        confirmationText: String
    ) async throws -> LauncherSkillUninstallResponse {
        try await uninstallLauncherSkill(
            request: LauncherSkillUninstallRequest(intent: intent, confirmationText: confirmationText)
        )
    }

    public func logText(sessionID: UUID) async throws -> String {
        try await sessionLog(sessionID: sessionID).text
    }

    public func sessionLog(sessionID: UUID) async throws -> SessionLogResponse {
        try await request(method: "GET", path: "/v1/sessions/\(sessionID.uuidString)/logs")
    }

    public func syncProject(id: UUID, repair: Bool) async throws -> SyncResult {
        try await request(method: "POST", path: "/v1/projects/\(id.uuidString)/sync", body: ["repair": repair])
    }

    public func apiEndpoint() throws -> String {
        try loadMetadata().endpoint
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        expectedRevision: Int? = nil,
        policy: RequestPolicy? = nil
    ) async throws -> Response {
        let requestPolicy = policy ?? .standard(for: method)
        return try await request(
            method: method,
            path: path,
            data: nil,
            expectedRevision: expectedRevision,
            policy: requestPolicy,
            retryMetadata: true,
            retryTransport: requestPolicy.allowsTransportRecovery
        )
    }

    private func request<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Body,
        expectedRevision: Int? = nil,
        policy: RequestPolicy? = nil
    ) async throws -> Response {
        let data = try LauncherJSON.encoder().encode(body)
        let requestPolicy = policy ?? .standard(for: method)
        return try await request(
            method: method,
            path: path,
            data: data,
            expectedRevision: expectedRevision,
            policy: requestPolicy,
            retryMetadata: true,
            retryTransport: requestPolicy.allowsTransportRecovery
        )
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        data: Data?,
        expectedRevision: Int?,
        policy: RequestPolicy,
        retryMetadata: Bool,
        retryTransport: Bool
    ) async throws -> Response {
        let metadata: ServiceMetadata
        do {
            metadata = try loadMetadata()
        } catch {
            if let apiError = error as? LauncherAPIError,
               case .invalidMetadata = apiError {
                // Existing but incompatible or malformed metadata is authoritative evidence of
                // a client/service mismatch. Restarting that same job cannot make the request
                // safe and would mutate process state during a compatibility refusal.
                throw apiError
            }
            // No request can have reached the daemon before metadata is loaded, so one
            // kickstart/reload is safe even for a mutation. This is distinct from retrying
            // a mutation after an ambiguous transport failure.
            if retryMetadata {
                try await recoverService()
                return try await self.request(
                    method: method,
                    path: path,
                    data: data,
                    expectedRevision: expectedRevision,
                    policy: policy,
                    retryMetadata: false,
                    retryTransport: retryTransport
                )
            }
            throw error
        }

        guard let baseURL = URL(string: metadata.endpoint), let url = URL(string: path, relativeTo: baseURL) else {
            throw LauncherAPIError.invalidMetadata("endpoint is not a valid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = policy.timeoutInterval
        request.setValue("Bearer \(metadata.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let expectedRevision {
            request.setValue("\(expectedRevision)", forHTTPHeaderField: "If-Match")
        }
        if let data {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let responseData: Data
        let rawResponse: URLResponse
        do {
            (responseData, rawResponse) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if retryTransport {
                try await recoverService()
                return try await self.request(
                    method: method,
                    path: path,
                    data: data,
                    expectedRevision: expectedRevision,
                    policy: policy,
                    retryMetadata: false,
                    retryTransport: false
                )
            }
            throw LauncherAPIError.transport(error.localizedDescription)
        }

        guard let response = rawResponse as? HTTPURLResponse else {
            throw LauncherAPIError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if let envelope = try? LauncherJSON.decoder().decode(APIErrorEnvelope.self, from: responseData) {
                throw LauncherAPIError.server(status: response.statusCode, code: envelope.error.code, message: envelope.error.message)
            }
            throw LauncherAPIError.server(status: response.statusCode, code: "http_\(response.statusCode)", message: "Launcher service returned HTTP \(response.statusCode).")
        }
        if Response.self == EmptyResponse.self, responseData.isEmpty {
            return EmptyResponse() as! Response
        }
        do {
            return try LauncherJSON.decoder().decode(Response.self, from: responseData)
        } catch {
            throw LauncherAPIError.invalidResponse
        }
    }

    private func recoverService() async throws {
        try? serviceKickstarter()
        if serviceRecoveryDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: serviceRecoveryDelayNanoseconds)
        }
    }

    private static let URLComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: URLComponentAllowed) ?? value
    }

    private static func path(_ path: String, queryName: String, value: String) -> String {
        "\(path)?\(percentEncodeComponent(queryName))=\(percentEncodeComponent(value))"
    }

    private static func path(_ path: String, query: [(String, String)]) -> String {
        guard !query.isEmpty else { return path }
        let encoded = query.map {
            "\(percentEncodeComponent($0.0))=\(percentEncodeComponent($0.1))"
        }.joined(separator: "&")
        return "\(path)?\(encoded)"
    }

    private func loadMetadata() throws -> ServiceMetadata {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw LauncherAPIError.serviceUnavailable("service metadata does not exist; install or start the LaunchAgent")
        }
        do {
            let metadata = try LauncherJSON.decoder().decode(
                ServiceMetadata.self,
                from: Data(contentsOf: metadataURL)
            )
            let status = ServiceStatus(
                version: metadata.version,
                schemaVersion: metadata.schemaVersion,
                pid: metadata.pid,
                startedAt: metadata.startedAt,
                endpoint: metadata.endpoint
            )
            if let reason = LauncherCompatibility.incompatibilityReason(for: status) {
                throw LauncherAPIError.invalidMetadata(reason)
            }
            return metadata
        } catch let error as LauncherAPIError {
            throw error
        } catch {
            throw LauncherAPIError.invalidMetadata(error.localizedDescription)
        }
    }
}
