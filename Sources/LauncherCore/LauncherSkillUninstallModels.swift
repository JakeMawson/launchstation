import Foundation

public enum LauncherSkillUninstallError: LocalizedError, Equatable, Sendable {
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let message):
            return "Skill uninstall refused: \(message)"
        }
    }
}

public enum LauncherSkillReceiptFileType: String, Codable, CaseIterable, Sendable {
    case regularFile = "regular-file"
}

public struct LauncherSkillReceiptFile: Codable, Equatable, Sendable {
    public var relativePath: String
    public var sha256: String
    public var type: LauncherSkillReceiptFileType
    public var posixMode: UInt32
    public var linkCount: UInt64

    public init(
        relativePath: String,
        sha256: String,
        type: LauncherSkillReceiptFileType,
        posixMode: UInt32,
        linkCount: UInt64
    ) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.type = type
        self.posixMode = posixMode
        self.linkCount = linkCount
    }
}

public struct LauncherSkillInstallReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var installationID: UUID
    public var managerID: String
    public var host: LauncherSkillHost
    public var destinationPath: String
    public var skillVersion: String
    public var installedAt: Date
    public var files: [LauncherSkillReceiptFile]

    public init(
        schemaVersion: Int,
        installationID: UUID,
        managerID: String,
        host: LauncherSkillHost,
        destinationPath: String,
        skillVersion: String,
        installedAt: Date,
        files: [LauncherSkillReceiptFile]
    ) {
        self.schemaVersion = schemaVersion
        self.installationID = installationID
        self.managerID = managerID
        self.host = host
        self.destinationPath = destinationPath
        self.skillVersion = skillVersion
        self.installedAt = installedAt
        self.files = files
    }
}

public struct LauncherSkillTargetIdentity: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum LauncherSkillUninstallInspectionState: String, Codable, CaseIterable, Sendable {
    case receiptProven = "receipt-proven"
    case modified
    case unrecognized
    case absent
    case blocked
}

/// Exact state a future service intent must bind before asking the manager to mutate.
public struct LauncherSkillUninstallBinding: Codable, Equatable, Sendable {
    public var host: LauncherSkillHost
    public var destinationPath: String
    public var installationID: UUID
    public var receiptDigest: String
    public var targetIdentity: LauncherSkillTargetIdentity
    public var targetFingerprint: String

    public init(
        host: LauncherSkillHost,
        destinationPath: String,
        installationID: UUID,
        receiptDigest: String,
        targetIdentity: LauncherSkillTargetIdentity,
        targetFingerprint: String
    ) {
        self.host = host
        self.destinationPath = destinationPath
        self.installationID = installationID
        self.receiptDigest = receiptDigest
        self.targetIdentity = targetIdentity
        self.targetFingerprint = targetFingerprint
    }
}

public struct LauncherSkillUninstallInspection: Codable, Equatable, Sendable {
    public var host: LauncherSkillHost
    public var destinationPath: String
    public var state: LauncherSkillUninstallInspectionState
    public var installationID: UUID?
    public var installedVersion: String?
    public var receiptDigest: String?
    public var targetIdentity: LauncherSkillTargetIdentity?
    public var targetFingerprint: String?
    public var preservedRelativePaths: [String]
    public var message: String

    public init(
        host: LauncherSkillHost,
        destinationPath: String,
        state: LauncherSkillUninstallInspectionState,
        installationID: UUID? = nil,
        installedVersion: String? = nil,
        receiptDigest: String? = nil,
        targetIdentity: LauncherSkillTargetIdentity? = nil,
        targetFingerprint: String? = nil,
        preservedRelativePaths: [String] = [],
        message: String
    ) {
        self.host = host
        self.destinationPath = destinationPath
        self.state = state
        self.installationID = installationID
        self.installedVersion = installedVersion
        self.receiptDigest = receiptDigest
        self.targetIdentity = targetIdentity
        self.targetFingerprint = targetFingerprint
        self.preservedRelativePaths = preservedRelativePaths
        self.message = message
    }
}

public struct LauncherSkillUninstallPlan: Codable, Equatable, Sendable {
    public var inspection: LauncherSkillUninstallInspection
    public var binding: LauncherSkillUninstallBinding?
    public var removableRelativePaths: [String]
    public var prunableEmptyDirectories: [String]

    public init(
        inspection: LauncherSkillUninstallInspection,
        binding: LauncherSkillUninstallBinding?,
        removableRelativePaths: [String],
        prunableEmptyDirectories: [String]
    ) {
        self.inspection = inspection
        self.binding = binding
        self.removableRelativePaths = removableRelativePaths
        self.prunableEmptyDirectories = prunableEmptyDirectories
    }

    public var canUninstall: Bool {
        inspection.state == .receiptProven && binding != nil
    }
}

public struct LauncherSkillUninstallResult: Codable, Equatable, Sendable {
    public var host: LauncherSkillHost
    public var destinationPath: String
    public var installationID: UUID
    public var consumedReceiptDigest: String
    public var removedRelativePaths: [String]
    public var preservedRelativePaths: [String]
    public var message: String

    public init(
        host: LauncherSkillHost,
        destinationPath: String,
        installationID: UUID,
        consumedReceiptDigest: String,
        removedRelativePaths: [String],
        preservedRelativePaths: [String],
        message: String
    ) {
        self.host = host
        self.destinationPath = destinationPath
        self.installationID = installationID
        self.consumedReceiptDigest = consumedReceiptDigest
        self.removedRelativePaths = removedRelativePaths
        self.preservedRelativePaths = preservedRelativePaths
        self.message = message
    }
}
