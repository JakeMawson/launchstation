import Foundation
import XCTest
@testable import LauncherCore

final class APIClientTests: XCTestCase {
    func testQueryValuesUseStrictDelimiterSafeEncoding() async throws {
        let observedRequest = LockedBox<URLRequest?>(nil)
        let client = try makeClient { request in
            observedRequest.set(request)
            return try Self.response(for: request, body: [LauncherDetail]())
        }
        let query = "alpha&beta=gamma?delta#fragment+plus /unicode-é"

        let launchers = try await client.listLaunchers(query: query)

        XCTAssertTrue(launchers.isEmpty)
        let request = try XCTUnwrap(observedRequest.get())
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query)])
        XCTAssertEqual(
            components.percentEncodedQuery,
            "q=alpha%26beta%3Dgamma%3Fdelta%23fragment%2Bplus%20%2Funicode-%C3%A9"
        )
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testSafeReadRecoversServiceAndRetriesOnceAfterTransportFailure() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let client = try makeClient(
            handler: { request in
                let attempt = requestCount.modify { value in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    throw URLError(.cannotConnectToHost)
                }
                return try Self.response(for: request, body: [LauncherDetail]())
            },
            serviceKickstarter: {
                kickstartCount.modify { $0 += 1 }
            }
        )

        let launchers = try await client.listLaunchers()

        XCTAssertTrue(launchers.isEmpty)
        XCTAssertEqual(requestCount.get(), 2)
        XCTAssertEqual(kickstartCount.get(), 1)
    }

    func testHealthProbeDoesNotMutateLaunchdOrRetryTransportFailure() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let client = try makeClient(
            handler: { _ in
                requestCount.modify { $0 += 1 }
                throw URLError(.cannotConnectToHost)
            },
            serviceKickstarter: { kickstartCount.modify { $0 += 1 } }
        )

        do {
            _ = try await client.probeHealth()
            XCTFail("Expected the non-mutating probe to fail")
        } catch let error as LauncherAPIError {
            guard case .transport = error else {
                return XCTFail("Expected a transport error, got \(error)")
            }
        }

        XCTAssertEqual(requestCount.get(), 1)
        XCTAssertEqual(kickstartCount.get(), 0)
    }

    func testExplicitServiceStartupKickstartsOnceAndWaitsForAuthenticatedHealth() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let expected = ServiceStatus(
            version: LauncherRuntimeVersion.current(),
            schemaVersion: LauncherSchema.version,
            pid: 456,
            startedAt: Date(timeIntervalSince1970: 2),
            endpoint: "http://127.0.0.1:43210"
        )
        let client = try makeClient(
            handler: { request in
                let attempt = requestCount.modify { value in
                    value += 1
                    return value
                }
                if attempt < 3 { throw URLError(.cannotConnectToHost) }
                return try Self.response(for: request, body: expected)
            },
            serviceKickstarter: { kickstartCount.modify { $0 += 1 } },
            serviceReadinessMaxAttempts: 4
        )

        let health = try await client.startServiceAndWaitUntilReady()

        XCTAssertEqual(health, expected)
        XCTAssertEqual(requestCount.get(), 3)
        XCTAssertEqual(kickstartCount.get(), 1)
    }

    func testExplicitServiceStartupFailsAfterBoundedReadinessAttempts() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let client = try makeClient(
            handler: { _ in
                requestCount.modify { $0 += 1 }
                throw URLError(.cannotConnectToHost)
            },
            serviceKickstarter: { kickstartCount.modify { $0 += 1 } },
            serviceReadinessMaxAttempts: 3
        )

        do {
            _ = try await client.startServiceAndWaitUntilReady()
            XCTFail("Expected bounded readiness to fail")
        } catch let error as LauncherAPIError {
            guard case .transport = error else {
                return XCTFail("Expected the last transport error, got \(error)")
            }
        }

        XCTAssertEqual(requestCount.get(), 3)
        XCTAssertEqual(kickstartCount.get(), 1)
    }

    func testSafeReadReloadsReplacementMetadataWithoutDestructiveKickstart() async throws {
        XCTAssertEqual(
            LauncherPaths.serviceKickstartArguments(userID: 501),
            ["kickstart", "gui/501/com.jakemawson.codex-launcher.service"]
        )
        XCTAssertFalse(LauncherPaths.serviceKickstartArguments(userID: 501).contains("-k"))
        XCTAssertEqual(
            LauncherPaths.serviceBootstrapArguments(
                userID: 501,
                launchAgentURL: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/com.jakemawson.codex-launcher.service.plist")
            ),
            [
                "bootstrap",
                "gui/501",
                "/Users/test/Library/LaunchAgents/com.jakemawson.codex-launcher.service.plist"
            ]
        )

        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let observedAuthorization = LockedBox<[String]>([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-APIClientTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("service.json")
        let original = ServiceMetadata(
            endpoint: "http://127.0.0.1:43210",
            token: "old-token",
            pid: 111,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let replacement = ServiceMetadata(
            endpoint: "http://127.0.0.1:43211",
            token: "replacement-token",
            pid: 222,
            startedAt: Date(timeIntervalSince1970: 2)
        )
        try LauncherJSON.encoder().encode(original).write(to: metadataURL)
        StubURLProtocol.setHandler { request in
            requestCount.modify { $0 += 1 }
            observedAuthorization.modify { $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
            if requestCount.get() == 1 { throw URLError(.cannotConnectToHost) }
            return try Self.response(for: request, body: [LauncherDetail]())
        }
        let client = LauncherAPIClient(
            metadataURL: metadataURL,
            session: session,
            serviceKickstarter: {
                kickstartCount.modify { $0 += 1 }
                try LauncherJSON.encoder().encode(replacement).write(to: metadataURL)
            },
            serviceRecoveryDelayNanoseconds: 0
        )

        _ = try await client.listLaunchers()

        XCTAssertEqual(requestCount.get(), 2)
        XCTAssertEqual(kickstartCount.get(), 1)
        XCTAssertEqual(observedAuthorization.get(), ["Bearer old-token", "Bearer replacement-token"])
    }

    func testMutationTransportFailureIsNeverKickstartedOrRetried() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let observedTimeout = LockedBox<TimeInterval?>(nil)
        let client = try makeClient(
            handler: { request in
                requestCount.modify { $0 += 1 }
                observedTimeout.set(request.timeoutInterval)
                throw URLError(.networkConnectionLost)
            },
            serviceKickstarter: {
                kickstartCount.modify { $0 += 1 }
            }
        )

        do {
            _ = try await client.initializeProject(directory: "/tmp/example")
            XCTFail("Expected the mutation transport to fail")
        } catch let error as LauncherAPIError {
            guard case .transport = error else {
                return XCTFail("Expected a transport error, got \(error)")
            }
        }

        XCTAssertEqual(requestCount.get(), 1)
        XCTAssertEqual(kickstartCount.get(), 0)
        XCTAssertEqual(observedTimeout.get(), 30)
    }

    func testMutationMayKickstartBeforeItsFirstRequestWhenMetadataIsMissing() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-APIClientTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("service.json")
        let metadata = ServiceMetadata(
            endpoint: "http://127.0.0.1:43210",
            token: "test-token",
            pid: 123,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let project = ProjectRecord(displayName: "Recovered", directory: "/tmp/example")
        StubURLProtocol.setHandler { request in
            requestCount.modify { $0 += 1 }
            return try Self.response(for: request, status: 201, body: project)
        }
        let client = LauncherAPIClient(
            metadataURL: metadataURL,
            session: session,
            serviceKickstarter: {
                kickstartCount.modify { $0 += 1 }
                try LauncherJSON.encoder().encode(metadata).write(to: metadataURL)
            },
            serviceRecoveryDelayNanoseconds: 0
        )

        let created = try await client.initializeProject(directory: "/tmp/example")

        XCTAssertEqual(created.id, project.id)
        XCTAssertEqual(kickstartCount.get(), 1)
        XCTAssertEqual(requestCount.get(), 1, "the mutation itself must still be sent exactly once")
    }

    func testEveryRequestRejectsIncompatibleServiceMetadataBeforeTransport() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-APIClientTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("service.json")
        try LauncherJSON.encoder().encode(ServiceMetadata(
            endpoint: "http://127.0.0.1:43210",
            token: "old-token",
            pid: 111,
            startedAt: Date(timeIntervalSince1970: 1),
            schemaVersion: 1,
            version: "1.1.0"
        )).write(to: metadataURL)
        StubURLProtocol.setHandler { request in
            requestCount.modify { $0 += 1 }
            return try Self.response(for: request, body: EmptyResponse())
        }
        let client = LauncherAPIClient(
            metadataURL: metadataURL,
            session: session,
            serviceKickstarter: { kickstartCount.modify { $0 += 1 } },
            serviceRecoveryDelayNanoseconds: 0
        )

        do {
            _ = try await client.initializeProject(directory: "/tmp/example")
            XCTFail("Expected incompatible metadata to be rejected")
        } catch let error as LauncherAPIError {
            guard case .invalidMetadata(let message) = error else {
                return XCTFail("Expected invalid metadata, got \(error)")
            }
            XCTAssertTrue(message.contains("schema 1"))
        }
        XCTAssertEqual(requestCount.get(), 0)
        XCTAssertEqual(kickstartCount.get(), 0, "incompatible metadata must not restart the known service")
    }

    func testStartAndStopUseLongLifecycleTimeoutWithoutMutationRetry() async throws {
        let launcherID = UUID()
        let session = SessionRecord(
            launcherID: launcherID,
            launcherName: "Lifecycle",
            launcherRevision: 1,
            state: .running
        )
        let observedRequests = LockedBox<[URLRequest]>([])
        let client = try makeClient { request in
            observedRequests.modify { $0.append(request) }
            return try Self.response(for: request, body: session)
        }

        _ = try await client.startLauncher(id: launcherID, expectedLauncherRevision: 1)
        _ = try await client.stopSession(id: session.id)

        let requests = observedRequests.get()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map(\.timeoutInterval), [3_600, 3_600])
        let startBody = try LauncherJSON.decoder().decode(
            SessionStartRequest.self,
            from: Self.bodyData(from: requests[0])
        )
        XCTAssertEqual(startBody.expectedLauncherRevision, 1)
        XCTAssertEqual(startBody.mode, .reusePrimary)
    }

    func testExplicitNewInstanceIsEncodedOnStartRequest() async throws {
        let launcherID = UUID()
        let session = SessionRecord(
            launcherID: launcherID,
            launcherName: "Additional",
            launcherRevision: 4,
            launchRole: .additional,
            state: .running
        )
        let observedRequest = LockedBox<URLRequest?>(nil)
        let client = try makeClient { request in
            observedRequest.set(request)
            return try Self.response(for: request, status: 201, body: session)
        }

        _ = try await client.startLauncher(
            id: launcherID,
            expectedLauncherRevision: 4,
            mode: .newInstance
        )

        let body = try LauncherJSON.decoder().decode(
            SessionStartRequest.self,
            from: Self.bodyData(from: try XCTUnwrap(observedRequest.get()))
        )
        XCTAssertEqual(body.mode, .newInstance)
        let legacy = try LauncherJSON.decoder().decode(
            SessionStartRequest.self,
            from: Data(#"{"runtimeArguments":[],"openRequested":false}"#.utf8)
        )
        XCTAssertEqual(legacy.mode, .reusePrimary)
    }

    func testUpgradePreparationAndExactCancellationUseAuthenticatedMutationRoutes() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = UpgradeMaintenanceReservation(
            reservationToken: "private-cancellation-capability",
            expiresAt: expiresAt
        )
        let observedRequests = LockedBox<[URLRequest]>([])
        let client = try makeClient { request in
            observedRequests.modify { $0.append(request) }
            if request.url?.path == "/v1/maintenance/upgrade/prepare" {
                return try Self.response(for: request, status: 201, body: expected)
            }
            return try Self.response(for: request, body: EmptyResponse())
        }

        let reservation = try await client.prepareUpgrade()
        let cancellation = try await client.cancelUpgrade(
            reservationToken: reservation.reservationToken
        )

        XCTAssertEqual(reservation, expected)
        XCTAssertTrue(cancellation.ok)
        let requests = observedRequests.get()
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map(\.url?.path), [
            "/v1/maintenance/upgrade/prepare",
            "/v1/maintenance/upgrade/cancel"
        ])
        XCTAssertEqual(requests.map(\.timeoutInterval), [30, 30])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        })
        XCTAssertNil(requests[0].httpBody)
        XCTAssertNil(requests[0].httpBodyStream)
        let cancelBody = try LauncherJSON.decoder().decode(
            UpgradeMaintenanceCancelRequest.self,
            from: Self.bodyData(from: requests[1])
        )
        XCTAssertEqual(cancelBody.reservationToken, expected.reservationToken)
    }

    func testUpgradePreparationIsNeverRetriedAfterAmbiguousTransportFailure() async throws {
        let requestCount = LockedBox(0)
        let kickstartCount = LockedBox(0)
        let client = try makeClient(
            handler: { _ in
                requestCount.modify { $0 += 1 }
                throw URLError(.networkConnectionLost)
            },
            serviceKickstarter: { kickstartCount.modify { $0 += 1 } }
        )

        do {
            _ = try await client.prepareUpgrade()
            XCTFail("Expected upgrade preparation transport to fail")
        } catch let error as LauncherAPIError {
            guard case .transport = error else {
                return XCTFail("Expected a transport error, got \(error)")
            }
        }

        XCTAssertEqual(requestCount.get(), 1)
        XCTAssertEqual(kickstartCount.get(), 0)
    }

    func testRelaunchUsesOneLifecycleRequestAndBindsExpectedSession() async throws {
        let launcherID = UUID()
        let previousID = UUID()
        let previous = SessionRecord(
            id: previousID,
            launcherID: launcherID,
            launcherName: "Relaunch",
            launcherRevision: 1,
            state: .exited
        )
        let fresh = SessionRecord(
            launcherID: launcherID,
            launcherName: "Relaunch",
            launcherRevision: 1,
            state: .running
        )
        let observedRequest = LockedBox<URLRequest?>(nil)
        let client = try makeClient { request in
            observedRequest.set(request)
            return try Self.response(
                for: request,
                status: 201,
                body: SessionRelaunchResult(previousSession: previous, session: fresh)
            )
        }

        let result = try await client.relaunchLauncher(
            id: launcherID,
            runtimeArguments: ["--mode", "demo"],
            openRequested: true,
            expectedSessionID: previousID,
            expectedLauncherRevision: 1
        )

        XCTAssertEqual(result.previousSession?.id, previousID)
        XCTAssertEqual(result.session.id, fresh.id)
        let request = try XCTUnwrap(observedRequest.get())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/launchers/\(launcherID.uuidString)/relaunch")
        XCTAssertEqual(request.timeoutInterval, 3_600)
        let body = try LauncherJSON.decoder().decode(SessionRelaunchRequest.self, from: Self.bodyData(from: request))
        XCTAssertEqual(body.runtimeArguments, ["--mode", "demo"])
        XCTAssertTrue(body.openRequested)
        XCTAssertEqual(body.expectedSessionID, previousID)
        XCTAssertFalse(body.requireIdle)
        XCTAssertEqual(body.expectedLauncherRevision, 1)
    }

    func testIdleRelaunchCarriesExplicitIdlePreconditionAndLegacyJSONDefaultsFalse() async throws {
        let launcherID = UUID()
        let fresh = SessionRecord(
            launcherID: launcherID,
            launcherName: "Idle relaunch",
            launcherRevision: 1,
            state: .running
        )
        let observedRequest = LockedBox<URLRequest?>(nil)
        let client = try makeClient { request in
            observedRequest.set(request)
            return try Self.response(
                for: request,
                status: 201,
                body: SessionRelaunchResult(previousSession: nil, session: fresh)
            )
        }

        _ = try await client.relaunchLauncher(
            id: launcherID,
            requireIdle: true,
            expectedLauncherRevision: 1
        )

        let body = try LauncherJSON.decoder().decode(
            SessionRelaunchRequest.self,
            from: Self.bodyData(from: try XCTUnwrap(observedRequest.get()))
        )
        XCTAssertTrue(body.requireIdle)
        XCTAssertNil(body.expectedSessionID)
        XCTAssertEqual(body.expectedLauncherRevision, 1)

        let legacy = try LauncherJSON.decoder().decode(
            SessionRelaunchRequest.self,
            from: Data(#"{"runtimeArguments":[],"openRequested":false}"#.utf8)
        )
        XCTAssertFalse(legacy.requireIdle)
        XCTAssertNil(legacy.expectedSessionID)
        XCTAssertNil(legacy.expectedLauncherRevision)
    }

    func testExactSessionRelaunchUsesSessionScopedLifecycleRoute() async throws {
        let launcherID = UUID()
        let previousID = UUID()
        let previous = SessionRecord(
            id: previousID,
            launcherID: launcherID,
            launcherName: "Additional",
            launcherRevision: 2,
            launchRole: .additional,
            state: .exited
        )
        let replacement = SessionRecord(
            launcherID: launcherID,
            launcherName: "Additional",
            launcherRevision: 2,
            launchRole: .additional,
            state: .running
        )
        let observedRequest = LockedBox<URLRequest?>(nil)
        let client = try makeClient { request in
            observedRequest.set(request)
            return try Self.response(
                for: request,
                status: 201,
                body: SessionRelaunchResult(previousSession: previous, session: replacement)
            )
        }

        _ = try await client.relaunchSession(
            id: previousID,
            runtimeArguments: ["--fresh"],
            expectedLauncherRevision: 2
        )

        let request = try XCTUnwrap(observedRequest.get())
        XCTAssertEqual(request.url?.path, "/v1/sessions/\(previousID.uuidString)/relaunch")
        XCTAssertEqual(request.timeoutInterval, 3_600)
        let body = try LauncherJSON.decoder().decode(
            SessionRelaunchRequest.self,
            from: Self.bodyData(from: request)
        )
        XCTAssertEqual(body.expectedSessionID, previousID)
        XCTAssertEqual(body.runtimeArguments, ["--fresh"])
    }

    func testHistoryClientEncodesBoundedFiltersAndCursor() async throws {
        let launcherID = UUID()
        let observedRequest = LockedBox<URLRequest?>(nil)
        let client = try makeClient { request in
            observedRequest.set(request)
            return try Self.response(
                for: request,
                body: SessionHistoryPage(sessions: [], nextCursor: "next")
            )
        }

        let page = try await client.sessionHistory(
            launcherID: launcherID,
            state: .exited,
            role: .additional,
            limit: 25,
            cursor: "opaque+/="
        )

        XCTAssertEqual(page.nextCursor, "next")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(observedRequest.get()?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/v1/history/sessions")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["launcherID"], launcherID.uuidString)
        XCTAssertEqual(query["state"], "exited")
        XCTAssertEqual(query["role"], "additional")
        XCTAssertEqual(query["limit"], "25")
        XCTAssertEqual(query["cursor"], "opaque+/=")
    }

    func testCancelledReadRemainsCancellationAndDoesNotKickstart() async throws {
        let kickstartCount = LockedBox(0)
        let client = try makeClient(
            handler: { _ in throw URLError(.cancelled) },
            serviceKickstarter: { kickstartCount.modify { $0 += 1 } }
        )

        do {
            _ = try await client.launcherSkillStatus()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: view tasks may disappear without surfacing a transport error.
        }
        XCTAssertEqual(kickstartCount.get(), 0)
    }

    func testSkillInstallUsesOneHostOnlyMutation() async throws {
        let installStatus = LauncherSkillHostStatus(
            host: .codex,
            available: true,
            installationPath: "/tmp/codex-launcher",
            state: .current,
            installedVersion: "1.1.0",
            message: "current"
        )
        let requests = LockedBox<[URLRequest]>([])
        let client = try makeClient { request in
            requests.modify { $0.append(request) }
            return try Self.response(
                for: request,
                body: LauncherSkillInstallResult(status: installStatus, installedFiles: ["/tmp/codex-launcher/SKILL.md"])
            )
        }

        _ = try await client.installLauncherSkill(for: .codex)

        XCTAssertEqual(requests.get().map(\.httpMethod), ["POST"])
        XCTAssertEqual(requests.get().map(\.timeoutInterval), [30])
        let installBody = try LauncherJSON.decoder().decode(
            LauncherSkillInstallRequest.self,
            from: Self.bodyData(from: try XCTUnwrap(requests.get().last))
        )
        XCTAssertEqual(installBody.host, .codex)
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.bodyData(from: try XCTUnwrap(requests.get().last)))
                as? [String: String]
        )
        XCTAssertEqual(encodedObject, ["host": "codex"])
    }

    func testSkillModelsDecodeLegacyHostStatusAndInstallResult() throws {
        let host = try LauncherJSON.decoder().decode(
            LauncherSkillHostStatus.self,
            from: Data(#"{"host":"codex","available":true,"installationPath":"/tmp/skill","state":"current","installedVersion":"1.0","message":"legacy"}"#.utf8)
        )
        XCTAssertTrue(host.available)
        XCTAssertTrue(host.surfaces.isEmpty)

        let result = try LauncherJSON.decoder().decode(
            LauncherSkillInstallResult.self,
            from: Data(#"{"status":{"host":"codex","available":true,"installationPath":"/tmp/skill","state":"current","installedVersion":"1.0","message":"legacy"},"installedFiles":["/tmp/skill/SKILL.md"],"surface":"cli"}"#.utf8)
        )
        XCTAssertEqual(result.sharedInstallationPath, "/tmp/skill")
        XCTAssertFalse(result.restartRecommended)
    }

    func testSkillUninstallUsesTwoIntentBoundMutationRoutesAndConfirmationText() async throws {
        let binding = LauncherSkillUninstallBinding(
            host: .codex,
            destinationPath: "/tmp/codex-launcher",
            installationID: UUID(),
            receiptDigest: "receipt-digest",
            targetIdentity: LauncherSkillTargetIdentity(device: 1, inode: 2),
            targetFingerprint: "target-fingerprint"
        )
        let intent = LauncherSkillUninstallIntent(
            token: "single-use-capability",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            host: .codex,
            sharedInstallationPath: "/tmp/codex-launcher",
            installedVersion: "1.1.0",
            binding: binding,
            removablePaths: ["/tmp/codex-launcher/SKILL.md"],
            preservedPaths: [],
            confirmationText: "uninstall codex shared skill",
            message: "receipt proven"
        )
        let status = LauncherSkillHostStatus(
            host: .codex,
            available: true,
            installationPath: "/tmp/codex-launcher",
            state: .current,
            installedVersion: "1.1.0",
            message: "removed"
        )
        let requests = LockedBox<[URLRequest]>([])
        let client = try makeClient { request in
            requests.modify { $0.append(request) }
            if request.url?.path == "/v1/skills/uninstall-intent" {
                return try Self.response(for: request, status: 201, body: intent)
            }
            return try Self.response(
                for: request,
                body: LauncherSkillUninstallResponse(
                    result: LauncherSkillUninstallResult(
                        host: .codex,
                        destinationPath: "/tmp/codex-launcher",
                        installationID: binding.installationID,
                        consumedReceiptDigest: binding.receiptDigest,
                        removedRelativePaths: ["SKILL.md"],
                        preservedRelativePaths: [],
                        message: "removed"
                    ),
                    status: status
                )
            )
        }

        let prepared = try await client.prepareLauncherSkillUninstall(for: .codex)
        _ = try await client.uninstallLauncherSkill(
            intent: prepared,
            confirmationText: prepared.confirmationText
        )

        XCTAssertEqual(requests.get().map(\.url?.path), [
            "/v1/skills/uninstall-intent",
            "/v1/skills/uninstall"
        ])
        XCTAssertEqual(requests.get().map(\.timeoutInterval), [30, 30])
        let preparedRequest = try LauncherJSON.decoder().decode(
            LauncherSkillUninstallIntentRequest.self,
            from: Self.bodyData(from: requests.get()[0])
        )
        XCTAssertEqual(preparedRequest.host, .codex)
        let preparedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.bodyData(from: requests.get()[0])) as? [String: String]
        )
        XCTAssertEqual(preparedObject, ["host": "codex"])
        let intentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LauncherJSON.encoder().encode(intent)) as? [String: Any]
        )
        XCTAssertNil(intentObject["selectedSurface"])
        XCTAssertEqual(intentObject["affectedSurfaces"] as? [String], ["desktop", "cli"])
        let uninstallRequest = try LauncherJSON.decoder().decode(
            LauncherSkillUninstallRequest.self,
            from: Self.bodyData(from: requests.get()[1])
        )
        XCTAssertEqual(uninstallRequest.token, intent.token)
        XCTAssertEqual(uninstallRequest.binding, binding)
        XCTAssertEqual(uninstallRequest.confirmationText, intent.confirmationText)
        let uninstallObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.bodyData(from: requests.get()[1])) as? [String: Any]
        )
        XCTAssertNil(uninstallObject["surface"])
    }

    func testExternalProcessClientUsesFreshSnapshotAndExactIntentBoundCloseRoutes() async throws {
        let observationID = UUID()
        let intent = ExternalCloseIntent(
            token: "ephemeral-close-capability",
            observationID: observationID,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            pid: 4242,
            startedAt: Date(timeIntervalSince1970: 100),
            command: "node server.js",
            endpoints: [],
            ownership: .external,
            warning: "confirmation required",
            confirmationText: "CLOSE 4242"
        )
        let requests = LockedBox<[URLRequest]>([])
        let client = try makeClient { request in
            requests.modify { $0.append(request) }
            switch request.url?.path {
            case "/v1/external-processes/refresh":
                return try Self.response(
                    for: request,
                    body: ExternalProcessSnapshot(scannedAt: Date(timeIntervalSince1970: 10), observations: [], isComplete: true)
                )
            case "/v1/external-processes/\(observationID.uuidString)/close-intent":
                return try Self.response(for: request, status: 201, body: intent)
            default:
                return try Self.response(
                    for: request,
                    body: ExternalCloseResult(observationID: observationID, outcome: .stopped, message: "stopped")
                )
            }
        }

        _ = try await client.externalProcessSnapshot(fresh: true)
        let prepared = try await client.makeExternalCloseIntent(observationID: observationID)
        _ = try await client.closeExternalProcess(
            ExternalCloseRequest(
                observationID: observationID,
                intentToken: prepared.token,
                confirmationText: prepared.confirmationText
            )
        )

        let captured = requests.get()
        XCTAssertEqual(captured.map(\.url?.path), [
            "/v1/external-processes/refresh",
            "/v1/external-processes/\(observationID.uuidString)/close-intent",
            "/v1/external-processes/\(observationID.uuidString)/close",
        ])
        XCTAssertEqual(captured.map(\.httpMethod), ["GET", "POST", "POST"])
        let request = try LauncherJSON.decoder().decode(
            ExternalCloseRequest.self,
            from: Self.bodyData(from: captured[2])
        )
        XCTAssertEqual(request.observationID, observationID)
        XCTAssertEqual(request.intentToken, prepared.token)
        XCTAssertEqual(request.confirmationText, prepared.confirmationText)
    }

    func testSessionOpenClientUsesOnlyOpaqueServerDerivedOptionIDs() async throws {
        let sessionID = UUID()
        let actionRunID = UUID()
        let option = SessionOpenOption(
            id: SessionOpenOptionDeriver.optionID(actionRunID: actionRunID, kind: .expoIOS),
            sessionID: sessionID,
            actionRunID: actionRunID,
            actionID: UUID(),
            kind: .expoIOS,
            label: "Open Expo on iOS"
        )
        let requests = LockedBox<[URLRequest]>([])
        let client = try makeClient { request in
            requests.modify { $0.append(request) }
            switch request.url?.path {
            case "/v1/sessions/\(sessionID.uuidString)/open-options":
                return try Self.response(for: request, body: [option])
            case "/v1/sessions/\(sessionID.uuidString)/open":
                return try Self.response(
                    for: request,
                    body: SessionOpenResult(optionID: option.id, kind: .expoIOS, message: "opened")
                )
            default:
                return try Self.response(
                    for: request,
                    body: SessionOpenProbeResult(
                        optionID: option.id,
                        kind: .expoIOS,
                        available: true,
                        statusCode: 200,
                        message: "ready"
                    )
                )
            }
        }

        let listedOptions = try await client.sessionOpenOptions(sessionID: sessionID)
        XCTAssertEqual(listedOptions, [option])
        _ = try await client.openSessionOption(sessionID: sessionID, optionID: option.id)
        _ = try await client.probeSessionOpenOption(sessionID: sessionID, optionID: option.id)

        let captured = requests.get()
        XCTAssertEqual(captured.map(\.url?.path), [
            "/v1/sessions/\(sessionID.uuidString)/open-options",
            "/v1/sessions/\(sessionID.uuidString)/open",
            "/v1/sessions/\(sessionID.uuidString)/open-probe",
        ])
        for request in captured.dropFirst() {
            let body = try LauncherJSON.decoder().decode(
                SessionOpenRequest.self,
                from: Self.bodyData(from: request)
            )
            XCTAssertEqual(body.optionID, option.id)
        }
    }

    private func makeClient(
        handler: @escaping StubURLProtocol.Handler,
        serviceKickstarter: @escaping @Sendable () throws -> Void = {},
        serviceReadinessMaxAttempts: Int = 40
    ) throws -> LauncherAPIClient {
        StubURLProtocol.setHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLauncher-APIClientTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadataURL = root.appendingPathComponent("service.json")
        let metadata = ServiceMetadata(
            endpoint: "http://127.0.0.1:43210",
            token: "test-token",
            pid: 123,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        try LauncherJSON.encoder().encode(metadata).write(to: metadataURL)
        return LauncherAPIClient(
            metadataURL: metadataURL,
            session: session,
            serviceKickstarter: serviceKickstarter,
            serviceRecoveryDelayNanoseconds: 0,
            serviceReadinessRetryDelayNanoseconds: 0,
            serviceReadinessMaxAttempts: serviceReadinessMaxAttempts
        )
    }

    private static func response<Body: Encodable>(
        for request: URLRequest,
        status: Int = 200,
        body: Body
    ) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, try LauncherJSON.encoder().encode(body))
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    func modify<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}

private final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handler = LockedBox<Handler?> (nil)

    static func setHandler(_ newHandler: @escaping Handler) {
        handler.set(newHandler)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler.get() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
