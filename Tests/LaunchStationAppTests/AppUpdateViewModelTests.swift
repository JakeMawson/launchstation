import Foundation
import XCTest
@testable import LaunchStationApp
@testable import LauncherCore

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
    func testBusyDaemonPreventsReplacement() async {
        let updater = RecordingHomebrewUpdater()
        let maintenance = FixtureMaintenance(busy: true)
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater, maintenance: maintenance)
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        XCTAssertEqual(updater.installCount, 0)
        let events = await maintenance.events
        XCTAssertEqual(events, ["prepare"])
    }

    func testSuccessfulUpdateHoldsGateAndBlocksNewDraftsUntilRelaunch() async {
        let updater = RecordingHomebrewUpdater()
        updater.shouldFail = false
        let maintenance = FixtureMaintenance()
        let application = FixtureApplication(version: "99.0.0")
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater, maintenance: maintenance, application: application)
        updater.duringInstall = {
            XCTAssertTrue(viewModel.isInstallingAppUpdate)
            viewModel.presentManualLauncherDraft()
            viewModel.setArgumentsText("unsaved", for: UUID())
            XCTAssertNil(viewModel.externalDraftPresentation)
            XCTAssertTrue(viewModel.runtimeArgumentText.isEmpty)
        }
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        let events = await maintenance.events
        XCTAssertEqual(events, ["prepare", "cancel"])
        XCTAssertEqual(updater.installCount, 1)
        XCTAssertEqual(application.relaunchCount, 1)
    }

    func testFailedInstallReleasesGateAndReenablesEditing() async {
        let updater = RecordingHomebrewUpdater()
        let maintenance = FixtureMaintenance()
        let application = FixtureApplication(version: "99.0.0")
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater, maintenance: maintenance, application: application)
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        let events = await maintenance.events
        XCTAssertEqual(events, ["prepare", "cancel"])
        XCTAssertFalse(viewModel.isInstallingAppUpdate)
        XCTAssertEqual(application.relaunchCount, 0)
        viewModel.presentManualLauncherDraft()
        XCTAssertNotNil(viewModel.externalDraftPresentation)
    }

    func testVersionMismatchDoesNotRelaunchAndReleasesGate() async {
        let updater = RecordingHomebrewUpdater()
        updater.shouldFail = false
        let maintenance = FixtureMaintenance()
        let application = FixtureApplication(version: "1.0.0")
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater, maintenance: maintenance, application: application)
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        let events = await maintenance.events
        XCTAssertEqual(events, ["prepare", "cancel"])
        XCTAssertEqual(application.relaunchCount, 0)
    }

    func testLegacyNonpersistentGateIsRejectedBeforeReplacement() async {
        let updater = RecordingHomebrewUpdater()
        let maintenance = FixtureMaintenance(legacy: true)
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater, maintenance: maintenance)
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        let events = await maintenance.events
        XCTAssertEqual(events, ["prepare", "cancel"])
        XCTAssertEqual(updater.installCount, 0)
    }

    func testUnavailableDaemonMustPreventInstallerFromStarting() async {
        let updater = RecordingHomebrewUpdater()
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater)
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        XCTAssertEqual(updater.installCount, 0, "No replacement may start without an idle daemon reservation")
    }

    func testOpenDraftMustPreventInstallerFromStarting() async {
        let updater = RecordingHomebrewUpdater()
        let viewModel = makeViewModel(client: FixedUpdateClient(release: .init(tagName: "99.0.0")), automaticUpdatesEnabled: false, updater: updater)
        viewModel.presentManualLauncherDraft()
        await viewModel.checkForAppUpdate()
        await viewModel.installAppUpdate()
        XCTAssertEqual(updater.installCount, 0, "An update must not discard the user's draft")
        XCTAssertNotNil(viewModel.externalDraftPresentation)
    }

    func testAutomaticUpdatePreparationDefaultsOnButPreservesAnExplicitOptOut() {
        let defaultedViewModel = makeViewModel(client: FailingUpdateClient())
        XCTAssertTrue(defaultedViewModel.automaticAppUpdatesEnabled)

        let optOutViewModel = makeViewModel(
            client: FailingUpdateClient(),
            automaticUpdatesEnabled: false
        )
        XCTAssertFalse(optOutViewModel.automaticAppUpdatesEnabled)
    }

    func testUnavailableCheckKeepsTheDefaultCurrentState() async throws {
        let viewModel = makeViewModel(client: FailingUpdateClient())

        await viewModel.checkForAppUpdate()

        guard case let .current(version, lastChecked, note) = viewModel.appUpdateStatus else {
            return XCTFail("An unavailable check must keep the quiet current state")
        }
        XCTAssertEqual(version, LauncherRuntimeVersion.current())
        XCTAssertNotNil(lastChecked)
        XCTAssertEqual(note, "Couldn’t reach the update service. Launch Station will check again later.")
    }

    func testNewerReleaseShowsAnAvailableUpdateWithoutStartingHomebrew() async throws {
        let currentVersion = try XCTUnwrap(AppUpdateVersion(LauncherRuntimeVersion.current()))
        let newerVersion = "\(currentVersion.components[0] + 1).0.0"
        let release = AppUpdateRelease(
            tagName: "v\(newerVersion)",
            releaseNotes: "Adds named browser endpoints."
        )
        let viewModel = makeViewModel(
            client: FixedUpdateClient(release: release),
            automaticUpdatesEnabled: false
        )

        await viewModel.checkForAppUpdate()

        guard case let .available(receivedRelease, message) = viewModel.appUpdateStatus else {
            return XCTFail("A newer release must become available for the user to choose")
        }
        XCTAssertEqual(receivedRelease, release)
        XCTAssertNil(message)
    }

    private func makeViewModel(
        client: any AppUpdateChecking,
        automaticUpdatesEnabled: Bool? = nil,
        updater: any HomebrewCaskUpdating = FailingHomebrewUpdater(),
        maintenance: (any AppUpdateMaintenance)? = nil,
        application: (any AppUpdateApplicationLifecycle)? = nil
    ) -> LauncherViewModel {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchStationAppTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("service.json")
        let defaults = UserDefaults(suiteName: "LaunchStationAppTests.\(UUID().uuidString)")!
        if let automaticUpdatesEnabled {
            defaults.set(automaticUpdatesEnabled, forKey: "launchstation.appUpdates.automaticEnabled")
        }
        return LauncherViewModel(
            client: LauncherAPIClient(metadataURL: metadataURL, session: .shared, serviceKickstarter: { throw LauncherAPIError.serviceUnavailable("isolated test daemon unavailable") }),
            appUpdateClient: client,
            homebrewUpdater: updater,
            defaults: defaults,
            updateMaintenance: maintenance,
            updateApplication: application
        )
    }
}

@MainActor
private final class RecordingHomebrewUpdater: HomebrewCaskUpdating {
    var installCount = 0
    var shouldFail = true
    var duringInstall: (() -> Void)?
    func stage() async throws {}
    func install() async throws {
        installCount += 1
        duringInstall?()
        if shouldFail { throw URLError(.cannotConnectToHost) }
    }
}

private actor FixtureMaintenance: AppUpdateMaintenance {
    let busy: Bool
    let legacy: Bool
    var events: [String] = []
    init(busy: Bool = false, legacy: Bool = false) { self.busy = busy; self.legacy = legacy }
    func prepareUpgrade(ownerPID: Int32?) async throws -> UpgradeMaintenanceReservation {
        events.append("prepare")
        if busy { throw LauncherAPIError.server(status: 409, code: "conflict", message: "in-flight compound launch") }
        return .init(reservationToken: "fixture-only", expiresAt: Date().addingTimeInterval(900), ownerPID: legacy ? nil : ownerPID)
    }
    func cancelUpgrade(reservationToken: String) async throws -> EmptyResponse {
        XCTAssertEqual(reservationToken, "fixture-only")
        events.append("cancel")
        return EmptyResponse()
    }
}

@MainActor
private final class FixtureApplication: AppUpdateApplicationLifecycle {
    let version: String
    var relaunchCount = 0
    init(version: String) { self.version = version }
    func installedVersion() -> String { version }
    func relaunch() async throws { relaunchCount += 1 }
}

private struct FixedUpdateClient: AppUpdateChecking {
    var release: AppUpdateRelease

    func latestRelease() async throws -> AppUpdateRelease { release }
}

private struct FailingUpdateClient: AppUpdateChecking {
    func latestRelease() async throws -> AppUpdateRelease {
        throw URLError(.cannotConnectToHost)
    }
}

private struct FailingHomebrewUpdater: HomebrewCaskUpdating {
    func stage() async throws { throw URLError(.cannotFindHost) }
    func install() async throws { throw URLError(.cannotFindHost) }
}
