// Standalone, mocked UI harness. Compiled with the app sources excluding main.swift.
// Never contacts GitHub/Homebrew/launchd or the user's real launcher catalogue.
import AppKit
import Foundation
import LauncherCore
import SwiftUI

private struct FixtureRelease: AppUpdateChecking {
    func latestRelease() async throws -> AppUpdateRelease { .init(tagName: "99.0.0", releaseNotes: "Isolated updater verification.") }
}

private actor FixtureMaintenance: AppUpdateMaintenance {
    func prepareUpgrade(ownerPID: Int32?) async throws -> UpgradeMaintenanceReservation {
        .init(reservationToken: "visual-fixture-only", expiresAt: Date().addingTimeInterval(900), ownerPID: ownerPID)
    }
    func cancelUpgrade(reservationToken: String) async throws -> EmptyResponse { .init() }
}

@MainActor
private final class FixtureInstaller: HomebrewCaskUpdating {
    var completion: CheckedContinuation<Void, Error>?
    func stage() async throws {}
    func install() async throws { try await withCheckedThrowingContinuation { completion = $0 } }
    func fail() { completion?.resume(throwing: URLError(.notConnectedToInternet)); completion = nil }
}

private final class FixtureHTTP: URLProtocol {
    static let project = ProjectRecord(displayName: "Update safety fixture", directory: "/tmp")
    static let detail = LauncherDetail(project: project, launcher: LauncherRecord(projectID: project.id, name: "Example workspace", normalizedName: "example workspace", description: "Fictional launcher for isolated update verification.", actions: [LaunchAction(name: "Preview", normalizedName: "preview", description: "Not executed", runner: .process, executable: "/usr/bin/true")]))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let health = ServiceStatus(pid: 1, startedAt: Date(), endpoint: "http://127.0.0.1:1")
        let encoder = LauncherJSON.encoder()
        let data: Data
        switch request.url!.path {
        case "/v1/health": data = try! encoder.encode(health)
        case "/v1/snapshot": data = try! encoder.encode(CatalogSnapshot(launchers: [Self.detail], projects: [Self.project], service: health))
        case "/v1/external-processes": data = try! encoder.encode(ExternalProcessSnapshot(scannedAt: Date(), observations: [], isComplete: true))
        case "/v1/skills/status": data = try! encoder.encode(LauncherSkillStatus(skillName: "launchstation", version: "1.3.22", hosts: []))
        default: data = Data("[]".utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct AppUpdateVisualHarness: App {
    @StateObject private var model: LauncherViewModel
    private let installer: FixtureInstaller
    init() {
        let installer = FixtureInstaller()
        self.installer = installer
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAUNCH_STATION_QA_ROOT"]!)
        let metadata = root.appendingPathComponent("fixture-service.json")
        try! LauncherPaths.atomicWrite(LauncherJSON.encoder().encode(ServiceMetadata(endpoint: "http://127.0.0.1:1", token: "fixture-only", pid: 1, startedAt: Date())), to: metadata, permissions: 0o600)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureHTTP.self]
        let defaults = UserDefaults(suiteName: "LaunchStation.VisualQA.\(UUID().uuidString)")!
        defaults.set(false, forKey: "launchstation.appUpdates.automaticEnabled")
        _model = StateObject(wrappedValue: LauncherViewModel(client: LauncherAPIClient(metadataURL: metadata, session: URLSession(configuration: config)), appUpdateClient: FixtureRelease(), homebrewUpdater: installer, defaults: defaults, updateMaintenance: FixtureMaintenance()))
    }
    var body: some Scene {
        Window("Launch Station Update QA", id: "qa") {
            VStack(spacing: 0) {
                HStack {
                    Text("ISOLATED QA").font(.caption)
                    Button("Install fixture") { Task { await model.installAppUpdate() } }
                    Button("Fail fixture") { installer.fail() }
                    Button("Open draft") { model.presentManualLauncherDraft() }
                    Button("Minimum size") { NSApp.windows.first(where: { $0.title.contains("Launch Station Update QA") })?.setContentSize(NSSize(width: 820, height: 570)) }
                    Button("Default size") { NSApp.windows.first(where: { $0.title.contains("Launch Station Update QA") })?.setContentSize(NSSize(width: 1040, height: 710)) }
                }.padding(6)
                LauncherRootView(viewModel: model)
            }
        }.defaultSize(width: 1040, height: 710)
        Settings { LauncherSettingsView(viewModel: model) }
    }
}
