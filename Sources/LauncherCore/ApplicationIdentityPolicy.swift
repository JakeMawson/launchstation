import Foundation

public enum ApplicationIdentityPolicyError: LocalizedError, Equatable, Sendable {
    case configuredBundleIdentifierMismatch(configured: String, resolved: String)

    public var errorDescription: String? {
        switch self {
        case .configuredBundleIdentifierMismatch(let configured, let resolved):
            return "Configured application bundle identifier \(configured) does not match the resolved app bundle identifier \(resolved)."
        }
    }
}

/// Conservative ownership rules for LaunchServices applications. A caller may terminate a
/// launched PID only when the app bundle supplied a verified identifier, LaunchServices reports
/// that same identifier, and the PID was not present before launch.
public enum ApplicationIdentityPolicy {
    public static func nonemptyIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public static func verifiedBundleIdentifier(
        configured: String?,
        resolvedFromBundle: String?
    ) throws -> String? {
        let configured = nonemptyIdentifier(configured)
        let resolved = nonemptyIdentifier(resolvedFromBundle)
        if let configured, let resolved, configured != resolved {
            throw ApplicationIdentityPolicyError.configuredBundleIdentifierMismatch(
                configured: configured,
                resolved: resolved
            )
        }
        // A configured string is not proof by itself. If the bundle has no identifier, lifecycle
        // ownership must remain conservative even when LaunchServices later returns an identifier.
        return resolved
    }

    public static func provesDistinctOwnership(
        verifiedBundleIdentifier: String?,
        launchedBundleIdentifier: String?,
        launchedPID: Int32,
        preexistingPIDs: Set<Int32>
    ) -> Bool {
        guard let verified = nonemptyIdentifier(verifiedBundleIdentifier),
              let launched = nonemptyIdentifier(launchedBundleIdentifier),
              launched == verified,
              !preexistingPIDs.contains(launchedPID) else { return false }
        return true
    }
}
