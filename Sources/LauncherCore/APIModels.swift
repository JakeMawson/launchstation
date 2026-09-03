import Foundation

public struct ProjectInitRequest: Codable, Equatable, Sendable {
    public var directory: String
    public var displayName: String?

    public init(directory: String, displayName: String? = nil) {
        self.directory = directory
        self.displayName = displayName
    }
}

public struct ProjectPatchRequest: Codable, Equatable, Sendable {
    public var expectedRevision: Int
    public var displayName: String

    public init(expectedRevision: Int, displayName: String) {
        self.expectedRevision = expectedRevision
        self.displayName = displayName
    }
}

public struct LauncherCreateRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var name: String
    public var description: String
    public var runDetails: String?
    public var tags: [String]
    public var primaryAction: LaunchAction

    public init(
        projectID: UUID,
        name: String,
        description: String,
        runDetails: String? = nil,
        tags: [String] = [],
        primaryAction: LaunchAction
    ) {
        self.projectID = projectID
        self.name = name
        self.description = description
        self.runDetails = runDetails
        self.tags = tags
        self.primaryAction = primaryAction
    }
}

public struct LauncherPatchRequest: Codable, Equatable, Sendable {
    public var expectedRevision: Int
    public var name: String?
    public var description: String?
    public var runDetails: String?
    public var clearRunDetails: Bool
    public var replaceTags: [String]?
    public var addTags: [String]
    public var removeTags: [String]
    public var primaryAction: LaunchAction?
    public var primaryActionID: UUID?

    public init(
        expectedRevision: Int,
        name: String? = nil,
        description: String? = nil,
        runDetails: String? = nil,
        clearRunDetails: Bool = false,
        replaceTags: [String]? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        primaryAction: LaunchAction? = nil,
        primaryActionID: UUID? = nil
    ) {
        self.expectedRevision = expectedRevision
        self.name = name
        self.description = description
        self.runDetails = runDetails
        self.clearRunDetails = clearRunDetails
        self.replaceTags = replaceTags
        self.addTags = addTags
        self.removeTags = removeTags
        self.primaryAction = primaryAction
        self.primaryActionID = primaryActionID
    }
}

public struct ActionCreateRequest: Codable, Equatable, Sendable {
    public var expectedRevision: Int
    public var action: LaunchAction

    public init(expectedRevision: Int, action: LaunchAction) {
        self.expectedRevision = expectedRevision
        self.action = action
    }
}

public struct ActionPatchRequest: Codable, Equatable, Sendable {
    public var expectedRevision: Int
    public var action: LaunchAction

    public init(expectedRevision: Int, action: LaunchAction) {
        self.expectedRevision = expectedRevision
        self.action = action
    }
}

public struct SessionStartRequest: Codable, Equatable, Sendable {
    public var runtimeArguments: [String]
    public var openRequested: Bool
    public var expectedLauncherRevision: Int?
    public var mode: SessionStartMode

    public init(
        runtimeArguments: [String] = [],
        openRequested: Bool = false,
        expectedLauncherRevision: Int? = nil,
        mode: SessionStartMode = .reusePrimary
    ) {
        self.runtimeArguments = runtimeArguments
        self.openRequested = openRequested
        self.expectedLauncherRevision = expectedLauncherRevision
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeArguments
        case openRequested
        case expectedLauncherRevision
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeArguments = try container.decodeIfPresent([String].self, forKey: .runtimeArguments) ?? []
        openRequested = try container.decodeIfPresent(Bool.self, forKey: .openRequested) ?? false
        expectedLauncherRevision = try container.decodeIfPresent(Int.self, forKey: .expectedLauncherRevision)
        mode = try container.decodeIfPresent(SessionStartMode.self, forKey: .mode) ?? .reusePrimary
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeArguments, forKey: .runtimeArguments)
        try container.encode(openRequested, forKey: .openRequested)
        try container.encodeIfPresent(expectedLauncherRevision, forKey: .expectedLauncherRevision)
        try container.encode(mode, forKey: .mode)
    }
}

public struct SessionRelaunchResult: Codable, Equatable, Sendable {
    public var previousSession: SessionRecord?
    public var session: SessionRecord

    public init(previousSession: SessionRecord?, session: SessionRecord) {
        self.previousSession = previousSession
        self.session = session
    }
}

public struct SessionRelaunchRequest: Codable, Equatable, Sendable {
    public var runtimeArguments: [String]
    public var openRequested: Bool
    public var expectedSessionID: UUID?
    public var requireIdle: Bool
    public var expectedLauncherRevision: Int?

    public init(
        runtimeArguments: [String] = [],
        openRequested: Bool = false,
        expectedSessionID: UUID? = nil,
        requireIdle: Bool = false,
        expectedLauncherRevision: Int? = nil
    ) {
        self.runtimeArguments = runtimeArguments
        self.openRequested = openRequested
        self.expectedSessionID = expectedSessionID
        self.requireIdle = requireIdle
        self.expectedLauncherRevision = expectedLauncherRevision
    }

    public var startRequest: SessionStartRequest {
        startRequest(mode: .reusePrimary)
    }

    public func startRequest(mode: SessionStartMode) -> SessionStartRequest {
        SessionStartRequest(
            runtimeArguments: runtimeArguments,
            openRequested: openRequested,
            expectedLauncherRevision: expectedLauncherRevision,
            mode: mode
        )
    }

    private enum CodingKeys: String, CodingKey {
        case runtimeArguments
        case openRequested
        case expectedSessionID
        case requireIdle
        case expectedLauncherRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeArguments = try container.decodeIfPresent([String].self, forKey: .runtimeArguments) ?? []
        openRequested = try container.decodeIfPresent(Bool.self, forKey: .openRequested) ?? false
        expectedSessionID = try container.decodeIfPresent(UUID.self, forKey: .expectedSessionID)
        requireIdle = try container.decodeIfPresent(Bool.self, forKey: .requireIdle) ?? false
        expectedLauncherRevision = try container.decodeIfPresent(Int.self, forKey: .expectedLauncherRevision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runtimeArguments, forKey: .runtimeArguments)
        try container.encode(openRequested, forKey: .openRequested)
        try container.encodeIfPresent(expectedSessionID, forKey: .expectedSessionID)
        try container.encode(requireIdle, forKey: .requireIdle)
        try container.encodeIfPresent(expectedLauncherRevision, forKey: .expectedLauncherRevision)
    }
}

public struct SessionHistoryPage: Codable, Equatable, Sendable {
    public var sessions: [SessionRecord]
    public var nextCursor: String?

    public init(sessions: [SessionRecord], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

/// A short-lived, daemon-owned gate used while replacing the installed app bundle.
///
/// `reservationToken` is a cancellation capability, not the service bearer token. Callers
/// should keep it in memory and must not include it in logs.
public struct UpgradeMaintenanceReservation: Codable, Equatable, Sendable {
    public var reservationToken: String
    public var expiresAt: Date

    public init(reservationToken: String, expiresAt: Date) {
        self.reservationToken = reservationToken
        self.expiresAt = expiresAt
    }
}

public struct UpgradeMaintenanceCancelRequest: Codable, Equatable, Sendable {
    public var reservationToken: String

    public init(reservationToken: String) {
        self.reservationToken = reservationToken
    }
}

public enum LauncherSkillHost: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode = "claude-code"

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }
}

public enum LauncherSkillSurface: String, Codable, CaseIterable, Sendable {
    case desktop
    case cli

    public var displayName: String {
        switch self {
        case .desktop: return "Desktop"
        case .cli: return "CLI"
        }
    }
}

public struct LauncherSkillSurfaceStatus: Codable, Equatable, Identifiable, Sendable {
    public var surface: LauncherSkillSurface
    public var available: Bool
    public var detectedPath: String?
    public var message: String

    public init(
        surface: LauncherSkillSurface,
        available: Bool,
        detectedPath: String? = nil,
        message: String
    ) {
        self.surface = surface
        self.available = available
        self.detectedPath = detectedPath
        self.message = message
    }

    public var id: LauncherSkillSurface { surface }
}

public enum LauncherSkillInstallationState: String, Codable, CaseIterable, Sendable {
    case unavailable
    case notInstalled = "not-installed"
    case outdated
    case current
    case blocked
}

public struct LauncherSkillHostStatus: Codable, Equatable, Identifiable, Sendable {
    public var host: LauncherSkillHost
    public var available: Bool
    public var surfaces: [LauncherSkillSurfaceStatus]
    public var installationPath: String
    public var state: LauncherSkillInstallationState
    public var installedVersion: String?
    public var message: String
    public var managementState: LauncherSkillUninstallInspectionState
    public var canUninstall: Bool
    public var preservedCount: Int
    public var managementMessage: String

    public init(
        host: LauncherSkillHost,
        available: Bool,
        surfaces: [LauncherSkillSurfaceStatus] = [],
        installationPath: String,
        state: LauncherSkillInstallationState,
        installedVersion: String? = nil,
        message: String,
        managementState: LauncherSkillUninstallInspectionState = .unrecognized,
        canUninstall: Bool = false,
        preservedCount: Int = 0,
        managementMessage: String = "Uninstall proof is unavailable from this service response."
    ) {
        self.host = host
        self.available = available
        self.surfaces = surfaces
        self.installationPath = installationPath
        self.state = state
        self.installedVersion = installedVersion
        self.message = message
        self.managementState = managementState
        self.canUninstall = canUninstall
        self.preservedCount = preservedCount
        self.managementMessage = managementMessage
    }

    public var id: LauncherSkillHost { host }
    public var needsInstallation: Bool { available && state != .current && state != .blocked }

    public func surfaceStatus(for surface: LauncherSkillSurface) -> LauncherSkillSurfaceStatus? {
        surfaces.first { $0.surface == surface }
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case available
        case surfaces
        case installationPath
        case state
        case installedVersion
        case message
        case managementState
        case canUninstall
        case preservedCount
        case managementMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(LauncherSkillHost.self, forKey: .host)
        surfaces = try container.decodeIfPresent([LauncherSkillSurfaceStatus].self, forKey: .surfaces) ?? []
        available = try container.decodeIfPresent(Bool.self, forKey: .available)
            ?? surfaces.contains(where: \.available)
        installationPath = try container.decode(String.self, forKey: .installationPath)
        state = try container.decode(LauncherSkillInstallationState.self, forKey: .state)
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        message = try container.decode(String.self, forKey: .message)
        managementState = try container.decodeIfPresent(
            LauncherSkillUninstallInspectionState.self,
            forKey: .managementState
        ) ?? .unrecognized
        canUninstall = try container.decodeIfPresent(Bool.self, forKey: .canUninstall) ?? false
        preservedCount = try container.decodeIfPresent(Int.self, forKey: .preservedCount) ?? 0
        managementMessage = try container.decodeIfPresent(String.self, forKey: .managementMessage)
            ?? "Uninstall proof is unavailable from this service response."
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(available, forKey: .available)
        try container.encode(surfaces, forKey: .surfaces)
        try container.encode(installationPath, forKey: .installationPath)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(installedVersion, forKey: .installedVersion)
        try container.encode(message, forKey: .message)
        try container.encode(managementState, forKey: .managementState)
        try container.encode(canUninstall, forKey: .canUninstall)
        try container.encode(preservedCount, forKey: .preservedCount)
        try container.encode(managementMessage, forKey: .managementMessage)
    }
}

public struct LauncherSkillStatus: Codable, Equatable, Sendable {
    public var skillName: String
    public var version: String
    public var hosts: [LauncherSkillHostStatus]

    public init(skillName: String, version: String, hosts: [LauncherSkillHostStatus]) {
        self.skillName = skillName
        self.version = version
        self.hosts = hosts
    }
}

public struct LauncherSkillInstallRequest: Codable, Equatable, Sendable {
    public var host: LauncherSkillHost

    public init(host: LauncherSkillHost) {
        self.host = host
    }
}

public struct LauncherSkillInstallResult: Codable, Equatable, Sendable {
    public var status: LauncherSkillHostStatus
    public var installedFiles: [String]
    public var sharedInstallationPath: String
    public var restartRecommended: Bool
    public var message: String

    public init(
        status: LauncherSkillHostStatus,
        installedFiles: [String],
        sharedInstallationPath: String? = nil,
        restartRecommended: Bool = false,
        message: String? = nil
    ) {
        self.status = status
        self.installedFiles = installedFiles
        self.sharedInstallationPath = sharedInstallationPath ?? status.installationPath
        self.restartRecommended = restartRecommended
        self.message = message ?? "Installed at \(status.installationPath)."
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case installedFiles
        case sharedInstallationPath
        case restartRecommended
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(LauncherSkillHostStatus.self, forKey: .status)
        installedFiles = try container.decode([String].self, forKey: .installedFiles)
        sharedInstallationPath = try container.decodeIfPresent(String.self, forKey: .sharedInstallationPath)
            ?? status.installationPath
        restartRecommended = try container.decodeIfPresent(Bool.self, forKey: .restartRecommended) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? "Installed at \(status.installationPath)."
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(installedFiles, forKey: .installedFiles)
        try container.encode(sharedInstallationPath, forKey: .sharedInstallationPath)
        try container.encode(restartRecommended, forKey: .restartRecommended)
        try container.encode(message, forKey: .message)
    }
}

public struct LauncherSkillUninstallIntentRequest: Codable, Equatable, Sendable {
    public var host: LauncherSkillHost

    public init(host: LauncherSkillHost) {
        self.host = host
    }
}

/// A short-lived deletion capability. Keep `token` private and never include it in logs.
public struct LauncherSkillUninstallIntent: Codable, Equatable, Sendable {
    public var token: String
    public var expiresAt: Date
    public var host: LauncherSkillHost
    /// Informational only: Desktop and CLI share the same receipt-backed installation.
    /// It is not selected by, nor echoed back from, any mutation request.
    public var affectedSurfaces: [LauncherSkillSurface]
    public var sharedInstallationPath: String
    public var installedVersion: String?
    public var binding: LauncherSkillUninstallBinding
    public var removablePaths: [String]
    public var preservedPaths: [String]
    public var confirmationText: String
    public var message: String

    public init(
        token: String,
        expiresAt: Date,
        host: LauncherSkillHost,
        affectedSurfaces: [LauncherSkillSurface] = LauncherSkillSurface.allCases,
        sharedInstallationPath: String,
        installedVersion: String? = nil,
        binding: LauncherSkillUninstallBinding,
        removablePaths: [String],
        preservedPaths: [String],
        confirmationText: String,
        message: String
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.host = host
        self.affectedSurfaces = affectedSurfaces
        self.sharedInstallationPath = sharedInstallationPath
        self.installedVersion = installedVersion
        self.binding = binding
        self.removablePaths = removablePaths
        self.preservedPaths = preservedPaths
        self.confirmationText = confirmationText
        self.message = message
    }
}

public struct LauncherSkillUninstallRequest: Codable, Equatable, Sendable {
    public var token: String
    public var host: LauncherSkillHost
    public var binding: LauncherSkillUninstallBinding
    /// Exact text issued by the daemon with this single-use intent. The daemon validates it
    /// before allowing the receipt-backed filesystem transaction to begin.
    public var confirmationText: String

    public init(
        token: String,
        host: LauncherSkillHost,
        binding: LauncherSkillUninstallBinding,
        confirmationText: String
    ) {
        self.token = token
        self.host = host
        self.binding = binding
        self.confirmationText = confirmationText
    }

    public init(intent: LauncherSkillUninstallIntent, confirmationText: String) {
        self.init(
            token: intent.token,
            host: intent.host,
            binding: intent.binding,
            confirmationText: confirmationText
        )
    }
}

public struct LauncherSkillUninstallResponse: Codable, Equatable, Sendable {
    public var result: LauncherSkillUninstallResult
    public var status: LauncherSkillHostStatus

    public init(result: LauncherSkillUninstallResult, status: LauncherSkillHostStatus) {
        self.result = result
        self.status = status
    }
}

public struct LauncherSkillSource: Codable, Equatable, Sendable {
    public var fileName: String
    public var skillName: String
    public var version: String
    public var contents: String

    public init(fileName: String, skillName: String, version: String, contents: String) {
        self.fileName = fileName
        self.skillName = skillName
        self.version = version
        self.contents = contents
    }
}

public struct DeleteIntent: Codable, Equatable, Sendable {
    public var token: String
    public var expiresAt: Date
    public var launcher: LauncherDetail

    public init(token: String, expiresAt: Date, launcher: LauncherDetail) {
        self.token = token
        self.expiresAt = expiresAt
        self.launcher = launcher
    }
}

public struct DeleteRequest: Codable, Equatable, Sendable {
    public var expectedRevision: Int
    public var intentToken: String

    public init(expectedRevision: Int, intentToken: String) {
        self.expectedRevision = expectedRevision
        self.intentToken = intentToken
    }
}

public struct SyncResult: Codable, Equatable, Sendable {
    public var project: ProjectRecord
    public var path: String
    public var inSync: Bool
    public var repaired: Bool
    public var expectedHash: String
    public var actualHash: String?
    public var message: String

    public init(project: ProjectRecord, path: String, inSync: Bool, repaired: Bool, expectedHash: String, actualHash: String?, message: String) {
        self.project = project
        self.path = path
        self.inSync = inSync
        self.repaired = repaired
        self.expectedHash = expectedHash
        self.actualHash = actualHash
        self.message = message
    }
}

public struct APIErrorEnvelope: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public var field: String?
        public var requestID: String

        public init(code: String, message: String, field: String? = nil, requestID: String = UUID().uuidString) {
            self.code = code
            self.message = message
            self.field = field
            self.requestID = requestID
        }
    }

    public var error: Detail

    public init(error: Detail) {
        self.error = error
    }
}

public struct EmptyResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public init(ok: Bool = true) { self.ok = ok }
}
