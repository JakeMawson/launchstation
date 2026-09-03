import Foundation

/// A user-facing explanation of a failed managed launch. It intentionally separates a
/// command's own failure from the lifecycle evidence gathered by Launcher so the UI never
/// presents an implementation guard as though it were the project's root cause.
public enum LaunchFailureOrigin: String, Codable, CaseIterable, Sendable {
    case projectCommand = "project-command"
    case launcherLifecycle = "launcher-lifecycle"
    case processObservation = "process-observation"
    case unknown
}

public enum LaunchFailureConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public struct LaunchFailureDiagnosis: Codable, Equatable, Sendable {
    public var origin: LaunchFailureOrigin
    public var confidence: LaunchFailureConfidence
    public var title: String
    public var summary: String
    public var rootCause: String
    public var lifecycle: String
    public var nextStep: String
    public var evidence: [String]

    public init(
        origin: LaunchFailureOrigin,
        confidence: LaunchFailureConfidence,
        title: String,
        summary: String,
        rootCause: String,
        lifecycle: String,
        nextStep: String,
        evidence: [String]
    ) {
        self.origin = origin
        self.confidence = confidence
        self.title = title
        self.summary = summary
        self.rootCause = rootCause
        self.lifecycle = lifecycle
        self.nextStep = nextStep
        self.evidence = evidence
    }
}

/// Server-observed inputs used to make a bounded, evidence-labelled diagnosis. `logText` is
/// command output captured by the run owner; no shell is re-executed to infer a cause.
public struct LaunchFailureDiagnosisInput: Equatable, Sendable {
    public var launcherMessage: String?
    public var logText: String?
    public var processStarted: Bool?
    public var managerReportedLive: Bool?
    public var identityReadableAfterFailure: Bool?
    public var launcherRequestedCleanup: Bool

    public init(
        launcherMessage: String? = nil,
        logText: String? = nil,
        processStarted: Bool? = nil,
        managerReportedLive: Bool? = nil,
        identityReadableAfterFailure: Bool? = nil,
        launcherRequestedCleanup: Bool = false
    ) {
        self.launcherMessage = launcherMessage
        self.logText = logText
        self.processStarted = processStarted
        self.managerReportedLive = managerReportedLive
        self.identityReadableAfterFailure = identityReadableAfterFailure
        self.launcherRequestedCleanup = launcherRequestedCleanup
    }
}

public enum LaunchFailureDiagnoser {
    public static func diagnose(_ input: LaunchFailureDiagnosisInput) -> LaunchFailureDiagnosis {
        let message = input.launcherMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let log = input.logText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = "\(message)\n\(log)"
        let evidence = evidenceLines(input: input, message: message, log: log)

        if let module = missingModule(in: combined) {
            return LaunchFailureDiagnosis(
                origin: .projectCommand,
                confidence: .high,
                title: "A required Python module is missing",
                summary: "The project command started, then Python could not import \(module).",
                rootCause: "The Python environment selected by this launcher does not have the \(module) module installed.",
                lifecycle: lifecycle(input),
                nextStep: "Use the project’s intended virtual environment, or install \(module) into the Python interpreter used by this launcher, then relaunch.",
                evidence: evidence
            )
        }

        if combined.localizedCaseInsensitiveContains("command not found")
            || combined.localizedCaseInsensitiveContains("executable not found") {
            return LaunchFailureDiagnosis(
                origin: .projectCommand,
                confidence: .high,
                title: "The launch command is unavailable",
                summary: "The command could not be resolved in the launcher’s configured environment.",
                rootCause: firstMeaningfulLine(from: log, fallback: message),
                lifecycle: lifecycle(input),
                nextStep: "Check the launcher executable, PATH, and project runtime setup, then relaunch.",
                evidence: evidence
            )
        }

        if combined.localizedCaseInsensitiveContains("traceback")
            || combined.localizedCaseInsensitiveContains("uncaught exception") {
            return LaunchFailureDiagnosis(
                origin: .projectCommand,
                confidence: .high,
                title: "The project process crashed during startup",
                summary: "Launcher captured an application error after starting the command.",
                rootCause: firstMeaningfulLine(from: log, fallback: message),
                lifecycle: lifecycle(input),
                nextStep: "Review the captured command output below, correct the first project error, then relaunch.",
                evidence: evidence
            )
        }

        if message.localizedCaseInsensitiveContains("birth identity")
            || message.localizedCaseInsensitiveContains("process identity") {
            let root: String
            if input.identityReadableAfterFailure == false {
                root = "The managed process ended before Launcher could verify its exact PID identity."
            } else if input.managerReportedLive == true {
                root = "Launcher could not safely prove that the live manager PID was the exact process it started."
            } else {
                root = "The manager could not be corroborated as a live, exact process when Launcher checked it."
            }
            return LaunchFailureDiagnosis(
                origin: .processObservation,
                confidence: input.identityReadableAfterFailure == false ? .medium : .low,
                title: "Launcher could not verify the managed process",
                summary: root,
                rootCause: root,
                lifecycle: lifecycle(input),
                nextStep: "Open the evidence below. If the project output names a command error, fix that first; otherwise retry and report this lifecycle evidence to Launcher.",
                evidence: evidence
            )
        }

        return LaunchFailureDiagnosis(
            origin: .unknown,
            confidence: .low,
            title: "The launch did not complete",
            summary: message.isEmpty ? "Launcher did not receive enough evidence to identify one root cause." : message,
            rootCause: firstMeaningfulLine(from: log, fallback: message.isEmpty ? "No root-cause output was captured." : message),
            lifecycle: lifecycle(input),
            nextStep: "Review the captured evidence below. If it remains inconclusive, retry once and compare the new session log.",
            evidence: evidence
        )
    }

    private static func missingModule(in value: String) -> String? {
        guard let marker = value.range(of: "no module named", options: [.caseInsensitive]) else { return nil }
        let suffix = value[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = suffix.split(whereSeparator: \.isWhitespace).first else { return nil }
        let module = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\".:-"))
        return module.isEmpty ? nil : module
    }

    private static func lifecycle(_ input: LaunchFailureDiagnosisInput) -> String {
        if input.launcherRequestedCleanup {
            return "Launcher deliberately stopped the manager after gathering the available failure evidence; it did not adopt an unverified process."
        }
        if input.processStarted == true {
            return "Launcher observed startup evidence for the managed process."
        }
        if input.processStarted == false {
            return "Launcher did not observe evidence that the command reached startup."
        }
        return "Launcher could not prove the command’s final lifecycle state from the available evidence."
    }

    private static func evidenceLines(
        input: LaunchFailureDiagnosisInput,
        message: String,
        log: String
    ) -> [String] {
        var evidence: [String] = []
        if input.processStarted == true { evidence.append("Runner published startup status for the managed process.") }
        if input.managerReportedLive == true { evidence.append("The port manager reported the process as live when inspected.") }
        if input.identityReadableAfterFailure == false { evidence.append("A follow-up exact PID identity read was unavailable.") }
        if input.launcherRequestedCleanup { evidence.append("Launcher requested manager cleanup after its verification boundary failed.") }
        if !message.isEmpty { evidence.append("Launcher: \(firstMeaningfulLine(from: message, fallback: message))") }
        if !log.isEmpty { evidence.append("Command output: \(firstMeaningfulLine(from: log, fallback: log))") }
        return evidence
    }

    private static func firstMeaningfulLine(from value: String, fallback: String) -> String {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0) } ?? fallback
    }
}

public struct SessionLogResponse: Codable, Equatable, Sendable {
    public var text: String
    public var diagnoses: [LaunchFailureDiagnosis]

    public init(text: String, diagnoses: [LaunchFailureDiagnosis] = []) {
        self.text = text
        self.diagnoses = diagnoses
    }
}
