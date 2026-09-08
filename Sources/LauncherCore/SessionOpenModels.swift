import Foundation

/// A fixed, server-derived way to open or focus one part of a stored launch session.
///
/// The raw values are part of the local API contract. In particular, callers select an
/// option by its opaque `SessionOpenOption.id`; they never submit a URL, PID, device ID,
/// command, or platform of their own.
public enum SessionOpenOptionKind: String, Codable, CaseIterable, Sendable {
    case browser
    case browserEndpoint = "browser-endpoint"
    case application
    case simulator
    case expoIOS = "expo-ios"
    case expoAndroid = "expo-android"
    case expoWeb = "expo-web"

    public var expoPlatform: String? {
        switch self {
        case .expoIOS: return "ios"
        case .expoAndroid: return "android"
        case .expoWeb: return "web"
        case .browser, .browserEndpoint, .application, .simulator: return nil
        }
    }
}

public struct SessionOpenOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionID: UUID
    public var actionRunID: UUID
    public var actionID: UUID
    public var kind: SessionOpenOptionKind
    public var label: String
    /// Endpoint identity from the stored session snapshot. It is meaningful only for
    /// `.browserEndpoint`; execution still resolves the path from the snapshot rather than
    /// trusting this presentation value.
    public var configuredEndpointID: UUID?
    /// Human-readable context only. Execution always re-derives its target from the
    /// stored session/action run and never trusts this value.
    public var detail: String?

    public init(
        id: String,
        sessionID: UUID,
        actionRunID: UUID,
        actionID: UUID,
        kind: SessionOpenOptionKind,
        label: String,
        configuredEndpointID: UUID? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.actionRunID = actionRunID
        self.actionID = actionID
        self.kind = kind
        self.label = label
        self.configuredEndpointID = configuredEndpointID
        self.detail = detail
    }
}

/// The complete mutation request accepted by the session-open endpoint.
///
/// Keeping this request deliberately narrow prevents callers from smuggling an arbitrary
/// URL, PID, Simulator UDID, platform, or command into the daemon.
public struct SessionOpenRequest: Codable, Equatable, Sendable {
    public var optionID: String

    public init(optionID: String) {
        self.optionID = optionID
    }
}

public struct SessionOpenResult: Codable, Equatable, Sendable {
    public var optionID: String
    public var kind: SessionOpenOptionKind
    public var message: String
    public var performedAt: Date

    public init(
        optionID: String,
        kind: SessionOpenOptionKind,
        message: String,
        performedAt: Date = Date()
    ) {
        self.optionID = optionID
        self.kind = kind
        self.message = message
        self.performedAt = performedAt
    }
}

/// Result of the explicit non-launching Expo GET probe. Merely deriving options never
/// performs this request (or any other I/O).
public struct SessionOpenProbeResult: Codable, Equatable, Sendable {
    public var optionID: String
    public var kind: SessionOpenOptionKind
    public var available: Bool
    public var statusCode: Int
    public var message: String

    public init(
        optionID: String,
        kind: SessionOpenOptionKind,
        available: Bool,
        statusCode: Int,
        message: String
    ) {
        self.optionID = optionID
        self.kind = kind
        self.available = available
        self.statusCode = statusCode
        self.message = message
    }
}

/// Pure derivation of the open/focus choices represented by a stored session snapshot.
/// This type intentionally performs no process inspection, network access, application
/// activation, or Simulator commands.
public enum SessionOpenOptionDeriver {
    public static func options(for session: SessionRecord) -> [SessionOpenOption] {
        let actionsByID = (session.actionSnapshots ?? []).reduce(into: [UUID: LaunchAction]()) {
            $0[$1.id] = $1
        }
        let runs = session.actionRuns
            .filter { $0.state == .running }
            .sorted { lhs, rhs in
                let lhsOrder = actionsByID[lhs.actionID]?.order ?? Int.max
                let rhsOrder = actionsByID[rhs.actionID]?.order ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        let namedEndpoints = session.endpointSnapshots ?? []

        return runs.flatMap { run -> [SessionOpenOption] in
            let action = actionsByID[run.actionID]
            let expo = action.map(isExpoAction) ?? false
            var result: [SessionOpenOption] = []

            if let endpoint = validatedHTTPURL(run.endpointURL) {
                if expo, isLoopbackHost(endpoint.host) {
                    result.append(makeOption(
                        session: session,
                        run: run,
                        kind: .expoIOS,
                        label: "Open Expo on iOS",
                        detail: endpoint.absoluteString
                    ))
                    result.append(makeOption(
                        session: session,
                        run: run,
                        kind: .expoAndroid,
                        label: "Open Expo on Android",
                        detail: endpoint.absoluteString
                    ))
                    result.append(makeOption(
                        session: session,
                        run: run,
                        kind: .expoWeb,
                        label: "Open Expo on Web",
                        detail: endpoint.absoluteString
                    ))
                } else if !expo {
                    if session.primaryActionID == run.actionID, !namedEndpoints.isEmpty {
                        for namedEndpoint in namedEndpoints {
                            guard let destination = namedEndpointURL(
                                endpointURL: endpoint.absoluteString,
                                path: namedEndpoint.path
                            ) else { continue }
                            result.append(makeEndpointOption(
                                session: session,
                                run: run,
                                endpoint: namedEndpoint,
                                detail: destination.absoluteString
                            ))
                        }
                    } else {
                        result.append(makeOption(
                            session: session,
                            run: run,
                            kind: .browser,
                            label: "Open in Browser",
                            detail: endpoint.absoluteString
                        ))
                    }
                }
            }

            if run.manager == .application,
               let pid = run.pid,
               run.pidStartIdentity != nil {
                result.append(makeOption(
                    session: session,
                    run: run,
                    kind: .application,
                    label: "Focus Application",
                    detail: "\(run.actionName) · PID \(pid)"
                ))
            }

            if let udid = nonempty(run.simulatorUDID) {
                let name = nonempty(run.simulatorName) ?? "iOS"
                result.append(makeOption(
                    session: session,
                    run: run,
                    kind: .simulator,
                    label: "Focus \(name) Simulator",
                    detail: "\(name) · \(udid)"
                ))
            }

            return result
        }
    }

    public static func option(id: String, in session: SessionRecord) -> SessionOpenOption? {
        options(for: session).first { $0.id == id }
    }

    public static func optionID(actionRunID: UUID, kind: SessionOpenOptionKind) -> String {
        "open-v1:\(actionRunID.uuidString.lowercased()):\(kind.rawValue)"
    }

    public static func endpointOptionID(actionRunID: UUID, endpointID: UUID) -> String {
        "open-v2:\(actionRunID.uuidString.lowercased()):browser-endpoint:\(endpointID.uuidString.lowercased())"
    }

    public static func isExpoAction(_ action: LaunchAction) -> Bool {
        let executable = action.executable
            .map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
            ?? ""
        if executable == "expo" { return true }
        if executable == "npx",
           action.arguments.contains(where: { $0.lowercased() == "expo" }) {
            return true
        }
        return action.shellCommand?.range(
            of: #"(^|\s)(npx\s+)?expo(\s|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public static func validatedHTTPURL(_ value: String?) -> URL? {
        guard let value = nonempty(value),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    /// Resolves a named endpoint from immutable session data. This routine does not accept a
    /// caller-provided URL: it preserves the running action's origin and replaces only its safe
    /// stored path.
    public static func browserURL(for option: SessionOpenOption, in session: SessionRecord) -> URL? {
        guard (option.kind == .browser || option.kind == .browserEndpoint),
              let derived = self.option(id: option.id, in: session),
              derived == option,
              let run = session.actionRuns.first(where: { $0.id == option.actionRunID && $0.state == .running }) else {
            return nil
        }

        switch option.kind {
        case .browser:
            return validatedHTTPURL(run.endpointURL)
        case .browserEndpoint:
            guard session.primaryActionID == run.actionID,
                  let endpointID = option.configuredEndpointID,
                  let namedEndpoint = session.endpointSnapshots?.first(where: { $0.id == endpointID }) else {
                return nil
            }
            return namedEndpointURL(endpointURL: run.endpointURL, path: namedEndpoint.path)
        case .application, .simulator, .expoIOS, .expoAndroid, .expoWeb:
            return nil
        }
    }

    /// Returns a path-only endpoint on the exact scheme/host/port recorded by a running action.
    public static func namedEndpointURL(endpointURL: String?, path: String) -> URL? {
        guard let base = validatedHTTPURL(endpointURL),
              let safePath = try? LauncherValidation.validatedEndpointPath(path),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath = safePath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Builds the only Expo control URL the daemon may call. The host and port come from
    /// the stored action run; the path and platform come from a derived option kind.
    public static func expoControlURL(
        endpointURL: String?,
        kind: SessionOpenOptionKind
    ) -> URL? {
        guard kind.expoPlatform != nil,
              let endpoint = validatedHTTPURL(endpointURL),
              isLoopbackHost(endpoint.host),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/_expo/open"
        components.queryItems = [URLQueryItem(name: "platform", value: kind.expoPlatform)]
        components.fragment = nil
        return components.url
    }

    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func makeOption(
        session: SessionRecord,
        run: ActionRunRecord,
        kind: SessionOpenOptionKind,
        label: String,
        detail: String?
    ) -> SessionOpenOption {
        SessionOpenOption(
            id: optionID(actionRunID: run.id, kind: kind),
            sessionID: session.id,
            actionRunID: run.id,
            actionID: run.actionID,
            kind: kind,
            label: label,
            detail: detail
        )
    }

    private static func makeEndpointOption(
        session: SessionRecord,
        run: ActionRunRecord,
        endpoint: LauncherEndpoint,
        detail: String
    ) -> SessionOpenOption {
        SessionOpenOption(
            id: endpointOptionID(actionRunID: run.id, endpointID: endpoint.id),
            sessionID: session.id,
            actionRunID: run.id,
            actionID: run.actionID,
            kind: .browserEndpoint,
            label: "Open \(endpoint.name)",
            configuredEndpointID: endpoint.id,
            detail: detail
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
