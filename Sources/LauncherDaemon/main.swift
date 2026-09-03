import Darwin
import Foundation
import LauncherCore

private func runDaemon() async throws {
    try LauncherPaths.ensurePrivateDirectory(LauncherPaths.defaultStateDirectory)
    try LauncherPaths.ensurePrivateDirectory(LauncherPaths.logDirectory)

    let store = try SQLiteStore(databaseURL: LauncherPaths.databaseURL)
    let environment = ProcessInfo.processInfo.environment
    let runnerURL = environment["CODEX_LAUNCHER_RUNNER"].map { URL(fileURLWithPath: $0) }
    let codexPortURL = environment["CODEX_PORT_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
    let supervisor = ProcessSupervisor(
        runtimeDirectory: LauncherPaths.defaultStateDirectory,
        runnerExecutableURL: runnerURL,
        codexPortExecutableURL: codexPortURL
    )
    // Read the enclosing application's version once so the metadata written at boot and every
    // health/catalog response describe the same daemon binary throughout this process lifetime.
    let serviceVersion = LauncherRuntimeVersion.current()
    let service = LauncherService(
        store: store,
        supervisor: supervisor,
        skillManager: try? LauncherSkillManager.located(environment: environment),
        serviceVersion: serviceVersion
    )

    // Finish persisted-state reconciliation before publishing fresh connection metadata. Until the
    // metadata atomically changes, clients cannot authenticate to this new daemon instance.
    await service.reconcileProjectManifests()
    await service.recoverActiveSessions()
    await service.ensureManagedPortLeaseRenewals()

    let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
    let server = HTTPServer(token: token) { request in
        await service.handle(request)
    }
    let requestedPort = environment["CODEX_PORT"].flatMap(UInt16.init) ?? 0
    let port = try await server.start(port: requestedPort)
    defer { server.stop() }

    let endpoint = "http://127.0.0.1:\(port)"
    await service.setEndpoint(endpoint)
    let metadata = ServiceMetadata(
        endpoint: endpoint,
        token: token,
        pid: getpid(),
        startedAt: Date(),
        version: serviceVersion
    )
    try LauncherPaths.atomicWrite(
        LauncherJSON.encoder(pretty: true).encode(metadata),
        to: LauncherPaths.serviceMetadataURL,
        permissions: 0o600
    )

    while !Task.isCancelled {
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            break
        }
        guard !Task.isCancelled else { break }
        await service.reconcileProjectManifests()
        await service.ensureManagedPortLeaseRenewals()
    }
}

Task {
    do {
        try await runDaemon()
    } catch {
        fputs("codex-launcherd: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

dispatchMain()
