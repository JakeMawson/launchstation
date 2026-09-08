import Foundation
import XCTest
@testable import LaunchStationApp
@testable import LauncherCore

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
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
        let release = AppUpdateRelease(
            tagName: "v1.3.7",
            releaseNotes: "Adds named browser endpoints."
        )
        let viewModel = makeViewModel(client: FixedUpdateClient(release: release))

        await viewModel.checkForAppUpdate()

        guard case let .available(receivedRelease, message) = viewModel.appUpdateStatus else {
            return XCTFail("A newer release must become available for the user to choose")
        }
        XCTAssertEqual(receivedRelease, release)
        XCTAssertNil(message)
    }

    private func makeViewModel(client: any AppUpdateChecking) -> LauncherViewModel {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchStationAppTests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("service.json")
        let defaults = UserDefaults(suiteName: "LaunchStationAppTests.\(UUID().uuidString)")!
        return LauncherViewModel(
            client: LauncherAPIClient(metadataURL: metadataURL),
            appUpdateClient: client,
            homebrewUpdater: FailingHomebrewUpdater(),
            defaults: defaults
        )
    }
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
