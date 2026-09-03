import Foundation

/// An immutable snapshot of the launcher and argument text selected by an
/// interactive client before it schedules asynchronous work.
public struct LauncherStartIntent: Equatable, Sendable {
    public let detail: LauncherDetail
    public let rawRuntimeArguments: String
    public let openRequested: Bool
    public let mode: SessionStartMode

    public init(
        detail: LauncherDetail,
        rawRuntimeArguments: String,
        openRequested: Bool = true,
        mode: SessionStartMode = .reusePrimary
    ) {
        self.detail = detail
        self.rawRuntimeArguments = rawRuntimeArguments
        self.openRequested = openRequested
        self.mode = mode
    }

    public var launcherID: UUID { detail.launcher.id }
    public var launcherName: String { detail.launcher.name }
    public var expectedLauncherRevision: Int { detail.launcher.revision }
}

/// The lifecycle identity observed for one action when a relaunch is
/// requested. Keeping these values in the intent prevents a later catalog
/// refresh from changing which services the confirmation described.
public struct LauncherServiceIdentitySnapshot: Equatable, Identifiable, Sendable {
    public let actionRunID: UUID
    public let actionID: UUID
    public let actionName: String
    public let state: ActionRunState
    public let manager: RunManager
    public let managerID: String?
    public let pid: Int32?
    public let processGroupID: Int32?
    public let pidStartIdentity: String?
    public let host: String?
    public let port: Int?
    public let endpointURL: String?

    public init(actionRun: ActionRunRecord) {
        actionRunID = actionRun.id
        actionID = actionRun.actionID
        actionName = actionRun.actionName
        state = actionRun.state
        manager = actionRun.manager
        managerID = actionRun.managerID
        pid = actionRun.pid
        processGroupID = actionRun.processGroupID
        pidStartIdentity = actionRun.pidStartIdentity
        host = actionRun.host
        port = actionRun.port
        endpointURL = actionRun.endpointURL
    }

    public var id: UUID { actionRunID }

    public var isActive: Bool {
        state == .starting || state == .running || state == .stopping
    }
}

/// An immutable relaunch confirmation and execution contract.
///
/// Runtime arguments are intentionally accepted only after parsing so edits to
/// the argument field while a confirmation is visible cannot alter the
/// confirmed operation. The failable initializer rejects a session that is no
/// longer active or belongs to a different launcher.
public struct LauncherRelaunchIntent: Equatable, Identifiable, Sendable {
    public let detail: LauncherDetail
    public let expectedSessionID: UUID
    public let sessionLauncherRevision: Int
    public let runtimeArguments: [String]
    public let openRequested: Bool
    public let services: [LauncherServiceIdentitySnapshot]

    public init?(
        detail: LauncherDetail,
        session: SessionRecord,
        runtimeArguments: [String],
        openRequested: Bool = true
    ) {
        guard session.launcherID == detail.launcher.id, session.isActive else {
            return nil
        }

        self.detail = detail
        expectedSessionID = session.id
        sessionLauncherRevision = session.launcherRevision
        self.runtimeArguments = runtimeArguments
        self.openRequested = openRequested
        services = session.actionRuns.map(LauncherServiceIdentitySnapshot.init(actionRun:))
    }

    public var id: UUID { expectedSessionID }
    public var launcherID: UUID { detail.launcher.id }
    public var launcherName: String { detail.launcher.name }
    public var expectedLauncherRevision: Int { detail.launcher.revision }
    public var activeServiceNames: [String] {
        services.filter(\.isActive).map(\.actionName)
    }

    public var confirmationMessage: String {
        let serviceDescription = activeServiceNames.isEmpty
            ? "its active processes"
            : activeServiceNames.joined(separator: ", ")
        return "Fully close the exact active session for \(launcherName), including \(serviceDescription), then start a fresh session with new managed ports where configured?"
    }
}
