import Foundation
import XCTest
@testable import LauncherCore
@testable import LauncherDaemon

final class UpgradeMaintenanceTests: XCTestCase {
    private func request(_ path: String, body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: "POST", target: path, path: path, query: [:], headers: [:], body: body, requestID: "test")
    }

    func testInstallerGateSurvivesDaemonReplacementAndCancelsExactly() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LaunchStation-UpgradeTests/\(UUID().uuidString)")
        try LauncherPaths.ensurePrivateDirectory(root)
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("fixture.sqlite3"))
        let journal = root.appendingPathComponent("upgrade.json")
        let supervisor = ProcessSupervisor(runtimeDirectory: root)
        let first = LauncherService(store: store, supervisor: supervisor, upgradeJournalURL: journal)
        let prepared = await first.handle(request("/v1/maintenance/upgrade/prepare", body: try LauncherJSON.encoder().encode(UpgradeMaintenancePrepareRequest(ownerPID: ProcessInfo.processInfo.processIdentifier))))
        XCTAssertEqual(prepared.status, 201)
        let reservation = try LauncherJSON.decoder().decode(UpgradeMaintenanceReservation.self, from: prepared.body)
        XCTAssertEqual(reservation.ownerPID, ProcessInfo.processInfo.processIdentifier)
        let replacement = LauncherService(store: store, supervisor: supervisor, upgradeJournalURL: journal)
        // Expire the timestamp while keeping the exact installer alive: a slow
        // Homebrew operation must not silently lose its mutation barrier.
        struct Journal: Codable {
            var reservation: UpgradeMaintenanceReservation?
            var owner: ProcessBirthIdentity?
        }
        var saved = try LauncherJSON.decoder().decode(Journal.self, from: Data(contentsOf: journal))
        saved.reservation?.expiresAt = Date.distantPast
        try LauncherPaths.atomicWrite(LauncherJSON.encoder().encode(saved), to: journal, permissions: 0o600)
        let blocked = await replacement.handle(request("/v1/projects/init"))
        XCTAssertEqual(blocked.status, 409)
        let wrong = await replacement.handle(request("/v1/maintenance/upgrade/cancel", body: try LauncherJSON.encoder().encode(UpgradeMaintenanceCancelRequest(reservationToken: "wrong"))))
        XCTAssertEqual(wrong.status, 409)
        let cancelled = await replacement.handle(request("/v1/maintenance/upgrade/cancel", body: try LauncherJSON.encoder().encode(UpgradeMaintenanceCancelRequest(reservationToken: reservation.reservationToken))))
        XCTAssertEqual(cancelled.status, 200)
        let after = await replacement.handle(request("/v1/maintenance/upgrade/prepare"))
        XCTAssertEqual(after.status, 201)
    }

    func testCorruptPersistentGateFailsClosed() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LaunchStation-UpgradeTests/\(UUID().uuidString)")
        try LauncherPaths.ensurePrivateDirectory(root)
        let store = try SQLiteStore(databaseURL: root.appendingPathComponent("fixture.sqlite3"))
        let journal = root.appendingPathComponent("upgrade.json")
        try Data("corrupt".utf8).write(to: journal)
        let service = LauncherService(store: store, supervisor: ProcessSupervisor(runtimeDirectory: root), upgradeJournalURL: journal)
        let response = await service.handle(request("/v1/projects/init"))
        XCTAssertNotEqual(response.status, 201)
        XCTAssertTrue(try store.listProjects().isEmpty)
    }

    func testStartingRunningAndStoppingSessionsRefuseUpgrade() async throws {
        for state in [SessionState.starting, .running, .stopping] {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/LaunchStation-UpgradeTests/\(UUID().uuidString)")
            try LauncherPaths.ensurePrivateDirectory(root)
            let store = try SQLiteStore(databaseURL: root.appendingPathComponent("fixture.sqlite3"))
            let project = try store.createProject(.init(displayName: "Fixture", directory: root.path))
            let action = LaunchAction(name: "first", normalizedName: "first", description: "No process is executed", runner: .process, executable: "/usr/bin/true")
            let launcher = try store.createLauncher(.init(projectID: project.id, name: "Fixture", normalizedName: "fixture", description: "Fixture", actions: [action]))
            _ = try store.createSession(.init(launcherID: launcher.id, launcherName: launcher.name, launcherRevision: launcher.revision, state: state))
            let service = LauncherService(store: store, supervisor: ProcessSupervisor(runtimeDirectory: root), upgradeJournalURL: root.appendingPathComponent("upgrade.json"))
            let response = await service.handle(request("/v1/maintenance/upgrade/prepare", body: try LauncherJSON.encoder().encode(UpgradeMaintenancePrepareRequest(ownerPID: ProcessInfo.processInfo.processIdentifier))))
            XCTAssertEqual(response.status, 409, "Must refuse \(state)")
        }
    }
}
