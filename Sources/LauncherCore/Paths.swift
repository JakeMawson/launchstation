import Darwin
import Foundation

public enum LauncherPaths {
    public static let launchAgentLabel = "com.jakemawson.launchstation.service"

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public static var defaultStateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["LAUNCH_STATION_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Launch Station", isDirectory: true)
    }

    public static var databaseURL: URL {
        defaultStateDirectory.appendingPathComponent("launcher.sqlite3")
    }

    public static var serviceMetadataURL: URL {
        defaultStateDirectory.appendingPathComponent("service.json")
    }

    public static var runsDirectory: URL {
        defaultStateDirectory.appendingPathComponent("Runs", isDirectory: true)
    }

    public static var logDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Launch Station", isDirectory: true)
    }

    public static var launchAgentURL: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func atomicWrite(
        _ data: Data,
        to url: URL,
        permissions: Int,
        createParentDirectories: Bool = true
    ) throws {
        if createParentDirectories {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    public static func kickstartService() throws {
        guard ProcessInfo.processInfo.environment["LAUNCH_STATION_STATE_DIR"] == nil else {
            throw LauncherAPIError.serviceUnavailable("An isolated state directory requires its own explicitly managed daemon.")
        }
        try ensureServiceRegistered(run: runLaunchctl, restore: { try ServiceRegistration.restoreIfNeeded() })
    }

    static func ensureServiceRegistered(
        run: ([String]) throws -> (status: Int32, message: String),
        restore: () throws -> Void
    ) throws {
        // Never use `-k` here: clients may still be reading the previous daemon's metadata while
        // launchd has already started a replacement that is reconciling persisted sessions. A
        // destructive kickstart from a polling GUI could otherwise kill every replacement before
        // it publishes fresh metadata. Plain kickstart starts an idle job and leaves a live one.
        let initialKickstart = try run(serviceKickstartArguments())
        if initialKickstart.status == 0 { return }

        // A user may terminate the daemon by unloading its job while leaving the installed
        // LaunchAgent intact. Recover that exact installed definition, then ask launchd to start
        // the exact label again. A concurrent client may win the bootstrap race, so the final
        // kickstart is authoritative rather than the bootstrap exit status by itself.
        // A loaded job must never be replaced/booted out by client recovery. Only repair
        // the on-disk definition after proving registration is absent.
        let loaded = try run(["print", "gui/\(getuid())/\(launchAgentLabel)"])
        guard loaded.status != 0 else {
            throw LauncherAPIError.serviceUnavailable(initialKickstart.message)
        }
        try restore()
        let bootstrap = try run(serviceBootstrapArguments())
        let recoveredKickstart = try run(serviceKickstartArguments())
        guard recoveredKickstart.status == 0 else {
            let detail = bootstrap.status == 0 ? recoveredKickstart.message : "\(bootstrap.message); \(recoveredKickstart.message)"
            throw LauncherAPIError.serviceUnavailable(detail)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + 5) == .success else {
            // This is the exact short-lived launchctl child we created, never the daemon.
            process.terminate()
            if completed.wait(timeout: .now() + 1) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            throw LauncherAPIError.serviceUnavailable("launchctl did not respond within five seconds; recovery will retry.")
        }
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.flatMap { $0.isEmpty ? nil : $0 } ?? "launchctl failed"
        return (process.terminationStatus, normalizedMessage)
    }

    static func serviceKickstartArguments(userID: uid_t = getuid()) -> [String] {
        ["kickstart", "gui/\(userID)/\(launchAgentLabel)"]
    }

    static func serviceBootstrapArguments(
        userID: uid_t = getuid(),
        launchAgentURL: URL = LauncherPaths.launchAgentURL
    ) -> [String] {
        ["bootstrap", "gui/\(userID)", launchAgentURL.path]
    }
}
