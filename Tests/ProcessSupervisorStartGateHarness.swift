import Darwin
import Foundation
import LauncherCore

private struct HarnessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ExpectedRegistrationFailure: Error {}

private actor RegistrationGate {
    private let shouldFail: Bool
    private var arrivedRecord: ActionRunRecord?
    private var arrivalWaiters: [CheckedContinuation<ActionRunRecord, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func register(_ record: ActionRunRecord) async throws {
        arrivedRecord = record
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: record) }

        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseWaiter = continuation
            }
        }
        if shouldFail { throw ExpectedRegistrationFailure() }
    }

    func waitForArrival() async -> ActionRunRecord {
        if let arrivedRecord { return arrivedRecord }
        return await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor UpdateRecorder {
    private var updates: [ActionRunRecord] = []

    func append(_ update: ActionRunRecord) {
        updates.append(update)
    }

    func snapshot() -> [ActionRunRecord] {
        updates
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HarnessFailure(message: message) }
}

private func waitForFile(_ url: URL, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

private func waitForExactProcessExit(_ record: ActionRunRecord, timeout: TimeInterval) async -> Bool {
    guard let pid = record.pid else { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return !ProcessBirthIdentity.matches(pid: pid, serialized: record.pidStartIdentity)
}

private func makeAction(marker: URL) -> LaunchAction {
    LaunchAction(
        name: "main",
        normalizedName: "main",
        description: "Durable registration start-gate regression",
        runner: .process,
        executable: "/usr/bin/python3",
        arguments: [
            "-c",
            "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('released', encoding='utf-8')",
            marker.path,
        ],
        port: .none,
        openTarget: .none
    )
}

private func acknowledgementURL(runtime: URL, runID: UUID) -> URL {
    runtime
        .appendingPathComponent("Runner Acknowledgements", isDirectory: true)
        .appendingPathComponent("\(runID.uuidString).json")
}

private func runSuspendedRegistrationCase(root: URL, runner: URL) async throws {
    let runtime = root.appendingPathComponent("suspended", isDirectory: true)
    let workspace = runtime.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let marker = runtime.appendingPathComponent("command-ran.txt")
    let project = ProjectRecord(displayName: "Suspended registration", directory: workspace.path)
    let supervisor = ProcessSupervisor(runtimeDirectory: runtime, runnerExecutableURL: runner)
    let gate = RegistrationGate(shouldFail: false)
    let recorder = UpdateRecorder()

    let launch = Task {
        try await supervisor.launch(
            action: makeAction(marker: marker),
            project: project,
            sessionID: UUID(),
            onRegister: { record in try await gate.register(record) },
            onUpdate: { update in Task { await recorder.append(update) } }
        )
    }

    let gatedRecord = await gate.waitForArrival()
    let acknowledgement = acknowledgementURL(runtime: runtime, runID: gatedRecord.id)
    try? await Task.sleep(nanoseconds: 150_000_000)
    let wasBlockedWithoutAcknowledgement = !FileManager.default.fileExists(atPath: acknowledgement.path)
    let commandWasBlocked = !FileManager.default.fileExists(atPath: marker.path)
    let runnerWasLive = gatedRecord.pid.map {
        ProcessBirthIdentity.matches(pid: $0, serialized: gatedRecord.pidStartIdentity)
    } ?? false

    // Always release the real runner before reporting an assertion so the harness cannot strand it.
    await gate.release()
    let launched = try await launch.value
    let commandRan = await waitForFile(marker, timeout: 2)
    if await supervisor.isExactProcessAlive(launched) {
        _ = await supervisor.stop(launched, timeoutSeconds: 2)
    }

    try require(wasBlockedWithoutAcknowledgement, "acknowledgement appeared while durable registration was suspended")
    try require(commandWasBlocked, "command executed while durable registration was suspended")
    try require(runnerWasLive, "verified runner did not remain live at the suspended registration boundary")
    try require(commandRan, "command did not execute after durable registration was released")
}

private func runFailedRegistrationCase(root: URL, runner: URL) async throws {
    let runtime = root.appendingPathComponent("failed", isDirectory: true)
    let workspace = runtime.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let marker = runtime.appendingPathComponent("command-ran.txt")
    let project = ProjectRecord(displayName: "Failed registration", directory: workspace.path)
    let supervisor = ProcessSupervisor(runtimeDirectory: runtime, runnerExecutableURL: runner)
    let gate = RegistrationGate(shouldFail: true)
    let recorder = UpdateRecorder()

    let launch = Task {
        try await supervisor.launch(
            action: makeAction(marker: marker),
            project: project,
            sessionID: UUID(),
            onRegister: { record in try await gate.register(record) },
            onUpdate: { update in Task { await recorder.append(update) } }
        )
    }

    let gatedRecord = await gate.waitForArrival()
    let acknowledgement = acknowledgementURL(runtime: runtime, runID: gatedRecord.id)
    try? await Task.sleep(nanoseconds: 150_000_000)
    let wasBlockedWithoutAcknowledgement = !FileManager.default.fileExists(atPath: acknowledgement.path)
    let commandWasBlocked = !FileManager.default.fileExists(atPath: marker.path)

    await gate.release()
    var registrationFailed = false
    do {
        _ = try await launch.value
    } catch is ExpectedRegistrationFailure {
        registrationFailed = true
    }
    let exactGroupExited = await waitForExactProcessExit(gatedRecord, timeout: 2)
    let updates = await recorder.snapshot()

    try require(wasBlockedWithoutAcknowledgement, "acknowledgement appeared before failing durable registration returned")
    try require(commandWasBlocked, "command executed before failing durable registration returned")
    try require(registrationFailed, "registration failure was not propagated by ProcessSupervisor.launch")
    try require(!FileManager.default.fileExists(atPath: acknowledgement.path), "registration failure wrote an acknowledgement")
    try require(!FileManager.default.fileExists(atPath: marker.path), "registration failure released the command")
    try require(exactGroupExited, "registration failure did not terminate the verified exact process group")
    try require(updates.isEmpty, "registration failure installed a lifecycle callback for an unregistered run")
}

@main
private struct ProcessSupervisorStartGateHarness {
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            try require(arguments.count == 3, "usage: harness RUNNER ARTIFACT_DIRECTORY")
            let runner = URL(fileURLWithPath: arguments[1])
            let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try require(FileManager.default.isExecutableFile(atPath: runner.path), "runner is not executable: \(runner.path)")

            try await runSuspendedRegistrationCase(root: root, runner: runner)
            try await runFailedRegistrationCase(root: root, runner: runner)
            print("PROCESS SUPERVISOR START GATE PASS")
            print("Artifacts: \(root.path)")
        } catch {
            fputs("ProcessSupervisor start-gate failure: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
