import AppKit
import Foundation
import LauncherCore

protocol AppUpdateChecking {
    func latestRelease() async throws -> AppUpdateRelease
}

protocol HomebrewCaskUpdating {
    func stage() async throws
    func install() async throws
}

protocol AppUpdateMaintenance: Sendable {
    func prepareUpgrade(ownerPID: Int32?) async throws -> UpgradeMaintenanceReservation
    func cancelUpgrade(reservationToken: String) async throws -> EmptyResponse
}

extension LauncherAPIClient: AppUpdateMaintenance {}

@MainActor
protocol AppUpdateApplicationLifecycle {
    func installedVersion() -> String
    func relaunch() async throws
}

struct RunningAppUpdateApplication: AppUpdateApplicationLifecycle {
    func installedVersion() -> String { LauncherRuntimeVersion.current() }

    func relaunch() async throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            throw AppUpdateError.relaunchFailed("The running app is not installed as an application bundle.")
        }
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.05; done; exec /usr/bin/open -n \"$2\"",
            "launchstation-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            bundleURL.path,
        ]
        relauncher.standardInput = FileHandle.nullDevice
        relauncher.standardOutput = FileHandle.nullDevice
        relauncher.standardError = FileHandle.nullDevice
        do { try relauncher.run() }
        catch { throw AppUpdateError.relaunchFailed(error.localizedDescription) }
        NSApp.terminate(nil)
    }
}

enum AppUpdateStatus: Equatable {
    case current(version: String, lastChecked: Date?, note: String?)
    case checking(version: String)
    case available(release: AppUpdateRelease, message: String?)
    case staging(release: AppUpdateRelease)
    case readyToInstall(release: AppUpdateRelease)
    case installing(release: AppUpdateRelease)
    case relaunching(release: AppUpdateRelease)

    var release: AppUpdateRelease? {
        switch self {
        case .available(let release, _), .staging(let release), .readyToInstall(let release),
             .installing(let release), .relaunching(let release):
            return release
        case .current, .checking:
            return nil
        }
    }
}

enum AppUpdateError: LocalizedError {
    case unsafeServiceVersion
    case unavailableHomebrew
    case invalidLatestRelease
    case unexpectedResponse(Int)
    case commandFailed(command: String, status: Int32, output: String)
    case installedVersionDidNotAdvance(expected: String, actual: String)
    case relaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeServiceVersion:
            return "The running service cannot preserve an installer-owned upgrade gate. Restart the updated service before trying again."
        case .unavailableHomebrew:
            return "Homebrew is required to install Launch Station updates."
        case .invalidLatestRelease:
            return "The latest-release response did not contain a supported numeric version."
        case .unexpectedResponse(let status):
            return "The update service returned HTTP \(status)."
        case .commandFailed(let command, let status, let output):
            let detail = output.isEmpty ? "No diagnostic output was returned." : output
            return "\(command) exited with status \(status). \(detail)"
        case .installedVersionDidNotAdvance(let expected, let actual):
            return "Homebrew finished, but the installed bundle reports \(actual) instead of at least \(expected)."
        case .relaunchFailed(let message):
            return "The updated app was installed, but could not be reopened automatically: \(message)"
        }
    }
}

struct GitHubReleaseUpdateClient {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/JakeMawson/launchstation/releases/latest")!

    var session: URLSession = .shared

    func latestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LaunchStation/\(LauncherRuntimeVersion.current())", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidLatestRelease
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppUpdateError.unexpectedResponse(http.statusCode)
        }
        let release = try JSONDecoder().decode(AppUpdateRelease.self, from: data)
        guard !release.isPrerelease, release.version != nil else {
            throw AppUpdateError.invalidLatestRelease
        }
        return release
    }
}

extension GitHubReleaseUpdateClient: AppUpdateChecking {}

struct HomebrewCaskUpdater {
    static let caskIdentifier = "JakeMawson/tap/launchstation"
    private static let outputLimit = 24_576

    func stage() async throws {
        _ = try await run(arguments: ["update"])
        _ = try await run(arguments: ["fetch", "--cask", Self.caskIdentifier])
    }

    func install() async throws {
        _ = try await run(arguments: ["upgrade", "--cask", Self.caskIdentifier])
    }

    private func run(arguments: [String]) async throws -> String {
        guard let executableURL = brewExecutableURL() else {
            throw AppUpdateError.unavailableHomebrew
        }
        let result = try await ProcessOutput.run(
            executableURL: executableURL,
            arguments: arguments,
            maximumOutputBytes: Self.outputLimit
        )
        guard result.status == 0 else {
            throw AppUpdateError.commandFailed(
                command: "brew \(arguments.joined(separator: " "))",
                status: result.status,
                output: result.output
            )
        }
        return result.output
    }

    private func brewExecutableURL() -> URL? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map { URL(fileURLWithPath: $0) }
        return candidates.first { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        }
    }
}

extension HomebrewCaskUpdater: HomebrewCaskUpdating {}

private enum ProcessOutput {
    struct Result {
        var status: Int32
        var output: String
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var data = Data()

        init(maximumBytes: Int) {
            self.maximumBytes = max(1, maximumBytes)
        }

        func append(_ next: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = maximumBytes - data.count
            if remaining > 0 { data.append(next.prefix(remaining)) }
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return data.count >= maximumBytes ? value + "\n[output truncated]" : value
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        maximumOutputBytes: Int
    ) async throws -> Result {
        let process = Process()
        let pipe = Pipe()
        let output = Buffer(maximumBytes: maximumOutputBytes)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let next = handle.availableData
            if !next.isEmpty { output.append(next) }
        }

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe.fileHandleForWriting
        process.standardError = pipe.fileHandleForWriting

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completed in
                try? pipe.fileHandleForWriting.close()
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                try? pipe.fileHandleForReading.close()
                continuation.resume(returning: Result(status: completed.terminationStatus, output: output.string()))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }
}
