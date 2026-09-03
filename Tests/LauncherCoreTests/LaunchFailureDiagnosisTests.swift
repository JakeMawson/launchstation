import XCTest
@testable import LauncherCore

final class LaunchFailureDiagnosisTests: XCTestCase {
    func testMissingPythonModuleIsPrimaryRootCauseEvenWhenLifecycleVerificationAlsoFailed() throws {
        let diagnosis = LaunchFailureDiagnoser.diagnose(
            LaunchFailureDiagnosisInput(
                launcherMessage: "Unable to read exact birth identity for PID 21262.",
                logText: "/opt/homebrew/opt/python@3.14/bin/python3.14: No module named uvicorn\n",
                processStarted: true,
                managerReportedLive: true,
                identityReadableAfterFailure: false,
                launcherRequestedCleanup: true
            )
        )

        XCTAssertEqual(diagnosis.origin, .projectCommand)
        XCTAssertEqual(diagnosis.confidence, .high)
        XCTAssertEqual(diagnosis.title, "A required Python module is missing")
        XCTAssertTrue(diagnosis.rootCause.contains("uvicorn"))
        XCTAssertTrue(diagnosis.lifecycle.contains("deliberately stopped"))
        XCTAssertTrue(diagnosis.evidence.contains(where: { $0.contains("birth identity") }))
        XCTAssertTrue(diagnosis.evidence.contains(where: { $0.contains("No module named uvicorn") }))
    }

    func testIdentityFailureExplainsUnobservedManagerWithoutInventingProjectCause() throws {
        let diagnosis = LaunchFailureDiagnoser.diagnose(
            LaunchFailureDiagnosisInput(
                launcherMessage: "Unable to read exact birth identity for PID 89608.",
                processStarted: nil,
                managerReportedLive: false,
                identityReadableAfterFailure: false
            )
        )

        XCTAssertEqual(diagnosis.origin, .processObservation)
        XCTAssertEqual(diagnosis.title, "Launcher could not verify the managed process")
        XCTAssertEqual(diagnosis.confidence, .medium)
        XCTAssertFalse(diagnosis.rootCause.localizedCaseInsensitiveContains("crashed"))
        XCTAssertTrue(diagnosis.nextStep.contains("evidence"))
    }

    func testFailureDiagnosisRoundTripsWithActionRunAndSessionLogResponse() throws {
        let diagnosis = LaunchFailureDiagnoser.diagnose(
            LaunchFailureDiagnosisInput(logText: "zsh: command not found: uvicorn", processStarted: true)
        )
        let run = ActionRunRecord(
            actionID: UUID(),
            actionName: "web",
            state: .failed,
            manager: .codexPort,
            failureDiagnosis: diagnosis
        )
        let decodedRun = try LauncherJSON.decoder().decode(ActionRunRecord.self, from: LauncherJSON.encoder().encode(run))
        XCTAssertEqual(decodedRun.failureDiagnosis, diagnosis)

        let response = SessionLogResponse(text: "output", diagnoses: [diagnosis])
        let decodedResponse = try LauncherJSON.decoder().decode(SessionLogResponse.self, from: LauncherJSON.encoder().encode(response))
        XCTAssertEqual(decodedResponse, response)
    }
}
