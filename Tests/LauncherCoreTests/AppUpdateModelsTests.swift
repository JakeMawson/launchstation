import Foundation
import XCTest
@testable import LauncherCore

final class AppUpdateModelsTests: XCTestCase {
    func testNumericVersionsSortAcrossDifferentWidths() {
        let current = try! XCTUnwrap(AppUpdateVersion("1.3.5"))
        let next = try! XCTUnwrap(AppUpdateVersion("v1.3.6"))
        let laterMinor = try! XCTUnwrap(AppUpdateVersion("1.4"))
        let equivalent = try! XCTUnwrap(AppUpdateVersion("1.3.6.0"))

        XCTAssertLessThan(current, next)
        XCTAssertLessThan(next, laterMinor)
        XCTAssertFalse(next < equivalent)
        XCTAssertFalse(equivalent < next)
        XCTAssertNil(AppUpdateVersion("v1.3.6-beta"))
        XCTAssertNil(AppUpdateVersion("release-1.3.6"))
    }

    func testReleaseDecodingKeepsOnlyDisplayDataAndBoundsNotes() throws {
        let payload = """
        {
          "tag_name": "v1.3.6",
          "name": "Launch Station 1.3.6",
          "body": "# Update\\nAdds safe Homebrew update checks.\\nPreserves managed launchers.",
          "published_at": "2026-09-09T00:00:00Z",
          "prerelease": false
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(AppUpdateRelease.self, from: payload)
        XCTAssertEqual(release.version?.description, "1.3.6")
        XCTAssertEqual(release.conciseNotes, "Adds safe Homebrew update checks. Preserves managed launchers.")
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-09-09T00:00:00Z"))
        XCTAssertFalse(release.isPrerelease)
    }

    func testReleaseNotesAreBoundedForNativeDisplay() {
        let release = AppUpdateRelease(tagName: "1.3.6", releaseNotes: String(repeating: "x", count: 20_000))
        XCTAssertEqual(release.normalizedNotes.count, 16_000)
    }
}
