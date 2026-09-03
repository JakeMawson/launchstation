import Foundation
import XCTest
@testable import LauncherCore

final class SessionOpenModelsTests: XCTestCase {
    func testBrowserOptionIsDeterministicAndDerivedOnlyForRunningHTTPAction() throws {
        let actionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let action = LaunchAction(
            id: actionID,
            name: "web",
            normalizedName: "web",
            description: "Web server",
            runner: .process,
            executable: "npm",
            arguments: ["run", "dev"]
        )
        let run = ActionRunRecord(
            id: runID,
            actionID: actionID,
            actionName: "web",
            state: .running,
            manager: .codexPort,
            managerID: "managed-web",
            pid: 42,
            processGroupID: 42,
            pidStartIdentity: "42:1:2",
            endpointURL: "http://127.0.0.1:49152/dashboard"
        )
        let session = makeSession(
            id: sessionID,
            actions: [action],
            runs: [run]
        )

        let first = SessionOpenOptionDeriver.options(for: session)
        let second = SessionOpenOptionDeriver.options(for: session)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].kind, .browser)
        XCTAssertEqual(
            first[0].id,
            "open-v1:22222222-2222-2222-2222-222222222222:browser"
        )
        XCTAssertEqual(first[0].sessionID, sessionID)
        XCTAssertEqual(first[0].actionRunID, runID)
        XCTAssertEqual(first[0].detail, "http://127.0.0.1:49152/dashboard")
        XCTAssertEqual(
            SessionOpenOptionDeriver.option(id: first[0].id, in: session),
            first[0]
        )
        XCTAssertNil(SessionOpenOptionDeriver.option(id: first[0].id + ":forged", in: session))
    }

    func testTerminalAndNonHTTPRunsDoNotProduceBrowserOptions() {
        let action = makeAction(name: "server", executable: "python3")
        let terminal = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .exited,
            manager: .processGroup,
            endpointURL: "http://localhost:8000"
        )
        let invalidScheme = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .processGroup,
            pid: 11,
            pidStartIdentity: "11:1:1",
            endpointURL: "file:///tmp/not-a-server"
        )

        XCTAssertTrue(SessionOpenOptionDeriver.options(
            for: makeSession(actions: [action], runs: [terminal, invalidScheme])
        ).isEmpty)
    }

    func testExpoDerivesIOSAndroidAndWebWithoutGenericBrowserOption() {
        let action = LaunchAction(
            name: "expo",
            normalizedName: "expo",
            description: "Expo development server",
            runner: .process,
            executable: "/usr/local/bin/npx",
            arguments: ["expo", "start"],
            openTarget: .simulator
        )
        let run = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .codexPort,
            managerID: "expo-owner",
            pid: 77,
            processGroupID: 77,
            pidStartIdentity: "77:1:2",
            endpointURL: "http://localhost:8081/index?old=query#fragment",
            simulatorUDID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            simulatorName: "iPhone 16 Pro"
        )

        let options = SessionOpenOptionDeriver.options(
            for: makeSession(actions: [action], runs: [run])
        )

        XCTAssertEqual(options.map(\.kind), [.expoIOS, .expoAndroid, .expoWeb, .simulator])
        XCTAssertFalse(options.contains { $0.kind == .browser })
        XCTAssertEqual(
            SessionOpenOptionDeriver.expoControlURL(
                endpointURL: run.endpointURL,
                kind: .expoIOS
            )?.absoluteString,
            "http://localhost:8081/_expo/open?platform=ios"
        )
        XCTAssertEqual(
            SessionOpenOptionDeriver.expoControlURL(
                endpointURL: run.endpointURL,
                kind: .expoAndroid
            )?.absoluteString,
            "http://localhost:8081/_expo/open?platform=android"
        )
        XCTAssertEqual(
            SessionOpenOptionDeriver.expoControlURL(
                endpointURL: run.endpointURL,
                kind: .expoWeb
            )?.absoluteString,
            "http://localhost:8081/_expo/open?platform=web"
        )
    }

    func testExpoControlNeverTargetsRemoteOrCallerSelectedLocation() {
        let action = LaunchAction(
            name: "expo",
            normalizedName: "expo",
            description: "Expo development server",
            runner: .shell,
            shellCommand: "npx expo start"
        )
        let run = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .codexPort,
            pid: 88,
            pidStartIdentity: "88:1:2",
            endpointURL: "https://example.com:8081/"
        )

        XCTAssertTrue(SessionOpenOptionDeriver.options(
            for: makeSession(actions: [action], runs: [run])
        ).isEmpty)
        XCTAssertNil(SessionOpenOptionDeriver.expoControlURL(
            endpointURL: run.endpointURL,
            kind: .expoIOS
        ))
        XCTAssertNil(SessionOpenOptionDeriver.expoControlURL(
            endpointURL: "http://user:password@localhost:8081",
            kind: .expoIOS
        ))
        XCTAssertNil(SessionOpenOptionDeriver.expoControlURL(
            endpointURL: "http://localhost:8081",
            kind: .browser
        ))
    }

    func testApplicationAndExactSimulatorMetadataProduceSeparateOptions() {
        let action = LaunchAction(
            name: "native",
            normalizedName: "native",
            description: "Native app",
            runner: .app,
            executable: "/Applications/Example.app"
        )
        let run = ActionRunRecord(
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .application,
            managerID: "app:owned:123:com.example.Example",
            pid: 123,
            pidStartIdentity: "123:4:5",
            simulatorUDID: "SIM-EXACT-UDID",
            simulatorName: "iPhone SE"
        )

        let options = SessionOpenOptionDeriver.options(
            for: makeSession(actions: [action], runs: [run])
        )

        XCTAssertEqual(options.map(\.kind), [.application, .simulator])
        XCTAssertEqual(options[0].detail, "native · PID 123")
        XCTAssertEqual(options[1].detail, "iPhone SE · SIM-EXACT-UDID")
    }

    func testOpenMutationRequestContainsOnlyOpaqueOptionID() throws {
        let request = SessionOpenRequest(optionID: "open-v1:run-id:expo-ios")
        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), Set(["optionID"]))
        XCTAssertEqual(object["optionID"] as? String, request.optionID)
    }

    func testActionRunSimulatorFieldsRoundTripAndRemainLegacyOptional() throws {
        let actionID = UUID()
        let populated = ActionRunRecord(
            actionID: actionID,
            actionName: "ios",
            state: .running,
            manager: .processGroup,
            simulatorUDID: "STRUCTURED-UDID",
            simulatorName: "iPhone 16"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(ActionRunRecord.self, from: encoder.encode(populated)), populated)

        let legacy = ActionRunRecord(
            actionID: actionID,
            actionName: "legacy",
            state: .running,
            manager: .processGroup
        )
        let legacyData = try encoder.encode(legacy)
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        XCTAssertNil(legacyObject["simulatorUDID"])
        XCTAssertNil(legacyObject["simulatorName"])
        let decodedLegacy = try decoder.decode(ActionRunRecord.self, from: legacyData)
        XCTAssertNil(decodedLegacy.simulatorUDID)
        XCTAssertNil(decodedLegacy.simulatorName)
    }

    private func makeAction(name: String, executable: String) -> LaunchAction {
        LaunchAction(
            name: name,
            normalizedName: name,
            description: "Fixture",
            runner: .process,
            executable: executable
        )
    }

    private func makeSession(
        id: UUID = UUID(),
        actions: [LaunchAction],
        runs: [ActionRunRecord]
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            launcherID: UUID(),
            launcherName: "Fixture",
            launcherRevision: 1,
            actionSnapshots: actions,
            state: .running,
            actionRuns: runs,
            startedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
