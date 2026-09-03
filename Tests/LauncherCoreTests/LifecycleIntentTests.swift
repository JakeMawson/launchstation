import Foundation
import XCTest
@testable import LauncherCore

final class LifecycleIntentTests: XCTestCase {
    func testStartIntentSurvivesSelectionAndArgumentChangesBeforeDeferredExecution() throws {
        let scheduler = DeferredScheduler()
        let launcherA = makeDetail(name: "Launcher A", revision: 7)
        let launcherB = makeDetail(name: "Launcher B", revision: 12)
        var selectedDetail = launcherA
        var argumentText = #"--mode "alpha one""#
        var executedIntent: LauncherStartIntent?

        let capturedIntent = LauncherStartIntent(
            detail: selectedDetail,
            rawRuntimeArguments: argumentText
        )
        scheduler.schedule {
            executedIntent = capturedIntent
        }

        // Model a polling refresh reconciling selection and the user editing the
        // newly selected launcher's field before the deferred Task is allowed to run.
        selectedDetail = launcherB
        argumentText = "--mode beta"
        XCTAssertNil(executedIntent)

        try scheduler.runNext()

        let executed = try XCTUnwrap(executedIntent)
        XCTAssertEqual(executed.detail, launcherA)
        XCTAssertEqual(executed.launcherID, launcherA.launcher.id)
        XCTAssertEqual(executed.launcherName, "Launcher A")
        XCTAssertEqual(executed.expectedLauncherRevision, 7)
        XCTAssertEqual(executed.rawRuntimeArguments, #"--mode "alpha one""#)
        XCTAssertEqual(executed.mode, .reusePrimary)
        XCTAssertEqual(selectedDetail, launcherB)
        XCTAssertEqual(argumentText, "--mode beta")
    }

    func testRelaunchIntentCapturesParsedArgumentsAndLifecycleIdentities() throws {
        let detail = makeDetail(name: "Full stack", revision: 9)
        let actionRunID = UUID()
        let actionID = UUID()
        let activeRun = ActionRunRecord(
            id: actionRunID,
            actionID: actionID,
            actionName: "frontend",
            state: .running,
            manager: .codexPort,
            managerID: "port-owner-17",
            pid: 321,
            processGroupID: 320,
            pidStartIdentity: "321:987654",
            host: "127.0.0.1",
            port: 49321,
            endpointURL: "http://127.0.0.1:49321/",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let completedRun = ActionRunRecord(
            actionID: UUID(),
            actionName: "setup",
            state: .exited,
            manager: .processGroup,
            startedAt: Date(timeIntervalSince1970: 90),
            endedAt: Date(timeIntervalSince1970: 99)
        )
        let session = SessionRecord(
            id: UUID(),
            launcherID: detail.launcher.id,
            launcherName: detail.launcher.name,
            launcherRevision: 6,
            state: .running,
            actionRuns: [completedRun, activeRun],
            startedAt: Date(timeIntervalSince1970: 90)
        )
        var parsedArguments = ["--mode", "demo one"]

        let intent = try XCTUnwrap(LauncherRelaunchIntent(
            detail: detail,
            session: session,
            runtimeArguments: parsedArguments
        ))
        parsedArguments = ["--mode", "changed"]

        XCTAssertEqual(intent.id, session.id)
        XCTAssertEqual(intent.expectedSessionID, session.id)
        XCTAssertEqual(intent.launcherID, detail.launcher.id)
        XCTAssertEqual(intent.launcherName, "Full stack")
        XCTAssertEqual(intent.expectedLauncherRevision, 9)
        XCTAssertEqual(intent.sessionLauncherRevision, 6)
        XCTAssertEqual(intent.runtimeArguments, ["--mode", "demo one"])
        XCTAssertEqual(intent.services.count, 2)
        XCTAssertEqual(intent.activeServiceNames, ["frontend"])
        XCTAssertEqual(intent.services[1].actionRunID, actionRunID)
        XCTAssertEqual(intent.services[1].actionID, actionID)
        XCTAssertEqual(intent.services[1].manager, .codexPort)
        XCTAssertEqual(intent.services[1].managerID, "port-owner-17")
        XCTAssertEqual(intent.services[1].pid, 321)
        XCTAssertEqual(intent.services[1].processGroupID, 320)
        XCTAssertEqual(intent.services[1].pidStartIdentity, "321:987654")
        XCTAssertEqual(intent.services[1].host, "127.0.0.1")
        XCTAssertEqual(intent.services[1].port, 49321)
        XCTAssertEqual(intent.services[1].endpointURL, "http://127.0.0.1:49321/")
        XCTAssertEqual(
            intent.confirmationMessage,
            "Fully close the exact active session for Full stack, including frontend, then start a fresh session with new managed ports where configured?"
        )
        XCTAssertEqual(parsedArguments, ["--mode", "changed"])
    }

    func testRelaunchIntentRejectsMismatchedOrTerminalSession() {
        let detail = makeDetail(name: "Launcher A", revision: 3)
        let mismatched = SessionRecord(
            launcherID: UUID(),
            launcherName: "Other launcher",
            launcherRevision: 1,
            state: .running
        )
        let terminal = SessionRecord(
            launcherID: detail.launcher.id,
            launcherName: detail.launcher.name,
            launcherRevision: 3,
            state: .exited,
            endedAt: Date()
        )

        XCTAssertNil(LauncherRelaunchIntent(detail: detail, session: mismatched, runtimeArguments: []))
        XCTAssertNil(LauncherRelaunchIntent(detail: detail, session: terminal, runtimeArguments: []))
    }

    private func makeDetail(name: String, revision: Int) -> LauncherDetail {
        let projectID = UUID()
        let action = LaunchAction(
            id: UUID(),
            name: "main",
            normalizedName: "main",
            description: "Run \(name)",
            runner: .process,
            executable: "example",
            arguments: []
        )
        let launcher = LauncherRecord(
            id: UUID(),
            projectID: projectID,
            name: name,
            normalizedName: LauncherValidation.normalizeName(name),
            description: "Test launcher",
            actions: [action],
            primaryActionID: action.id,
            revision: revision,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        return LauncherDetail(
            project: ProjectRecord(
                id: projectID,
                displayName: "Intent fixtures",
                directory: "/tmp/intent-fixtures",
                revision: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)
            ),
            launcher: launcher
        )
    }
}

private final class DeferredScheduler {
    private var jobs: [() -> Void] = []

    func schedule(_ job: @escaping () -> Void) {
        jobs.append(job)
    }

    func runNext() throws {
        guard !jobs.isEmpty else { throw DeferredSchedulerError.noScheduledJob }
        jobs.removeFirst()()
    }
}

private enum DeferredSchedulerError: Error {
    case noScheduledJob
}
