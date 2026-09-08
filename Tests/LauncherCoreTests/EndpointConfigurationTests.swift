import Foundation
import XCTest
@testable import LauncherCore

final class EndpointConfigurationTests: XCTestCase {
    func testConfigurationLinesNormalizeAndRetainUnchangedEndpointIdentity() throws {
        let fullID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let existing = [LauncherEndpoint(id: fullID, name: "Full Simulator", path: "/")]

        let parsed = try LauncherEndpoint.parseConfigurationLines(
            "  Full Simulator: /  \nV2 UI Simulator: /index-v2.html\nCompare Models: /compare.html",
            preserving: existing
        )

        XCTAssertEqual(parsed.map(\.name), ["Full Simulator", "V2 UI Simulator", "Compare Models"])
        XCTAssertEqual(parsed.map(\.path), ["/", "/index-v2.html", "/compare.html"])
        XCTAssertEqual(parsed[0].id, fullID)
        XCTAssertEqual(
            LauncherEndpoint.configurationText(for: parsed),
            "Full Simulator: /\nV2 UI Simulator: /index-v2.html\nCompare Models: /compare.html"
        )
    }

    func testEndpointValidationRejectsUnsafeOrAmbiguousPaths() {
        let unsafePaths = ["https://example.test", "//example.test", "/../secret", "/compare?debug=1", "/a%2fb"]
        for path in unsafePaths {
            XCTAssertThrowsError(try LauncherValidation.normalizedEndpoints([
                LauncherEndpoint(name: "Unsafe", path: path)
            ]), "Expected \(path) to be rejected")
        }

        XCTAssertThrowsError(try LauncherValidation.normalizedEndpoints([
            LauncherEndpoint(name: "One", path: "/"),
            LauncherEndpoint(name: "Two", path: "/")
        ]))
        XCTAssertThrowsError(try LauncherEndpoint.parseConfigurationLines("One: /\none: /other"))
    }

    func testLegacyLauncherAndSessionRecordsDecodeWithoutEndpointFields() throws {
        let project = ProjectRecord(displayName: "Legacy", directory: "/tmp/legacy")
        let action = fixtureAction()
        let launcher = LauncherRecord(
            projectID: project.id,
            name: "Legacy",
            normalizedName: "legacy",
            description: "Legacy launcher",
            endpoints: [LauncherEndpoint(name: "Full", path: "/")],
            actions: [action],
            primaryActionID: action.id
        )
        var launcherObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LauncherJSON.encoder().encode(launcher)) as? [String: Any]
        )
        launcherObject.removeValue(forKey: "endpoints")
        let decodedLauncher = try LauncherJSON.decoder().decode(
            LauncherRecord.self,
            from: JSONSerialization.data(withJSONObject: launcherObject)
        )
        XCTAssertEqual(decodedLauncher.endpoints, [])

        let session = SessionRecord(
            launcherID: launcher.id,
            launcherName: launcher.name,
            launcherRevision: launcher.revision,
            primaryActionID: action.id,
            endpointSnapshots: launcher.endpoints,
            actionSnapshots: [action]
        )
        var sessionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LauncherJSON.encoder().encode(session)) as? [String: Any]
        )
        sessionObject.removeValue(forKey: "primaryActionID")
        sessionObject.removeValue(forKey: "endpointSnapshots")
        let decodedSession = try LauncherJSON.decoder().decode(
            SessionRecord.self,
            from: JSONSerialization.data(withJSONObject: sessionObject)
        )
        XCTAssertNil(decodedSession.primaryActionID)
        XCTAssertNil(decodedSession.endpointSnapshots)
    }

    func testNamedSessionOptionsUseOnlyTheExactRunningOrigin() throws {
        let action = fixtureAction()
        let full = LauncherEndpoint(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Full Simulator",
            path: "/"
        )
        let v2 = LauncherEndpoint(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "V2 UI Simulator",
            path: "/index-v2.html"
        )
        let runID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let run = ActionRunRecord(
            id: runID,
            actionID: action.id,
            actionName: action.name,
            state: .running,
            manager: .codexPort,
            managerID: "fixture-port",
            pid: 12,
            pidStartIdentity: "12:1:2",
            endpointURL: "https://127.0.0.1:42001/compare.html?old=query#fragment"
        )
        let session = SessionRecord(
            launcherID: UUID(),
            launcherName: "Simulator",
            launcherRevision: 3,
            primaryActionID: action.id,
            endpointSnapshots: [full, v2],
            actionSnapshots: [action],
            state: .running,
            actionRuns: [run]
        )

        let options = SessionOpenOptionDeriver.options(for: session)

        XCTAssertEqual(options.map(\.kind), [.browserEndpoint, .browserEndpoint])
        XCTAssertEqual(options.map(\.label), ["Open Full Simulator", "Open V2 UI Simulator"])
        XCTAssertEqual(
            options.map(\.id),
            [
                SessionOpenOptionDeriver.endpointOptionID(actionRunID: runID, endpointID: full.id),
                SessionOpenOptionDeriver.endpointOptionID(actionRunID: runID, endpointID: v2.id),
            ]
        )
        XCTAssertEqual(
            SessionOpenOptionDeriver.browserURL(for: options[1], in: session)?.absoluteString,
            "https://127.0.0.1:42001/index-v2.html"
        )

        var forged = options[1]
        forged.configuredEndpointID = UUID()
        XCTAssertNil(SessionOpenOptionDeriver.browserURL(for: forged, in: session))
        XCTAssertNil(SessionOpenOptionDeriver.option(id: options[1].id + ":forged", in: session))
    }

    func testMarkdownIncludesNamedEndpointMapping() throws {
        let project = ProjectRecord(displayName: "Example", directory: "/tmp/example")
        let action = fixtureAction()
        let launcher = LauncherRecord(
            projectID: project.id,
            name: "Example app",
            normalizedName: "example app",
            description: "Example",
            endpoints: [LauncherEndpoint(name: "V2", path: "/index-v2.html")],
            actions: [action],
            primaryActionID: action.id
        )

        let rendered = MarkdownRenderer().render(project: project, launchers: [launcher]).content

        XCTAssertTrue(rendered.contains("- Named endpoints:"))
        XCTAssertTrue(rendered.contains("`V2`: `/index-v2.html`"))
    }

    private func fixtureAction() -> LaunchAction {
        LaunchAction(
            name: "web",
            normalizedName: "web",
            description: "Web server",
            runner: .process,
            executable: "/usr/bin/true"
        )
    }
}
