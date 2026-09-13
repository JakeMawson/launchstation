import Foundation
import XCTest
@testable import LauncherCore

final class ServiceRegistrationTests: XCTestCase {
    func testRecoveryHonorsVerifiedCustomInstallationFromRegisteredContract() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LaunchStation-RecoveryTests/\(UUID().uuidString)")
        let customApp = root.appendingPathComponent("Custom Applications/Launch Station.app")
        let helper = customApp.appendingPathComponent("Contents/Helpers/launchstationd")
        let agent = root.appendingPathComponent("Library/LaunchAgents/test.plist")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let original = try ServiceRegistration.render(template: template, app: customApp, home: root)
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agent.path)
        var verifiedCustom = false
        XCTAssertNoThrow(try ServiceRegistration.restoreIfNeeded(agentURL: agent, home: root, installedApp: root.appendingPathComponent("Applications/Launch Station.app"), verifyBundle: { candidate in
            guard candidate.path == customApp.path else { throw LauncherAPIError.serviceUnavailable("wrong installation") }
            verifiedCustom = true
        }))
        XCTAssertTrue(verifiedCustom)
        XCTAssertEqual(try Data(contentsOf: agent), original)
        XCTAssertThrowsError(try ServiceRegistration.restoreIfNeeded(agentURL: agent, home: root, verifyBundle: { _ in
            throw LauncherAPIError.serviceUnavailable("untrusted signer")
        }))
        XCTAssertEqual(try Data(contentsOf: agent), original, "A rejected custom installation must never redirect the service")
    }

    func testRecoveryFollowsCanonicalInstalledClientButNeverRegistersPreview() {
        let home = URL(fileURLWithPath: "/Users/test")
        let userCLI = home.appendingPathComponent("Applications/Launch Station.app/Contents/Resources/bin/launch")
        XCTAssertEqual(ServiceRegistration.recoveryBundleURL(executable: userCLI, home: home).path, "/Users/test/Applications/Launch Station.app")
        let preview = home.appendingPathComponent("project/dist/Launch Station.app/Contents/MacOS/LaunchStation")
        XCTAssertEqual(ServiceRegistration.recoveryBundleURL(executable: preview, home: home).path, "/Applications/Launch Station.app")
    }

    private var template: Data {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try Data(contentsOf: root.appendingPathComponent("Resources/com.jakemawson.launchstation.service.plist"))
        }
    }

    func testRenderedJobRemainsDictionaryWithOneDaemonAndAutomaticRestart() throws {
        let app = URL(fileURLWithPath: "/Applications/Launch Station.app")
        let home = URL(fileURLWithPath: "/Users/a & b")
        let rendered = try ServiceRegistration.render(template: template, app: app, home: home)
        let job = try XCTUnwrap(PropertyListSerialization.propertyList(from: rendered, format: nil) as? [String: Any])
        XCTAssertEqual(job["Label"] as? String, LauncherPaths.launchAgentLabel)
        XCTAssertEqual(job["ProgramArguments"] as? [String], [app.appendingPathComponent("Contents/Helpers/launchstationd").path])
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(job["KeepAlive"] as? Bool, true)
        XCTAssertEqual(job["StandardOutPath"] as? String, "/Users/a & b/Library/Logs/Launch Station/service.log")
        XCTAssertFalse(String(decoding: rendered, as: UTF8.self).contains("__LAUNCH_STATION_HOME__"))
    }

    func testMissingAndObservedArrayRegistrationAreRepairedAndOriginalPreserved() throws {
        for damaged in [false, true] {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LaunchStation-RecoveryTests/\(UUID().uuidString)")
            let app = root.appendingPathComponent("Launch Station.app")
            let agent = root.appendingPathComponent("Library/LaunchAgents/test.plist")
            let bundled = app.appendingPathComponent("Contents/Resources/LaunchStationLaunchAgent.plist")
            try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try template.write(to: bundled)
            let original = try PropertyListSerialization.data(fromPropertyList: ["/Applications/Launch Station.app/Contents/Helpers/launchstationd"], format: .xml, options: 0)
            if damaged {
                try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: agent)
            }
            var verified = false
            try ServiceRegistration.restoreIfNeeded(agentURL: agent, home: root, installedApp: app, verifyBundle: { _ in verified = true })
            XCTAssertTrue(verified)
            let job = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? [String: Any])
            XCTAssertEqual(job["Label"] as? String, LauncherPaths.launchAgentLabel)
            XCTAssertEqual(job["KeepAlive"] as? Bool, true)
            let backups = try FileManager.default.contentsOfDirectory(at: agent.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
            XCTAssertEqual(backups.count, damaged ? 1 : 0)
            if let backup = backups.first { XCTAssertEqual(try Data(contentsOf: backup), original) }
        }
    }

    func testRecoveryRefusesSymlinkAndUnverifiedBundleWithoutChangingOriginal() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LaunchStation-RecoveryTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original")
        let data = Data("not a plist".utf8)
        try data.write(to: original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try ServiceRegistration.restoreIfNeeded(agentURL: link, home: root, verifyBundle: { _ in XCTFail("Must reject the symlink first") }))
        XCTAssertThrowsError(try ServiceRegistration.restoreIfNeeded(agentURL: original, home: root, verifyBundle: { _ in throw LauncherAPIError.serviceUnavailable("bad signature") }))
        XCTAssertEqual(try Data(contentsOf: original), data)
    }

    func testConcurrentBootstrapWinnerIsAcceptedAndNoDestructiveKickstartIsUsed() throws {
        var calls: [[String]] = []
        var repairs = 0
        try LauncherPaths.ensureServiceRegistered(run: { arguments in
            calls.append(arguments)
            return (calls.count == 4 ? 0 : 113, "missing or concurrent bootstrap")
        }, restore: { repairs += 1 })
        XCTAssertEqual(calls.map { $0[0] }, ["kickstart", "print", "bootstrap", "kickstart"])
        XCTAssertEqual(repairs, 1)
        XCTAssertFalse(calls.flatMap { $0 }.contains("-k"))
    }

    func testLiveJobIsNeverRewrittenOrBootedOut() throws {
        var calls = 0
        XCTAssertThrowsError(try LauncherPaths.ensureServiceRegistered(run: { _ in
            calls += 1
            return (calls == 1 ? 1 : 0, "failed to kickstart live job")
        }, restore: { XCTFail("Must preserve loaded service") }))
        XCTAssertEqual(calls, 2)
    }

    func testHealthyJobNeedsNoRegistrationChanges() throws {
        var calls = 0
        try LauncherPaths.ensureServiceRegistered(run: { _ in calls += 1; return (0, "") }, restore: { XCTFail("No repair needed") })
        XCTAssertEqual(calls, 1)
    }
}
