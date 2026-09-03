import Foundation

/// Resolves the version advertised by a running Launcher process.
///
/// A packaged helper does not have its own `Info.plist`: both the GUI executable
/// (`Contents/MacOS/LaunchStation`) and the daemon helper
/// (`Contents/Helpers/launchstationd`) inherit their version from the enclosing
/// application bundle. Source builds and XCTest bundles do not have that layout,
/// so they deliberately retain the minimum compatible development version.
public enum LauncherRuntimeVersion {
    public static let developmentFallback = "1.3.2"

    /// Returns the packaged application's `CFBundleShortVersionString` when this
    /// process is located inside an `.app` bundle, otherwise the development fallback.
    public static func current() -> String {
        let executableURLs = [
            Bundle.main.executableURL,
            CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
        ].compactMap { $0 }

        for executableURL in executableURLs {
            if let version = packagedVersion(forExecutableURL: executableURL) {
                return version
            }
        }
        return developmentFallback
    }

    /// Resolves a version for a specific executable path. This is public so callers
    /// that host Launcher helpers can use the same bundle contract, and so the
    /// packaged-bundle behavior can be tested without launching a daemon.
    public static func version(forExecutableURL executableURL: URL?) -> String {
        packagedVersion(forExecutableURL: executableURL) ?? developmentFallback
    }

    private static func packagedVersion(forExecutableURL executableURL: URL?) -> String? {
        guard let executableURL,
              let applicationBundleURL = enclosingApplicationBundle(for: executableURL),
              isPackagedLauncherExecutable(
                  executableURL,
                  in: applicationBundleURL
              ) else {
            return nil
        }

        let infoURL = applicationBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let values = propertyList as? [String: Any],
              let rawVersion = values["CFBundleShortVersionString"] as? String else {
            return nil
        }

        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private static func isPackagedLauncherExecutable(
        _ executableURL: URL,
        in applicationBundleURL: URL
    ) -> Bool {
        let executableParent = URL(
            fileURLWithPath: executableURL.path,
            isDirectory: false
        ).standardizedFileURL.deletingLastPathComponent()
        let contentsURL = applicationBundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let supportedExecutableDirectories = [
            contentsURL.appendingPathComponent("MacOS", isDirectory: true),
            contentsURL.appendingPathComponent("Helpers", isDirectory: true),
        ]
        return supportedExecutableDirectories.contains(executableParent)
    }

    private static func enclosingApplicationBundle(for executableURL: URL) -> URL? {
        // `Bundle.main.executableURL` can be a Foundation URL whose base/reference
        // representation does not become equal to the path-backed root URL after
        // repeatedly deleting path components. Rebuild it from its filesystem path
        // before walking so source-built executables terminate cleanly at `/`.
        var candidate = URL(
            fileURLWithPath: executableURL.path,
            isDirectory: false
        ).standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
