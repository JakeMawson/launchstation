import Foundation

public enum LauncherValidationError: LocalizedError, Equatable {
    case invalidName(String)
    case reservedName(String)
    case invalidDescription
    case invalidDirectory(String)
    case invalidAction(String)
    case invalidPort(String)
    case duplicateAction(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason): return "Invalid launcher name: \(reason)"
        case .reservedName(let name): return "“\(name)” is reserved by the launch CLI."
        case .invalidDescription: return "Description must contain non-whitespace text."
        case .invalidDirectory(let path): return "Launch directory is unavailable: \(path)"
        case .invalidAction(let reason): return "Invalid launch action: \(reason)"
        case .invalidPort(let reason): return "Invalid port configuration: \(reason)"
        case .duplicateAction(let name): return "An action named “\(name)” already exists in this launcher."
        }
    }
}

public enum LauncherValidation {
    public static let linkedActionEnvironmentPrefix = "LAUNCH_STATION_ACTION_"
    public static let reservedNames: Set<String> = [
        ".", "..",
        "init", "create", "run", "list", "details", "retrieve", "update", "delete",
        "status", "close", "relaunch", "history", "action", "project", "sync", "doctor", "logs", "api",
        "skill", "maintenance", "external", "open", "help"
    ]

    public static func normalizeName(_ input: String) -> String {
        let compatibility = input.precomposedStringWithCompatibilityMapping
        let collapsed = compatibility
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public static func linkedActionEnvironmentBase(for action: LaunchAction) -> String {
        let source = normalizeName(action.name).uppercased(with: Locale(identifier: "en_US_POSIX"))
        var token = ""
        var lastWasUnderscore = false
        for scalar in source.unicodeScalars {
            let isASCIIAlphaNumeric = (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
            if isASCIIAlphaNumeric {
                token.unicodeScalars.append(scalar)
                lastWasUnderscore = false
            } else if !lastWasUnderscore, !token.isEmpty {
                token.append("_")
                lastWasUnderscore = true
            }
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if token.isEmpty {
            token = "ID_" + action.id.uuidString.replacingOccurrences(of: "-", with: "_")
        }
        return linkedActionEnvironmentPrefix + token
    }

    public static func validatedName(_ input: String, allowReserved: Bool = false) throws -> (display: String, normalized: String) {
        let display = input.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let normalized = normalizeName(display)
        guard !display.isEmpty else { throw LauncherValidationError.invalidName("it is empty") }
        guard display.count <= 80, display.utf8.count <= 240 else {
            throw LauncherValidationError.invalidName("use at most 80 characters and 240 UTF-8 bytes")
        }
        guard display.first != "-" else { throw LauncherValidationError.invalidName("it cannot begin with a hyphen") }
        guard !display.contains("/"), !display.contains("\\") else {
            throw LauncherValidationError.invalidName("slashes are not allowed")
        }
        guard display.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw LauncherValidationError.invalidName("control characters are not allowed")
        }
        if !allowReserved, reservedNames.contains(normalized) {
            throw LauncherValidationError.reservedName(display)
        }
        return (display, normalized)
    }

    public static func canonicalDirectory(_ input: String, mustExist: Bool = true) throws -> String {
        let expanded = NSString(string: input).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expanded)
                .path
        }
        let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
        if mustExist {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LauncherValidationError.invalidDirectory(standardized)
            }
        }
        return standardized
    }

    public static func validateLauncher(_ launcher: LauncherRecord, project: ProjectRecord) throws {
        _ = try validatedName(launcher.name)
        guard !launcher.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherValidationError.invalidDescription
        }
        guard !launcher.actions.isEmpty else { throw LauncherValidationError.invalidAction("at least one action is required") }
        var actionNames = Set<String>()
        var actionOrders = Set<Int>()
        var linkedEnvironmentBases = Set<String>()
        for action in launcher.actions {
            let (_, normalized) = try validatedName(action.name, allowReserved: true)
            guard actionNames.insert(normalized).inserted else { throw LauncherValidationError.duplicateAction(action.name) }
            guard actionOrders.insert(action.order).inserted else {
                throw LauncherValidationError.invalidAction("action order values must be unique")
            }
            let linkedBase = linkedActionEnvironmentBase(for: action)
            guard linkedEnvironmentBases.insert(linkedBase).inserted else {
                throw LauncherValidationError.invalidAction(
                    "action names must map to unique linked environment tokens; \(linkedBase) collides"
                )
            }
            try validateAction(action, project: project)
        }
        var availableLinkedValues: [String: LaunchAction] = [:]
        for action in launcher.sortedActions {
            let unsupportedTemplateReferences = linkedReferences(
                in: [action.port.URLTemplate, action.healthCheckURL].compactMap { $0 }
            )
            if let unsupported = unsupportedTemplateReferences.sorted().first {
                throw LauncherValidationError.invalidAction(
                    "\(unsupported) cannot be used in URL or health templates; link it through executable arguments, shell commands, or environment values"
                )
            }
            let references = linkedActionReferences(in: action)
            if !references.isEmpty,
               action.runner != .process, action.runner != .shell, action.runner != .ios {
                throw LauncherValidationError.invalidAction(
                    "linked action environment references are supported only by process, shell, or iOS actions"
                )
            }
            if let unavailable = references.sorted().first(where: { availableLinkedValues[$0] == nil }) {
                throw LauncherValidationError.invalidAction(
                    "\(unavailable) must name a HOST, PORT, or URL value exposed by an earlier action"
                )
            }
            if let optionalReference = references.sorted().first(where: { availableLinkedValues[$0]?.required == false }),
               let provider = availableLinkedValues[optionalReference] {
                throw LauncherValidationError.invalidAction(
                    "\(optionalReference) references optional action \(provider.name); linked providers must be required"
                )
            }
            for name in linkedActionEnvironmentNamesExposed(by: action) {
                availableLinkedValues[name] = action
            }
        }
        guard launcher.actions.contains(where: { $0.id == launcher.primaryActionID }) else {
            throw LauncherValidationError.invalidAction("primary action does not exist")
        }
    }

    private static func linkedActionReferences(in action: LaunchAction) -> Set<String> {
        let values = [action.executable, action.shellCommand]
            .compactMap { $0 }
            + action.arguments
            + Array(action.environment.values)
        return linkedReferences(in: values)
    }

    private static func linkedReferences(in values: [String]) -> Set<String> {
        let expression = try! NSRegularExpression(
            pattern: #"\$\{(LAUNCH_STATION_ACTION_[A-Za-z0-9_]+)\}"#
        )
        var references = Set<String>()
        for value in values {
            let source = value as NSString
            for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)) {
                references.insert(source.substring(with: match.range(at: 1)))
            }
        }
        return references
    }

    private static func linkedActionEnvironmentNamesExposed(by action: LaunchAction) -> Set<String> {
        guard action.runner != .url else { return [] }
        let base = linkedActionEnvironmentBase(for: action)
        var names = Set<String>()
        if action.port.mode != .none {
            names.insert("\(base)_HOST")
            names.insert("\(base)_PORT")
            names.insert("\(base)_URL")
        } else if renderedStaticEndpoint(for: action) != nil {
            names.insert("\(base)_URL")
        }
        return names
    }

    public static func validateAction(_ action: LaunchAction, project: ProjectRecord) throws {
        _ = try validatedName(action.name, allowReserved: true)
        guard !action.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherValidationError.invalidAction("description must contain non-whitespace text")
        }
        _ = try resolvedWorkingDirectory(action: action, project: project)
        let reservedManagerEnvironment = Set(["CODEX_PORT", "CODEX_HOST", "CODEX_SERVICE_ID"])
        let configuredEnvironmentNames = Set(action.environment.keys)
            .union(action.inheritedEnvironment)
            .union([action.port.environmentVariable, action.port.hostEnvironmentVariable])
        for name in configuredEnvironmentNames {
            guard isValidEnvironmentName(name) else {
                throw LauncherValidationError.invalidAction("invalid environment variable name: \(name)")
            }
            guard !reservedManagerEnvironment.contains(name) else {
                throw LauncherValidationError.invalidAction("\(name) is reserved for launcher lifecycle management")
            }
        }
        guard action.readyTimeoutSeconds > 0, action.readyTimeoutSeconds <= 600 else {
            throw LauncherValidationError.invalidAction("ready timeout must be between 1 and 600 seconds")
        }
        guard action.stopTimeoutSeconds > 0, action.stopTimeoutSeconds <= 60 else {
            throw LauncherValidationError.invalidAction("stop timeout must be between 1 and 60 seconds")
        }
        switch action.runner {
        case .shell:
            guard let command = action.shellCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LauncherValidationError.invalidAction("shell actions require a command")
            }
            guard action.executable == nil else {
                throw LauncherValidationError.invalidAction("shell actions cannot also store an executable")
            }
        case .process, .ios, .app, .url:
            guard let executable = action.executable, !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LauncherValidationError.invalidAction("\(action.runner.rawValue) actions require an executable or target")
            }
            guard action.shellCommand == nil else {
                throw LauncherValidationError.invalidAction("\(action.runner.rawValue) actions cannot also store a shell command")
            }
        }
        if action.runner == .url, action.allowsRuntimeArguments {
            throw LauncherValidationError.invalidAction("URL actions cannot accept runtime arguments")
        }
        if action.runner == .url, !action.arguments.isEmpty {
            throw LauncherValidationError.invalidAction("URL actions cannot store process arguments")
        }
        if action.runner == .url, let target = action.executable {
            try validateOpenTarget(target)
        }
        if action.openTarget == .application, action.runner != .app {
            throw LauncherValidationError.invalidAction("the application open target requires an app runner")
        }
        if let template = action.port.URLTemplate {
            try validateURLTemplate(template, field: "port URL", schemes: nil)
        }
        if let health = action.healthCheckURL {
            try validateURLTemplate(health, field: "health check", schemes: Set(["http", "https"]))
        }
        if action.port.mode != .none {
            let managedAliases = Set([
                action.port.environmentVariable,
                action.port.hostEnvironmentVariable,
            ])
            if let collision = action.environment.keys.first(where: { managedAliases.contains($0) }) {
                throw LauncherValidationError.invalidAction("managed port alias \(collision) cannot also be configured in the action environment")
            }
            if let collision = action.inheritedEnvironment.first(where: { managedAliases.contains($0) }) {
                throw LauncherValidationError.invalidAction("managed port alias \(collision) cannot also be inherited from the daemon environment")
            }
        }
        if let name = action.environment.keys.first(where: { $0.hasPrefix(linkedActionEnvironmentPrefix) }) {
            throw LauncherValidationError.invalidAction("\(name) is reserved for values from earlier compound actions")
        }
        if let name = action.inheritedEnvironment.first(where: { $0.hasPrefix(linkedActionEnvironmentPrefix) }) {
            throw LauncherValidationError.invalidAction("\(name) is reserved for values from earlier compound actions")
        }
        switch action.port.mode {
        case .none:
            if containsPortPlaceholder(action.port.URLTemplate) || containsPortPlaceholder(action.healthCheckURL) {
                throw LauncherValidationError.invalidPort("a ${PORT} placeholder requires an automatic or fixed port")
            }
            break
        case .automatic:
            guard action.runner == .process || action.runner == .shell || action.runner == .ios else {
                throw LauncherValidationError.invalidPort("only process, shell, or iOS actions may request a managed TCP port")
            }
            guard action.port.fixedPort == nil else {
                throw LauncherValidationError.invalidPort("automatic port actions cannot also store a fixed port")
            }
            try validateManagedPortMetadata(action.port)
        case .fixed:
            guard action.runner == .process || action.runner == .shell || action.runner == .ios else {
                throw LauncherValidationError.invalidPort("only process, shell, or iOS actions may request a managed TCP port")
            }
            guard let fixedPort = action.port.fixedPort, (1...65535).contains(fixedPort) else {
                throw LauncherValidationError.invalidPort("fixed port must be between 1 and 65535")
            }
            try validateManagedPortMetadata(action.port)
        }
        if action.openTarget == .browser, action.runner != .url {
            let endpointTemplate: String?
            if action.port.mode == .none {
                endpointTemplate = action.port.URLTemplate ?? action.healthCheckURL
            } else {
                endpointTemplate = action.port.URLTemplate ?? action.healthCheckURL ?? "http://${HOST}:${PORT}"
            }
            guard let endpointTemplate else {
                throw LauncherValidationError.invalidAction("browser open requires a resolvable HTTP or HTTPS endpoint")
            }
            try validateURLTemplate(endpointTemplate, field: "browser endpoint", schemes: Set(["http", "https"]))
        }
    }

    private static func validateManagedPortMetadata(_ port: PortConfiguration) throws {
        guard !port.logicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherValidationError.invalidPort("logical name must contain non-whitespace text")
        }
        guard validLeaseSeconds(port.lease) != nil else {
            throw LauncherValidationError.invalidPort("lease must look like 90s, 15m, 2h, 1d, or positive seconds")
        }
        guard port.environmentVariable != port.hostEnvironmentVariable else {
            throw LauncherValidationError.invalidPort("port and host environment aliases must be distinct")
        }
    }

    /// Renders a validated endpoint for an action that does not use a managed port. Port
    /// placeholders are intentionally not substituted here: validation rejects them in `.none`
    /// mode, while host aliases deterministically map to the private loopback address.
    public static func renderedStaticEndpoint(for action: LaunchAction) -> String? {
        guard action.port.mode == .none,
              let template = action.port.URLTemplate ?? action.healthCheckURL else { return nil }
        return template
            .replacingOccurrences(of: "${HOST}", with: "127.0.0.1")
            .replacingOccurrences(of: "{{host}}", with: "127.0.0.1")
            .replacingOccurrences(of: "{host}", with: "127.0.0.1")
    }

    private static func validLeaseSeconds(_ input: String) -> Double? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seconds = Double(value), seconds.isFinite, seconds > 0 { return seconds }
        guard let suffix = value.last, "smhd".contains(suffix) else { return nil }
        let number = value.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = Double(number), amount.isFinite, amount > 0 else { return nil }
        let multiplier: Double = suffix == "s" ? 1 : suffix == "m" ? 60 : suffix == "h" ? 3_600 : 86_400
        return amount * multiplier
    }

    private static func validateURLTemplate(_ input: String, field: String, schemes: Set<String>?) throws {
        let rendered = renderURLTemplate(input)
        guard let components = URLComponents(string: rendered),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw LauncherValidationError.invalidAction("\(field) must be an absolute URL after host/port substitution")
        }
        if let schemes, !schemes.contains(scheme) {
            throw LauncherValidationError.invalidAction("\(field) must use \(schemes.sorted().joined(separator: " or "))")
        }
        if scheme == "http" || scheme == "https", components.host == nil {
            throw LauncherValidationError.invalidAction("\(field) must include a host")
        }
    }

    private static func validateOpenTarget(_ input: String) throws {
        if let components = URLComponents(string: input), components.scheme != nil { return }
        let expanded = NSString(string: input).expandingTildeInPath
        guard expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) else {
            throw LauncherValidationError.invalidAction("URL/file targets must be an absolute URL or an existing absolute file path")
        }
    }

    private static func renderURLTemplate(_ input: String) -> String {
        input
            .replacingOccurrences(of: "${HOST}", with: "127.0.0.1")
            .replacingOccurrences(of: "${PORT}", with: "12345")
            .replacingOccurrences(of: "{{host}}", with: "127.0.0.1")
            .replacingOccurrences(of: "{{port}}", with: "12345")
            .replacingOccurrences(of: "{host}", with: "127.0.0.1")
            .replacingOccurrences(of: "{port}", with: "12345")
    }

    private static func containsPortPlaceholder(_ input: String?) -> Bool {
        guard let input else { return false }
        return input.contains("${PORT}") || input.contains("{{port}}") || input.contains("{port}")
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        let remainder = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars.dropFirst().allSatisfy { remainder.contains($0) }
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = normalizeName(value)
            guard seen.insert(key).inserted else { return nil }
            return value
        }.sorted { normalizeName($0) < normalizeName($1) }
    }

    public static func resolvedWorkingDirectory(action: LaunchAction, project: ProjectRecord) throws -> String {
        let path = NSString(string: action.workingDirectory).expandingTildeInPath
        let candidate: String
        if path.hasPrefix("/") {
            candidate = path
        } else {
            candidate = URL(fileURLWithPath: project.directory).appendingPathComponent(path).path
        }
        return try canonicalDirectory(candidate)
    }
}

public enum LauncherCompatibility {
    // Keep one release of daemon compatibility so the renamed GUI can connect
    // during a controlled in-place upgrade without interrupting live sessions.
    public static let minimumServiceVersion = "1.2.0"

    public static func incompatibilityReason(for status: ServiceStatus) -> String? {
        guard status.schemaVersion == LauncherSchema.version else {
            return "service schema \(status.schemaVersion) is incompatible with required schema \(LauncherSchema.version)"
        }
        guard let actual = semanticVersion(status.version),
              let minimum = semanticVersion(minimumServiceVersion),
              !isOrdered(actual, before: minimum) else {
            return "service version \(status.version) is older than required version \(minimumServiceVersion)"
        }
        return nil
    }

    private static func semanticVersion(_ value: String) -> [Int]? {
        let core = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let pieces = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var values: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else { return nil }
            values.append(number)
        }
        while values.count < 3 { values.append(0) }
        return values
    }

    private static func isOrdered(_ lhs: [Int], before rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left < right }
        return false
    }
}

public enum ShellEscaping {
    public static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }
}
