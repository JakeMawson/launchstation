import Foundation
import XCTest
@testable import LauncherCore

final class LauncherRuntimeVersionTests: XCTestCase {
    private var fixtureApplicationURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("versioned-bundle", isDirectory: true)
            .appendingPathComponent("Launch Station.app", isDirectory: true)
    }

    func testPackagedHelperAndApplicationReadEnclosingApplicationVersion() {
        let helperExecutable = fixtureApplicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("launchstationd", isDirectory: false)
        let applicationExecutable = fixtureApplicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("LaunchStation", isDirectory: false)

        // The deliberately non-development version proves both packaged executable paths
        // read the enclosing app's Info.plist rather than a fixed service version.
        let helperVersion = LauncherRuntimeVersion.version(forExecutableURL: helperExecutable)
        let applicationVersion = LauncherRuntimeVersion.version(forExecutableURL: applicationExecutable)
        XCTAssertEqual(helperVersion, "9.8.7")
        XCTAssertEqual(applicationVersion, "9.8.7")

        // The daemon carries this one resolved value into both its on-disk metadata and
        // health/catalog status, so a package version can never be reported as the fallback.
        let metadata = ServiceMetadata(
            endpoint: "http://127.0.0.1:9876",
            token: "test-token",
            pid: 42,
            startedAt: Date(timeIntervalSince1970: 0),
            version: helperVersion
        )
        let status = ServiceStatus(
            version: helperVersion,
            pid: 42,
            startedAt: Date(timeIntervalSince1970: 0),
            endpoint: "http://127.0.0.1:9876"
        )
        XCTAssertEqual(metadata.version, "9.8.7")
        XCTAssertEqual(status.version, "9.8.7")
    }

    func testSourceBuildPathUsesDevelopmentFallback() {
        let sourceBuildExecutable = URL(fileURLWithPath: "/tmp/launchstation/.build/debug/launchstationd")
        XCTAssertEqual(
            LauncherRuntimeVersion.version(forExecutableURL: sourceBuildExecutable),
            LauncherRuntimeVersion.developmentFallback
        )
    }

    func testCurrentSourceTestExecutableUsesDevelopmentFallback() {
        // Exercise the real Bundle.main executable URL representation. A synthetic
        // path-backed URL does not reproduce the ancestor-walk failure this guards.
        XCTAssertEqual(
            LauncherRuntimeVersion.current(),
            LauncherRuntimeVersion.developmentFallback
        )
    }
}
