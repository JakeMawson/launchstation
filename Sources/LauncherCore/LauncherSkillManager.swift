import Foundation
import CryptoKit
import Security
import Darwin

public enum LauncherSkillError: LocalizedError, Equatable {
    case bundledSkillUnavailable(String)
    case hostUnavailable(LauncherSkillHost, String)
    case unsafeDestination(String)
    case installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledSkillUnavailable(let message):
            return "Bundled Launch Station skill unavailable: \(message)"
        case .hostUnavailable(let host, let message):
            return "\(host.displayName) is not available: \(message)"
        case .unsafeDestination(let message):
            return "Skill installation destination is unsafe: \(message)"
        case .installationFailed(let message):
            return "Skill installation failed: \(message)"
        }
    }
}

/// Owns the signed, bundled copy of the agent skill and the two documented user-scope
/// destinations. The daemon invokes mutations; GUI and CLI clients only call its API.
public struct LauncherSkillManager: Sendable {
    public static let skillName = "launchstation"
    public static let version = "1.3.2"
    public static let exportedFileName = "SKILL.md"
    public static let installReceiptFileName = ".launchstation-install-receipt.json"

    private static let receiptSchemaVersion = 1
    private static let receiptManagerID = "com.jakemawson.launchstation"
    private static let maximumManagedFileBytes: Int64 = 4 * 1_024 * 1_024
    private static let maximumInspectionEntries = 4_096
    private static let maximumInspectionDepth = 24
    fileprivate static let maximumInspectionBytes: Int64 = 64 * 1_024 * 1_024

    private static let managedRelativePaths = [
        "SKILL.md",
        "agents/openai.yaml",
        "VERSION",
    ]
    private static let managedTreePaths = Set(
        managedRelativePaths + ["agents", installReceiptFileName]
    )

    public let sourceDirectory: URL
    public let homeDirectory: URL
    private let detectionCandidates: [LauncherSkillHost: [LauncherSkillSurface: [URL]]]
    private let candidateAuthenticator: @Sendable (URL, LauncherSkillHost, LauncherSkillSurface) -> Bool
    private let transactionHooks: LauncherSkillTransactionHooks

    public init(
        sourceDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexDetectionCandidates: [URL]? = nil,
        claudeCodeDetectionCandidates: [URL]? = nil,
        codexDesktopDetectionCandidates: [URL]? = nil,
        codexCLIDetectionCandidates: [URL]? = nil,
        claudeDesktopDetectionCandidates: [URL]? = nil,
        claudeCLIDetectionCandidates: [URL]? = nil,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.init(
            sourceDirectory: sourceDirectory,
            homeDirectory: homeDirectory,
            codexDetectionCandidates: codexDetectionCandidates,
            claudeCodeDetectionCandidates: claudeCodeDetectionCandidates,
            codexDesktopDetectionCandidates: codexDesktopDetectionCandidates,
            codexCLIDetectionCandidates: codexCLIDetectionCandidates,
            claudeDesktopDetectionCandidates: claudeDesktopDetectionCandidates,
            claudeCLIDetectionCandidates: claudeCLIDetectionCandidates,
            environmentPath: environmentPath,
            candidateAuthenticator: nil,
            transactionHooks: .live
        )
    }

    init(
        sourceDirectory: URL,
        homeDirectory: URL,
        codexDetectionCandidates: [URL]?,
        claudeCodeDetectionCandidates: [URL]?,
        codexDesktopDetectionCandidates: [URL]? = nil,
        codexCLIDetectionCandidates: [URL]? = nil,
        claudeDesktopDetectionCandidates: [URL]? = nil,
        claudeCLIDetectionCandidates: [URL]? = nil,
        environmentPath: String?,
        candidateAuthenticator: (@Sendable (URL, LauncherSkillHost, LauncherSkillSurface) -> Bool)? = nil,
        transactionHooks: LauncherSkillTransactionHooks
    ) {
        self.sourceDirectory = sourceDirectory.standardizedFileURL
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.candidateAuthenticator = candidateAuthenticator ?? { url, host, surface in
            Self.isAuthenticCandidate(url, host: host, surface: surface)
        }
        self.transactionHooks = transactionHooks
        detectionCandidates = Self.makeDetectionCandidates(
            home: homeDirectory,
            path: environmentPath,
            codexLegacy: codexDetectionCandidates,
            claudeLegacy: claudeCodeDetectionCandidates,
            codexDesktop: codexDesktopDetectionCandidates,
            codexCLI: codexCLIDetectionCandidates,
            claudeDesktop: claudeDesktopDetectionCandidates,
            claudeCLI: claudeCLIDetectionCandidates
        )
    }

    public static func located(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) throws -> LauncherSkillManager {
        var candidates: [URL] = []
        if let override = environment["LAUNCH_STATION_SKILL_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Skills/launchstation", isDirectory: true))
        }
        if !executablePath.isEmpty,
           let applicationURL = containingApplicationURL(for: URL(fileURLWithPath: executablePath).standardizedFileURL) {
            candidates.append(applicationURL.appendingPathComponent("Contents/Resources/Skills/launchstation", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Skills/launchstation", isDirectory: true)
        )

        for candidate in candidates where hasCanonicalFiles(at: candidate) {
            return LauncherSkillManager(sourceDirectory: candidate)
        }
        let searched = candidates.map(\.path).joined(separator: ", ")
        throw LauncherSkillError.bundledSkillUnavailable("no complete skill bundle was found (searched: \(searched)).")
    }

    public func status() throws -> LauncherSkillStatus {
        try validateSource()
        return LauncherSkillStatus(
            skillName: Self.skillName,
            version: try bundledVersion(),
            hosts: try LauncherSkillHost.allCases.map(status(for:))
        )
    }

    public func source() throws -> LauncherSkillSource {
        try validateSource()
        let data = try sourceData(relativePath: Self.exportedFileName)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw LauncherSkillError.bundledSkillUnavailable("SKILL.md is not valid UTF-8.")
        }
        return LauncherSkillSource(
            fileName: Self.exportedFileName,
            skillName: Self.skillName,
            version: try bundledVersion(),
            contents: contents
        )
    }

    public func install(host: LauncherSkillHost) throws -> LauncherSkillInstallResult {
        try validateSource()
        let before = try status(for: host)
        guard before.available else {
            throw LauncherSkillError.hostUnavailable(host, before.message)
        }
        guard before.state != .blocked else {
            throw LauncherSkillError.unsafeDestination(before.message)
        }

        let target = installationDirectory(for: host)
        let skillsRootExisted = Self.isRealDirectory(target.deletingLastPathComponent())
        try rejectUnsafeExistingComponents(for: host)
        do {
            try installTransaction(host: host, target: target)

            let after = try status(for: host)
            guard after.state == .current else {
                throw LauncherSkillError.installationFailed("the managed files did not verify after writing.")
            }
            let restartRecommended = Self.restartRecommended(
                for: host,
                skillsRootExistedBeforeInstall: skillsRootExisted
            )
            let productName = host == .codex ? "Codex" : "Claude"
            let discoveryMessage: String
            if restartRecommended {
                discoveryMessage = host == .codex
                    ? "Restart Codex to discover the installed skill."
                    : "Restart Claude because its top-level skills directory was created during installation."
            } else if host == .codex {
                discoveryMessage = "Codex auto-detects skill changes; restart only if the skill still does not appear."
            } else {
                discoveryMessage = "Claude can discover this change in its existing skills directory without restarting."
            }
            let resultMessage = "Installed for \(productName) at \(target.path), the shared destination used by both Desktop and CLI. \(discoveryMessage)"
            return LauncherSkillInstallResult(
                status: after,
                installedFiles: Self.managedRelativePaths.map {
                    target.appendingPathComponent($0, isDirectory: false).path
                },
                sharedInstallationPath: target.path,
                restartRecommended: restartRecommended,
                message: resultMessage
            )
        } catch let error as LauncherSkillError {
            throw error
        } catch {
            throw LauncherSkillError.installationFailed(error.localizedDescription)
        }
    }

    /// Builds a complete replacement outside the host's scanned skills directory and
    /// exposes it with one filesystem transaction. Existing unmanaged files are copied
    /// into the staged tree, so a successful swap changes only the managed files. A
    /// failed staging or commit attempt leaves the previously visible directory untouched.
    private func installTransaction(host: LauncherSkillHost, target: URL) throws {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        let transactionRoot = transactionDirectory(for: host)
        let hostRoot = parent.deletingLastPathComponent()

        let homeDescriptor = open(
            homeDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard homeDescriptor >= 0 else {
            let code = errno
            throw LauncherSkillError.unsafeDestination(
                "could not secure the home directory: \(String(cString: strerror(code)))."
            )
        }
        defer { close(homeDescriptor) }
        let hostDescriptor = try openOrCreateDirectory(
            named: hostRoot.lastPathComponent,
            in: homeDescriptor,
            createMode: 0o755
        )
        defer { close(hostDescriptor) }
        let parentDescriptor = try openOrCreateDirectory(
            named: parent.lastPathComponent,
            in: hostDescriptor,
            createMode: 0o755
        )
        defer { close(parentDescriptor) }
        let transactionDescriptor = try openOrCreateDirectory(
            named: transactionRoot.lastPathComponent,
            in: hostDescriptor,
            createMode: 0o700
        )
        defer { close(transactionDescriptor) }
        guard fchmod(transactionDescriptor, 0o700) == 0 else {
            let code = errno
            throw LauncherSkillError.installationFailed(
                "could not protect the skill transaction directory: \(String(cString: strerror(code)))"
            )
        }
        try rejectUnsafeExistingComponents(for: host)

        var parentAttributes = stat()
        guard fstat(parentDescriptor, &parentAttributes) == 0 else {
            throw LauncherSkillError.installationFailed("could not inspect the secured skills directory.")
        }
        let parentIdentity = DirectoryIdentity(device: parentAttributes.st_dev, inode: parentAttributes.st_ino)
        var transactionAttributes = stat()
        guard fstat(transactionDescriptor, &transactionAttributes) == 0 else {
            throw LauncherSkillError.installationFailed("could not inspect the secured skill transaction directory.")
        }
        let transactionRootIdentity = DirectoryIdentity(
            device: transactionAttributes.st_dev,
            inode: transactionAttributes.st_ino
        )
        guard try directoryIdentity(at: parent) == parentIdentity,
              try directoryIdentity(at: transactionRoot) == transactionRootIdentity else {
            throw LauncherSkillError.installationFailed("a secured skill directory was moved during preflight.")
        }
        guard parentIdentity.device == transactionRootIdentity.device else {
            throw LauncherSkillError.installationFailed("the skill transaction directory is not on the destination volume.")
        }
        let originalTargetIdentity = try optionalDirectoryIdentity(at: target)
        let originalUnmanaged = originalTargetIdentity == nil
            ? SkillTreeFingerprint.empty
            : try unmanagedFingerprint(at: target)

        let staging = transactionRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        var cleanupIdentity: DirectoryIdentity?
        defer {
            if !transactionHooks.skipCleanup,
               (try? directoryIdentity(at: transactionRoot)) == transactionRootIdentity,
               let expected = cleanupIdentity,
               (try? optionalDirectoryIdentity(at: staging)) == expected {
                try? fileManager.removeItem(at: staging)
            }
        }

        if originalTargetIdentity == nil {
            guard mkdirat(transactionDescriptor, staging.lastPathComponent, 0o755) == 0 else {
                let code = errno
                throw LauncherSkillError.installationFailed(
                    "could not create the staged skill directory: \(String(cString: strerror(code)))"
                )
            }
        } else {
            let flags = copyfile_flags_t(
                COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW
            )
            guard copyfile(target.path, staging.path, nil, flags) == 0 else {
                let code = errno
                throw LauncherSkillError.installationFailed(
                    "could not stage the existing skill safely: \(String(cString: strerror(code)))"
                )
            }
        }
        cleanupIdentity = try directoryIdentity(at: staging)
        guard try unmanagedFingerprint(at: staging) == originalUnmanaged else {
            throw LauncherSkillError.installationFailed("the copied unmanaged files did not match before managed writes began.")
        }

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        for relativePath in Self.managedRelativePaths {
            let destination = staging.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try LauncherPaths.atomicWrite(
                sourceData(relativePath: relativePath),
                to: destination,
                permissions: 0o644
            )
            try transactionHooks.afterManagedWrite(relativePath, staging)
        }
        let receipt = try makeInstallReceipt(host: host, destination: target, directory: staging)
        try LauncherPaths.atomicWrite(
            try Self.encodeReceipt(receipt),
            to: receiptURL(in: staging),
            permissions: 0o600
        )
        try transactionHooks.afterReceiptWrite(receiptURL(in: staging), staging)
        guard try managedFilesMatchSource(at: staging) else {
            throw LauncherSkillError.installationFailed("the staged managed files did not verify before commit.")
        }
        guard try managedFilesMatchReceipt(receipt, at: staging),
              try readReceipt(at: staging).receipt == receipt else {
            throw LauncherSkillError.installationFailed("the staged install receipt did not verify before commit.")
        }
        guard try unmanagedFingerprint(at: staging) == originalUnmanaged else {
            throw LauncherSkillError.installationFailed("unmanaged skill files changed while the replacement was staged.")
        }

        try transactionHooks.beforeCommit(staging)
        guard try managedFilesMatchSource(at: staging),
              try managedFilesMatchReceipt(receipt, at: staging),
              try readReceipt(at: staging).receipt == receipt,
              try unmanagedFingerprint(at: staging) == originalUnmanaged else {
            throw LauncherSkillError.installationFailed(
                "the staged managed files or install receipt changed before commit."
            )
        }
        try rejectUnsafeExistingComponents(for: host)
        guard try directoryIdentity(at: parent) == parentIdentity else {
            throw LauncherSkillError.installationFailed("the skills directory changed while the installation was staged.")
        }
        guard try directoryIdentity(at: transactionRoot) == transactionRootIdentity else {
            throw LauncherSkillError.installationFailed("the skill transaction directory changed while the installation was staged.")
        }
        guard try optionalDirectoryIdentity(at: target) == originalTargetIdentity else {
            throw LauncherSkillError.installationFailed("the destination changed while the installation was staged.")
        }
        if originalTargetIdentity != nil {
            guard try unmanagedFingerprint(at: target) == originalUnmanaged else {
                throw LauncherSkillError.installationFailed("the destination contents changed while the installation was staged.")
            }
        }

        let flags = originalTargetIdentity == nil
            ? UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
            : UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
        guard renameatx_np(
            transactionDescriptor,
            staging.lastPathComponent,
            parentDescriptor,
            target.lastPathComponent,
            flags
        ) == 0 else {
            let code = errno
            throw LauncherSkillError.installationFailed(
                "could not atomically commit the staged skill: \(String(cString: strerror(code)))"
            )
        }
        // For an existing install, the hidden sibling now contains the exact old
        // target. Remove it only while that saved identity still matches.
        cleanupIdentity = originalTargetIdentity
    }

    public func installationDirectory(for host: LauncherSkillHost) -> URL {
        switch host {
        case .codex:
            return homeDirectory.appendingPathComponent(".agents/skills/launchstation", isDirectory: true)
        case .claudeCode:
            return homeDirectory.appendingPathComponent(".claude/skills/launchstation", isDirectory: true)
        }
    }

    func transactionDirectory(for host: LauncherSkillHost) -> URL {
        let hostRoot: URL
        switch host {
        case .codex:
            hostRoot = homeDirectory.appendingPathComponent(".agents", isDirectory: true)
        case .claudeCode:
            hostRoot = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        return hostRoot.appendingPathComponent(".launchstation-transactions", isDirectory: true)
    }

    public func inspectUninstall(host: LauncherSkillHost) -> LauncherSkillUninstallInspection {
        let target = installationDirectory(for: host)
        let identity: DirectoryIdentity
        do {
            guard let existing = try optionalDirectoryIdentity(at: target) else {
                return LauncherSkillUninstallInspection(
                    host: host,
                    destinationPath: target.path,
                    state: .absent,
                    message: "No installed skill destination exists."
                )
            }
            identity = existing
        } catch {
            return blockedUninstallInspection(host: host, target: target, message: error.localizedDescription)
        }

        if let unsafe = unsafeExistingComponent(for: host) {
            return blockedUninstallInspection(
                host: host,
                target: target,
                identity: identity,
                message: "Unsafe destination component: \(unsafe)"
            )
        }

        let snapshot: CompleteSkillTreeSnapshot
        do {
            snapshot = try completeTreeSnapshot(at: target)
        } catch {
            return blockedUninstallInspection(
                host: host,
                target: target,
                identity: identity,
                message: error.localizedDescription
            )
        }

        let receiptRecord: InstallReceiptRecord
        do {
            receiptRecord = try readReceipt(at: target)
        } catch ReceiptInspectionError.absent {
            let state: LauncherSkillUninstallInspectionState = hasManagedPathPresence(at: target)
                ? .unrecognized
                : .absent
            return LauncherSkillUninstallInspection(
                host: host,
                destinationPath: target.path,
                state: state,
                targetIdentity: publicIdentity(identity),
                targetFingerprint: snapshot.fingerprint,
                preservedRelativePaths: snapshot.preservedRelativePaths,
                message: state == .absent
                    ? "No receipt-backed Launcher installation is present; unmanaged content is untouched."
                    : "Launcher-managed path names exist without an install receipt."
            )
        } catch ReceiptInspectionError.blocked(let message) {
            return blockedUninstallInspection(
                host: host,
                target: target,
                identity: identity,
                fingerprint: snapshot.fingerprint,
                preserved: snapshot.preservedRelativePaths,
                message: message
            )
        } catch ReceiptInspectionError.invalid(let message) {
            return LauncherSkillUninstallInspection(
                host: host,
                destinationPath: target.path,
                state: .unrecognized,
                targetIdentity: publicIdentity(identity),
                targetFingerprint: snapshot.fingerprint,
                preservedRelativePaths: snapshot.preservedRelativePaths,
                message: message
            )
        } catch {
            return blockedUninstallInspection(
                host: host,
                target: target,
                identity: identity,
                fingerprint: snapshot.fingerprint,
                preserved: snapshot.preservedRelativePaths,
                message: error.localizedDescription
            )
        }

        if let invalid = receiptValidationMessage(
            receiptRecord.receipt,
            host: host,
            destination: target
        ) {
            return LauncherSkillUninstallInspection(
                host: host,
                destinationPath: target.path,
                state: .unrecognized,
                installationID: receiptRecord.receipt.installationID,
                installedVersion: receiptRecord.receipt.skillVersion,
                receiptDigest: receiptRecord.digest,
                targetIdentity: publicIdentity(identity),
                targetFingerprint: snapshot.fingerprint,
                preservedRelativePaths: snapshot.preservedRelativePaths,
                message: invalid
            )
        }

        do {
            try verifyManagedFiles(against: receiptRecord.receipt, at: target)
        } catch ReceiptInspectionError.blocked(let message) {
            return blockedUninstallInspection(
                host: host,
                target: target,
                identity: identity,
                fingerprint: snapshot.fingerprint,
                preserved: snapshot.preservedRelativePaths,
                receipt: receiptRecord,
                message: message
            )
        } catch ReceiptInspectionError.modified(let message) {
            return LauncherSkillUninstallInspection(
                host: host,
                destinationPath: target.path,
                state: .modified,
                installationID: receiptRecord.receipt.installationID,
                installedVersion: receiptRecord.receipt.skillVersion,
                receiptDigest: receiptRecord.digest,
                targetIdentity: publicIdentity(identity),
                targetFingerprint: snapshot.fingerprint,
                preservedRelativePaths: snapshot.preservedRelativePaths,
                message: message
            )
        } catch {
            return blockedUninstallInspection(
                host: host,
                target: target,
                identity: identity,
                fingerprint: snapshot.fingerprint,
                preserved: snapshot.preservedRelativePaths,
                receipt: receiptRecord,
                message: error.localizedDescription
            )
        }

        return LauncherSkillUninstallInspection(
            host: host,
            destinationPath: target.path,
            state: .receiptProven,
            installationID: receiptRecord.receipt.installationID,
            installedVersion: receiptRecord.receipt.skillVersion,
            receiptDigest: receiptRecord.digest,
            targetIdentity: publicIdentity(identity),
            targetFingerprint: snapshot.fingerprint,
            preservedRelativePaths: snapshot.preservedRelativePaths,
            message: "Receipt and every allowlisted managed file match exactly. Unmanaged content will be preserved."
        )
    }

    public func uninstallPlan(host: LauncherSkillHost) -> LauncherSkillUninstallPlan {
        let inspection = inspectUninstall(host: host)
        let binding: LauncherSkillUninstallBinding?
        if inspection.state == .receiptProven,
           let installationID = inspection.installationID,
           let receiptDigest = inspection.receiptDigest,
           let targetIdentity = inspection.targetIdentity,
           let targetFingerprint = inspection.targetFingerprint {
            binding = LauncherSkillUninstallBinding(
                host: host,
                destinationPath: inspection.destinationPath,
                installationID: installationID,
                receiptDigest: receiptDigest,
                targetIdentity: targetIdentity,
                targetFingerprint: targetFingerprint
            )
        } else {
            binding = nil
        }
        return LauncherSkillUninstallPlan(
            inspection: inspection,
            binding: binding,
            removableRelativePaths: Self.managedRelativePaths + [Self.installReceiptFileName],
            prunableEmptyDirectories: ["agents"]
        )
    }

    public func uninstall(
        host: LauncherSkillHost,
        expected binding: LauncherSkillUninstallBinding
    ) throws -> LauncherSkillUninstallResult {
        let target = installationDirectory(for: host)
        guard binding.host == host,
              binding.destinationPath == target.path else {
            throw LauncherSkillUninstallError.refused("the expected host or destination does not match this manager.")
        }
        let plan = uninstallPlan(host: host)
        guard plan.inspection.state == .receiptProven,
              plan.binding == binding else {
            throw LauncherSkillUninstallError.refused(
                "the receipt, target identity, or target fingerprint no longer matches the inspected uninstall plan."
            )
        }
        do {
            return try uninstallTransaction(host: host, target: target, binding: binding, plan: plan)
        } catch let error as LauncherSkillUninstallError {
            throw error
        } catch {
            throw LauncherSkillUninstallError.refused(error.localizedDescription)
        }
    }

    private func uninstallTransaction(
        host: LauncherSkillHost,
        target: URL,
        binding: LauncherSkillUninstallBinding,
        plan: LauncherSkillUninstallPlan
    ) throws -> LauncherSkillUninstallResult {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        let hostRoot = parent.deletingLastPathComponent()
        let transactionRoot = transactionDirectory(for: host)

        let homeDescriptor = open(homeDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard homeDescriptor >= 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not secure the home directory: \(String(cString: strerror(code)))."
            )
        }
        defer { close(homeDescriptor) }
        let hostDescriptor = try openExistingDirectory(named: hostRoot.lastPathComponent, in: homeDescriptor)
        defer { close(hostDescriptor) }
        let parentDescriptor = try openExistingDirectory(named: parent.lastPathComponent, in: hostDescriptor)
        defer { close(parentDescriptor) }
        let transactionDescriptor = try openOrCreateDirectory(
            named: transactionRoot.lastPathComponent,
            in: hostDescriptor,
            createMode: 0o700
        )
        defer { close(transactionDescriptor) }
        guard fchmod(transactionDescriptor, 0o700) == 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not protect the uninstall transaction directory: \(String(cString: strerror(code)))."
            )
        }

        var parentAttributes = stat()
        var transactionAttributes = stat()
        guard fstat(parentDescriptor, &parentAttributes) == 0,
              fstat(transactionDescriptor, &transactionAttributes) == 0 else {
            throw LauncherSkillUninstallError.refused("could not inspect secured uninstall directories.")
        }
        let parentIdentity = DirectoryIdentity(device: parentAttributes.st_dev, inode: parentAttributes.st_ino)
        let transactionIdentity = DirectoryIdentity(
            device: transactionAttributes.st_dev,
            inode: transactionAttributes.st_ino
        )
        guard parentIdentity.device == transactionIdentity.device,
              try directoryIdentity(at: parent) == parentIdentity,
              try directoryIdentity(at: transactionRoot) == transactionIdentity else {
            throw LauncherSkillUninstallError.refused("secured uninstall directories changed during preflight.")
        }
        guard uninstallPlan(host: host).binding == binding else {
            throw LauncherSkillUninstallError.refused("the uninstall proof changed during secured preflight.")
        }

        let originalTargetIdentity = try directoryIdentity(at: target)
        guard publicIdentity(originalTargetIdentity) == binding.targetIdentity else {
            throw LauncherSkillUninstallError.refused("the destination directory identity changed.")
        }
        let originalUnmanaged = try unmanagedFingerprint(at: target)
        let staging = transactionRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        var cleanupIdentity: DirectoryIdentity?
        defer {
            if !transactionHooks.skipCleanup,
               (try? directoryIdentity(at: transactionRoot)) == transactionIdentity,
               let expected = cleanupIdentity,
               (try? optionalDirectoryIdentity(at: staging)) == expected {
                try? fileManager.removeItem(at: staging)
            }
        }

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        guard copyfile(target.path, staging.path, nil, flags) == 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not stage the receipt-proven destination: \(String(cString: strerror(code)))."
            )
        }
        cleanupIdentity = try directoryIdentity(at: staging)
        let stagedSnapshot = try completeTreeSnapshot(at: staging)
        guard stagedSnapshot.fingerprint == binding.targetFingerprint else {
            throw LauncherSkillUninstallError.refused("the staged tree does not match the expected target fingerprint.")
        }
        let stagedReceipt = try readReceipt(at: staging)
        guard stagedReceipt.digest == binding.receiptDigest,
              stagedReceipt.receipt.installationID == binding.installationID,
              receiptValidationMessage(stagedReceipt.receipt, host: host, destination: target) == nil else {
            throw LauncherSkillUninstallError.refused("the staged install receipt does not match the expected proof.")
        }
        try verifyManagedFiles(against: stagedReceipt.receipt, at: staging)
        try transactionHooks.afterUninstallStage(staging)
        let recheckedStagedReceipt = try readReceipt(at: staging)
        guard recheckedStagedReceipt.digest == binding.receiptDigest,
              recheckedStagedReceipt.receipt.installationID == binding.installationID,
              try completeTreeSnapshot(at: staging).fingerprint == binding.targetFingerprint else {
            throw LauncherSkillUninstallError.refused("the private staged tree changed before allowlisted removal.")
        }
        try verifyManagedFiles(against: recheckedStagedReceipt.receipt, at: staging)

        try removeAllowlistedManagedPaths(from: staging)
        guard !hasManagedPathPresence(at: staging),
              try unmanagedFingerprint(at: staging) == originalUnmanaged else {
            throw LauncherSkillUninstallError.refused(
                "the staged uninstall did not preserve the exact unmanaged tree."
            )
        }

        try transactionHooks.beforeUninstallCommit(staging)
        guard let stagedIdentity = cleanupIdentity else {
            throw LauncherSkillUninstallError.refused("the staged uninstall identity was lost.")
        }
        guard try directoryIdentity(at: parent) == parentIdentity,
              try directoryIdentity(at: transactionRoot) == transactionIdentity,
              uninstallPlan(host: host).binding == binding,
              try directoryIdentity(at: staging) == stagedIdentity else {
            throw LauncherSkillUninstallError.refused(
                "the target, receipt, fingerprint, or transaction identity changed before commit."
            )
        }

        guard renameatx_np(
            transactionDescriptor,
            staging.lastPathComponent,
            parentDescriptor,
            target.lastPathComponent,
            UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
        ) == 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not atomically commit the staged uninstall: \(String(cString: strerror(code)))."
            )
        }
        // The live destination is now the staged directory. The hidden sibling is the
        // exact old target and is the only tree eligible for post-commit cleanup.
        cleanupIdentity = originalTargetIdentity

        return LauncherSkillUninstallResult(
            host: host,
            destinationPath: target.path,
            installationID: binding.installationID,
            consumedReceiptDigest: binding.receiptDigest,
            removedRelativePaths: plan.removableRelativePaths,
            preservedRelativePaths: plan.inspection.preservedRelativePaths,
            message: "Removed only receipt-proven Launcher-managed paths. The destination directory remains and unmanaged content was preserved."
        )
    }

    private func status(for host: LauncherSkillHost) throws -> LauncherSkillHostStatus {
        let target = installationDirectory(for: host)
        let surfaces = surfaceStatuses(for: host)
        let available = surfaces.contains(where: \.available)
        let availableNames = surfaces.filter(\.available).map { $0.surface.displayName }.joined(separator: " and ")
        let availabilityMessage = available
            ? "Available through \(availableNames)."
            : "No supported Desktop or CLI surface is currently available."

        if let unsafe = unsafeExistingComponent(for: host) {
            return LauncherSkillHostStatus(
                host: host,
                available: available,
                surfaces: surfaces,
                installationPath: target.path,
                state: .blocked,
                installedVersion: installedVersion(at: target),
                message: "Refusing to write through or replace \(unsafe). \(availabilityMessage)"
            )
        }

        if FileManager.default.fileExists(atPath: target.path) {
            do {
                // Status must surface unsafe unmanaged entries before a mutation is attempted.
                // The bounded no-follow walk rejects links, hard links, special files, excessive
                // depth, and excessive entry counts without reading user-controlled contents.
                _ = try inspectedTreeEntries(at: target, includeRoot: false)
            } catch {
                return LauncherSkillHostStatus(
                    host: host,
                    available: available,
                    surfaces: surfaces,
                    installationPath: target.path,
                    state: .blocked,
                    installedVersion: installedVersion(at: target),
                    message: "Unsafe destination tree: \(error.localizedDescription) \(availabilityMessage)"
                )
            }
        }

        let skillFile = target.appendingPathComponent("SKILL.md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: skillFile.path) else {
            return LauncherSkillHostStatus(
                host: host,
                available: available,
                surfaces: surfaces,
                installationPath: target.path,
                state: .notInstalled,
                message: available
                    ? "Not installed at the shared Desktop/CLI destination. \(availabilityMessage) Ready to install."
                    : "Not installed at the shared Desktop/CLI destination. \(availabilityMessage)"
            )
        }

        let current = Self.managedRelativePaths.allSatisfy { relativePath in
            let destination = target.appendingPathComponent(relativePath, isDirectory: false)
            guard let installed = try? readRegularFileNoFollow(at: destination).data else { return false }
            return installed == (try? sourceData(relativePath: relativePath))
        }
        return LauncherSkillHostStatus(
            host: host,
            available: available,
            surfaces: surfaces,
            installationPath: target.path,
            state: current ? .current : .outdated,
            installedVersion: installedVersion(at: target),
            message: current
                ? "Installed bytes and version are current at \(target.path). \(availabilityMessage)"
                : "A different or older managed copy is installed at \(target.path). Reinstall to update it. \(availabilityMessage)"
        )
    }

    private func surfaceStatuses(for host: LauncherSkillHost) -> [LauncherSkillSurfaceStatus] {
        LauncherSkillSurface.allCases.map { surface in
            let candidate = (detectionCandidates[host]?[surface] ?? []).first {
                isDetectedCandidate($0, host: host, surface: surface)
            }
            if let candidate {
                return LauncherSkillSurfaceStatus(
                    surface: surface,
                    available: true,
                    detectedPath: candidate.path,
                    message: "Detected at \(candidate.path)."
                )
            }
            return LauncherSkillSurfaceStatus(
                surface: surface,
                available: false,
                message: Self.unavailableSurfaceMessage(host: host, surface: surface)
            )
        }
    }

    private func validateSource() throws {
        guard Self.hasCanonicalFiles(at: sourceDirectory) else {
            throw LauncherSkillError.bundledSkillUnavailable("required files are missing from \(sourceDirectory.path).")
        }
        let version = try bundledVersion()
        guard version == Self.version else {
            throw LauncherSkillError.bundledSkillUnavailable(
                "bundle version \(version) does not match application version \(Self.version)."
            )
        }
    }

    private func bundledVersion() throws -> String {
        guard let value = String(data: try sourceData(relativePath: "VERSION"), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw LauncherSkillError.bundledSkillUnavailable("VERSION is missing or invalid.")
        }
        return value
    }

    private func installedVersion(at target: URL) -> String? {
        let versionURL = target.appendingPathComponent("VERSION", isDirectory: false)
        return (try? String(data: readRegularFileNoFollow(at: versionURL).data, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sourceData(relativePath: String) throws -> Data {
        do {
            let components = relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw NoFollowFileReadError.unsafe("Invalid bundled-skill relative path.")
            }
            var directoryDescriptor = open(
                sourceDirectory.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryDescriptor >= 0 else {
                let code = errno
                throw NoFollowFileReadError.unreadable(
                    "Could not open the bundled-skill root without following links: "
                        + "\(String(cString: strerror(code)))."
                )
            }
            defer { close(directoryDescriptor) }

            for component in components.dropLast() {
                let next = openat(
                    directoryDescriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    let code = errno
                    throw NoFollowFileReadError.unreadable(
                        "Could not open bundled-skill directory \(component) without following links: "
                            + "\(String(cString: strerror(code)))."
                    )
                }
                close(directoryDescriptor)
                directoryDescriptor = next
            }

            guard let fileName = components.last else {
                throw NoFollowFileReadError.unsafe("Bundled-skill file name is missing.")
            }
            let descriptor = openat(
                directoryDescriptor,
                fileName,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                let code = errno
                throw NoFollowFileReadError.unreadable(
                    "Could not open bundled-skill file \(relativePath) without following links: "
                        + "\(String(cString: strerror(code)))."
                )
            }
            defer { close(descriptor) }
            return try readOpenedRegularFile(
                descriptor: descriptor,
                displayPath: sourceDirectory.appendingPathComponent(relativePath).path
            ).data
        }
        catch {
            throw LauncherSkillError.bundledSkillUnavailable(
                "could not safely read \(relativePath): \(error.localizedDescription)"
            )
        }
    }

    private func managedFilesMatchSource(at directory: URL) throws -> Bool {
        try Self.managedRelativePaths.allSatisfy { relativePath in
            let destination = directory.appendingPathComponent(relativePath, isDirectory: false)
            var attributes = stat()
            guard lstat(destination.path, &attributes) == 0,
                  (attributes.st_mode & S_IFMT) == S_IFREG,
                  (attributes.st_mode & 0o7777) == 0o644 else { return false }
            return try readRegularFileNoFollow(at: destination).data == sourceData(relativePath: relativePath)
        }
    }

    private func makeInstallReceipt(
        host: LauncherSkillHost,
        destination: URL,
        directory: URL
    ) throws -> LauncherSkillInstallReceipt {
        let files = try Self.managedRelativePaths.map { relativePath in
            let url = directory.appendingPathComponent(relativePath, isDirectory: false)
            let file: NoFollowRegularFile
            do {
                file = try readRegularFileNoFollow(at: url)
            } catch {
                throw LauncherSkillError.installationFailed(
                    "could not record safe no-follow metadata for \(relativePath): \(error.localizedDescription)"
                )
            }
            return LauncherSkillReceiptFile(
                relativePath: relativePath,
                sha256: Self.sha256Hex(file.data),
                type: .regularFile,
                posixMode: file.posixMode,
                linkCount: file.linkCount
            )
        }
        return LauncherSkillInstallReceipt(
            schemaVersion: Self.receiptSchemaVersion,
            installationID: UUID(),
            managerID: Self.receiptManagerID,
            host: host,
            destinationPath: destination.standardizedFileURL.path,
            skillVersion: try bundledVersion(),
            installedAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            files: files
        )
    }

    private func receiptURL(in directory: URL) -> URL {
        directory.appendingPathComponent(Self.installReceiptFileName, isDirectory: false)
    }

    private static func encodeReceipt(_ receipt: LauncherSkillInstallReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipt)
    }

    private static func decodeReceipt(_ data: Data) throws -> LauncherSkillInstallReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LauncherSkillInstallReceipt.self, from: data)
    }

    private func readReceipt(at directory: URL) throws -> InstallReceiptRecord {
        let url = receiptURL(in: directory)
        let file: NoFollowRegularFile
        do {
            file = try readRegularFileNoFollow(at: url)
        } catch NoFollowFileReadError.missing {
            throw ReceiptInspectionError.absent
        } catch NoFollowFileReadError.unsafe(let message) {
            throw ReceiptInspectionError.blocked(message)
        } catch NoFollowFileReadError.unreadable(let message) {
            throw ReceiptInspectionError.blocked(message)
        }
        guard file.posixMode == 0o600 else {
            throw ReceiptInspectionError.invalid("The install receipt is not private mode 0600.")
        }
        let receipt: LauncherSkillInstallReceipt
        do {
            receipt = try Self.decodeReceipt(file.data)
        } catch {
            throw ReceiptInspectionError.invalid("The install receipt is malformed or has an unsupported value.")
        }
        return InstallReceiptRecord(
            receipt: receipt,
            digest: Self.sha256Hex(file.data)
        )
    }

    private func receiptValidationMessage(
        _ receipt: LauncherSkillInstallReceipt,
        host: LauncherSkillHost,
        destination: URL
    ) -> String? {
        guard receipt.schemaVersion == Self.receiptSchemaVersion else {
            return "The install receipt schema is not supported."
        }
        guard receipt.managerID == Self.receiptManagerID else {
            return "The install receipt belongs to an unrecognized manager."
        }
        guard receipt.host == host,
              receipt.destinationPath == destination.standardizedFileURL.path else {
            return "The install receipt host or exact destination does not match."
        }
        guard !receipt.skillVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "The install receipt has no skill version."
        }
        guard receipt.files.map(\.relativePath) == Self.managedRelativePaths else {
            return "The install receipt managed-path allowlist does not match this build."
        }
        for file in receipt.files {
            guard file.type == .regularFile,
                  file.posixMode == 0o644,
                  file.linkCount == 1,
                  file.sha256.count == 64,
                  file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return "The install receipt contains invalid metadata for \(file.relativePath)."
            }
        }
        return nil
    }

    private func verifyManagedFiles(
        against receipt: LauncherSkillInstallReceipt,
        at directory: URL
    ) throws {
        for file in receipt.files {
            let url = directory.appendingPathComponent(file.relativePath, isDirectory: false)
            let installed: NoFollowRegularFile
            do {
                installed = try readRegularFileNoFollow(at: url)
            } catch NoFollowFileReadError.missing {
                throw ReceiptInspectionError.modified("Managed file \(file.relativePath) is missing.")
            } catch NoFollowFileReadError.unsafe(let message) {
                throw ReceiptInspectionError.blocked(message)
            } catch NoFollowFileReadError.unreadable(let message) {
                throw ReceiptInspectionError.blocked(message)
            }
            guard installed.posixMode == file.posixMode,
                  installed.linkCount == file.linkCount else {
                throw ReceiptInspectionError.modified("Managed metadata changed for \(file.relativePath).")
            }
            guard Self.sha256Hex(installed.data) == file.sha256 else {
                throw ReceiptInspectionError.modified("Managed bytes changed for \(file.relativePath).")
            }
        }
    }

    private func managedFilesMatchReceipt(
        _ receipt: LauncherSkillInstallReceipt,
        at directory: URL
    ) throws -> Bool {
        do {
            try verifyManagedFiles(against: receipt, at: directory)
            return true
        } catch {
            return false
        }
    }

    private func completeTreeSnapshot(at root: URL) throws -> CompleteSkillTreeSnapshot {
        var fingerprintRows: [String] = []
        var preserved: [String] = []
        var budget = SkillInspectionBudget()
        for entry in try inspectedTreeEntries(at: root, includeRoot: true) {
            let kind = entry.kind == .directory ? "directory" : "regular-file"
            let digest = entry.kind == .regularFile
                ? Self.hex(try hashRegularFileNoFollow(entry, budget: &budget))
                : ""
            let path = entry.relativePath.isEmpty ? "." : entry.relativePath
            fingerprintRows.append(
                "\(path.utf8.count):\(path)|\(kind)|\(entry.mode)|\(entry.linkCount)|\(digest)"
            )
            if !entry.relativePath.isEmpty, !Self.managedTreePaths.contains(entry.relativePath) {
                preserved.append(entry.relativePath)
            }
        }
        let joined = fingerprintRows.joined(separator: "\n") + "\n"
        return CompleteSkillTreeSnapshot(
            fingerprint: Self.sha256Hex(Data(joined.utf8)),
            preservedRelativePaths: preserved.sorted()
        )
    }

    private func hasManagedPathPresence(at directory: URL) -> Bool {
        (Self.managedRelativePaths + [Self.installReceiptFileName]).contains { relativePath in
            var attributes = stat()
            return lstat(directory.appendingPathComponent(relativePath).path, &attributes) == 0
        }
    }

    private func readRegularFileNoFollow(at url: URL) throws -> NoFollowRegularFile {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { throw NoFollowFileReadError.missing }
            if code == ELOOP {
                throw NoFollowFileReadError.unsafe("Refusing a symbolic link at \(url.path).")
            }
            throw NoFollowFileReadError.unreadable(
                "Could not open \(url.path) without following links: \(String(cString: strerror(code)))."
            )
        }
        defer { close(descriptor) }
        return try readOpenedRegularFile(descriptor: descriptor, displayPath: url.path)
    }

    private func readOpenedRegularFile(
        descriptor: Int32,
        displayPath: String
    ) throws -> NoFollowRegularFile {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            let code = errno
            throw NoFollowFileReadError.unreadable(
                "Could not inspect opened file \(displayPath): \(String(cString: strerror(code)))."
            )
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG else {
            throw NoFollowFileReadError.unsafe("Refusing a non-regular file at \(displayPath).")
        }
        guard attributes.st_nlink == 1 else {
            throw NoFollowFileReadError.unsafe("Refusing a hard-linked file at \(displayPath).")
        }
        guard attributes.st_size >= 0,
              attributes.st_size <= Self.maximumManagedFileBytes else {
            throw NoFollowFileReadError.unsafe(
                "Refusing to load \(displayPath) because it exceeds the bounded managed-file limit."
            )
        }
        var data = Data()
        data.reserveCapacity(Int(attributes.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                let code = errno
                throw NoFollowFileReadError.unreadable(
                    "Could not read \(displayPath): \(String(cString: strerror(code)))."
                )
            }
            guard data.count <= Int(Self.maximumManagedFileBytes) - count else {
                throw NoFollowFileReadError.unsafe(
                    "Refusing to load \(displayPath) because it grew beyond the bounded managed-file limit."
                )
            }
            data.append(buffer, count: count)
        }
        guard data.count == Int(attributes.st_size) else {
            throw NoFollowFileReadError.unsafe(
                "Refusing \(displayPath) because its size changed during inspection."
            )
        }
        return NoFollowRegularFile(
            data: data,
            posixMode: UInt32(attributes.st_mode & 0o7777),
            linkCount: UInt64(attributes.st_nlink)
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(Array(SHA256.hash(data: data)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func blockedUninstallInspection(
        host: LauncherSkillHost,
        target: URL,
        identity: DirectoryIdentity? = nil,
        fingerprint: String? = nil,
        preserved: [String] = [],
        receipt: InstallReceiptRecord? = nil,
        message: String
    ) -> LauncherSkillUninstallInspection {
        LauncherSkillUninstallInspection(
            host: host,
            destinationPath: target.path,
            state: .blocked,
            installationID: receipt?.receipt.installationID,
            installedVersion: receipt?.receipt.skillVersion,
            receiptDigest: receipt?.digest,
            targetIdentity: identity.map { publicIdentity($0) },
            targetFingerprint: fingerprint,
            preservedRelativePaths: preserved,
            message: message
        )
    }

    private func publicIdentity(_ identity: DirectoryIdentity) -> LauncherSkillTargetIdentity {
        LauncherSkillTargetIdentity(
            device: UInt64(identity.device),
            inode: UInt64(identity.inode)
        )
    }

    private func removeAllowlistedManagedPaths(from staging: URL) throws {
        let rootDescriptor = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not secure the staged uninstall root: \(String(cString: strerror(code)))."
            )
        }
        defer { close(rootDescriptor) }

        guard unlinkat(rootDescriptor, "SKILL.md", 0) == 0,
              unlinkat(rootDescriptor, "VERSION", 0) == 0,
              unlinkat(rootDescriptor, Self.installReceiptFileName, 0) == 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not remove an allowlisted staged file: \(String(cString: strerror(code)))."
            )
        }
        let agentsDescriptor = openat(
            rootDescriptor,
            "agents",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard agentsDescriptor >= 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not secure the staged agents directory: \(String(cString: strerror(code)))."
            )
        }
        guard unlinkat(agentsDescriptor, "openai.yaml", 0) == 0 else {
            let code = errno
            close(agentsDescriptor)
            throw LauncherSkillUninstallError.refused(
                "could not remove the allowlisted staged metadata file: \(String(cString: strerror(code)))."
            )
        }
        close(agentsDescriptor)
        if unlinkat(rootDescriptor, "agents", AT_REMOVEDIR) != 0, errno != ENOTEMPTY {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not prune the empty staged agents directory: \(String(cString: strerror(code)))."
            )
        }
    }

    private func unmanagedFingerprint(at root: URL) throws -> SkillTreeFingerprint {
        var entries: [String: SkillTreeEntry] = [:]
        var budget = SkillInspectionBudget()
        for entry in try inspectedTreeEntries(at: root, includeRoot: false) {
            guard !Self.managedTreePaths.contains(entry.relativePath) else { continue }
            switch entry.kind {
            case .directory:
                entries[entry.relativePath] = SkillTreeEntry(
                    kind: .directory,
                    permissions: mode_t(entry.mode),
                    digest: []
                )
            case .regularFile:
                entries[entry.relativePath] = SkillTreeEntry(
                    kind: .regularFile,
                    permissions: mode_t(entry.mode),
                    digest: try hashRegularFileNoFollow(entry, budget: &budget)
                )
            }
        }
        return SkillTreeFingerprint(entries: entries)
    }

    private func inspectedTreeEntries(
        at root: URL,
        includeRoot: Bool
    ) throws -> [SkillInspectionEntry] {
        let requestedRoot = root.standardizedFileURL
        let requestedRootEntry = try inspectedTreeEntry(at: requestedRoot, relativePath: "")
        guard requestedRootEntry.kind == .directory else {
            throw LauncherSkillError.unsafeDestination("skill tree root is not a directory: \(requestedRoot.path).")
        }

        // FileManager canonicalizes the system /var -> /private/var alias while enumerating.
        // Resolve only after the no-follow root inspection, then prove the canonical path is the
        // exact same directory identity before using it for lexical containment checks.
        let enumerationRoot = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let enumerationRootEntry = try inspectedTreeEntry(at: enumerationRoot, relativePath: "")
        guard enumerationRootEntry.kind == .directory,
              enumerationRootEntry.device == requestedRootEntry.device,
              enumerationRootEntry.inode == requestedRootEntry.inode else {
            throw LauncherSkillError.unsafeDestination(
                "skill tree root identity changed while canonicalizing \(requestedRoot.path)."
            )
        }
        let prefix = enumerationRoot.path.hasSuffix("/")
            ? enumerationRoot.path
            : enumerationRoot.path + "/"
        var result: [SkillInspectionEntry] = []
        if includeRoot {
            result.append(requestedRootEntry)
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: enumerationRoot,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LauncherSkillError.unsafeDestination("could not enumerate \(requestedRoot.path).")
        }
        while let url = enumerator.nextObject() as? URL {
            let inspectedURL = url.standardizedFileURL
            guard inspectedURL.path.hasPrefix(prefix) else {
                throw LauncherSkillError.unsafeDestination("tree enumeration escaped \(requestedRoot.path).")
            }
            let relativePath = String(inspectedURL.path.dropFirst(prefix.count))
            let depth = relativePath.split(separator: "/", omittingEmptySubsequences: true).count
            guard depth <= Self.maximumInspectionDepth else {
                throw LauncherSkillError.unsafeDestination(
                    "skill tree exceeds the maximum inspection depth of \(Self.maximumInspectionDepth)."
                )
            }
            guard result.count < Self.maximumInspectionEntries else {
                throw LauncherSkillError.unsafeDestination(
                    "skill tree exceeds the maximum inspection entry count of \(Self.maximumInspectionEntries)."
                )
            }
            result.append(try inspectedTreeEntry(at: inspectedURL, relativePath: relativePath))
        }
        if let enumerationError {
            throw LauncherSkillError.unsafeDestination(
                "skill tree enumeration failed: \(enumerationError.localizedDescription)"
            )
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func inspectedTreeEntry(at url: URL, relativePath: String) throws -> SkillInspectionEntry {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else {
            let code = errno
            throw LauncherSkillError.unsafeDestination(
                "could not inspect \(url.path): \(String(cString: strerror(code)))"
            )
        }
        let type = attributes.st_mode & S_IFMT
        let kind: SkillInspectionEntry.Kind
        if type == S_IFDIR {
            kind = .directory
        } else if type == S_IFREG {
            guard attributes.st_nlink == 1 else {
                throw LauncherSkillError.unsafeDestination("refusing a hard-linked file at \(url.path).")
            }
            kind = .regularFile
        } else if type == S_IFLNK {
            throw LauncherSkillError.unsafeDestination("refusing a symbolic link at \(url.path).")
        } else {
            throw LauncherSkillError.unsafeDestination("refusing a special file at \(url.path).")
        }
        return SkillInspectionEntry(
            url: url,
            relativePath: relativePath,
            kind: kind,
            mode: UInt32(attributes.st_mode & 0o7777),
            linkCount: UInt64(attributes.st_nlink),
            device: UInt64(bitPattern: Int64(attributes.st_dev)),
            inode: UInt64(attributes.st_ino),
            size: Int64(attributes.st_size)
        )
    }

    private func hashRegularFileNoFollow(
        _ entry: SkillInspectionEntry,
        budget: inout SkillInspectionBudget
    ) throws -> [UInt8] {
        guard entry.kind == .regularFile, entry.size >= 0 else {
            throw LauncherSkillError.unsafeDestination("invalid regular-file metadata at \(entry.url.path).")
        }
        try budget.consume(bytes: entry.size)
        let descriptor = open(entry.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw LauncherSkillError.unsafeDestination(
                "could not open \(entry.url.path) without following links: \(String(cString: strerror(code)))."
            )
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_nlink == 1,
              UInt64(bitPattern: Int64(attributes.st_dev)) == entry.device,
              UInt64(attributes.st_ino) == entry.inode,
              Int64(attributes.st_size) == entry.size else {
            throw LauncherSkillError.unsafeDestination(
                "file identity changed while inspecting \(entry.url.path)."
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total: Int64 = 0
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                let code = errno
                throw LauncherSkillError.unsafeDestination(
                    "could not read \(entry.url.path): \(String(cString: strerror(code)))."
                )
            }
            total += Int64(count)
            guard total <= entry.size else {
                throw LauncherSkillError.unsafeDestination(
                    "file size changed while inspecting \(entry.url.path)."
                )
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard total == entry.size else {
            throw LauncherSkillError.unsafeDestination(
                "file size changed while inspecting \(entry.url.path)."
            )
        }
        return Array(hasher.finalize())
    }

    private func optionalDirectoryIdentity(at url: URL) throws -> DirectoryIdentity? {
        var attributes = stat()
        if lstat(url.path, &attributes) == 0 {
            guard (attributes.st_mode & S_IFMT) == S_IFDIR else {
                throw LauncherSkillError.unsafeDestination("expected a directory at \(url.path).")
            }
            return DirectoryIdentity(device: attributes.st_dev, inode: attributes.st_ino)
        }
        let code = errno
        if code == ENOENT { return nil }
        throw LauncherSkillError.installationFailed(
            "could not inspect \(url.path): \(String(cString: strerror(code)))"
        )
    }

    private func directoryIdentity(at url: URL) throws -> DirectoryIdentity {
        guard let identity = try optionalDirectoryIdentity(at: url) else {
            throw LauncherSkillError.installationFailed("expected a directory at \(url.path).")
        }
        return identity
    }

    private func openOrCreateDirectory(
        named name: String,
        in parentDescriptor: Int32,
        createMode: mode_t
    ) throws -> Int32 {
        precondition(!name.isEmpty && !name.contains("/"))
        var attributes = stat()
        if fstatat(parentDescriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) != 0 {
            let inspectionCode = errno
            guard inspectionCode == ENOENT else {
                throw LauncherSkillError.unsafeDestination(
                    "could not inspect \(name): \(String(cString: strerror(inspectionCode)))."
                )
            }
            if mkdirat(parentDescriptor, name, createMode) != 0, errno != EEXIST {
                let creationCode = errno
                throw LauncherSkillError.installationFailed(
                    "could not create \(name): \(String(cString: strerror(creationCode)))"
                )
            }
        } else if (attributes.st_mode & S_IFMT) != S_IFDIR {
            throw LauncherSkillError.unsafeDestination("refusing a non-directory component named \(name).")
        }

        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            throw LauncherSkillError.unsafeDestination(
                "could not open \(name) without following links: \(String(cString: strerror(code)))."
            )
        }
        return descriptor
    }

    private func openExistingDirectory(named name: String, in parentDescriptor: Int32) throws -> Int32 {
        precondition(!name.isEmpty && !name.contains("/"))
        var attributes = stat()
        guard fstatat(parentDescriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not inspect existing directory \(name): \(String(cString: strerror(code)))."
            )
        }
        guard (attributes.st_mode & S_IFMT) == S_IFDIR else {
            throw LauncherSkillUninstallError.refused("expected a real existing directory named \(name).")
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            let code = errno
            throw LauncherSkillUninstallError.refused(
                "could not open \(name) without following links: \(String(cString: strerror(code)))."
            )
        }
        return descriptor
    }

    private func rejectUnsafeExistingComponents(for host: LauncherSkillHost) throws {
        if let unsafe = unsafeExistingComponent(for: host) {
            throw LauncherSkillError.unsafeDestination("refusing to write through or replace \(unsafe).")
        }
    }

    private func unsafeExistingComponent(for host: LauncherSkillHost) -> String? {
        let target = installationDirectory(for: host)
        let directories = [
            target.deletingLastPathComponent().deletingLastPathComponent(),
            target.deletingLastPathComponent(),
            transactionDirectory(for: host),
            target,
            target.appendingPathComponent("agents", isDirectory: true),
        ]
        for url in directories {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return url.path
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
                return url.path
            }
            if values.isSymbolicLink == true || values.isDirectory != true { return url.path }
        }
        for relativePath in Self.managedRelativePaths + [Self.installReceiptFileName] {
            let url = target.appendingPathComponent(relativePath, isDirectory: false)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return url.path
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else {
                return url.path
            }
            if values.isSymbolicLink == true || values.isRegularFile != true { return url.path }
        }
        return nil
    }

    private static func hasCanonicalFiles(at directory: URL) -> Bool {
        let directoryPaths = [directory, directory.appendingPathComponent("agents", isDirectory: true)]
        for path in directoryPaths {
            guard let values = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { return false }
        }
        return managedRelativePaths.allSatisfy { relativePath in
            let url = directory.appendingPathComponent(relativePath, isDirectory: false)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private static func containingApplicationURL(for executable: URL) -> URL? {
        var cursor = executable.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { return cursor }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private func isDetectedCandidate(
        _ url: URL,
        host: LauncherSkillHost,
        surface: LauncherSkillSurface
    ) -> Bool {
        switch surface {
        case .desktop:
            let expectedBundleIdentifier = host == .codex
                ? "com.openai.codex"
                : "com.anthropic.claudefordesktop"
            guard url.pathExtension.lowercased() == "app",
                  Self.isRealDirectory(url),
                  let bundle = Bundle(url: url),
                  bundle.bundleIdentifier == expectedBundleIdentifier,
                  let executable = bundle.executableURL,
                  Self.isRealExecutable(executable) else { return false }
            // The production authenticator performs this same strict nested/all-architectures
            // validation together with the publisher requirement. Running an unrestricted deep
            // validation first doubles the most expensive part of every status refresh without
            // adding a security boundary.
            return candidateAuthenticator(url, host, surface)
        case .cli:
            let expectedExecutable = host == .codex ? "codex" : "claude"
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return url.lastPathComponent == expectedExecutable
                && Self.isRealExecutable(resolved)
                && candidateAuthenticator(resolved, host, surface)
        }
    }

    private static func isAuthenticCandidate(
        _ url: URL,
        host: LauncherSkillHost,
        surface: LauncherSkillSurface
    ) -> Bool {
        switch surface {
        case .desktop:
            let bundleID = host == .codex
                ? "com.openai.codex"
                : "com.anthropic.claudefordesktop"
            let teamID = host == .codex ? "2DC432GLL2" : "Q6L2SF6YDW"
            let requirementText = "identifier \"\(bundleID)\" and anchor apple generic "
                + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
                + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
                + "and certificate leaf[subject.OU] = \"\(teamID)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(
                requirementText as CFString,
                SecCSFlags(),
                &requirement
            ) == errSecSuccess,
            let requirement else { return false }
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
                  let staticCode else { return false }
            let flags = SecCSFlags(
                rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures
            )
            return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess

        case .cli:
            switch host {
            case .codex:
                // Never execute a PATH candidate merely to discover whether it is Codex. Prove
                // the OpenAI publisher and product identifier first, then use the bounded probe
                // only to distinguish the expected CLI product from another signed executable.
                guard signedCode(at: url, identifier: "codex", teamID: "2DC432GLL2"),
                      let output = boundedVersionOutput(from: url)?.lowercased() else {
                    return false
                }
                guard output.hasPrefix("codex-cli ") || output.hasPrefix("codex ") else {
                    return false
                }
                return true
            case .claudeCode:
                // Anthropic's supported macOS installs all resolve to the same notarized native
                // binary. As with Codex, authenticate its publisher before invoking --version.
                guard signedCode(at: url, identifier: nil, teamID: "Q6L2SF6YDW"),
                      let output = boundedVersionOutput(from: url)?.lowercased() else {
                    return false
                }
                return output.range(
                    of: #"^\d+(?:\.\d+){1,3}(?:[-+][a-z0-9._-]+)?\s+\(claude code\)$"#,
                    options: .regularExpression
                ) != nil
            }
        }
    }

    private static func signedCode(at url: URL, identifier: String?, teamID: String) -> Bool {
        let productRequirement = identifier.map { "identifier \"\($0)\" and " } ?? ""
        let requirementText = productRequirement + "anchor apple generic "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
        let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
            == errSecSuccess
    }

    private static func boundedVersionOutput(from executable: URL) -> String? {
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()

            func append(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                let remaining = max(0, 16_384 - storage.count)
                if remaining > 0 { storage.append(data.prefix(remaining)) }
            }

            func string() -> String {
                lock.lock()
                defer { lock.unlock() }
                return String(decoding: storage, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let process = Process()
        let pipe = Pipe()
        let output = OutputBuffer()
        let reachedEOF = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                reachedEOF.signal()
            } else {
                output.append(data)
            }
        }
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe.fileHandleForWriting
        process.standardError = pipe.fileHandleForWriting
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return nil
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < terminateDeadline { usleep(10_000) }
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < killDeadline { usleep(10_000) }
        }
        _ = reachedEOF.wait(timeout: .now() + 0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        guard !process.isRunning, process.terminationStatus == 0 else { return nil }
        let value = output.string()
        return value.isEmpty ? nil : value
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var attributes = stat()
        return lstat(url.path, &attributes) == 0 && (attributes.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRealExecutable(_ url: URL) -> Bool {
        var attributes = stat()
        return lstat(url.path, &attributes) == 0
            && (attributes.st_mode & S_IFMT) == S_IFREG
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func unavailableSurfaceMessage(
        host: LauncherSkillHost,
        surface: LauncherSkillSurface
    ) -> String {
        switch (host, surface) {
        case (.codex, .desktop):
            return "Install the OpenAI Developer-ID signed Codex or ChatGPT app with bundle identifier com.openai.codex in /Applications or ~/Applications."
        case (.codex, .cli):
            return "Install the OpenAI Developer-ID signed Codex CLI and make its real codex executable available in ~/.local/bin, ~/bin, Homebrew, /usr/local/bin, or the daemon PATH."
        case (.claudeCode, .desktop):
            return "Install the Anthropic Developer-ID signed Claude app with bundle identifier com.anthropic.claudefordesktop in /Applications or ~/Applications."
        case (.claudeCode, .cli):
            return "Install the Anthropic-signed Claude Code CLI and make its real claude executable available in ~/.local/bin, ~/bin, Homebrew, /usr/local/bin, or the daemon PATH."
        }
    }

    private static func restartRecommended(
        for host: LauncherSkillHost,
        skillsRootExistedBeforeInstall: Bool
    ) -> Bool {
        switch host {
        case .codex:
            return false
        case .claudeCode:
            return !skillsRootExistedBeforeInstall
        }
    }

    private static func makeDetectionCandidates(
        home: URL,
        path: String?,
        codexLegacy: [URL]?,
        claudeLegacy: [URL]?,
        codexDesktop: [URL]?,
        codexCLI: [URL]?,
        claudeDesktop: [URL]?,
        claudeCLI: [URL]?
    ) -> [LauncherSkillHost: [LauncherSkillSurface: [URL]]] {
        func candidates(
            legacy: [URL]?,
            desktop: [URL]?,
            cli: [URL]?,
            defaultDesktop: [URL],
            defaultCLI: [URL]
        ) -> [LauncherSkillSurface: [URL]] {
            if let legacy {
                return [
                    .desktop: unique(desktop ?? legacy.filter { $0.pathExtension.lowercased() == "app" }),
                    .cli: unique(cli ?? legacy.filter { $0.pathExtension.lowercased() != "app" }),
                ]
            }
            return [
                .desktop: unique(desktop ?? defaultDesktop),
                .cli: unique(cli ?? defaultCLI),
            ]
        }

        return [
            .codex: candidates(
                legacy: codexLegacy,
                desktop: codexDesktop,
                cli: codexCLI,
                defaultDesktop: defaultCodexDesktopCandidates(home: home),
                defaultCLI: defaultCodexCLICandidates(home: home, path: path)
            ),
            .claudeCode: candidates(
                legacy: claudeLegacy,
                desktop: claudeDesktop,
                cli: claudeCLI,
                defaultDesktop: defaultClaudeDesktopCandidates(home: home),
                defaultCLI: defaultClaudeCLICandidates(home: home, path: path)
            ),
        ]
    }

    private static func defaultCodexDesktopCandidates(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            home.appendingPathComponent("Applications/Codex.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            home.appendingPathComponent("Applications/ChatGPT.app", isDirectory: true),
        ]
    }

    private static func defaultCodexCLICandidates(home: URL, path: String?) -> [URL] {
        var values = [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent("bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        values.append(contentsOf: pathCandidates(executable: "codex", path: path))
        return unique(values)
    }

    private static func defaultClaudeDesktopCandidates(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true),
            home.appendingPathComponent("Applications/Claude.app", isDirectory: true),
        ]
    }

    private static func defaultClaudeCLICandidates(home: URL, path: String?) -> [URL] {
        var values = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent("bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        values.append(contentsOf: pathCandidates(executable: "claude", path: path))
        return unique(values)
    }

    private static func pathCandidates(executable: String, path: String?) -> [URL] {
        (path ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(executable)
        }
    }

    private static func unique(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private enum ReceiptInspectionError: Error {
    case absent
    case invalid(String)
    case modified(String)
    case blocked(String)
}

private enum NoFollowFileReadError: LocalizedError {
    case missing
    case unsafe(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missing: return "The file does not exist."
        case .unsafe(let message), .unreadable(let message): return message
        }
    }
}

private struct NoFollowRegularFile {
    var data: Data
    var posixMode: UInt32
    var linkCount: UInt64
}

private struct InstallReceiptRecord {
    var receipt: LauncherSkillInstallReceipt
    var digest: String
}

private struct CompleteSkillTreeSnapshot {
    var fingerprint: String
    var preservedRelativePaths: [String]
}

private struct DirectoryIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
}

private struct SkillTreeFingerprint: Equatable {
    var entries: [String: SkillTreeEntry]

    static let empty = SkillTreeFingerprint(entries: [:])
}

private struct SkillTreeEntry: Equatable {
    enum Kind: Equatable {
        case directory
        case regularFile
    }

    var kind: Kind
    var permissions: mode_t
    var digest: [UInt8]
}

private struct SkillInspectionEntry {
    enum Kind: Equatable {
        case directory
        case regularFile
    }

    var url: URL
    var relativePath: String
    var kind: Kind
    var mode: UInt32
    var linkCount: UInt64
    var device: UInt64
    var inode: UInt64
    var size: Int64
}

private struct SkillInspectionBudget {
    private var consumedBytes: Int64 = 0

    mutating func consume(bytes: Int64) throws {
        guard bytes >= 0,
              consumedBytes <= LauncherSkillManager.maximumInspectionBytes - bytes else {
            throw LauncherSkillError.unsafeDestination(
                "skill tree exceeds the bounded inspection byte limit."
            )
        }
        consumedBytes += bytes
    }
}

struct LauncherSkillTransactionHooks: Sendable {
    var afterManagedWrite: @Sendable (String, URL) throws -> Void
    var afterReceiptWrite: @Sendable (URL, URL) throws -> Void
    var beforeCommit: @Sendable (URL) throws -> Void
    var afterUninstallStage: @Sendable (URL) throws -> Void
    var beforeUninstallCommit: @Sendable (URL) throws -> Void
    var skipCleanup: Bool

    init(
        afterManagedWrite: @escaping @Sendable (String, URL) throws -> Void = { _, _ in },
        afterReceiptWrite: @escaping @Sendable (URL, URL) throws -> Void = { _, _ in },
        beforeCommit: @escaping @Sendable (URL) throws -> Void = { _ in },
        afterUninstallStage: @escaping @Sendable (URL) throws -> Void = { _ in },
        beforeUninstallCommit: @escaping @Sendable (URL) throws -> Void = { _ in },
        skipCleanup: Bool = false
    ) {
        self.afterManagedWrite = afterManagedWrite
        self.afterReceiptWrite = afterReceiptWrite
        self.beforeCommit = beforeCommit
        self.afterUninstallStage = afterUninstallStage
        self.beforeUninstallCommit = beforeUninstallCommit
        self.skipCleanup = skipCleanup
    }

    static let live = LauncherSkillTransactionHooks()
}
