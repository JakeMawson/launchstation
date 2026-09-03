import CryptoKit
import Darwin
import Foundation
import LauncherCore

enum ExternalInspectionError: LocalizedError, Sendable {
    case commandUnavailable(String)
    case commandTimedOut(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandUnavailable(let message), .commandTimedOut(let message), .commandFailed(let message):
            return message
        }
    }
}

struct BoundedExternalCommandResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
}

/// Direct helper runner used only for fixed local binaries such as lsof and codex-port. It never
/// invokes a shell, bounds output, and terminates only the exact helper process it created.
struct BoundedExternalCommandRunner: Sendable {
    var maximumOutputBytes = 4 * 1_024 * 1_024

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> BoundedExternalCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ExternalInspectionError.commandUnavailable("Required helper is unavailable: \(executable.path)")
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in exitSemaphore.signal() }
        try process.run()

        let pid = process.processIdentifier
        let birthIdentity = ProcessBirthIdentity(pid: pid)?.serialized
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let stdoutBox = LockedBoundedData()
        let stderrBox = LockedBoundedData()
        let readers = DispatchGroup()
        let outputLimit = max(0, maximumOutputBytes)
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.store(Self.readBounded(from: stdout.fileHandleForReading, limit: outputLimit))
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.store(Self.readBounded(from: stderr.fileHandleForReading, limit: outputLimit))
            readers.leave()
        }

        let boundedTimeout = max(0.1, min(timeout, 30))
        var exited = exitSemaphore.wait(timeout: .now() + boundedTimeout) == .success
        if !exited {
            if ProcessBirthIdentity.matches(pid: pid, serialized: birthIdentity) {
                _ = kill(pid, SIGTERM)
            }
            exited = exitSemaphore.wait(timeout: .now() + 0.5) == .success
            if !exited, ProcessBirthIdentity.matches(pid: pid, serialized: birthIdentity) {
                // This is the exact disposable helper created above, not an observed listener.
                _ = kill(pid, SIGKILL)
                exited = exitSemaphore.wait(timeout: .now() + 1) == .success
            }
        }

        let readersTimedOut = readers.wait(timeout: .now() + 1) == .timedOut
        if readersTimedOut {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 0.25)
        }

        guard exited else {
            throw ExternalInspectionError.commandTimedOut("\(executable.lastPathComponent) did not exit within its bounded timeout.")
        }
        let capturedStdout = stdoutBox.load()
        let capturedStderr = stderrBox.load()
        return BoundedExternalCommandResult(
            status: process.terminationStatus,
            stdout: capturedStdout.data,
            stderr: capturedStderr.data,
            stdoutTruncated: capturedStdout.truncated || readersTimedOut,
            stderrTruncated: capturedStderr.truncated || readersTimedOut
        )
    }

    private static func readBounded(from handle: FileHandle, limit: Int) -> (data: Data, truncated: Bool) {
        var retained = Data()
        var truncated = false
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 64 * 1_024), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            let remaining = max(0, limit - retained.count)
            if remaining > 0 { retained.append(contentsOf: chunk.prefix(remaining)) }
            if chunk.count > remaining { truncated = true }
        }
        return (retained, truncated)
    }
}

private final class LockedBoundedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (data: Data, truncated: Bool) = (Data(), false)

    func store(_ value: (data: Data, truncated: Bool)) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct MacListenerScan: Sendable {
    var inventory: ExternalListenerInventory
    var isComplete: Bool
    var warning: String?
}

struct MacInspectedProcess: Sendable {
    var pid: Int32
    var pidStartIdentity: String
    var startedAt: Date
    var userID: UInt32
    var parentPID: Int32
    var processGroupID: Int32
    var processGroupLeaderPID: Int32?
    var processGroupLeaderStartIdentity: String?
    var executablePath: String?
    var executableIdentity: ExternalExecutableIdentity?
    var workingDirectory: String?
    var command: ExternalCommandSummary
    /// Opaque daemon-only digest over the source argv. It is used for confirmation staleness and
    /// must never be copied into an API model, UI state, log, or persistent store.
    var commandDigest: String
}

struct ExternalObservationSecurityContext: Equatable, Sendable {
    var pid: Int32
    var pidStartIdentity: String
    var userID: UInt32
    var parentPID: Int32
    var processGroupID: Int32
    var processGroupLeaderPID: Int32?
    var processGroupLeaderStartIdentity: String?
    var listenerExecutablePath: String?
    var listenerExecutableIdentity: ExternalExecutableIdentity?
    var listenerWorkingDirectory: String?
    var commandDigest: String
    var endpoints: [ExternalListenerEndpoint]
    var ownershipKind: ExternalProcessOwnershipKind
    var codexPortManagerID: String?
}

struct MacProcessInspector: Sendable {
    private let lsofURL: URL
    private let runner: BoundedExternalCommandRunner
    private let maximumAncestorDepth: Int
    private let currentUserID: UInt32

    init(
        lsofURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof"),
        maximumAncestorDepth: Int = 8,
        runner: BoundedExternalCommandRunner = BoundedExternalCommandRunner()
    ) {
        self.lsofURL = lsofURL
        self.maximumAncestorDepth = max(0, min(maximumAncestorDepth, 16))
        self.runner = runner
        currentUserID = geteuid()
    }

    func scanListeners(timeout: TimeInterval = 2) async throws -> MacListenerScan {
        let lsofURL = self.lsofURL
        let runner = self.runner
        return try await Task.detached(priority: .utility) {
            let result = try runner.run(
                executable: lsofURL,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F0pcfn"],
                timeout: timeout
            )
            let noVisibleListeners = result.status == 1 && result.stdout.isEmpty
            guard result.status == 0 || noVisibleListeners else {
                let stderr = ExternalCommandRedactor
                    .sanitizeDisplayText(String(decoding: result.stderr, as: UTF8.self), maximumScalars: 1_024)
                    .value
                throw ExternalInspectionError.commandFailed(
                    stderr.isEmpty ? "lsof listener discovery failed with status \(result.status)." : stderr
                )
            }
            let inventory = LSOFFieldParser.parse(result.stdout)
            let truncated = result.stdoutTruncated || result.stderrTruncated
            let discarded = inventory.discardedFieldCount
            let warning: String?
            if truncated {
                warning = "Listener discovery output exceeded its safety limit; some listeners may be omitted."
            } else if discarded > 0 {
                warning = "Listener discovery ignored \(discarded) malformed field\(discarded == 1 ? "" : "s")."
            } else {
                warning = nil
            }
            return MacListenerScan(
                inventory: inventory,
                isComplete: !truncated,
                warning: warning
            )
        }.value
    }

    /// Reads raw argv only inside this method and reduces it to a redacted summary plus an opaque
    /// digest before returning. Parent traversal is same-UID, same-process-group, and depth-bounded.
    func inspect(pid: Int32, shortCommand: String?) -> MacInspectedProcess? {
        guard let listener = rawProcessInfo(pid: pid) else { return nil }

        var commandSource = listener
        var depth = 0
        var visited = Set([listener.pid])
        while depth < maximumAncestorDepth,
              commandSource.parentPID > 1,
              !visited.contains(commandSource.parentPID),
              let parent = rawProcessInfo(pid: commandSource.parentPID),
              parent.userID == listener.userID,
              parent.processGroupID == listener.processGroupID {
            commandSource = parent
            visited.insert(parent.pid)
            depth += 1
            if parent.pid == listener.processGroupID { break }
        }

        let groupLeader = listener.processGroupID > 0
            ? rawProcessInfo(pid: listener.processGroupID)
            : nil
        let verifiedGroupLeader = groupLeader?.userID == listener.userID ? groupLeader : nil

        let provenance: ExternalCommandProvenance
        if commandSource.pid == listener.pid {
            provenance = .listenerProcess
        } else if commandSource.pid == listener.processGroupID {
            provenance = .processGroupLeader
        } else {
            provenance = .sameProcessGroupAncestor
        }

        let rawArguments = commandSource.userID == currentUserID
            ? processArguments(pid: commandSource.pid)
            : nil
        let command: ExternalCommandSummary
        if let rawArguments, !rawArguments.isEmpty {
            command = ExternalCommandRedactor.redact(
                argv: rawArguments,
                provenance: provenance,
                sourcePID: commandSource.pid,
                fallbackExecutable: commandSource.executablePath
            )
        } else if let executable = commandSource.executablePath {
            let sanitized = ExternalCommandRedactor.sanitizeDisplayText(executable)
            command = ExternalCommandSummary(
                executable: sanitized.value,
                displayCommand: ShellEscaping.quote(sanitized.value),
                provenance: provenance,
                sourcePID: commandSource.pid,
                contentSanitized: sanitized.changed,
                unavailableReason: commandSource.userID == currentUserID
                    ? "The process argument vector could not be read; review the complete command manually."
                    : "Full arguments are unavailable for a process owned by another user."
            )
        } else {
            let reason = commandSource.userID == currentUserID
                ? "The launch argv and executable path could not be read."
                : "Full command details are unavailable for a process owned by another user."
            command = .unavailable(shortCommand: shortCommand, reason: reason)
        }

        // The raw vector is reduced to a one-way digest here and then goes out of scope.
        let digest = commandDigest(
            arguments: rawArguments ?? [],
            executablePath: commandSource.executablePath,
            workingDirectory: commandSource.workingDirectory
        )
        return MacInspectedProcess(
            pid: listener.pid,
            pidStartIdentity: listener.startIdentity,
            startedAt: listener.startedAt,
            userID: listener.userID,
            parentPID: listener.parentPID,
            processGroupID: listener.processGroupID,
            processGroupLeaderPID: verifiedGroupLeader?.pid,
            processGroupLeaderStartIdentity: verifiedGroupLeader?.startIdentity,
            executablePath: listener.executablePath,
            executableIdentity: listener.executableIdentity,
            workingDirectory: commandSource.workingDirectory ?? listener.workingDirectory,
            command: command,
            commandDigest: digest
        )
    }

    func currentIdentity(pid: Int32, shortCommand: String? = nil) -> MacInspectedProcess? {
        inspect(pid: pid, shortCommand: shortCommand)
    }

    private struct RawProcessInfo {
        var pid: Int32
        var parentPID: Int32
        var processGroupID: Int32
        var userID: UInt32
        var startIdentity: String
        var startedAt: Date
        var executablePath: String?
        var executableIdentity: ExternalExecutableIdentity?
        var workingDirectory: String?
    }

    private func rawProcessInfo(pid: Int32) -> RawProcessInfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
        }
        guard read == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }

        let seconds = info.pbi_start_tvsec
        let microseconds = info.pbi_start_tvusec
        let executablePath = processPath(pid: pid)
        return RawProcessInfo(
            pid: pid,
            parentPID: Int32(bitPattern: info.pbi_ppid),
            processGroupID: Int32(bitPattern: info.pbi_pgid),
            userID: info.pbi_uid,
            startIdentity: "\(pid):\(seconds):\(microseconds)",
            startedAt: Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(microseconds) / 1_000_000),
            executablePath: executablePath,
            executableIdentity: executablePath.flatMap(fileIdentity),
            workingDirectory: processWorkingDirectory(pid: pid)
        )
    }

    private func processPath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro that Swift does not import.
        let capacity = Int(MAXPATHLEN) * 4
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(capacity))
        }
        guard count > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) }
        }
    }

    private func processWorkingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDVNODEPATHINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_vnodepathinfo>.size)
            )
        }
        guard read == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { characters in
                let value = String(cString: characters)
                return value.isEmpty ? nil : value
            }
        }
    }

    private func fileIdentity(path: String) -> ExternalExecutableIdentity? {
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { return nil }
        return ExternalExecutableIdentity(
            device: UInt64(bitPattern: Int64(attributes.st_dev)),
            inode: UInt64(attributes.st_ino)
        )
    }

    private func processArguments(pid: Int32) -> [String]? {
        var argMaxMIB = [Int32(CTL_KERN), Int32(KERN_ARGMAX)]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argMaxMIB, u_int(argMaxMIB.count), &argMax, &argMaxSize, nil, 0) == 0,
              argMax > 0 else { return nil }

        let capacity = min(Int(argMax), 1_048_576)
        var buffer = [UInt8](repeating: 0, count: capacity)
        var size = capacity
        var argumentsMIB = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&argumentsMIB, u_int(argumentsMIB.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0,
              size >= MemoryLayout<Int32>.size,
              size <= buffer.count else { return nil }
        buffer.removeSubrange(size..<buffer.count)

        let count = Int(
            UInt32(buffer[0])
                | UInt32(buffer[1]) << 8
                | UInt32(buffer[2]) << 16
                | UInt32(buffer[3]) << 24
        )
        guard count > 0, count <= 256 else { return nil }
        var index = MemoryLayout<Int32>.size

        // Skip the executable path and its terminating NUL, then kernel padding before argv[0].
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var totalBytes = 0
        while arguments.count < count, index <= buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            guard index <= buffer.count else { break }
            let length = index - start
            totalBytes += length
            guard totalBytes <= 256 * 1_024 else { return nil }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            if index < buffer.count { index += 1 }
        }
        return arguments.count == count ? arguments : nil
    }

    private func commandDigest(
        arguments: [String],
        executablePath: String?,
        workingDirectory: String?
    ) -> String {
        var data = Data()
        for value in [executablePath, workingDirectory].compactMap({ $0 }) + arguments {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
