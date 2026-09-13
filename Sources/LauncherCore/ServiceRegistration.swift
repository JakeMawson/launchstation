import Darwin
import Foundation
import Security

/// Repairs only Launch Station's own per-user registration. Never unload a live job or
/// infer a process to terminate from stale metadata. launchd remains the sole daemon owner.
enum ServiceRegistration {
    static func restoreIfNeeded(
        agentURL: URL = LauncherPaths.launchAgentURL,
        home: URL = LauncherPaths.homeDirectory,
        installedApp: URL = recoveryBundleURL(),
        verifyBundle: (URL) throws -> Void = verifyInstalledBundle
    ) throws {
        try requireSafePath(agentURL, allowMissing: true)
        let existing = try? Data(contentsOf: agentURL)
        let value = existing.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        var installedApp = installedApp
        if let dictionary = value as? [String: Any],
           dictionary["Label"] as? String == LauncherPaths.launchAgentLabel,
           dictionary["AssociatedBundleIdentifiers"] as? [String] == ["com.jakemawson.launchstation"],
           let arguments = dictionary["ProgramArguments"] as? [String], arguments.count == 1,
           let program = arguments.first, program.hasPrefix("/"),
           program.hasSuffix("/Contents/Helpers/launchstationd") {
            let candidate = URL(fileURLWithPath: program).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            // The installed contract, not a preview's executable path, selects a custom
            // location. Verify the fixed publisher and complete bundle before trusting it.
            // A rejected custom target never silently switches to a different installation.
            try requireSafePath(candidate, allowMissing: false)
            try requireSafePath(URL(fileURLWithPath: program), allowMissing: false)
            try verifyBundle(candidate)
            installedApp = candidate
        }
        if let dictionary = value as? [String: Any],
           dictionary["Label"] as? String == LauncherPaths.launchAgentLabel,
           let arguments = dictionary["ProgramArguments"] as? [String],
           arguments == [installedApp.appendingPathComponent("Contents/Helpers/launchstationd").path],
           FileManager.default.isExecutableFile(atPath: arguments[0]),
           dictionary["RunAtLoad"] as? Bool == true,
           dictionary["KeepAlive"] as? Bool == true {
            return
        }

        // A canonical installed bundle is the recovery source, not a daemon path taken
        // from corrupt/untrusted registration bytes or a temporary development preview.
        try verifyBundle(installedApp)
        let templateURL = installedApp.appendingPathComponent("Contents/Resources/LaunchStationLaunchAgent.plist")
        let template = try Data(contentsOf: templateURL)
        let replacement = try render(template: template, app: installedApp, home: home)
        let logs = home.appendingPathComponent("Library/Logs/Launch Station", isDirectory: true)
        try requireSafePath(logs, allowMissing: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            // Preserve the exact original for diagnosis/recovery; never truncate it in place.
            let backup = agentURL.deletingLastPathComponent()
                .appendingPathComponent(".\(agentURL.lastPathComponent).\(UUID().uuidString).backup")
            try LauncherPaths.atomicWrite(existing, to: backup, permissions: 0o600)
        }
        try LauncherPaths.atomicWrite(replacement, to: agentURL, permissions: 0o600)
    }

    static func recoveryBundleURL(
        executable: URL? = Bundle.main.executableURL,
        home: URL = LauncherPaths.homeDirectory
    ) -> URL {
        let userApp = home.appendingPathComponent("Applications/Launch Station.app")
        let systemApp = URL(fileURLWithPath: "/Applications/Launch Station.app")
        if let executable {
            let path = executable.resolvingSymlinksInPath().path
            for candidate in [userApp, systemApp] where path.hasPrefix(candidate.path + "/Contents/") {
                return candidate
            }
        }
        // A source build or temporary preview must not register itself as the permanent
        // daemon. Honor the supported per-user install before the system-wide fallback.
        return FileManager.default.fileExists(atPath: userApp.path) ? userApp : systemApp
    }

    static func render(template: Data, app: URL, home: URL) throws -> Data {
        guard var value = try PropertyListSerialization.propertyList(from: template, format: nil) as? [String: Any],
              value["Label"] as? String == LauncherPaths.launchAgentLabel,
              value["ProgramArguments"] is [String],
              value["AssociatedBundleIdentifiers"] as? [String] == ["com.jakemawson.launchstation"] else {
            throw LauncherAPIError.serviceUnavailable("The bundled service definition is invalid; reinstall Launch Station.")
        }
        value["ProgramArguments"] = [app.appendingPathComponent("Contents/Helpers/launchstationd").path]
        value["RunAtLoad"] = true
        value["KeepAlive"] = true
        value["ThrottleInterval"] = 5
        value["EnvironmentVariables"] = [
            "LANG": "en_US.UTF-8",
            "PATH": "\(home.path)/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        value["StandardOutPath"] = home.appendingPathComponent("Library/Logs/Launch Station/service.log").path
        value["StandardErrorPath"] = home.appendingPathComponent("Library/Logs/Launch Station/service-error.log").path
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    private static func verifyInstalledBundle(_ app: URL) throws {
        try requireSafePath(app, allowMissing: false)
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/Helpers/launchstationd").path),
              Bundle(url: app)?.bundleIdentifier == "com.jakemawson.launchstation" else {
            throw LauncherAPIError.serviceUnavailable("Install Launch Station in Applications to restore its service.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let identity = "anchor apple generic and identifier \"com.jakemawson.launchstation\" and certificate leaf[subject.OU] = \"6RWK4446NQ\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw LauncherAPIError.serviceUnavailable("The installed Launch Station signature could not be verified; reinstall the signed app.")
        }
    }

    private static func requireSafePath(_ url: URL, allowMissing: Bool) throws {
        // Keep the filesystem spelling: Foundation's URL standardization can turn
        // /private/var back into /var, which is a system symlink on macOS.
        var path = url.path
        var isLeaf = true
        while path != "/" {
            var info = stat()
            if lstat(path, &info) == 0 {
                let type = info.st_mode & S_IFMT
                guard type != S_IFLNK,
                      (!isLeaf || type == S_IFREG || type == S_IFDIR),
                      info.st_uid == getuid() || info.st_uid == 0,
                      (!isLeaf || info.st_mode & 0o022 == 0) else {
                    throw LauncherAPIError.serviceUnavailable("Unsafe service recovery path: \(path)")
                }
            } else if errno != ENOENT || (isLeaf && !allowMissing) {
                throw LauncherAPIError.serviceUnavailable("Service recovery path is unavailable: \(path)")
            }
            isLeaf = false
            path = (path as NSString).deletingLastPathComponent
        }
    }
}
