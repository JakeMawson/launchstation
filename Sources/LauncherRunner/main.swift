import Darwin
import Foundation

private struct RunnerLaunchSpecification: Codable {
    var schemaVersion: Int
    var runID: UUID
    var workingDirectory: String
    var executable: String?
    var arguments: [String]
    var shellCommand: String?
    var environment: [String: String]
    var portEnvironmentVariable: String?
    var hostEnvironmentVariable: String?
    var statusPath: String
    var acknowledgementPath: String?
}

private struct RunnerStatus: Codable {
    var schemaVersion: Int
    var runID: UUID
    var pid: Int32
    var processGroupID: Int32
    var pidStartIdentity: String
    var startedAt: Date
}

private struct RunnerAcknowledgement: Codable {
    var schemaVersion: Int
    var runID: UUID
    var pid: Int32
    var pidStartIdentity: String
}

private enum RunnerError: LocalizedError {
    case usage
    case invalidSchema(Int)
    case unableToCreateSession(Int32)
    case missingCommand
    case executableNotFound(String)
    case missingEnvironmentVariable(String)
    case reservedEnvironmentVariable(String)
    case invalidManagedEnvironmentAlias(String)
    case duplicateManagedEnvironmentAlias(String)
    case managedEnvironmentAliasCollision(String)
    case unableToDetermineBirthIdentity
    case unableToCreateProcessGroup(Int32)
    case unableToConfigureSpawn(String, Int32)
    case unableToSpawn(Int32)
    case invalidAcknowledgement
    case acknowledgementTimedOut

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: launchstation-runner --spec /absolute/path/to/spec.json"
        case .invalidSchema(let schema):
            return "Unsupported runner specification schema: \(schema)"
        case .unableToCreateSession(let code):
            return "Unable to create the launcher process session (errno \(code))."
        case .missingCommand:
            return "The runner specification contains no executable or shell command."
        case .executableNotFound(let executable):
            return "Executable not found in the configured PATH: \(executable)"
        case .missingEnvironmentVariable(let name):
            return "The command requires an unavailable environment variable: \(name)"
        case .reservedEnvironmentVariable(let name):
            return "\(name) is owned by codex-port and cannot be supplied in a runner specification."
        case .invalidManagedEnvironmentAlias(let name):
            return "Managed port environment alias \(name) is not a valid environment variable name."
        case .duplicateManagedEnvironmentAlias(let name):
            return "Managed port and host environment aliases must be distinct; both were \(name)."
        case .managedEnvironmentAliasCollision(let name):
            return "Managed environment alias \(name) cannot also be configured in the runner environment."
        case .unableToDetermineBirthIdentity:
            return "Unable to read the runner process birth identity."
        case .unableToCreateProcessGroup(let code):
            return "Unable to create the launcher-owned process group (errno \(code))."
        case .unableToConfigureSpawn(let operation, let code):
            return "Unable to configure the launcher child process (\(operation), error \(code))."
        case .unableToSpawn(let code):
            return "Unable to create the launcher child process (error \(code))."
        case .invalidAcknowledgement:
            return "The launcher daemon supplied an invalid runner acknowledgement."
        case .acknowledgementTimedOut:
            return "Timed out waiting for the launcher daemon to acknowledge exact process ownership."
        }
    }
}

private final class CStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointer = .allocate(capacity: count + 1)
        for (index, value) in values.enumerated() {
            pointer[index] = strdup(value)
        }
        pointer[count] = nil
    }

    deinit {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deallocate()
    }
}

private func baselinePath(home: String) -> String {
    [
        "\(home)/bin",
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")
}

private func baselineEnvironment() -> [String: String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let user = NSUserName()
    return [
        "HOME": home,
        "USER": user,
        "LOGNAME": user,
        "SHELL": "/bin/zsh",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": "en_US.UTF-8",
        "PATH": baselinePath(home: home),
    ]
}

private func isValidEnvironmentName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first,
          CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
        return false
    }
    let remainder = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    return name.unicodeScalars.dropFirst().allSatisfy { remainder.contains($0) }
}

private func processBirthIdentity(_ pid: Int32) -> String? {
    var info = proc_bsdinfo()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            pointer,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
    }
    guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
    return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}

private func expandEnvironmentReferences(_ value: String, environment: [String: String]) throws -> String {
    let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#
    let expression = try NSRegularExpression(pattern: pattern)
    let source = value as NSString
    let matches = expression.matches(in: value, range: NSRange(location: 0, length: source.length))
    var result = value
    for match in matches.reversed() {
        let name = source.substring(with: match.range(at: 1))
        guard let replacement = environment[name] else {
            throw RunnerError.missingEnvironmentVariable(name)
        }
        if let range = Range(match.range(at: 0), in: result) {
            result.replaceSubrange(range, with: replacement)
        }
    }
    return result
}

private func resolvedExecutable(
    _ executable: String,
    environment: [String: String],
    workingDirectory: String
) throws -> URL {
    let expanded = NSString(string: executable).expandingTildeInPath
    if expanded.contains("/") {
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded).standardizedFileURL
            : URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(expanded)
                .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw RunnerError.executableNotFound(executable)
        }
        return url
    }

    let path = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let base = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
        let candidate = URL(fileURLWithPath: base).appendingPathComponent(expanded)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
    }
    throw RunnerError.executableNotFound(executable)
}

private func processGroupMembers(_ groupID: Int32, excluding excludedPID: Int32) -> [Int32] {
    let type = UInt32(PROC_PGRP_ONLY)
    let group = UInt32(bitPattern: groupID)
    let requiredBytes = proc_listpids(type, group, nil, 0)
    guard requiredBytes > 0 else { return [] }

    let capacity = max(1, Int(requiredBytes) / MemoryLayout<pid_t>.size + 8)
    var pids = [pid_t](repeating: 0, count: capacity)
    let populatedBytes = pids.withUnsafeMutableBytes { buffer in
        proc_listpids(type, group, buffer.baseAddress, Int32(buffer.count))
    }
    guard populatedBytes > 0 else { return [] }
    let populatedCount = min(capacity, Int(populatedBytes) / MemoryLayout<pid_t>.size)
    return pids.prefix(populatedCount).filter { pid in
        guard pid > 0, pid != excludedPID else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

private func writeStatus(_ status: RunnerStatus, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(status)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func waitForAcknowledgement(
    at path: String,
    runID: UUID,
    pid: Int32,
    pidStartIdentity: String,
    timeoutSeconds: TimeInterval = 5
) throws {
    let url = URL(fileURLWithPath: path)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let decoder = JSONDecoder()
    while Date() < deadline {
        if let data = try? Data(contentsOf: url) {
            guard let acknowledgement = try? decoder.decode(RunnerAcknowledgement.self, from: data),
                  acknowledgement.schemaVersion == 1,
                  acknowledgement.runID == runID,
                  acknowledgement.pid == pid,
                  acknowledgement.pidStartIdentity == pidStartIdentity else {
                throw RunnerError.invalidAcknowledgement
            }
            return
        }
        usleep(10_000)
    }
    throw RunnerError.acknowledgementTimedOut
}

private func waitForChild(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        if errno != EINTR { return 126 }
    }
    let low = status & 0x7f
    if low == 0 {
        return (status >> 8) & 0xff
    }
    if low == 0x7f {
        return 126
    }
    return 128 + low
}

private func run() throws -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--spec" else { throw RunnerError.usage }

    let specificationURL = URL(fileURLWithPath: arguments[2])
    let data = try Data(contentsOf: specificationURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let specification = try decoder.decode(RunnerLaunchSpecification.self, from: data)
    guard specification.schemaVersion == 1 else {
        throw RunnerError.invalidSchema(specification.schemaVersion)
    }

    let portEnvironmentAlias = specification.portEnvironmentVariable.flatMap { value -> String? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    let hostEnvironmentAlias = specification.hostEnvironmentVariable.flatMap { value -> String? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    let managedPortRun = portEnvironmentAlias != nil || hostEnvironmentAlias != nil
    if managedPortRun {
        // codex-port already starts this executable as a session/process-group leader.
        // A direct test invocation may not, so establish a same-session group without
        // escaping the manager's ownership boundary.
        if getpgrp() != getpid(), setpgid(0, 0) != 0 {
            throw RunnerError.unableToCreateProcessGroup(errno)
        }
    } else if setsid() == -1, getpgrp() != getpid() {
        throw RunnerError.unableToCreateSession(errno)
    }

    let runnerPID = getpid()
    let processGroupID = getpgrp()
    guard let identity = processBirthIdentity(runnerPID) else {
        throw RunnerError.unableToDetermineBirthIdentity
    }

    let runnerEnvironment = ProcessInfo.processInfo.environment
    let reserved = Set(["CODEX_PORT", "CODEX_HOST", "CODEX_SERVICE_ID"])
    if let name = specification.environment.keys.first(where: { reserved.contains($0) }) {
        throw RunnerError.reservedEnvironmentVariable(name)
    }
    let managedAliases = [portEnvironmentAlias, hostEnvironmentAlias].compactMap { $0 }
    if let name = managedAliases.first(where: { !isValidEnvironmentName($0) }) {
        throw RunnerError.invalidManagedEnvironmentAlias(name)
    }
    if let name = managedAliases.first(where: { reserved.contains($0) }) {
        throw RunnerError.reservedEnvironmentVariable(name)
    }
    if let portEnvironmentAlias, portEnvironmentAlias == hostEnvironmentAlias {
        throw RunnerError.duplicateManagedEnvironmentAlias(portEnvironmentAlias)
    }
    if let name = managedAliases.first(where: { specification.environment[$0] != nil }) {
        throw RunnerError.managedEnvironmentAliasCollision(name)
    }

    let managedPort: String?
    if portEnvironmentAlias != nil {
        guard let port = runnerEnvironment["CODEX_PORT"] else {
            throw RunnerError.missingEnvironmentVariable("CODEX_PORT")
        }
        managedPort = port
    } else {
        managedPort = nil
    }
    let managedHost: String?
    if hostEnvironmentAlias != nil {
        guard let host = runnerEnvironment["CODEX_HOST"] else {
            throw RunnerError.missingEnvironmentVariable("CODEX_HOST")
        }
        managedHost = host
    } else {
        managedHost = nil
    }

    var environment = baselineEnvironment()
    var expansionEnvironment = environment
    for (name, value) in specification.environment {
        expansionEnvironment[name] = value
    }
    if let portEnvironmentAlias, let managedPort {
        expansionEnvironment["CODEX_PORT"] = managedPort
        expansionEnvironment[portEnvironmentAlias] = managedPort
    }
    if let hostEnvironmentAlias, let managedHost {
        expansionEnvironment["CODEX_HOST"] = managedHost
        expansionEnvironment[hostEnvironmentAlias] = managedHost
    }
    for (name, value) in specification.environment {
        let expanded = try expandEnvironmentReferences(value, environment: expansionEnvironment)
        environment[name] = expanded
        expansionEnvironment[name] = expanded
    }
    // Manager-owned values are applied after all configured expansion. Even if a malformed
    // specification evades upstream validation, the assigned port and host always win.
    if let portEnvironmentAlias, let managedPort {
        environment["CODEX_PORT"] = managedPort
        environment[portEnvironmentAlias] = managedPort
    }
    if let hostEnvironmentAlias, let managedHost {
        environment["CODEX_HOST"] = managedHost
        environment[hostEnvironmentAlias] = managedHost
    }

    let executable: String
    let childArguments: [String]
    if let shellCommand = specification.shellCommand {
        executable = "/bin/zsh"
        childArguments = ["-lc", shellCommand]
    } else if let configuredExecutable = specification.executable {
        executable = try expandEnvironmentReferences(configuredExecutable, environment: environment)
        childArguments = try specification.arguments.map {
            try expandEnvironmentReferences($0, environment: environment)
        }
    } else {
        throw RunnerError.missingCommand
    }

    let executableURL = try resolvedExecutable(
        executable,
        environment: environment,
        workingDirectory: specification.workingDirectory
    )
    let argv = CStringVector([executableURL.path] + childArguments)
    let envp = CStringVector(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" })

    // The status describes this long-lived group leader. The spawned command is
    // forced into this exact group so codex-port retains one lifecycle boundary.
    try writeStatus(
        RunnerStatus(
            schemaVersion: 1,
            runID: specification.runID,
            pid: runnerPID,
            processGroupID: processGroupID,
            pidStartIdentity: identity,
            startedAt: Date()
        ),
        to: specification.statusPath
    )
    if let acknowledgementPath = specification.acknowledgementPath {
        try waitForAcknowledgement(
            at: acknowledgementPath,
            runID: specification.runID,
            pid: runnerPID,
            pidStartIdentity: identity
        )
    }

    var spawnAttributes: posix_spawnattr_t?
    var fileActions: posix_spawn_file_actions_t?
    var attributesInitialized = false
    var fileActionsInitialized = false
    defer {
        if fileActionsInitialized {
            posix_spawn_file_actions_destroy(&fileActions)
        }
        if attributesInitialized {
            posix_spawnattr_destroy(&spawnAttributes)
        }
    }

    var spawnCode = posix_spawnattr_init(&spawnAttributes)
    guard spawnCode == 0 else {
        throw RunnerError.unableToConfigureSpawn("attribute initialization", spawnCode)
    }
    attributesInitialized = true

    spawnCode = posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETPGROUP))
    guard spawnCode == 0 else {
        throw RunnerError.unableToConfigureSpawn("process-group flags", spawnCode)
    }
    spawnCode = posix_spawnattr_setpgroup(&spawnAttributes, processGroupID)
    guard spawnCode == 0 else {
        throw RunnerError.unableToConfigureSpawn("process group", spawnCode)
    }

    spawnCode = posix_spawn_file_actions_init(&fileActions)
    guard spawnCode == 0 else {
        throw RunnerError.unableToConfigureSpawn("file-action initialization", spawnCode)
    }
    fileActionsInitialized = true

    spawnCode = specification.workingDirectory.withCString { path in
        posix_spawn_file_actions_addchdir_np(&fileActions, path)
    }
    guard spawnCode == 0 else {
        throw RunnerError.unableToConfigureSpawn("working directory", spawnCode)
    }
    spawnCode = "/dev/null".withCString { path in
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, path, O_RDONLY, 0)
    }
    guard spawnCode == 0 else {
        throw RunnerError.unableToConfigureSpawn("standard input", spawnCode)
    }

    var childPID = pid_t(0)
    spawnCode = executableURL.path.withCString { path in
        posix_spawn(
            &childPID,
            path,
            &fileActions,
            &spawnAttributes,
            argv.pointer,
            envp.pointer
        )
    }
    guard spawnCode == 0 else { throw RunnerError.unableToSpawn(spawnCode) }

    // Group signals reach the command and descendants while the verified leader waits.
    // These dispositions are set only in the parent, so the exec'd child keeps defaults.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    let exitStatus = waitForChild(childPID)
    while !processGroupMembers(processGroupID, excluding: runnerPID).isEmpty {
        usleep(100_000)
    }
    return exitStatus
}

do {
    Darwin.exit(try run())
} catch {
    let message = "launchstation-runner: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    Darwin.exit(126)
}
