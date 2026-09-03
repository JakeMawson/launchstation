import Foundation

public enum LauncherSchema {
    public static let version = 2
    public static let launchDetailsIdentifier = "com.codex.launcher/launch-details-v1"
}

public struct ProjectRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var directory: String
    public var revision: Int
    public var manifestHash: String?
    public var manifestSyncState: ManifestSyncState
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        directory: String,
        revision: Int = 1,
        manifestHash: String? = nil,
        manifestSyncState: ManifestSyncState = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.directory = directory
        self.revision = revision
        self.manifestHash = manifestHash
        self.manifestSyncState = manifestSyncState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ManifestSyncState: String, Codable, CaseIterable, Sendable {
    case synced
    case pending
    case drifted
    case failed
}

public struct LauncherRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var normalizedName: String
    public var description: String
    public var runDetails: String?
    public var tags: [String]
    public var actions: [LaunchAction]
    public var primaryActionID: UUID
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        normalizedName: String,
        description: String,
        runDetails: String? = nil,
        tags: [String] = [],
        actions: [LaunchAction],
        primaryActionID: UUID? = nil,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.normalizedName = normalizedName
        self.description = description
        self.runDetails = runDetails
        self.tags = tags
        self.actions = actions
        self.primaryActionID = primaryActionID ?? actions.first?.id ?? UUID()
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var sortedActions: [LaunchAction] {
        actions.sorted {
            if $0.order == $1.order { return $0.id.uuidString < $1.id.uuidString }
            return $0.order < $1.order
        }
    }
}

public struct LaunchAction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var normalizedName: String
    public var description: String
    public var order: Int
    public var runner: ActionRunner
    public var workingDirectory: String
    public var executable: String?
    public var arguments: [String]
    public var shellCommand: String?
    public var environment: [String: String]
    public var inheritedEnvironment: [String]
    public var port: PortConfiguration
    public var healthCheckURL: String?
    public var openTarget: OpenTarget
    public var appBundleIdentifier: String?
    public var readyTimeoutSeconds: Int
    public var stopTimeoutSeconds: Int
    public var required: Bool
    public var allowsRuntimeArguments: Bool

    public init(
        id: UUID = UUID(),
        name: String = "main",
        normalizedName: String = "main",
        description: String = "Primary launch action",
        order: Int = 0,
        runner: ActionRunner = .shell,
        workingDirectory: String = ".",
        executable: String? = nil,
        arguments: [String] = [],
        shellCommand: String? = nil,
        environment: [String: String] = [:],
        inheritedEnvironment: [String] = [],
        port: PortConfiguration = .none,
        healthCheckURL: String? = nil,
        openTarget: OpenTarget = .none,
        appBundleIdentifier: String? = nil,
        readyTimeoutSeconds: Int = 30,
        stopTimeoutSeconds: Int = 8,
        required: Bool = true,
        allowsRuntimeArguments: Bool = true
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
        self.description = description
        self.order = order
        self.runner = runner
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.arguments = arguments
        self.shellCommand = shellCommand
        self.environment = environment
        self.inheritedEnvironment = inheritedEnvironment
        self.port = port
        self.healthCheckURL = healthCheckURL
        self.openTarget = openTarget
        self.appBundleIdentifier = appBundleIdentifier
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.required = required
        self.allowsRuntimeArguments = runner == .url ? false : allowsRuntimeArguments
    }

    public var displayCommand: String {
        switch runner {
        case .shell:
            let command = shellCommand ?? ""
            guard !arguments.isEmpty else { return command }
            return command + " " + arguments.map(ShellEscaping.quote).joined(separator: " ")
        case .process, .ios:
            return ShellEscaping.command(executable: executable ?? "", arguments: arguments)
        case .app:
            guard let executable else { return "" }
            let inferredBundleIdentifier = appBundleIdentifier
                ?? (!executable.contains("/") && executable.contains(".") ? executable : nil)
            let base: String
            if let inferredBundleIdentifier, !executable.hasPrefix("/"), !executable.hasPrefix("~/") {
                base = "open -n -b " + ShellEscaping.quote(inferredBundleIdentifier)
            } else {
                base = "open -n " + ShellEscaping.quote(executable)
            }
            guard !arguments.isEmpty else { return base }
            return base + " --args " + arguments.map(ShellEscaping.quote).joined(separator: " ")
        case .url:
            return executable.map { "open " + ShellEscaping.quote($0) } ?? ""
        }
    }
}

public enum ActionRunner: String, Codable, CaseIterable, Sendable {
    case process
    case shell
    case app
    case url
    case ios
}

public struct PortConfiguration: Codable, Equatable, Sendable {
    public var mode: PortMode
    public var logicalName: String
    public var fixedPort: Int?
    public var environmentVariable: String
    public var hostEnvironmentVariable: String
    public var URLTemplate: String?
    public var lease: String

    public init(
        mode: PortMode,
        logicalName: String = "main",
        fixedPort: Int? = nil,
        environmentVariable: String = "PORT",
        hostEnvironmentVariable: String = "HOST",
        URLTemplate: String? = nil,
        lease: String = "8h"
    ) {
        self.mode = mode
        self.logicalName = logicalName
        self.fixedPort = fixedPort
        self.environmentVariable = environmentVariable
        self.hostEnvironmentVariable = hostEnvironmentVariable
        self.URLTemplate = URLTemplate
        self.lease = lease
    }

    public static let none = PortConfiguration(mode: .none)
}

public enum PortMode: String, Codable, CaseIterable, Sendable {
    case none
    case automatic
    case fixed
}

public enum OpenTarget: String, Codable, CaseIterable, Sendable {
    case none
    case browser
    case application
    case simulator
}

public struct LauncherDetail: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { launcher.id }
    public var project: ProjectRecord
    public var launcher: LauncherRecord
    /// Compatibility projection for clients that predate multi-instance sessions. It is the
    /// active primary when one exists, otherwise the newest active additional instance.
    public var activeSession: SessionRecord?
    public var activeSessions: [SessionRecord]
    public var lastSession: SessionRecord?

    public init(
        project: ProjectRecord,
        launcher: LauncherRecord,
        activeSession: SessionRecord? = nil,
        activeSessions: [SessionRecord]? = nil,
        lastSession: SessionRecord? = nil
    ) {
        self.project = project
        self.launcher = launcher
        let resolved = activeSessions ?? activeSession.map { [$0] } ?? []
        self.activeSessions = resolved
        self.activeSession = activeSession
            ?? resolved.first(where: { $0.launchRole == .primary })
            ?? resolved.first
        self.lastSession = lastSession
    }

    public var primaryActiveSession: SessionRecord? {
        activeSessions.first { $0.launchRole == .primary && $0.isActive }
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case launcher
        case activeSession
        case activeSessions
        case lastSession
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(ProjectRecord.self, forKey: .project)
        launcher = try container.decode(LauncherRecord.self, forKey: .launcher)
        let legacyActive = try container.decodeIfPresent(SessionRecord.self, forKey: .activeSession)
        activeSessions = try container.decodeIfPresent([SessionRecord].self, forKey: .activeSessions)
            ?? legacyActive.map { [$0] }
            ?? []
        activeSession = legacyActive
            ?? activeSessions.first(where: { $0.launchRole == .primary })
            ?? activeSessions.first
        lastSession = try container.decodeIfPresent(SessionRecord.self, forKey: .lastSession)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(launcher, forKey: .launcher)
        try container.encodeIfPresent(activeSession, forKey: .activeSession)
        try container.encode(activeSessions, forKey: .activeSessions)
        try container.encodeIfPresent(lastSession, forKey: .lastSession)
    }
}

public struct CatalogSnapshot: Codable, Equatable, Sendable {
    public var launchers: [LauncherDetail]
    public var projects: [ProjectRecord]
    public var service: ServiceStatus

    public init(launchers: [LauncherDetail], projects: [ProjectRecord], service: ServiceStatus) {
        self.launchers = launchers
        self.projects = projects
        self.service = service
    }
}

public struct ServiceStatus: Codable, Equatable, Sendable {
    public var version: String
    public var schemaVersion: Int
    public var pid: Int32
    public var startedAt: Date
    public var endpoint: String

    public init(version: String = LauncherRuntimeVersion.current(), schemaVersion: Int = LauncherSchema.version, pid: Int32, startedAt: Date, endpoint: String) {
        self.version = version
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.startedAt = startedAt
        self.endpoint = endpoint
    }
}

public enum SessionLaunchRole: String, Codable, CaseIterable, Sendable {
    case primary
    case additional
}

public enum SessionStartMode: String, Codable, CaseIterable, Sendable {
    case reusePrimary = "reuse-primary"
    case newInstance = "new-instance"

    public var launchRole: SessionLaunchRole {
        switch self {
        case .reusePrimary: return .primary
        case .newInstance: return .additional
        }
    }
}

public struct SessionProjectSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var directory: String

    public init(id: UUID, displayName: String, directory: String) {
        self.id = id
        self.displayName = displayName
        self.directory = directory
    }

    public init(project: ProjectRecord) {
        self.init(id: project.id, displayName: project.displayName, directory: project.directory)
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var launcherID: UUID
    public var launcherName: String
    public var launcherRevision: Int
    public var launchRole: SessionLaunchRole
    public var projectSnapshot: SessionProjectSnapshot?
    public var runtimeArguments: [String]
    /// Immutable action definitions captured when the session starts. This lets CLOSE
    /// use the same lifecycle policy even if the launcher is edited while it runs.
    public var actionSnapshots: [LaunchAction]?
    public var state: SessionState
    public var actionRuns: [ActionRunRecord]
    public var startedAt: Date
    public var endedAt: Date?
    public var lastError: String?
    public var exitCode: Int32?

    public init(
        id: UUID = UUID(),
        launcherID: UUID,
        launcherName: String,
        launcherRevision: Int,
        launchRole: SessionLaunchRole = .primary,
        projectSnapshot: SessionProjectSnapshot? = nil,
        runtimeArguments: [String] = [],
        actionSnapshots: [LaunchAction]? = nil,
        state: SessionState = .starting,
        actionRuns: [ActionRunRecord] = [],
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        lastError: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.id = id
        self.launcherID = launcherID
        self.launcherName = launcherName
        self.launcherRevision = launcherRevision
        self.launchRole = launchRole
        self.projectSnapshot = projectSnapshot
        self.runtimeArguments = runtimeArguments
        self.actionSnapshots = actionSnapshots
        self.state = state
        self.actionRuns = actionRuns
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastError = lastError
        self.exitCode = exitCode
    }

    public var isActive: Bool {
        state == .starting || state == .running || state == .partial || state == .stopping
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case launcherID
        case launcherName
        case launcherRevision
        case launchRole
        case projectSnapshot
        case runtimeArguments
        case actionSnapshots
        case state
        case actionRuns
        case startedAt
        case endedAt
        case lastError
        case exitCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        launcherID = try container.decode(UUID.self, forKey: .launcherID)
        launcherName = try container.decode(String.self, forKey: .launcherName)
        launcherRevision = try container.decode(Int.self, forKey: .launcherRevision)
        launchRole = try container.decodeIfPresent(SessionLaunchRole.self, forKey: .launchRole) ?? .primary
        projectSnapshot = try container.decodeIfPresent(SessionProjectSnapshot.self, forKey: .projectSnapshot)
        runtimeArguments = try container.decodeIfPresent([String].self, forKey: .runtimeArguments) ?? []
        actionSnapshots = try container.decodeIfPresent([LaunchAction].self, forKey: .actionSnapshots)
        state = try container.decode(SessionState.self, forKey: .state)
        actionRuns = try container.decodeIfPresent([ActionRunRecord].self, forKey: .actionRuns) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(launcherID, forKey: .launcherID)
        try container.encode(launcherName, forKey: .launcherName)
        try container.encode(launcherRevision, forKey: .launcherRevision)
        try container.encode(launchRole, forKey: .launchRole)
        try container.encodeIfPresent(projectSnapshot, forKey: .projectSnapshot)
        try container.encode(runtimeArguments, forKey: .runtimeArguments)
        try container.encodeIfPresent(actionSnapshots, forKey: .actionSnapshots)
        try container.encode(state, forKey: .state)
        try container.encode(actionRuns, forKey: .actionRuns)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
    }
}

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case partial
    case stopping
    case exited
    case failed
    case orphaned
}

public struct ActionRunRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var actionID: UUID
    public var actionName: String
    public var state: ActionRunState
    public var manager: RunManager
    public var managerID: String?
    public var pid: Int32?
    public var processGroupID: Int32?
    public var pidStartIdentity: String?
    public var host: String?
    public var port: Int?
    public var endpointURL: String?
    /// Exact Simulator device selected when this action started. These values describe
    /// runtime state only; they do not imply ownership of Simulator or of the device.
    public var simulatorUDID: String?
    public var simulatorName: String?
    public var logPath: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var message: String?
    /// Structured, evidence-labelled root-cause analysis for terminal runs. It is optional for
    /// legacy records and intentionally contains no unbounded raw log text.
    public var failureDiagnosis: LaunchFailureDiagnosis?

    public init(
        id: UUID = UUID(),
        actionID: UUID,
        actionName: String,
        state: ActionRunState = .starting,
        manager: RunManager,
        managerID: String? = nil,
        pid: Int32? = nil,
        processGroupID: Int32? = nil,
        pidStartIdentity: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        endpointURL: String? = nil,
        simulatorUDID: String? = nil,
        simulatorName: String? = nil,
        logPath: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
        failureDiagnosis: LaunchFailureDiagnosis? = nil
    ) {
        self.id = id
        self.actionID = actionID
        self.actionName = actionName
        self.state = state
        self.manager = manager
        self.managerID = managerID
        self.pid = pid
        self.processGroupID = processGroupID
        self.pidStartIdentity = pidStartIdentity
        self.host = host
        self.port = port
        self.endpointURL = endpointURL
        self.simulatorUDID = simulatorUDID
        self.simulatorName = simulatorName
        self.logPath = logPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.message = message
        self.failureDiagnosis = failureDiagnosis
    }
}

public enum ActionRunState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case stopping
    case exited
    case failed
    case orphaned
}

public enum RunManager: String, Codable, CaseIterable, Sendable {
    case processGroup
    case codexPort
    case application
    case fireAndForget
}

public struct ServiceMetadata: Codable, Equatable, Sendable {
    public var endpoint: String
    public var token: String
    public var pid: Int32
    public var startedAt: Date
    public var schemaVersion: Int
    public var version: String

    public init(
        endpoint: String,
        token: String,
        pid: Int32,
        startedAt: Date,
        schemaVersion: Int = LauncherSchema.version,
        version: String = LauncherRuntimeVersion.current()
    ) {
        self.endpoint = endpoint
        self.token = token
        self.pid = pid
        self.startedAt = startedAt
        self.schemaVersion = schemaVersion
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, token, pid, startedAt, schemaVersion, version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        token = try container.decode(String.self, forKey: .token)
        pid = try container.decode(Int32.self, forKey: .pid)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Older metadata did not publish a version. Keep it decodable so callers receive the
        // explicit compatibility refusal below instead of a generic malformed-JSON error.
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
    }
}

public enum LauncherJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
