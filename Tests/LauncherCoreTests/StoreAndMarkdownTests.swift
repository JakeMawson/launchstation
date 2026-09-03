import Foundation
import SQLite3
import XCTest
@testable import LauncherCore

final class StoreAndMarkdownTests: XCTestCase {
    func testServiceCompatibilityRequiresCurrentSchemaAndMinimumFeatureVersion() {
        func status(version: String, schema: Int = LauncherSchema.version) -> ServiceStatus {
            ServiceStatus(
                version: version,
                schemaVersion: schema,
                pid: 1,
                startedAt: Date(timeIntervalSince1970: 0),
                endpoint: "http://127.0.0.1:1"
            )
        }

        XCTAssertNil(LauncherCompatibility.incompatibilityReason(for: status(version: "1.2.0")))
        XCTAssertNil(LauncherCompatibility.incompatibilityReason(for: status(version: "1.4.2")))
        XCTAssertNotNil(LauncherCompatibility.incompatibilityReason(for: status(version: "1.1.0")))
        XCTAssertNotNil(LauncherCompatibility.incompatibilityReason(for: status(version: "not-a-version")))
        XCTAssertNotNil(LauncherCompatibility.incompatibilityReason(
            for: status(version: "1.2.0", schema: LauncherSchema.version + 1)
        ))
    }

    func testSQLiteConfigurationAndCanonicalProjectUniqueness() throws {
        let fixture = try makeFixture()
        let configuration = try fixture.store.configuration()
        XCTAssertEqual(configuration.journalMode, "wal")
        XCTAssertTrue(configuration.foreignKeysEnabled)

        let project = try fixture.store.createProject(
            ProjectRecord(displayName: "Example", directory: fixture.projectDirectory.path)
        )
        XCTAssertEqual(project.directory, fixture.projectDirectory.resolvingSymlinksInPath().path)
        XCTAssertEqual(project.revision, 1)
        XCTAssertEqual(project.manifestSyncState, .pending)

        let alias = fixture.root.appendingPathComponent("project-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.projectDirectory)
        XCTAssertThrowsError(
            try fixture.store.createProject(ProjectRecord(displayName: "Alias", directory: alias.path))
        ) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .duplicateProjectDirectory(project.directory))
        }
        XCTAssertEqual(try fixture.store.listProjects().count, 1)

        let reopened = try SQLiteStore(databaseURL: fixture.store.databaseURL)
        XCTAssertEqual(try reopened.project(id: project.id)?.directory, project.directory)
        XCTAssertEqual(try reopened.configuration(), configuration)
    }

    func testGlobalNormalizedNameUniquenessTransactionsAndStaleUpdates() throws {
        let fixture = try makeFixture()
        let secondDirectory = fixture.root.appendingPathComponent("second-project", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstProject = try fixture.store.createProject(
            ProjectRecord(displayName: "First", directory: fixture.projectDirectory.path)
        )
        let secondProject = try fixture.store.createProject(
            ProjectRecord(displayName: "Second", directory: secondDirectory.path)
        )

        let launcher = try fixture.store.createLauncher(makeLauncher(projectID: firstProject.id, name: "Fóo   Web"))
        XCTAssertEqual(launcher.normalizedName, LauncherValidation.normalizeName("foo web"))
        XCTAssertEqual(try fixture.store.project(id: firstProject.id)?.revision, 2)

        XCTAssertThrowsError(
            try fixture.store.createLauncher(makeLauncher(projectID: secondProject.id, name: "ＦＯＯ web"))
        ) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .duplicateLauncherName("FOO web"))
        }
        XCTAssertEqual(try fixture.store.project(id: secondProject.id)?.revision, 1, "failed create must roll back project mutation")

        var changed = launcher
        changed.description = "Updated description"
        let updated = try fixture.store.updateLauncher(changed, expectedRevision: launcher.revision)
        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(updated.description, "Updated description")

        var stale = launcher
        stale.description = "Stale overwrite"
        XCTAssertThrowsError(try fixture.store.updateLauncher(stale, expectedRevision: 1)) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .staleRevision(entity: "launcher", expected: 1, actual: 2))
        }
        XCTAssertEqual(try fixture.store.launcher(id: launcher.id)?.description, "Updated description")
    }

    func testSessionRevisionCRUDAndActiveDeletionGuard() throws {
        let fixture = try makeFixture()
        let project = try fixture.store.createProject(
            ProjectRecord(displayName: "Sessions", directory: fixture.projectDirectory.path)
        )
        let launcher = try fixture.store.createLauncher(makeLauncher(projectID: project.id, name: "session-app"))
        let session = SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision
        )
        let created = try fixture.store.createSession(session)
        XCTAssertEqual(created.storeRevision, 1)
        XCTAssertEqual(created.record.state, .starting)

        var running = created.record
        running.state = .running
        let updated = try fixture.store.updateSession(running, expectedRevision: 1)
        XCTAssertEqual(updated.storeRevision, 2)
        XCTAssertThrowsError(try fixture.store.updateSession(running, expectedRevision: 1)) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .staleRevision(entity: "session", expected: 1, actual: 2))
        }
        XCTAssertThrowsError(try fixture.store.deleteLauncher(id: launcher.id, expectedRevision: launcher.revision)) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .launcherHasActiveSessions(launcher.id))
        }

        var exited = updated.record
        exited.state = .exited
        exited.endedAt = Date()
        let finished = try fixture.store.updateSession(exited, expectedRevision: updated.storeRevision)
        try fixture.store.deleteLauncher(id: launcher.id, expectedRevision: launcher.revision)
        XCTAssertNotNil(try fixture.store.session(id: session.id), "soft-deleted launchers retain historical sessions")
        try fixture.store.deleteSession(id: session.id, expectedRevision: finished.storeRevision)
        XCTAssertNil(try fixture.store.session(id: session.id))
    }

    func testSessionAndLauncherDetailDecodeLegacyJSONAsPrimary() throws {
        let launcherID = UUID()
        let legacySession = SessionRecord(
            launcherID: launcherID,
            launcherName: "Legacy",
            launcherRevision: 3,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        var sessionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LauncherJSON.encoder().encode(legacySession)) as? [String: Any]
        )
        sessionObject.removeValue(forKey: "launchRole")
        sessionObject.removeValue(forKey: "projectSnapshot")
        sessionObject.removeValue(forKey: "runtimeArguments")
        let legacySessionData = try JSONSerialization.data(withJSONObject: sessionObject)
        let decodedSession = try LauncherJSON.decoder().decode(SessionRecord.self, from: legacySessionData)
        XCTAssertEqual(decodedSession.launchRole, .primary)
        XCTAssertEqual(decodedSession.runtimeArguments, [])
        XCTAssertNil(decodedSession.projectSnapshot)

        let project = ProjectRecord(displayName: "Legacy", directory: "/tmp/legacy")
        let launcher = makeLauncher(id: launcherID, projectID: project.id, name: "Legacy")
        let detail = LauncherDetail(
            project: project,
            launcher: launcher,
            activeSession: decodedSession,
            lastSession: decodedSession
        )
        var detailObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LauncherJSON.encoder().encode(detail)) as? [String: Any]
        )
        detailObject.removeValue(forKey: "activeSessions")
        let legacyDetailData = try JSONSerialization.data(withJSONObject: detailObject)
        let decodedDetail = try LauncherJSON.decoder().decode(LauncherDetail.self, from: legacyDetailData)
        XCTAssertEqual(decodedDetail.activeSessions.map(\.id), [decodedSession.id])
        XCTAssertEqual(decodedDetail.primaryActiveSession?.id, decodedSession.id)
    }

    func testStoreEnforcesOnePrimaryButAllowsAdditionalActiveSessions() throws {
        let fixture = try makeFixture()
        let project = try fixture.store.createProject(
            ProjectRecord(displayName: "Instances", directory: fixture.projectDirectory.path)
        )
        let launcher = try fixture.store.createLauncher(makeLauncher(projectID: project.id, name: "Instances"))
        let primary = try fixture.store.createSession(SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            launchRole: .primary
        )).record

        XCTAssertThrowsError(try fixture.store.createSession(SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            launchRole: .primary
        ))) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .primarySessionAlreadyActive(launcher.id))
        }

        let firstAdditional = try fixture.store.createSession(SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            launchRole: .additional
        )).record
        let secondAdditional = try fixture.store.createSession(SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            launchRole: .additional
        )).record

        let detail = try XCTUnwrap(fixture.store.launcherDetail(id: launcher.id))
        XCTAssertEqual(detail.primaryActiveSession?.id, primary.id)
        XCTAssertEqual(Set(detail.activeSessions.map(\.id)), Set([primary.id, firstAdditional.id, secondAdditional.id]))
        XCTAssertEqual(detail.activeSession?.id, primary.id, "legacy projection remains the primary")
    }

    func testSessionHistoryIsCursorBoundedAndRoleFilterable() throws {
        let fixture = try makeFixture()
        let project = try fixture.store.createProject(
            ProjectRecord(displayName: "Session ledger", directory: fixture.projectDirectory.path)
        )
        let launcher = try fixture.store.createLauncher(
            makeLauncher(projectID: project.id, name: "Session ledger fixture")
        )
        var created: [SessionRecord] = []
        for index in 0..<5 {
            created.append(try fixture.store.createSession(SessionRecord(
                launcherID: launcher.id,
                launcherName: launcher.name,
                launcherRevision: launcher.revision,
                launchRole: index.isMultiple(of: 2) ? .primary : .additional,
                state: .exited,
                startedAt: Date(timeIntervalSince1970: TimeInterval(100 + index)),
                endedAt: Date(timeIntervalSince1970: TimeInterval(101 + index))
            )).record)
        }

        let first = try fixture.store.sessionHistory(launcherID: launcher.id, limit: 2)
        XCTAssertEqual(first.sessions.map(\.id), [created[4].id, created[3].id])
        XCTAssertEqual(first.sessions.first?.projectSnapshot?.directory, project.directory)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try fixture.store.sessionHistory(launcherID: launcher.id, limit: 2, cursor: cursor)
        XCTAssertEqual(second.sessions.map(\.id), [created[2].id, created[1].id])
        XCTAssertNotNil(second.nextCursor)
        let primaryOnly = try fixture.store.sessionHistory(
            launcherID: launcher.id,
            role: .primary,
            limit: 10
        )
        XCTAssertEqual(primaryOnly.sessions.map(\.id), [created[4].id, created[2].id, created[0].id])
    }

    func testSchemaOneMigrationDefaultsLegacySessionsToPrimaryAndAddsUniqueness() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-MigrationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let databaseURL = stateDirectory.appendingPathComponent("launcher.sqlite3")
        let project = ProjectRecord(displayName: "Migration", directory: projectDirectory.path)
        let launcher = makeLauncher(projectID: project.id, name: "Migration")
        let legacy = SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            state: .running,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try createLegacyV1Database(at: databaseURL, project: project, launcher: launcher, sessions: [legacy])

        let migrated = try SQLiteStore(databaseURL: databaseURL)
        XCTAssertEqual(try migrated.session(id: legacy.id)?.record.launchRole, .primary)
        XCTAssertThrowsError(try migrated.createSession(SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            launchRole: .primary
        ))) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .primarySessionAlreadyActive(launcher.id))
        }
    }

    func testSchemaOneMigrationRefusesAmbiguousMultipleActiveSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-MigrationPreflightTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let databaseURL = stateDirectory.appendingPathComponent("launcher.sqlite3")
        let project = ProjectRecord(displayName: "Ambiguous", directory: projectDirectory.path)
        let launcher = makeLauncher(projectID: project.id, name: "Ambiguous")
        let sessions = [100.0, 101.0].map { startedAt in
            SessionRecord(
                launcherID: launcher.id,
                launcherName: launcher.name,
                launcherRevision: launcher.revision,
                state: .running,
                startedAt: Date(timeIntervalSince1970: startedAt)
            )
        }
        try createLegacyV1Database(at: databaseURL, project: project, launcher: launcher, sessions: sessions)

        XCTAssertThrowsError(try SQLiteStore(databaseURL: databaseURL)) { error in
            guard let storeError = error as? SQLiteStoreError,
                  case .invalidStoredData(let message) = storeError else {
                return XCTFail("Expected invalid stored data, got \(error)")
            }
            XCTAssertTrue(message.contains("multiple active legacy sessions"))
        }
    }

    func testMarkdownIsDeterministicSortedAndOmitsEnvironmentValues() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Markdown",
            directory: fixture.projectDirectory.path,
            revision: 8,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let zeta = makeLauncher(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!,
            projectID: project.id,
            name: "zeta",
            secret: "zeta-super-secret"
        )
        let alpha = makeLauncher(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!,
            projectID: project.id,
            name: "Alpha",
            secret: "alpha-super-secret"
        )

        let renderer = MarkdownRenderer()
        let first = renderer.render(project: project, launchers: [zeta, alpha])
        let second = renderer.render(project: project, launchers: [alpha, zeta])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.bodySHA256.count, 64)
        XCTAssertEqual(first.fileSHA256.count, 64)
        XCTAssertTrue(first.content.contains("content-sha256: sha256:\(first.bodySHA256)"))
        XCTAssertFalse(first.content.contains("alpha-super-secret"))
        XCTAssertFalse(first.content.contains("zeta-super-secret"))
        XCTAssertTrue(first.content.contains("Environment keys (values omitted): `API_TOKEN`, `VISIBLE_NAME`"))

        let alphaRange = try XCTUnwrap(first.content.range(of: "## `Alpha`"))
        let zetaRange = try XCTUnwrap(first.content.range(of: "## `zeta`"))
        XCTAssertLessThan(alphaRange.lowerBound, zetaRange.lowerBound)
    }

    func testAtomicReadOnlyWriteDriftDetectionAndRepair() throws {
        let fixture = try makeFixture()
        let project = try fixture.store.createProject(
            ProjectRecord(displayName: "Manifest", directory: fixture.projectDirectory.path)
        )
        _ = try fixture.store.createLauncher(makeLauncher(projectID: project.id, name: "manifest-app"))

        let repaired = try fixture.store.repairManifest(projectID: project.id)
        XCTAssertTrue(repaired.inSync)
        XCTAssertTrue(repaired.repaired)
        let manifestURL = fixture.projectDirectory.appendingPathComponent(MarkdownRenderer.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o444)
        XCTAssertEqual(try fixture.store.project(id: project.id)?.manifestSyncState, .synced)

        let initiallyCurrent = try fixture.store.checkManifest(projectID: project.id)
        XCTAssertTrue(initiallyCurrent.inSync)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
        let permissionDrift = try fixture.store.checkManifest(projectID: project.id)
        XCTAssertFalse(permissionDrift.inSync)
        XCTAssertTrue(permissionDrift.message.contains("read-only"))
        XCTAssertEqual(try fixture.store.project(id: project.id)?.manifestSyncState, .drifted)

        _ = try fixture.store.repairManifest(projectID: project.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
        try Data("tampered\n".utf8).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: manifestURL.path)
        let contentDrift = try fixture.store.checkManifest(projectID: project.id)
        XCTAssertFalse(contentDrift.inSync)
        XCTAssertTrue(contentDrift.message.contains("content differs"))

        let finalRepair = try fixture.store.repairManifest(projectID: project.id)
        XCTAssertEqual(finalRepair.actualHash, finalRepair.expectedHash)
        XCTAssertTrue(try fixture.store.checkManifest(projectID: project.id).inSync)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        XCTAssertEqual((finalAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o444)
    }

    func testCompoundActionOrderMustBeUnique() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Order", directory: fixture.projectDirectory.path)
        let first = LaunchAction(
            name: "first",
            normalizedName: "first",
            description: "First",
            order: 2,
            runner: .process,
            executable: "/usr/bin/true"
        )
        let second = LaunchAction(
            name: "second",
            normalizedName: "second",
            description: "Second",
            order: 2,
            runner: .process,
            executable: "/usr/bin/true"
        )
        let launcher = LauncherRecord(
            projectID: project.id,
            name: "duplicate-order",
            normalizedName: "duplicate-order",
            description: "Invalid compound order",
            actions: [first, second],
            primaryActionID: first.id
        )

        XCTAssertThrowsError(try LauncherValidation.validateLauncher(launcher, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("action order values must be unique")
            )
        }
    }

    func testCompoundLinkedEnvironmentTokensMustBeUnique() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Linked", directory: fixture.projectDirectory.path)
        let first = LaunchAction(name: "api-v2", order: 0, runner: .process, executable: "/usr/bin/true")
        let second = LaunchAction(name: "api v2", order: 1, runner: .process, executable: "/usr/bin/true")
        let launcher = LauncherRecord(
            projectID: project.id,
            name: "linked-collision",
            normalizedName: "linked-collision",
            description: "Collision fixture",
            actions: [first, second],
            primaryActionID: first.id
        )

        XCTAssertThrowsError(try LauncherValidation.validateLauncher(launcher, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("action names must map to unique linked environment tokens; CODEX_LAUNCHER_ACTION_API_V2 collides")
            )
        }
    }

    func testLinkedActionReferencesRequireAnEarlierMatchingProvider() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Linked", directory: fixture.projectDirectory.path)
        var provider = LaunchAction(
            name: "api",
            description: "API provider",
            order: 0,
            runner: .process,
            executable: "/usr/bin/true",
            port: PortConfiguration(
                mode: .automatic,
                logicalName: "api",
                URLTemplate: "http://${HOST}:${PORT}/"
            )
        )
        var consumer = LaunchAction(
            name: "frontend",
            description: "Frontend consumer",
            order: 1,
            runner: .process,
            executable: "/usr/bin/true",
            environment: ["API_URL": "${CODEX_LAUNCHER_ACTION_API_URL}"]
        )
        var launcher = LauncherRecord(
            projectID: project.id,
            name: "linked-valid",
            normalizedName: "linked-valid",
            description: "Linked fixture",
            actions: [consumer, provider],
            primaryActionID: consumer.id
        )

        XCTAssertNoThrow(try LauncherValidation.validateLauncher(launcher, project: project))

        provider.order = 2
        launcher.actions = [consumer, provider]
        XCTAssertThrowsError(try LauncherValidation.validateLauncher(launcher, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("CODEX_LAUNCHER_ACTION_API_URL must name a HOST, PORT, or URL value exposed by an earlier action")
            )
        }

        provider.order = 0
        consumer.environment = ["API_URL": "${CODEX_LAUNCHER_ACTION_AP1_URL}"]
        launcher.actions = [provider, consumer]
        XCTAssertThrowsError(try LauncherValidation.validateLauncher(launcher, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("CODEX_LAUNCHER_ACTION_AP1_URL must name a HOST, PORT, or URL value exposed by an earlier action")
            )
        }

        provider.required = false
        consumer.environment = ["API_URL": "${CODEX_LAUNCHER_ACTION_API_URL}"]
        launcher.actions = [provider, consumer]
        XCTAssertThrowsError(try LauncherValidation.validateLauncher(launcher, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("CODEX_LAUNCHER_ACTION_API_URL references optional action api; linked providers must be required")
            )
        }
    }

    func testTerminalURLActionCannotProvideALinkedRuntimeURL() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "URL provider", directory: fixture.projectDirectory.path)
        let provider = LaunchAction(
            name: "guide",
            description: "One-shot guide",
            order: 0,
            runner: .url,
            executable: "https://example.test/guide",
            allowsRuntimeArguments: false
        )
        let consumer = LaunchAction(
            name: "consumer",
            description: "Consumer",
            order: 1,
            runner: .process,
            executable: "/usr/bin/true",
            environment: ["GUIDE_URL": "${CODEX_LAUNCHER_ACTION_GUIDE_URL}"]
        )
        let launcher = LauncherRecord(
            projectID: project.id,
            name: "url-provider",
            normalizedName: "url-provider",
            description: "URL provider fixture",
            actions: [provider, consumer],
            primaryActionID: consumer.id
        )

        XCTAssertThrowsError(try LauncherValidation.validateLauncher(launcher, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("CODEX_LAUNCHER_ACTION_GUIDE_URL must name a HOST, PORT, or URL value exposed by an earlier action")
            )
        }
    }

    func testLifecycleEnvironmentNamesAreReserved() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Environment", directory: fixture.projectDirectory.path)
        var action = LaunchAction(
            runner: .process,
            executable: "/usr/bin/true",
            environment: ["CODEX_PORT": "9999"]
        )

        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("CODEX_PORT is reserved for launcher lifecycle management")
            )
        }

        action.environment = ["INVALID-NAME": "value"]
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("invalid environment variable name: INVALID-NAME")
            )
        }

        action.environment = ["CODEX_LAUNCHER_ACTION_API_URL": "spoofed"]
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("CODEX_LAUNCHER_ACTION_API_URL is reserved for values from earlier compound actions")
            )
        }

        action.environment = [:]
        action.name = "API service"
        XCTAssertEqual(
            LauncherValidation.linkedActionEnvironmentBase(for: action),
            "CODEX_LAUNCHER_ACTION_API_SERVICE"
        )
    }

    func testManagedPortAliasesCannotCollideOrBeShadowed() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Aliases", directory: fixture.projectDirectory.path)
        var action = LaunchAction(
            runner: .process,
            executable: "/usr/bin/true",
            port: PortConfiguration(
                mode: .automatic,
                environmentVariable: "PORT",
                hostEnvironmentVariable: "HOST"
            )
        )

        action.environment = ["PORT": "9999"]
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("managed port alias PORT cannot also be configured in the action environment")
            )
        }

        action.environment = [:]
        action.inheritedEnvironment = ["HOST"]
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("managed port alias HOST cannot also be inherited from the daemon environment")
            )
        }

        action.inheritedEnvironment = []
        action.port.hostEnvironmentVariable = "PORT"
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidPort("port and host environment aliases must be distinct")
            )
        }
    }

    func testOpenTargetsRequireCompatibleRunnerAndResolvableBrowserEndpoint() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Endpoints", directory: fixture.projectDirectory.path)
        var action = LaunchAction(
            runner: .process,
            executable: "/usr/bin/true",
            openTarget: .application
        )
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("the application open target requires an app runner")
            )
        }

        action.openTarget = .browser
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("browser open requires a resolvable HTTP or HTTPS endpoint")
            )
        }

        action.port = PortConfiguration(
            mode: .none,
            URLTemplate: "http://${HOST}/ready"
        )
        XCTAssertNoThrow(try LauncherValidation.validateAction(action, project: project))
        XCTAssertEqual(
            LauncherValidation.renderedStaticEndpoint(for: action),
            "http://127.0.0.1/ready"
        )

        action.port = PortConfiguration(mode: .automatic)
        XCTAssertNoThrow(try LauncherValidation.validateAction(action, project: project))
        XCTAssertNil(LauncherValidation.renderedStaticEndpoint(for: action))
    }

    func testDotPathSegmentsAndCLICommandsAreReservedLauncherNames() {
        for name in [".", "..", "history", "maintenance", "external", "open"] {
            XCTAssertThrowsError(try LauncherValidation.validatedName(name)) { error in
                XCTAssertEqual(error as? LauncherValidationError, .reservedName(name))
            }
        }
    }

    func testURLActionsDoNotAdvertiseUnsupportedRuntimeArguments() {
        let action = LaunchAction(
            runner: .url,
            executable: "https://example.invalid"
        )
        XCTAssertFalse(action.allowsRuntimeArguments)
    }

    func testDisplayCommandsIncludeStoredShellAndAppArguments() {
        let shell = LaunchAction(
            runner: .shell,
            arguments: ["--mode", "two words"],
            shellCommand: "npm run dev"
        )
        XCTAssertEqual(shell.displayCommand, "npm run dev --mode 'two words'")

        let app = LaunchAction(
            runner: .app,
            executable: "/Applications/Example App.app",
            arguments: ["--document", "Two Words.txt"]
        )
        XCTAssertEqual(
            app.displayCommand,
            "open -n '/Applications/Example App.app' --args --document 'Two Words.txt'"
        )

        let bundleApp = LaunchAction(
            runner: .app,
            executable: "com.example.Editor",
            arguments: ["--safe-mode"],
            appBundleIdentifier: "com.example.Editor"
        )
        XCTAssertEqual(bundleApp.displayCommand, "open -n -b com.example.Editor --args --safe-mode")
    }

    func testManifestWriteDoesNotCreateAMissingProjectDirectory() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-MissingProject", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = ProjectRecord(displayName: "Missing", directory: missingDirectory.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
        XCTAssertThrowsError(try MarkdownRenderer().write(project: project, launchers: [])) { error in
            XCTAssertEqual(error as? LauncherValidationError, .invalidDirectory(missingDirectory.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
    }

    func testActionValidationRejectsBrokenRegistrationMetadata() throws {
        let fixture = try makeFixture()
        let project = ProjectRecord(displayName: "Validation", directory: fixture.projectDirectory.path)
        var action = LaunchAction(
            description: "Valid action",
            runner: .process,
            executable: "/usr/bin/true"
        )

        action.description = "   "
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project))

        action.description = "Valid action"
        action.workingDirectory = "missing-subdirectory"
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project))

        action.workingDirectory = "."
        action.port = PortConfiguration(mode: .automatic, logicalName: "main", lease: "eventually")
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidPort("lease must look like 90s, 15m, 2h, 1d, or positive seconds")
            )
        }

        action.port.lease = "2h"
        action.healthCheckURL = "file:///tmp/not-http"
        XCTAssertThrowsError(try LauncherValidation.validateAction(action, project: project)) { error in
            XCTAssertEqual(
                error as? LauncherValidationError,
                .invalidAction("health check must use http or https")
            )
        }
    }

    private struct Fixture {
        var root: URL
        var projectDirectory: URL
        var store: SQLiteStore
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-StoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let store = try SQLiteStore(databaseURL: stateDirectory.appendingPathComponent("launcher.sqlite3"))
        return Fixture(root: root, projectDirectory: projectDirectory, store: store)
    }

    private func createLegacyV1Database(
        at url: URL,
        project: ProjectRecord,
        launcher: LauncherRecord,
        sessions: [SessionRecord]
    ) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }

        let projectData = try LauncherJSON.encoder().encode(project)
        let launcherData = try LauncherJSON.encoder().encode(launcher)
        let sessionInserts = try sessions.map { session -> String in
            var legacySessionObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: LauncherJSON.encoder().encode(session)) as? [String: Any]
            )
            legacySessionObject.removeValue(forKey: "launchRole")
            legacySessionObject.removeValue(forKey: "projectSnapshot")
            legacySessionObject.removeValue(forKey: "runtimeArguments")
            let legacySessionData = try JSONSerialization.data(withJSONObject: legacySessionObject)
            return """
            INSERT INTO sessions VALUES (
                '\(session.id.uuidString)', '\(launcher.id.uuidString)', 1, '\(session.state.rawValue)',
                \(session.startedAt.timeIntervalSince1970), \(session.startedAt.timeIntervalSince1970),
                X'\(hex(legacySessionData))'
            );
            """
        }.joined(separator: "\n")
        let script = """
        PRAGMA foreign_keys=ON;
        CREATE TABLE projects (
            id TEXT PRIMARY KEY NOT NULL,
            canonical_directory TEXT NOT NULL,
            revision INTEGER NOT NULL,
            record_json BLOB NOT NULL,
            deleted_at REAL
        );
        CREATE TABLE launchers (
            id TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
            normalized_name TEXT NOT NULL,
            revision INTEGER NOT NULL,
            record_json BLOB NOT NULL,
            deleted_at REAL
        );
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY NOT NULL,
            launcher_id TEXT NOT NULL REFERENCES launchers(id) ON DELETE RESTRICT,
            revision INTEGER NOT NULL,
            state TEXT NOT NULL,
            started_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            record_json BLOB NOT NULL
        );
        INSERT INTO projects VALUES (
            '\(project.id.uuidString)', '\(sqlQuote(project.directory))', \(project.revision), X'\(hex(projectData))', NULL
        );
        INSERT INTO launchers VALUES (
            '\(launcher.id.uuidString)', '\(project.id.uuidString)', '\(sqlQuote(launcher.normalizedName))',
            \(launcher.revision), X'\(hex(launcherData))', NULL
        );
        \(sessionInserts)
        PRAGMA user_version=1;
        """
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, script, nil, nil, &errorPointer)
        if status != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite status \(status)"
            sqlite3_free(errorPointer)
            XCTFail(message)
            throw NSError(domain: "StoreAndMarkdownTests", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func sqlQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func makeLauncher(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        secret: String = "runtime-secret"
    ) -> LauncherRecord {
        let action = LaunchAction(
            id: UUID(),
            name: "main",
            normalizedName: "main",
            description: "Primary process",
            runner: .process,
            executable: "/usr/bin/env",
            arguments: ["python3", "server.py", "--port", "{port:main}"],
            environment: ["API_TOKEN": secret, "VISIBLE_NAME": "development"],
            inheritedEnvironment: ["PATH"],
            port: PortConfiguration(
                mode: .automatic,
                logicalName: "main",
                environmentVariable: "PORT",
                hostEnvironmentVariable: "HOST",
                URLTemplate: "http://${HOST}:${PORT}",
                lease: "8h"
            ),
            healthCheckURL: "http://${HOST}:${PORT}/health"
        )
        return LauncherRecord(
            id: id,
            projectID: projectID,
            name: name,
            normalizedName: "ignored-on-write",
            description: "Development server",
            runDetails: "Local mode",
            tags: ["dev", "Web", "DEV"],
            actions: [action],
            primaryActionID: action.id,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    func testApplicationIdentityRejectsConfiguredBundleMismatch() throws {
        XCTAssertThrowsError(
            try ApplicationIdentityPolicy.verifiedBundleIdentifier(
                configured: "com.example.Configured",
                resolvedFromBundle: "com.example.Actual"
            )
        ) { error in
            XCTAssertEqual(
                error as? ApplicationIdentityPolicyError,
                .configuredBundleIdentifierMismatch(
                    configured: "com.example.Configured",
                    resolved: "com.example.Actual"
                )
            )
        }

        XCTAssertEqual(
            try ApplicationIdentityPolicy.verifiedBundleIdentifier(
                configured: "com.example.Actual",
                resolvedFromBundle: "com.example.Actual"
            ),
            "com.example.Actual"
        )
        XCTAssertNil(
            try ApplicationIdentityPolicy.verifiedBundleIdentifier(
                configured: "com.example.Unverified",
                resolvedFromBundle: nil
            )
        )
    }

    func testApplicationOwnershipRequiresVerifiedMatchingIdentityAndFreshPID() {
        XCTAssertTrue(
            ApplicationIdentityPolicy.provesDistinctOwnership(
                verifiedBundleIdentifier: "com.example.App",
                launchedBundleIdentifier: "com.example.App",
                launchedPID: 200,
                preexistingPIDs: [100]
            )
        )
        XCTAssertFalse(
            ApplicationIdentityPolicy.provesDistinctOwnership(
                verifiedBundleIdentifier: "com.example.App",
                launchedBundleIdentifier: "com.example.App",
                launchedPID: 100,
                preexistingPIDs: [100]
            )
        )
        XCTAssertFalse(
            ApplicationIdentityPolicy.provesDistinctOwnership(
                verifiedBundleIdentifier: nil,
                launchedBundleIdentifier: "com.example.App",
                launchedPID: 200,
                preexistingPIDs: []
            )
        )
        XCTAssertFalse(
            ApplicationIdentityPolicy.provesDistinctOwnership(
                verifiedBundleIdentifier: "com.example.App",
                launchedBundleIdentifier: "com.example.Other",
                launchedPID: 200,
                preexistingPIDs: []
            )
        )
    }
}
