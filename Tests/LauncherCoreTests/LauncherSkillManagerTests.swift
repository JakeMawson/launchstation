import Foundation
import XCTest
import Darwin
@testable import LauncherCore

final class LauncherSkillManagerTests: XCTestCase {
    func testRepositorySkillMetadataAndVersionArePackageReady() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let skill = repositoryRoot.appendingPathComponent("Skills/launchstation", isDirectory: true)
        let markdown = try String(contentsOf: skill.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let metadata = try String(contentsOf: skill.appendingPathComponent("agents/openai.yaml"), encoding: .utf8)
        let version = try String(contentsOf: skill.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("\nname: launchstation\n"))
        XCTAssertTrue(markdown.contains("\ndescription: "))
        XCTAssertTrue(markdown.contains("\n---\n\n# Launch Station"))
        XCTAssertTrue(metadata.contains("interface:"))
        XCTAssertTrue(metadata.contains("display_name:"))
        XCTAssertTrue(metadata.contains("short_description:"))
        XCTAssertTrue(metadata.contains("default_prompt:"))
        XCTAssertEqual(version, LauncherSkillManager.version)
    }

    func testBundledSourceReadsAreNoFollowSingleLinkAndBounded() throws {
        let oversized = try makeFixture(codexDetected: false, claudeDetected: false)
        let oversizedSkill = oversized.source.appendingPathComponent("SKILL.md")
        let oversizedHandle = try FileHandle(forWritingTo: oversizedSkill)
        try oversizedHandle.truncate(atOffset: 5 * 1_024 * 1_024)
        try oversizedHandle.close()
        XCTAssertThrowsError(try oversized.manager.source())

        let hardLinked = try makeFixture(codexDetected: false, claudeDetected: false)
        let hardLinkedSkill = hardLinked.source.appendingPathComponent("SKILL.md")
        let siblingLink = hardLinked.source.appendingPathComponent("SKILL-hard-link.md")
        XCTAssertEqual(link(hardLinkedSkill.path, siblingLink.path), 0)
        XCTAssertThrowsError(try hardLinked.manager.source())

        let symbolic = try makeFixture(codexDetected: false, claudeDetected: false)
        let symbolicSkill = symbolic.source.appendingPathComponent("SKILL.md")
        try FileManager.default.removeItem(at: symbolicSkill)
        try FileManager.default.createSymbolicLink(
            at: symbolicSkill,
            withDestinationURL: symbolic.source.appendingPathComponent("VERSION")
        )
        XCTAssertThrowsError(try symbolic.manager.source())
    }

    func testCodexInstallIsExactIdempotentAndPreservesUnmanagedFiles() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        let otherSkill = fixture.home.appendingPathComponent(".agents/skills/other/SKILL.md")
        try FileManager.default.createDirectory(at: otherSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "other".write(to: otherSkill, atomically: true, encoding: .utf8)

        let initial = try fixture.manager.status()
        XCTAssertEqual(initial.hosts.first(where: { $0.host == .codex })?.state, .notInstalled)
        XCTAssertEqual(initial.hosts.first(where: { $0.host == .claudeCode })?.state, .notInstalled)

        let first = try fixture.manager.install(host: .codex)
        XCTAssertEqual(first.status.state, .current)
        XCTAssertEqual(first.installedFiles.count, 3)
        XCTAssertEqual(try String(contentsOf: otherSkill, encoding: .utf8), "other")

        let target = fixture.manager.installationDirectory(for: .codex)
        let unmanaged = target.appendingPathComponent("personal-note.txt")
        try "preserve me".write(to: unmanaged, atomically: true, encoding: .utf8)
        try "corrupted".write(to: target.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try fixture.manager.status().hosts.first(where: { $0.host == .codex })?.state,
            .outdated
        )

        let second = try fixture.manager.install(host: .codex)
        XCTAssertEqual(second.status.state, .current)
        XCTAssertEqual(try String(contentsOf: unmanaged, encoding: .utf8), "preserve me")
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("SKILL.md")),
            try Data(contentsOf: fixture.source.appendingPathComponent("SKILL.md"))
        )
    }

    func testUnavailableHostRefusesWithoutCreatingConfiguration() throws {
        let fixture = try makeFixture(codexDetected: false, claudeDetected: false)
        let target = fixture.manager.installationDirectory(for: .claudeCode)

        XCTAssertThrowsError(try fixture.manager.install(host: .claudeCode)) { error in
            guard case LauncherSkillError.hostUnavailable(.claudeCode, _) = error else {
                return XCTFail("Expected a Claude Code host-unavailable error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testPrecommitFailureNeverExposesPartialFreshOrUpdatedInstall() throws {
        let existing = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try existing.manager.install(host: .codex)
        let existingTarget = existing.manager.installationDirectory(for: .codex)
        let unmanaged = existingTarget.appendingPathComponent("personal-note.txt")
        try "preserve this exact file".write(to: unmanaged, atomically: true, encoding: .utf8)
        try "older managed copy".write(
            to: existingTarget.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let before = try snapshotTree(at: existingTarget)
        let failingExisting = manager(
            for: existing,
            transactionHooks: LauncherSkillTransactionHooks(beforeCommit: { _ in
                throw NSError(domain: "LauncherSkillManagerTests", code: 77)
            })
        )

        XCTAssertThrowsError(try failingExisting.install(host: .codex))
        XCTAssertEqual(try snapshotTree(at: existingTarget), before)
        XCTAssertEqual(
            try failingExisting.status().hosts.first(where: { $0.host == .codex })?.state,
            .outdated
        )
        XCTAssertFalse(try hasTransactionResidue(for: failingExisting, host: .codex))

        let fresh = try makeFixture(codexDetected: true, claudeDetected: false)
        let freshTarget = fresh.manager.installationDirectory(for: .codex)
        let failingFresh = manager(
            for: fresh,
            transactionHooks: LauncherSkillTransactionHooks(beforeCommit: { _ in
                throw NSError(domain: "LauncherSkillManagerTests", code: 78)
            })
        )

        XCTAssertThrowsError(try failingFresh.install(host: .codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshTarget.path))
        XCTAssertFalse(try hasTransactionResidue(for: failingFresh, host: .codex))

        for managedPath in ["SKILL.md", "agents/openai.yaml", "VERSION"] {
            let midWrite = try makeFixture(codexDetected: true, claudeDetected: false)
            let midWriteTarget = midWrite.manager.installationDirectory(for: .codex)
            let failingMidWrite = manager(
                for: midWrite,
                transactionHooks: LauncherSkillTransactionHooks(afterManagedWrite: { path, _ in
                    if path == managedPath {
                        throw NSError(domain: "LauncherSkillManagerTests", code: 79)
                    }
                })
            )

            XCTAssertThrowsError(try failingMidWrite.install(host: .codex))
            XCTAssertFalse(FileManager.default.fileExists(atPath: midWriteTarget.path))
            XCTAssertFalse(try hasTransactionResidue(for: failingMidWrite, host: .codex))
        }
    }

    func testConcurrentUnmanagedEditAbortsSwapAndPreservesTheNewEdit() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let target = fixture.manager.installationDirectory(for: .codex)
        let unmanaged = target.appendingPathComponent("personal-note.txt")
        try "before staging".write(to: unmanaged, atomically: true, encoding: .utf8)
        let racingManager = manager(
            for: fixture,
            transactionHooks: LauncherSkillTransactionHooks(beforeCommit: { _ in
                try "edited while staged".write(to: unmanaged, atomically: true, encoding: .utf8)
            })
        )

        XCTAssertThrowsError(try racingManager.install(host: .codex))
        XCTAssertEqual(try String(contentsOf: unmanaged, encoding: .utf8), "edited while staged")
        XCTAssertFalse(try hasTransactionResidue(for: racingManager, host: .codex))
    }

    func testCleanupResidueStaysOutsideScannedSkillsRoot() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let manager = manager(
            for: fixture,
            transactionHooks: LauncherSkillTransactionHooks(skipCleanup: true)
        )
        _ = try manager.install(host: .codex)

        let target = manager.installationDirectory(for: .codex)
        let skillsRoot = target.deletingLastPathComponent()
        let skillDocuments = try allFiles(named: "SKILL.md", under: skillsRoot)
        XCTAssertEqual(
            skillDocuments,
            [target.appendingPathComponent("SKILL.md").resolvingSymlinksInPath().path]
        )

        let residueDocuments = try allFiles(
            named: "SKILL.md",
            under: manager.transactionDirectory(for: .codex)
        )
        XCTAssertEqual(residueDocuments.count, 1)
        XCTAssertTrue(try manager.status().hosts.first(where: { $0.host == .codex })?.state == .current)
    }

    func testSymlinkedSkillDestinationIsBlockedWithoutWritingThroughIt() throws {
        let fixture = try makeFixture(codexDetected: false, claudeDetected: true)
        let target = fixture.manager.installationDirectory(for: .claudeCode)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)

        let status = try fixture.manager.status().hosts.first(where: { $0.host == .claudeCode })
        XCTAssertEqual(status?.state, .blocked)
        XCTAssertThrowsError(try fixture.manager.install(host: .claudeCode)) { error in
            guard case LauncherSkillError.unsafeDestination = error else {
                return XCTFail("Expected an unsafe-destination error, got \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testDanglingSymlinksAreBlockedAtEveryManagedPathLevel() throws {
        enum LinkLocation: CaseIterable {
            case hostRoot, skillsRoot, skillRoot, agentsDirectory, skillFile
        }

        for location in LinkLocation.allCases {
            let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
            let target = fixture.manager.installationDirectory(for: .codex)
            let link: URL
            switch location {
            case .hostRoot:
                link = fixture.home.appendingPathComponent(".agents")
            case .skillsRoot:
                link = fixture.home.appendingPathComponent(".agents/skills")
            case .skillRoot:
                link = target
            case .agentsDirectory:
                link = target.appendingPathComponent("agents")
            case .skillFile:
                link = target.appendingPathComponent("SKILL.md")
            }
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: fixture.root.appendingPathComponent("missing-\(UUID().uuidString)")
            )

            let state = try fixture.manager.status().hosts.first(where: { $0.host == .codex })?.state
            XCTAssertEqual(state, .blocked, "expected dangling \(location) symlink to block installation")
            XCTAssertThrowsError(try fixture.manager.install(host: .codex))
        }
    }

    func testUnmanagedSymlinkInsideExistingSkillIsBlockedAndUntouched() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let target = fixture.manager.installationDirectory(for: .codex)
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try "outside remains untouched".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("personal-link"),
            withDestinationURL: outside
        )

        let host = try fixture.manager.status().hosts.first(where: { $0.host == .codex })
        XCTAssertEqual(host?.state, .blocked)
        XCTAssertThrowsError(try fixture.manager.install(host: .codex))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside remains untouched")
    }

    func testExecutableHostCandidateCannotBeADirectory() throws {
        let fixture = try makeFixture(codexDetected: false, claudeDetected: false)
        try FileManager.default.createDirectory(at: fixture.codexCandidate, withIntermediateDirectories: true)

        let codex = try fixture.manager.status().hosts.first(where: { $0.host == .codex })
        XCTAssertEqual(codex?.state, .notInstalled)
        XCTAssertFalse(codex?.available ?? true)
    }

    func testDesktopOnlyClaudeDetectionUsesExactSignedBundleIdentity() throws {
        let fixture = try makeFixture(codexDetected: false, claudeDetected: false)
        let claudeApp = fixture.root.appendingPathComponent("detected/Claude.app", isDirectory: true)
        try makeSignedApplication(
            at: claudeApp,
            bundleIdentifier: "com.anthropic.claudefordesktop"
        )
        let manager = surfacedManager(
            for: fixture,
            codexDesktop: [],
            codexCLI: [],
            claudeDesktop: [claudeApp],
            claudeCLI: []
        )

        let claude = try XCTUnwrap(manager.status().hosts.first { $0.host == .claudeCode })
        XCTAssertTrue(try XCTUnwrap(claude.surfaceStatus(for: .desktop)).available)
        XCTAssertEqual(claude.surfaceStatus(for: .desktop)?.detectedPath, claudeApp.path)
        XCTAssertFalse(try XCTUnwrap(claude.surfaceStatus(for: .cli)).available)
        XCTAssertEqual(claude.state, .notInstalled)

        let first = try manager.install(host: .claudeCode)
        XCTAssertEqual(first.sharedInstallationPath, manager.installationDirectory(for: .claudeCode).path)
        XCTAssertTrue(first.restartRecommended, "creating ~/.claude/skills requires a Claude restart")
        XCTAssertTrue(first.message.contains("shared destination used by both Desktop and CLI"))

        let second = try manager.install(host: .claudeCode)
        XCTAssertFalse(second.restartRecommended, "Claude hot-reloads changes inside an existing skills root")
    }

    func testProductionDetectionRejectsAdHocDesktopAndNeverExecutesUnsignedCLISpoofs() throws {
        let fixture = try makeFixture(codexDetected: false, claudeDetected: false)
        let codexApp = fixture.root.appendingPathComponent("detected/Codex-lookalike.app", isDirectory: true)
        try makeSignedApplication(at: codexApp, bundleIdentifier: "com.openai.codex")
        let executionMarker = fixture.root.appendingPathComponent("unsigned-spoof-was-executed")
        let codexSpoof = fixture.root.appendingPathComponent("detected/codex")
        try "#!/bin/sh\n/usr/bin/touch \(ShellEscaping.quote(executionMarker.path))\necho 'codex-cli 99.0.0'\n"
            .write(to: codexSpoof, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexSpoof.path)
        let claudeSpoof = fixture.root.appendingPathComponent("detected/claude")
        try "#!/bin/sh\n/usr/bin/touch \(ShellEscaping.quote(executionMarker.path))\necho '99.0.0 (Claude Code)'\n"
            .write(to: claudeSpoof, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeSpoof.path)
        let manager = LauncherSkillManager(
            sourceDirectory: fixture.source,
            homeDirectory: fixture.home,
            codexDesktopDetectionCandidates: [codexApp],
            codexCLIDetectionCandidates: [codexSpoof],
            claudeDesktopDetectionCandidates: [],
            claudeCLIDetectionCandidates: [claudeSpoof],
            environmentPath: nil
        )

        let status = try manager.status()
        let codex = try XCTUnwrap(status.hosts.first { $0.host == .codex })
        let claude = try XCTUnwrap(status.hosts.first { $0.host == .claudeCode })
        XCTAssertFalse(try XCTUnwrap(codex.surfaceStatus(for: .desktop)).available)
        XCTAssertFalse(try XCTUnwrap(codex.surfaceStatus(for: .cli)).available)
        XCTAssertFalse(try XCTUnwrap(claude.surfaceStatus(for: .cli)).available)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: executionMarker.path),
            "unsigned product lookalikes must be rejected before any version probe executes them"
        )
    }

    func testCLIOnlyCodexDetectionIsReportedPerSurface() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        let manager = surfacedManager(
            for: fixture,
            codexDesktop: [],
            codexCLI: [fixture.codexCandidate],
            claudeDesktop: [],
            claudeCLI: []
        )

        let codex = try XCTUnwrap(manager.status().hosts.first { $0.host == .codex })
        XCTAssertFalse(try XCTUnwrap(codex.surfaceStatus(for: .desktop)).available)
        XCTAssertTrue(try XCTUnwrap(codex.surfaceStatus(for: .cli)).available)
        XCTAssertEqual(codex.surfaceStatus(for: .cli)?.detectedPath, fixture.codexCandidate.path)
        XCTAssertEqual(codex.state, .notInstalled)
    }

    func testDesktopAndCLIShareOneCodexInstallationState() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        let codexApp = fixture.root.appendingPathComponent("detected/Codex.app", isDirectory: true)
        try makeSignedApplication(at: codexApp, bundleIdentifier: "com.openai.codex")
        let manager = surfacedManager(
            for: fixture,
            codexDesktop: [codexApp],
            codexCLI: [fixture.codexCandidate],
            claudeDesktop: [],
            claudeCLI: []
        )

        let desktopInstall = try manager.install(host: .codex)
        XCTAssertEqual(desktopInstall.status.state, .current)
        XCTAssertFalse(desktopInstall.restartRecommended)
        XCTAssertTrue(desktopInstall.message.contains("auto-detects skill changes"))
        XCTAssertEqual(desktopInstall.sharedInstallationPath, manager.installationDirectory(for: .codex).path)

        let afterDesktop = try XCTUnwrap(manager.status().hosts.first { $0.host == .codex })
        XCTAssertEqual(afterDesktop.state, .current)
        XCTAssertTrue(try XCTUnwrap(afterDesktop.surfaceStatus(for: .desktop)).available)
        XCTAssertTrue(try XCTUnwrap(afterDesktop.surfaceStatus(for: .cli)).available)

        let cliInstall = try manager.install(host: .codex)
        XCTAssertEqual(cliInstall.status.state, .current)
        XCTAssertEqual(cliInstall.sharedInstallationPath, desktopInstall.sharedInstallationPath)
        XCTAssertEqual(cliInstall.installedFiles, desktopInstall.installedFiles)
    }

    func testAnyAuthenticatedSurfaceEnablesProductInstall() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        let manager = surfacedManager(
            for: fixture,
            codexDesktop: [],
            codexCLI: [fixture.codexCandidate],
            claudeDesktop: [],
            claudeCLI: []
        )
        let target = manager.installationDirectory(for: .codex)

        let result = try manager.install(host: .codex)
        XCTAssertEqual(result.status.state, .current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".agents").path))
    }

    func testInstalledByteAndVersionStateDoesNotDependOnSurfaceAvailability() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let unavailableManager = surfacedManager(
            for: fixture,
            codexDesktop: [],
            codexCLI: [],
            claudeDesktop: [],
            claudeCLI: []
        )

        let codex = try XCTUnwrap(unavailableManager.status().hosts.first { $0.host == .codex })
        XCTAssertFalse(codex.available)
        XCTAssertEqual(codex.state, .current)
        XCTAssertEqual(codex.installedVersion, LauncherSkillManager.version)

        let plan = unavailableManager.uninstallPlan(host: .codex)
        let binding = try XCTUnwrap(plan.binding)
        let result = try unavailableManager.uninstall(host: .codex, expected: binding)
        XCTAssertEqual(result.host, .codex)
        let target = unavailableManager.installationDirectory(for: .codex)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path))
        XCTAssertEqual(unavailableManager.inspectUninstall(host: .codex).state, .absent)
    }

    func testInstallWritesPrivateAllowlistedReceiptAndReinstallRotatesInstallationID() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let target = fixture.manager.installationDirectory(for: .codex)
        let receiptURL = target.appendingPathComponent(LauncherSkillManager.installReceiptFileName)
        let firstReceipt = try decodeReceipt(at: receiptURL)
        var attributes = stat()

        XCTAssertEqual(lstat(receiptURL.path, &attributes), 0)
        XCTAssertEqual(attributes.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(attributes.st_mode & 0o7777, 0o600)
        XCTAssertEqual(attributes.st_nlink, 1)
        XCTAssertEqual(firstReceipt.schemaVersion, 1)
        XCTAssertEqual(firstReceipt.managerID, "com.jakemawson.launchstation")
        XCTAssertEqual(firstReceipt.host, .codex)
        XCTAssertEqual(firstReceipt.destinationPath, target.path)
        XCTAssertEqual(firstReceipt.skillVersion, LauncherSkillManager.version)
        XCTAssertEqual(firstReceipt.files.map(\.relativePath), ["SKILL.md", "agents/openai.yaml", "VERSION"])
        XCTAssertTrue(firstReceipt.files.allSatisfy {
            $0.type == .regularFile && $0.posixMode == 0o644 && $0.linkCount == 1 && $0.sha256.count == 64
        })

        let firstPlan = fixture.manager.uninstallPlan(host: .codex)
        XCTAssertEqual(firstPlan.inspection.state, .receiptProven)
        XCTAssertEqual(firstPlan.binding?.installationID, firstReceipt.installationID)
        XCTAssertTrue(firstPlan.canUninstall)

        _ = try fixture.manager.install(host: .codex)
        let secondReceipt = try decodeReceipt(at: receiptURL)
        XCTAssertNotEqual(secondReceipt.installationID, firstReceipt.installationID)
        XCTAssertEqual(fixture.manager.uninstallPlan(host: .codex).binding?.installationID, secondReceipt.installationID)
    }

    func testUninstallInspectionRefusesOversizedPreservedTreeWithoutLoadingIt() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let oversized = fixture.manager.installationDirectory(for: .codex)
            .appendingPathComponent("oversized-preserved.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 300 * 1_024 * 1_024)
        try handle.close()

        let inspection = fixture.manager.inspectUninstall(host: .codex)
        XCTAssertEqual(inspection.state, .blocked)
        XCTAssertTrue(inspection.message.contains("bounded inspection byte limit"))
    }

    func testUninstallInspectionDistinguishesAbsentUnrecognizedModifiedAndBlocked() throws {
        let absent = try makeFixture(codexDetected: true, claudeDetected: false)
        XCTAssertEqual(absent.manager.inspectUninstall(host: .codex).state, .absent)

        let missingReceipt = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try missingReceipt.manager.install(host: .codex)
        let missingTarget = missingReceipt.manager.installationDirectory(for: .codex)
        try FileManager.default.removeItem(
            at: missingTarget.appendingPathComponent(LauncherSkillManager.installReceiptFileName)
        )
        XCTAssertEqual(missingReceipt.manager.inspectUninstall(host: .codex).state, .unrecognized)

        let modified = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try modified.manager.install(host: .codex)
        try "locally changed".write(
            to: modified.manager.installationDirectory(for: .codex).appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(modified.manager.inspectUninstall(host: .codex).state, .modified)

        let blocked = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try blocked.manager.install(host: .codex)
        let blockedTarget = blocked.manager.installationDirectory(for: .codex)
        let skillFile = blockedTarget.appendingPathComponent("SKILL.md")
        try FileManager.default.removeItem(at: skillFile)
        try FileManager.default.createSymbolicLink(
            at: skillFile,
            withDestinationURL: blocked.root.appendingPathComponent("outside")
        )
        XCTAssertEqual(blocked.manager.inspectUninstall(host: .codex).state, .blocked)
    }

    func testReceiptProvenUninstallPreservesUnmanagedContentAndLeavesDestinationDirectory() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let target = fixture.manager.installationDirectory(for: .codex)
        let personal = target.appendingPathComponent("personal-note.txt")
        try "keep exactly".write(to: personal, atomically: true, encoding: .utf8)
        let plan = fixture.manager.uninstallPlan(host: .codex)
        let binding = try XCTUnwrap(plan.binding)

        let result = try fixture.manager.uninstall(host: .codex, expected: binding)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try String(contentsOf: personal, encoding: .utf8), "keep exactly")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("VERSION").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("agents").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent(LauncherSkillManager.installReceiptFileName).path
        ))
        XCTAssertEqual(result.installationID, binding.installationID)
        XCTAssertTrue(result.preservedRelativePaths.contains("personal-note.txt"))
        XCTAssertEqual(fixture.manager.inspectUninstall(host: .codex).state, .absent)
    }

    func testUninstallPreservesUnmanagedAgentsContentAndPrunesOnlyEmptyManagedDirectory() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let target = fixture.manager.installationDirectory(for: .codex)
        let personalAgent = target.appendingPathComponent("agents/personal.yaml")
        try "personal: true".write(to: personalAgent, atomically: true, encoding: .utf8)
        let binding = try XCTUnwrap(fixture.manager.uninstallPlan(host: .codex).binding)

        _ = try fixture.manager.uninstall(host: .codex, expected: binding)

        XCTAssertEqual(try String(contentsOf: personalAgent, encoding: .utf8), "personal: true")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("agents/openai.yaml").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("agents", isDirectory: true).path
        ))
    }

    func testStaleReceiptProofAndConcurrentEditRefuseWithoutManagerMutation() throws {
        let tampered = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try tampered.manager.install(host: .codex)
        let tamperedTarget = tampered.manager.installationDirectory(for: .codex)
        let tamperedBinding = try XCTUnwrap(tampered.manager.uninstallPlan(host: .codex).binding)
        let tamperedReceipt = tamperedTarget.appendingPathComponent(LauncherSkillManager.installReceiptFileName)
        try Data("{}".utf8).write(to: tamperedReceipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tamperedReceipt.path)
        let tamperedSnapshot = try snapshotTree(at: tamperedTarget)

        XCTAssertEqual(tampered.manager.inspectUninstall(host: .codex).state, .unrecognized)
        XCTAssertThrowsError(try tampered.manager.uninstall(host: .codex, expected: tamperedBinding))
        XCTAssertEqual(try snapshotTree(at: tamperedTarget), tamperedSnapshot)

        let stale = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try stale.manager.install(host: .codex)
        let staleTarget = stale.manager.installationDirectory(for: .codex)
        let staleBinding = try XCTUnwrap(stale.manager.uninstallPlan(host: .codex).binding)
        try "changed after intent".write(
            to: staleTarget.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let staleSnapshot = try snapshotTree(at: staleTarget)

        XCTAssertThrowsError(try stale.manager.uninstall(host: .codex, expected: staleBinding))
        XCTAssertEqual(try snapshotTree(at: staleTarget), staleSnapshot)

        let concurrent = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try concurrent.manager.install(host: .codex)
        let concurrentTarget = concurrent.manager.installationDirectory(for: .codex)
        let personal = concurrentTarget.appendingPathComponent("personal.txt")
        try "before".write(to: personal, atomically: true, encoding: .utf8)
        let racingManager = manager(
            for: concurrent,
            transactionHooks: LauncherSkillTransactionHooks(beforeUninstallCommit: { _ in
                try "concurrent edit".write(to: personal, atomically: true, encoding: .utf8)
            })
        )
        let concurrentBinding = try XCTUnwrap(racingManager.uninstallPlan(host: .codex).binding)

        XCTAssertThrowsError(try racingManager.uninstall(host: .codex, expected: concurrentBinding))
        XCTAssertEqual(try String(contentsOf: personal, encoding: .utf8), "concurrent edit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: concurrentTarget.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: concurrentTarget.appendingPathComponent(LauncherSkillManager.installReceiptFileName).path
        ))
    }

    func testTargetReplacementBeforeUninstallCommitIsNeverOverwritten() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: false)
        _ = try fixture.manager.install(host: .codex)
        let target = fixture.manager.installationDirectory(for: .codex)
        let displaced = fixture.root.appendingPathComponent("displaced-original", isDirectory: true)
        let replacementMarker = target.appendingPathComponent("replacement-marker.txt")
        let replacingManager = manager(
            for: fixture,
            transactionHooks: LauncherSkillTransactionHooks(beforeUninstallCommit: { _ in
                try FileManager.default.moveItem(at: target, to: displaced)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try "replacement remains live".write(
                    to: replacementMarker,
                    atomically: true,
                    encoding: .utf8
                )
            })
        )
        let binding = try XCTUnwrap(replacingManager.uninstallPlan(host: .codex).binding)

        XCTAssertThrowsError(try replacingManager.uninstall(host: .codex, expected: binding))
        XCTAssertEqual(try String(contentsOf: replacementMarker, encoding: .utf8), "replacement remains live")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: displaced.appendingPathComponent(LauncherSkillManager.installReceiptFileName).path
        ))
    }

    func testExportSourceIsCanonicalStandaloneMarkdown() throws {
        let fixture = try makeFixture(codexDetected: true, claudeDetected: true)
        let source = try fixture.manager.source()

        XCTAssertEqual(source.fileName, "SKILL.md")
        XCTAssertEqual(source.skillName, "launchstation")
        XCTAssertEqual(source.version, LauncherSkillManager.version)
        XCTAssertEqual(
            source.contents,
            try String(contentsOf: fixture.source.appendingPathComponent("SKILL.md"), encoding: .utf8)
        )
    }

    private func makeFixture(codexDetected: Bool, claudeDetected: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchStation-SkillTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let detection = root.appendingPathComponent("detected", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: detection, withIntermediateDirectories: true)
        try "---\nname: launchstation\ndescription: Test fixture.\n---\n\n# Fixture\n"
            .write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "interface:\n  display_name: \"Launch Station\"\n"
            .write(to: source.appendingPathComponent("agents/openai.yaml"), atomically: true, encoding: .utf8)
        try "\(LauncherSkillManager.version)\n"
            .write(to: source.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        let codex = detection.appendingPathComponent("codex")
        let claude = detection.appendingPathComponent("claude")
        if codexDetected {
            try "executable".write(to: codex, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        }
        if claudeDetected {
            try "executable".write(to: claude, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        }

        return Fixture(
            root: root,
            source: source,
            home: home,
            codexCandidate: codex,
            claudeCandidate: claude,
            manager: LauncherSkillManager(
                sourceDirectory: source,
                homeDirectory: home,
                codexDetectionCandidates: [codex],
                claudeCodeDetectionCandidates: [claude],
                environmentPath: nil,
                candidateAuthenticator: { _, _, _ in true },
                transactionHooks: .live
            )
        )
    }

    private func decodeReceipt(at url: URL) throws -> LauncherSkillInstallReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LauncherSkillInstallReceipt.self, from: Data(contentsOf: url))
    }

    private func manager(
        for fixture: Fixture,
        transactionHooks: LauncherSkillTransactionHooks
    ) -> LauncherSkillManager {
        LauncherSkillManager(
            sourceDirectory: fixture.source,
            homeDirectory: fixture.home,
            codexDetectionCandidates: [fixture.codexCandidate],
            claudeCodeDetectionCandidates: [fixture.claudeCandidate],
            environmentPath: nil,
            candidateAuthenticator: { _, _, _ in true },
            transactionHooks: transactionHooks
        )
    }

    private func surfacedManager(
        for fixture: Fixture,
        codexDesktop: [URL],
        codexCLI: [URL],
        claudeDesktop: [URL],
        claudeCLI: [URL]
    ) -> LauncherSkillManager {
        LauncherSkillManager(
            sourceDirectory: fixture.source,
            homeDirectory: fixture.home,
            codexDetectionCandidates: nil,
            claudeCodeDetectionCandidates: nil,
            codexDesktopDetectionCandidates: codexDesktop,
            codexCLIDetectionCandidates: codexCLI,
            claudeDesktopDetectionCandidates: claudeDesktop,
            claudeCLIDetectionCandidates: claudeCLI,
            environmentPath: nil,
            candidateAuthenticator: { _, _, _ in true },
            transactionHooks: .live
        )
    }

    private func makeSignedApplication(
        at application: URL,
        bundleIdentifier: String
    ) throws {
        let executableName = "FixtureHost"
        let executable = application.appendingPathComponent("Contents/MacOS/\(executableName)")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": application.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: application.appendingPathComponent("Contents/Info.plist"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", application.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "LauncherSkillManagerTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not ad-hoc sign fixture application"]
            )
        }
    }

    private func snapshotTree(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var snapshot: [String: Data] = [:]
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            snapshot[relative] = try Data(contentsOf: url)
        }
        return snapshot
    }

    private func hasTransactionResidue(
        for manager: LauncherSkillManager,
        host: LauncherSkillHost
    ) throws -> Bool {
        let directory = manager.transactionDirectory(for: host)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
    }

    private func allFiles(named name: String, under root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == name { paths.append(url.resolvingSymlinksInPath().path) }
        }
        return paths.sorted()
    }
}

private struct Fixture {
    var root: URL
    var source: URL
    var home: URL
    var codexCandidate: URL
    var claudeCandidate: URL
    var manager: LauncherSkillManager
}
