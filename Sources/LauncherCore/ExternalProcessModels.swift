import Foundation

// MARK: - Listener inventory

public enum ExternalAddressFamily: String, Codable, CaseIterable, Sendable {
    case ipv4
    case ipv6
    case name
}

public struct ExternalListenerEndpoint: Codable, Hashable, Identifiable, Sendable {
    public var address: String
    public var port: Int
    public var family: ExternalAddressFamily
    public var isWildcard: Bool

    public init(address: String, port: Int) {
        let normalized = Self.normalizedAddress(address)
        self.address = normalized
        self.port = port
        family = Self.family(for: normalized)
        isWildcard = Self.wildcardAddresses.contains(normalized.lowercased())
    }

    public var id: String { "\(family.rawValue):\(address):\(port)" }

    public var displayValue: String {
        family == .ipv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    /// A wildcard address is not itself a browser destination. This gives clients a safe
    /// loopback host to present when they have independent evidence that the listener is HTTP.
    public var loopbackHost: String {
        if isWildcard { return "127.0.0.1" }
        return address
    }

    fileprivate static func sort(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        if lhs.family.rawValue != rhs.family.rawValue { return lhs.family.rawValue < rhs.family.rawValue }
        return lhs.address.localizedStandardCompare(rhs.address) == .orderedAscending
    }

    private static let wildcardAddresses = Set(["*", "0.0.0.0", "::", "::0"])

    private static func normalizedAddress(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("["), result.hasSuffix("]") {
            result.removeFirst()
            result.removeLast()
        }
        return result.isEmpty ? "*" : result
    }

    private static func family(for address: String) -> ExternalAddressFamily {
        if address.contains(":") { return .ipv6 }
        let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4,
           pieces.allSatisfy({ piece in
               guard let value = Int(piece) else { return false }
               return (0...255).contains(value)
           }) {
            return .ipv4
        }
        if address == "*" { return .name }
        return .name
    }
}

/// One process-level row from an lsof field scan. Repeated file descriptors and repeated
/// address/port rows are collapsed here, before any process metadata is inspected.
public struct ExternalListenerInventoryItem: Codable, Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var shortCommand: String?
    public var endpoints: [ExternalListenerEndpoint]

    public init(pid: Int32, shortCommand: String?, endpoints: [ExternalListenerEndpoint]) {
        self.pid = pid
        self.shortCommand = shortCommand
        self.endpoints = Array(Set(endpoints)).sorted(by: ExternalListenerEndpoint.sort)
    }

    public var id: Int32 { pid }
}

public struct ExternalListenerInventory: Codable, Equatable, Sendable {
    public var processes: [ExternalListenerInventoryItem]
    public var discardedFieldCount: Int

    public init(processes: [ExternalListenerInventoryItem], discardedFieldCount: Int = 0) {
        self.processes = processes.sorted { $0.pid < $1.pid }
        self.discardedFieldCount = discardedFieldCount
    }
}

/// Parser for `lsof -F0pcfn` output. It intentionally accepts only the four fields needed for
/// listener discovery and never treats lsof's short `c` field as the full launch command.
public enum LSOFFieldParser {
    public static func parse(_ data: Data) -> ExternalListenerInventory {
        struct Builder {
            var command: String?
            var endpoints = Set<ExternalListenerEndpoint>()
        }

        var builders: [Int32: Builder] = [:]
        var currentPID: Int32?
        var discarded = 0

        for rawField in data.split(separator: 0, omittingEmptySubsequences: true) {
            var bytes = Array(rawField)
            while let first = bytes.first, first == 10 || first == 13 {
                bytes.removeFirst()
            }
            guard let key = bytes.first else { continue }
            let value = String(decoding: bytes.dropFirst(), as: UTF8.self)

            switch key {
            case 112: // p
                guard let parsed = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
                    currentPID = nil
                    discarded += 1
                    continue
                }
                currentPID = parsed
                if builders[parsed] == nil { builders[parsed] = Builder() }

            case 99: // c
                guard let pid = currentPID else {
                    discarded += 1
                    continue
                }
                let sanitized = ExternalCommandRedactor.sanitizeDisplayText(value, maximumScalars: 256).value
                if !sanitized.isEmpty { builders[pid, default: Builder()].command = sanitized }

            case 110: // n
                guard let pid = currentPID, let endpoint = parseEndpoint(value) else {
                    discarded += 1
                    continue
                }
                builders[pid, default: Builder()].endpoints.insert(endpoint)

            case 102: // f
                // File descriptor boundaries are useful to lsof but do not change the process-level
                // grouping. The following `n` field is all this parser needs.
                continue

            default:
                continue
            }
        }

        let rows = builders.compactMap { pid, builder -> ExternalListenerInventoryItem? in
            guard !builder.endpoints.isEmpty else { return nil }
            return ExternalListenerInventoryItem(
                pid: pid,
                shortCommand: builder.command,
                endpoints: Array(builder.endpoints)
            )
        }
        return ExternalListenerInventory(processes: rows, discardedFieldCount: discarded)
    }

    private static func parseEndpoint(_ raw: String) -> ExternalListenerEndpoint? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: " (LISTEN)", options: [.backwards, .caseInsensitive]),
           range.upperBound == value.endIndex {
            value.removeSubrange(range)
        }
        guard !value.contains("->") else { return nil }

        let address: String
        let portText: Substring
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]"),
                  value.index(after: closing) < value.endIndex,
                  value[value.index(after: closing)] == ":" else { return nil }
            address = String(value[value.index(after: value.startIndex)..<closing])
            portText = value[value.index(closing, offsetBy: 2)...]
        } else {
            guard let separator = value.lastIndex(of: ":"), separator < value.index(before: value.endIndex) else {
                return nil
            }
            address = String(value[..<separator])
            portText = value[value.index(after: separator)...]
        }

        guard let port = Int(portText), (1...65_535).contains(port) else { return nil }
        return ExternalListenerEndpoint(address: address, port: port)
    }
}

// MARK: - Safe process presentation

public enum ExternalCommandProvenance: String, Codable, CaseIterable, Sendable {
    case exactCodexPortRecord = "exact-codex-port-record"
    case processGroupLeader = "process-group-leader"
    case sameProcessGroupAncestor = "same-process-group-ancestor"
    case listenerProcess = "listener-process"
    case shortProcessName = "short-process-name"
    case unavailable
}

public struct ExternalCommandSummary: Codable, Equatable, Sendable {
    public var executable: String?
    /// These values are sanitized and secret-redacted. They are not the raw process argv.
    public var arguments: [String]
    public var shellCommand: String?
    public var displayCommand: String
    public var provenance: ExternalCommandProvenance
    public var sourcePID: Int32?
    public var redactionApplied: Bool
    public var contentSanitized: Bool
    public var unavailableReason: String?

    public init(
        executable: String?,
        arguments: [String] = [],
        shellCommand: String? = nil,
        displayCommand: String,
        provenance: ExternalCommandProvenance,
        sourcePID: Int32? = nil,
        redactionApplied: Bool = false,
        contentSanitized: Bool = false,
        unavailableReason: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.shellCommand = shellCommand
        self.displayCommand = displayCommand
        self.provenance = provenance
        self.sourcePID = sourcePID
        self.redactionApplied = redactionApplied
        self.contentSanitized = contentSanitized
        self.unavailableReason = unavailableReason
    }

    public var isSafeDraftSource: Bool {
        let shellIsSafe = shellCommand.map {
            !ExternalCommandRedactor.containsRedactionMarker($0)
        } ?? true
        return !redactionApplied
            && !contentSanitized
            && unavailableReason == nil
            && !ExternalCommandRedactor.containsRedactionMarker(displayCommand)
            && !arguments.contains(where: ExternalCommandRedactor.containsRedactionMarker)
            && shellIsSafe
    }

    public static func unavailable(shortCommand: String?, reason: String) -> ExternalCommandSummary {
        let cleaned = shortCommand.map {
            ExternalCommandRedactor.sanitizeDisplayText($0, maximumScalars: 256)
        }
        return ExternalCommandSummary(
            executable: nil,
            displayCommand: cleaned?.value ?? "Command unavailable",
            provenance: cleaned == nil ? .unavailable : .shortProcessName,
            redactionApplied: false,
            contentSanitized: cleaned?.changed ?? false,
            unavailableReason: reason
        )
    }
}

public enum ExternalCommandRedactor {
    public static let redactionMarker = "<redacted>"

    public struct SanitizedText: Equatable, Sendable {
        public var value: String
        public var changed: Bool

        public init(value: String, changed: Bool) {
            self.value = value
            self.changed = changed
        }
    }

    private struct RedactedValue {
        var value: String
        var redacted: Bool
        var sanitized: Bool
    }

    private enum NextArgumentPolicy {
        case redact
        case inspectHeader
    }

    public static func redact(
        argv: [String],
        provenance: ExternalCommandProvenance,
        sourcePID: Int32? = nil,
        fallbackExecutable: String? = nil
    ) -> ExternalCommandSummary {
        guard !argv.isEmpty || fallbackExecutable != nil else {
            return .unavailable(shortCommand: nil, reason: "The process argument vector could not be read.")
        }

        let rawExecutable = argv.first ?? fallbackExecutable ?? ""
        let executableResult = redactComponent(rawExecutable)
        var sanitizedArguments: [String] = []
        var redactionApplied = executableResult.redacted
        var contentSanitized = executableResult.sanitized
        var pendingArgumentPolicy: NextArgumentPolicy?

        for raw in argv.dropFirst() {
            let sanitized = sanitizeDisplayText(raw)
            contentSanitized = contentSanitized || sanitized.changed

            if let policy = pendingArgumentPolicy {
                pendingArgumentPolicy = nil
                switch policy {
                case .redact:
                    sanitizedArguments.append(redactionMarker)
                    redactionApplied = true
                    continue
                case .inspectHeader:
                    if isSensitiveHeader(sanitized.value) {
                        sanitizedArguments.append(redactedHeader(sanitized.value))
                        redactionApplied = true
                        continue
                    }
                }
            }

            if let policy = nextArgumentPolicy(for: sanitized.value) {
                sanitizedArguments.append(sanitized.value)
                pendingArgumentPolicy = policy
                continue
            }

            if let attached = redactedAttachedShortCredential(sanitized.value) {
                sanitizedArguments.append(attached)
                redactionApplied = true
                continue
            }

            if let header = redactedInlineHeaderOption(sanitized.value) {
                sanitizedArguments.append(header.value)
                redactionApplied = redactionApplied || header.redacted
                continue
            }

            if let assignment = redactedAssignment(sanitized.value) {
                sanitizedArguments.append(assignment.value)
                redactionApplied = redactionApplied || assignment.redacted
                continue
            }

            let value = redactComponent(sanitized.value, alreadySanitized: true)
            sanitizedArguments.append(value.value)
            redactionApplied = redactionApplied || value.redacted
            contentSanitized = contentSanitized || value.sanitized
        }

        if pendingArgumentPolicy != nil {
            // A dangling secret option does not contain a secret value, but it is not a complete
            // command proposal and therefore must not be saved without review.
            contentSanitized = true
        }

        var shellCommand: String?
        if isShellExecutable(executableResult.value),
           let shellIndex = shellCommandIndex(in: sanitizedArguments) {
            let shell = redactShellCommand(sanitizedArguments[shellIndex])
            sanitizedArguments[shellIndex] = shell.value
            shellCommand = shell.value
            redactionApplied = redactionApplied || shell.redacted
            contentSanitized = contentSanitized || shell.sanitized
        }

        let display = ShellEscaping.command(
            executable: executableResult.value,
            arguments: sanitizedArguments
        )
        return ExternalCommandSummary(
            executable: executableResult.value.isEmpty ? nil : executableResult.value,
            arguments: sanitizedArguments,
            shellCommand: shellCommand,
            displayCommand: display,
            provenance: provenance,
            sourcePID: sourcePID,
            redactionApplied: redactionApplied,
            contentSanitized: contentSanitized
        )
    }

    public static func redactShellCommand(_ raw: String) -> (value: String, redacted: Bool, sanitized: Bool) {
        let sanitized = sanitizeDisplayText(raw, maximumScalars: 16_384)
        var value = sanitized.value
        var redacted = false

        if sanitized.changed {
            // Removing control/escape bytes or truncating a command can also remove syntax that
            // changes how the shell constructs its arguments. A modified observation is therefore
            // not safe to publish as a reusable command, even when the remaining text looks benign.
            return (redactionMarker, true, true)
        }

        if value.contains("-----BEGIN ") || value.contains("-----END ") {
            return (redactionMarker, true, true)
        }

        if containsOpaqueShellExpansion(in: value) {
            // Only a deliberately small literal shell grammar is safe to show. Quoting, escapes,
            // secondary evaluation, substitutions, control operators, redirection, comments, and
            // pathname expansion can all construct a credential option that is absent from the
            // top-level words. The observer must not emulate a shell, so hide the complete command
            // and require the user to enter a reusable definition explicitly.
            return (redactionMarker, true, true)
        }

        if containsSensitiveShellSyntax(in: value) {
            // Shell words may combine short options, quoting, escaped whitespace, and adjacent
            // quoted fragments (`-4uuser:'top secret'`). Trying to preserve only that word risks
            // exposing a suffix. Fail closed for the complete shell command once a credential-
            // consuming -u/-U cluster is detected; the public draft then requires re-entry.
            return (redactionMarker, true, true)
        }

        let secretNamePattern = secretNames.union(alwaysRedactedOptions)
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        let replacements: [(String, String)] = [
            (#"(?i)(--(?:\#(secretNamePattern))(?:=|\s+))(?:\"[^\"]*\"|'[^']*'|[^\s;&|]+)"#, "$1\(redactionMarker)"),
            (#"(?i)\b([A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_KEY|APIKEY|PRIVATE_KEY|CREDENTIALS?|AUTHORIZATION|DATABASE_URL|COOKIE|SESSION)[A-Za-z0-9_]*=)(?:\"[^\"]*\"|'[^']*'|[^\s;&|]+)"#, "$1\(redactionMarker)"),
            (#"(?i)(://)[^/@\s]+@"#, "$1\(redactionMarker)@"),
            (#"(?i)([?&](?:access_token|refresh_token|id_token|token|api_key|apikey|secret|password|client_secret|authorization)=)[^&#\s]*"#, "$1\(redactionMarker)"),
            (#"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1\(redactionMarker)"),
            (#"\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, redactionMarker),
            (#"(?i)\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|npm_[A-Za-z0-9]{8,}|(?:AKIA|ASIA)[0-9A-Z]{16})\b"#, redactionMarker),
        ]

        for (pattern, template) in replacements {
            let result = replacing(pattern: pattern, in: value, with: template)
            value = result.value
            redacted = redacted || result.changed
        }

        if containsLikelySecretIndicator(value), !quotesAreBalanced(value), !redacted {
            return (redactionMarker, true, true)
        }
        return (value, redacted, sanitized.changed)
    }

    public static func sanitizeDisplayText(
        _ input: String,
        maximumScalars: Int = 4_096
    ) -> SanitizedText {
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var changed = false

        while index < scalars.count, output.count < maximumScalars {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                changed = true
                index += 1
                guard index < scalars.count else { break }
                if scalars[index].value == 0x5B { // CSI
                    index += 1
                    while index < scalars.count {
                        let value = scalars[index].value
                        index += 1
                        if (0x40...0x7E).contains(value) { break }
                    }
                    continue
                }
                if scalars[index].value == 0x5D { // OSC
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x07 {
                            index += 1
                            break
                        }
                        if scalars[index].value == 0x1B,
                           index + 1 < scalars.count,
                           scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }
                // Unknown escape sequence: discard its introducer and one selector byte.
                index += 1
                continue
            }

            if CharacterSet.controlCharacters.contains(scalar) {
                changed = true
                output.append(" ")
            } else {
                output.append(scalar)
            }
            index += 1
        }

        if index < scalars.count {
            changed = true
            output.append("…")
        }
        return SanitizedText(value: String(output), changed: changed)
    }

    public static func containsRedactionMarker(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains(redactionMarker)
    }

    private static let secretNames: Set<String> = [
        "token", "access-token", "refresh-token", "id-token", "api-key", "apikey",
        "secret", "client-secret", "password", "passwd", "passphrase", "credential",
        "credentials", "auth", "authorization", "bearer", "cookie", "session",
        "private-key", "signing-key", "database-url", "db-url", "connection-string",
        "aws-secret-access-key", "npm-token",
    ]

    private static let alwaysRedactedOptions: Set<String> = [
        "u", "user", "proxy-user", "oauth2-bearer", "key-passphrase",
    ]

    private static let inspectedHeaderOptions: Set<String> = [
        "header", "proxy-header",
    ]

    private static func nextArgumentPolicy(for value: String) -> NextArgumentPolicy? {
        guard value.hasPrefix("-") else { return nil }
        let normalized = String(value.drop(while: { $0 == "-" }))
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if secretNames.contains(normalized) || alwaysRedactedOptions.contains(normalized) {
            return .redact
        }
        if !value.hasPrefix("--"),
           normalized.count > 1,
           normalized.last == "u" {
            // Conservatively treat a short-option cluster ending in curl's -u/-U as consuming
            // the next credential token (for example `-su person:secret`).
            return .redact
        }
        if !value.hasPrefix("--"),
           value.dropFirst().last == "H" {
            // curl permits clustered short options and `H` consumes the following argument.
            // `-sH X-API-Key:...` must receive the same inspection as exact `-H`.
            return .inspectHeader
        }
        if inspectedHeaderOptions.contains(normalized) {
            return .inspectHeader
        }
        return nil
    }

    private static func isSensitiveHeader(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ":") else { return false }
        let name = value[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return [
            "authorization", "proxy-authorization", "cookie", "set-cookie",
            "x-api-key", "api-key", "x-auth-token", "x-access-token",
        ].contains(name)
    }

    private static func redactedHeader(_ value: String) -> String {
        guard let separator = value.firstIndex(of: ":") else { return redactionMarker }
        return String(value[...separator]) + " " + redactionMarker
    }

    private static func redactedAssignment(_ value: String) -> (value: String, redacted: Bool)? {
        guard let equals = value.firstIndex(of: "=") else { return nil }
        let key = String(value[..<equals])
        let normalizedOption = String(key.drop(while: { $0 == "-" }))
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let isSecretOption = key.hasPrefix("-")
            && (secretNames.contains(normalizedOption) || alwaysRedactedOptions.contains(normalizedOption))
        let isSecretEnvironment = !key.hasPrefix("-") && isSecretEnvironmentName(key)
        guard isSecretOption || isSecretEnvironment else { return nil }
        return ("\(key)=\(redactionMarker)", true)
    }

    private static func redactedInlineHeaderOption(_ value: String) -> (value: String, redacted: Bool)? {
        let lowered = value.lowercased()
        let prefixes = ["--header=", "--proxy-header="]
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            let header = String(value.dropFirst(prefix.count))
            guard isSensitiveHeader(header) else { return (value, false) }
            return (String(value.prefix(prefix.count)) + redactedHeader(header), true)
        }
        if value.hasPrefix("-"),
           !value.hasPrefix("--"),
           let optionIndex = value.dropFirst().firstIndex(of: "H"),
           optionIndex < value.index(before: value.endIndex) {
            let headerStart = value.index(after: optionIndex)
            let header = String(value[headerStart...])
            guard isSensitiveHeader(header) else { return (value, false) }
            return (String(value[...optionIndex]) + redactedHeader(header), true)
        }
        return nil
    }

    /// `curl -uUSER:PASS` and `curl -UPROXY_USER:PASS` attach the secret value to the
    /// option token, so the ordinary "redact the next argv element" path never sees it.
    /// Redact these conservative credential forms regardless of the executable name: a false
    /// positive is preferable to publishing a credential from another CLI with the same syntax.
    private static func redactedAttachedShortCredential(_ value: String) -> String? {
        guard value.count > 2,
              value.hasPrefix("-"),
              !value.hasPrefix("--") else { return nil }
        let body = value.dropFirst()
        guard let optionIndex = body.firstIndex(where: { $0 == "u" || $0 == "U" }),
              optionIndex < body.index(before: body.endIndex) else { return nil }
        let optionCluster = body[...optionIndex]
        return "-\(optionCluster)\(redactionMarker)"
    }

    private static func containsSensitiveShellSyntax(in value: String) -> Bool {
        let words = literalShellWords(value)
        for index in words.indices {
            let word = words[index]
            if redactedAttachedShortCredential(word) != nil { return true }
            if let policy = nextArgumentPolicy(for: word) {
                switch policy {
                case .redact:
                    return true
                case .inspectHeader:
                    if words.indices.contains(index + 1), isSensitiveHeader(words[index + 1]) {
                        return true
                    }
                }
            }
            if redactedInlineHeaderOption(word)?.redacted == true { return true }
            if redactedAssignment(word)?.redacted == true { return true }
            if redactComponent(word, alreadySanitized: true).redacted { return true }
        }
        return false
    }

    private static func containsOpaqueShellExpansion(in value: String) -> Bool {
        // Preserve only ordinary unquoted ASCII command words. This is intentionally stricter
        // than a shell parser: every other scalar may alter tokenization or perform expansion in
        // at least one supported user's shell. Examples deliberately rejected here include
        // `eval '...'`, `sh -c "..."`, backslash continuations, `$'...'`, and `curl -? ...`
        // where a matching filename could expand to `-u`.
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x20, // space
                 0x25, // %
                 0x2B, // +
                 0x2C, // ,
                 0x2D, // -
                 0x2E, // .
                 0x2F, // /
                 0x30...0x39, // 0-9
                 0x3A, // :
                 0x3D, // =
                 0x40, // @
                 0x41...0x5A, // A-Z
                 0x5F, // _
                 0x61...0x7A: // a-z
                continue
            default:
                return true
            }
        }
        return false
    }

    /// Reduces literal shell quoting and backslash escaping to the words they produce, without
    /// expanding variables or executing anything. This is intentionally only a security scanner:
    /// control operators split words, and any statically visible sensitive option causes the
    /// complete public shell command to be redacted.
    private static func literalShellWords(_ source: String) -> [String] {
        enum Quote { case single, double }
        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaped = false

        func flush() {
            if !current.isEmpty {
                words.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for character in source {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch quote {
            case .some(.single):
                if character == "'" { quote = nil }
                else { current.append(character) }
            case .some(.double):
                if character == "\"" { quote = nil }
                else if character == "\\" { escaped = true }
                else { current.append(character) }
            case .none:
                if character == "'" { quote = .single }
                else if character == "\"" { quote = .double }
                else if character == "\\" { escaped = true }
                else if character.isWhitespace || ";&|()<>".contains(character) { flush() }
                else { current.append(character) }
            }
        }
        if escaped { current.append("\\") }
        flush()
        return words
    }

    private static func isSecretEnvironmentName(_ value: String) -> Bool {
        let tokens = value.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let exact = Set([
            "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE", "APIKEY", "AUTH",
            "AUTHORIZATION", "BEARER", "COOKIE", "SESSION", "CREDENTIAL", "CREDENTIALS",
            "PASS", "PWD",
        ])
        if tokens.contains(where: { exact.contains(String($0)) }) { return true }
        let normalized = tokens.joined(separator: "_")
        return normalized == "DATABASE_URL"
            || normalized == "DB_URL"
            || normalized == "PRIVATE_KEY"
            || normalized == "CLIENT_SECRET"
            || normalized == "AWS_SECRET_ACCESS_KEY"
            || normalized == "CONNECTION_STRING"
            || normalized.hasSuffix("_API_KEY")
            || normalized.hasSuffix("PASS")
            || normalized.hasSuffix("PWD")
    }

    private static func redactComponent(_ raw: String, alreadySanitized: Bool = false) -> RedactedValue {
        let sanitized = alreadySanitized
            ? SanitizedText(value: raw, changed: false)
            : sanitizeDisplayText(raw)
        var value = sanitized.value
        var redacted = false

        if value.contains("-----BEGIN ") || value.contains("-----END ") {
            return RedactedValue(value: redactionMarker, redacted: true, sanitized: true)
        }

        let replacements: [(String, String)] = [
            (#"(?i)(://)[^/@\s]+@"#, "$1\(redactionMarker)@"),
            (#"(?i)([?&](?:access_token|refresh_token|id_token|token|api_key|apikey|secret|password|client_secret|authorization)=)[^&#\s]*"#, "$1\(redactionMarker)"),
            (#"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1\(redactionMarker)"),
            (#"\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, redactionMarker),
            (#"(?i)\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|npm_[A-Za-z0-9]{8,}|(?:AKIA|ASIA)[0-9A-Z]{16})\b"#, redactionMarker),
        ]
        for (pattern, template) in replacements {
            let result = replacing(pattern: pattern, in: value, with: template)
            value = result.value
            redacted = redacted || result.changed
        }
        return RedactedValue(value: value, redacted: redacted, sanitized: sanitized.changed)
    }

    private static func replacing(pattern: String, in source: String, with template: String) -> (value: String, changed: Bool) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return (source, false)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard expression.firstMatch(in: source, range: range) != nil else {
            return (source, false)
        }
        return (expression.stringByReplacingMatches(in: source, range: range, withTemplate: template), true)
    }

    private static func isShellExecutable(_ executable: String) -> Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        return ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(name)
    }

    private static func shellCommandIndex(in arguments: [String]) -> Int? {
        for index in arguments.indices.dropLast() {
            let option = arguments[index]
            if option == "-c" || (option.hasPrefix("-") && option.dropFirst().contains("c")) {
                return arguments.index(after: index)
            }
        }
        return nil
    }

    private static func containsLikelySecretIndicator(_ source: String) -> Bool {
        let lowered = source.lowercased()
        return secretNames.contains(where: { lowered.contains($0) })
            || lowered.contains("api_key")
            || lowered.contains("private_key")
    }

    private static func quotesAreBalanced(_ source: String) -> Bool {
        enum Quote { case single, double }
        var quote: Quote?
        var escaped = false
        for character in source {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote != .single {
                escaped = true
                continue
            }
            switch (quote, character) {
            case (nil, "'"): quote = .single
            case (nil, "\""): quote = .double
            case (.single?, "'"): quote = nil
            case (.double?, "\""): quote = nil
            default: break
            }
        }
        return quote == nil && !escaped
    }
}

// MARK: - Correlation and observations

public struct ExternalExecutableIdentity: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum ExternalProcessOwnershipKind: String, Codable, CaseIterable, Sendable {
    case launcherOwned = "launcher-owned"
    case codexPort = "codex-port"
    case external
    case ambiguous
}

public struct ExternalProcessOwnership: Codable, Equatable, Sendable {
    public var kind: ExternalProcessOwnershipKind
    public var launcherID: UUID?
    public var sessionID: UUID?
    public var actionRunID: UUID?
    public var codexPortManagerID: String?
    public var message: String

    public init(
        kind: ExternalProcessOwnershipKind,
        launcherID: UUID? = nil,
        sessionID: UUID? = nil,
        actionRunID: UUID? = nil,
        codexPortManagerID: String? = nil,
        message: String
    ) {
        self.kind = kind
        self.launcherID = launcherID
        self.sessionID = sessionID
        self.actionRunID = actionRunID
        self.codexPortManagerID = codexPortManagerID
        self.message = message
    }

    public static let external = ExternalProcessOwnership(
        kind: .external,
        message: "This listener was started separately and is not owned by Launch Station."
    )
}

public struct ExternalLauncherRunCorrelation: Codable, Equatable, Sendable {
    public var launcherID: UUID
    public var sessionID: UUID
    public var actionRunID: UUID
    public var pid: Int32?
    public var processGroupID: Int32?
    public var pidStartIdentity: String?
    public var managerID: String?

    public init(
        launcherID: UUID,
        sessionID: UUID,
        actionRunID: UUID,
        pid: Int32?,
        processGroupID: Int32?,
        pidStartIdentity: String?,
        managerID: String? = nil
    ) {
        self.launcherID = launcherID
        self.sessionID = sessionID
        self.actionRunID = actionRunID
        self.pid = pid
        self.processGroupID = processGroupID
        self.pidStartIdentity = pidStartIdentity
        self.managerID = managerID
    }
}

public struct ExternalCodexPortCorrelation: Codable, Equatable, Sendable {
    public var managerID: String
    public var pid: Int32
    public var processGroupID: Int32
    /// Launcher-format PID birth identity, not codex-port's human-readable start label.
    public var pidStartIdentity: String
    public var listenerPIDs: [Int32]

    public init(
        managerID: String,
        pid: Int32,
        processGroupID: Int32,
        pidStartIdentity: String,
        listenerPIDs: [Int32]
    ) {
        self.managerID = managerID
        self.pid = pid
        self.processGroupID = processGroupID
        self.pidStartIdentity = pidStartIdentity
        self.listenerPIDs = Array(Set(listenerPIDs)).sorted()
    }
}

public struct ExternalCorrelationInput: Codable, Equatable, Sendable {
    public var launcherRuns: [ExternalLauncherRunCorrelation]
    public var codexPortRuns: [ExternalCodexPortCorrelation]
    public var protectedPIDs: [Int32]

    public init(
        launcherRuns: [ExternalLauncherRunCorrelation] = [],
        codexPortRuns: [ExternalCodexPortCorrelation] = [],
        protectedPIDs: [Int32] = []
    ) {
        self.launcherRuns = launcherRuns
        self.codexPortRuns = codexPortRuns
        self.protectedPIDs = Array(Set(protectedPIDs)).sorted()
    }
}

public struct ExternalProcessObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var pid: Int32
    public var pidStartIdentity: String
    public var startedAt: Date
    public var userID: UInt32
    public var parentPID: Int32
    public var processGroupID: Int32
    public var processGroupLeaderPID: Int32?
    public var processGroupLeaderStartIdentity: String?
    public var executablePath: String?
    public var executableIdentity: ExternalExecutableIdentity?
    public var workingDirectory: String?
    public var command: ExternalCommandSummary
    public var endpoints: [ExternalListenerEndpoint]
    public var ownership: ExternalProcessOwnership
    public var observedAt: Date
    public var canClose: Bool
    public var closeDisabledReason: String?

    public init(
        id: UUID = UUID(),
        pid: Int32,
        pidStartIdentity: String,
        startedAt: Date,
        userID: UInt32,
        parentPID: Int32,
        processGroupID: Int32,
        processGroupLeaderPID: Int32? = nil,
        processGroupLeaderStartIdentity: String? = nil,
        executablePath: String? = nil,
        executableIdentity: ExternalExecutableIdentity? = nil,
        workingDirectory: String? = nil,
        command: ExternalCommandSummary,
        endpoints: [ExternalListenerEndpoint],
        ownership: ExternalProcessOwnership,
        observedAt: Date = Date(),
        canClose: Bool,
        closeDisabledReason: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.pidStartIdentity = pidStartIdentity
        self.startedAt = startedAt
        self.userID = userID
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.processGroupLeaderPID = processGroupLeaderPID
        self.processGroupLeaderStartIdentity = processGroupLeaderStartIdentity
        self.executablePath = executablePath
        self.executableIdentity = executableIdentity
        self.workingDirectory = workingDirectory
        self.command = command
        self.endpoints = Array(Set(endpoints)).sorted(by: ExternalListenerEndpoint.sort)
        self.ownership = ownership
        self.observedAt = observedAt
        self.canClose = canClose
        self.closeDisabledReason = closeDisabledReason
    }
}

public struct ExternalProcessSnapshot: Codable, Equatable, Sendable {
    public var scannedAt: Date
    public var observations: [ExternalProcessObservation]
    public var isComplete: Bool
    public var isStale: Bool
    public var warning: String?

    public init(
        scannedAt: Date,
        observations: [ExternalProcessObservation],
        isComplete: Bool,
        isStale: Bool = false,
        warning: String? = nil
    ) {
        self.scannedAt = scannedAt
        self.observations = observations
        self.isComplete = isComplete
        self.isStale = isStale
        self.warning = warning
    }
}

// MARK: - Confirmation-bound close primitives

public struct ExternalCloseIntent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var token: String
    public var observationID: UUID
    public var expiresAt: Date
    public var pid: Int32
    public var startedAt: Date
    public var command: String
    public var endpoints: [ExternalListenerEndpoint]
    public var ownership: ExternalProcessOwnership
    public var warning: String
    public var confirmationText: String

    public init(
        id: UUID = UUID(),
        token: String,
        observationID: UUID,
        expiresAt: Date,
        pid: Int32,
        startedAt: Date,
        command: String,
        endpoints: [ExternalListenerEndpoint],
        ownership: ExternalProcessOwnership,
        warning: String,
        confirmationText: String
    ) {
        self.id = id
        self.token = token
        self.observationID = observationID
        self.expiresAt = expiresAt
        self.pid = pid
        self.startedAt = startedAt
        self.command = command
        self.endpoints = endpoints
        self.ownership = ownership
        self.warning = warning
        self.confirmationText = confirmationText
    }
}

public struct ExternalCloseRequest: Codable, Equatable, Sendable {
    public var observationID: UUID
    public var intentToken: String
    public var confirmationText: String

    public init(observationID: UUID, intentToken: String, confirmationText: String) {
        self.observationID = observationID
        self.intentToken = intentToken
        self.confirmationText = confirmationText
    }
}

public enum ExternalCloseOutcome: String, Codable, CaseIterable, Sendable {
    case stopped
    case alreadyExited = "already-exited"
    case stillRunning = "still-running"
    case delegatedToCodexPort = "delegated-to-codex-port"
}

public struct ExternalCloseResult: Codable, Equatable, Sendable {
    public var observationID: UUID
    public var outcome: ExternalCloseOutcome
    public var message: String

    public init(observationID: UUID, outcome: ExternalCloseOutcome, message: String) {
        self.observationID = observationID
        self.outcome = outcome
        self.message = message
    }
}

// MARK: - Editable launcher draft proposal

public enum ExternalDraftRunner: String, Codable, CaseIterable, Sendable {
    case process
    case shell
}

public enum ExternalDraftPortMode: String, Codable, CaseIterable, Sendable {
    case reviewRequired = "review-required"
    case automatic
    case fixed
    case none
}

public struct ExternalDraftPortPolicy: Codable, Equatable, Sendable {
    public var mode: ExternalDraftPortMode
    public var fixedPort: Int?

    public init(mode: ExternalDraftPortMode = .reviewRequired, fixedPort: Int? = nil) {
        self.mode = mode
        self.fixedPort = fixedPort
    }
}

public enum ExternalDraftBlocker: String, Codable, CaseIterable, Sendable {
    case nameRequired = "name-required"
    case descriptionRequired = "description-required"
    case commandUnavailable = "command-unavailable"
    case redactedCommand = "redacted-command"
    case sanitizedCommand = "sanitized-command"
    case commandReviewRequired = "command-review-required"
    case projectDirectoryRequired = "project-directory-required"
    case portPolicyReviewRequired = "port-policy-review-required"
    case managedPortConsumptionRequired = "managed-port-consumption-required"
}

public struct ExternalLauncherDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourceObservationID: UUID
    public var name: String
    public var description: String
    public var projectDirectory: String
    public var runner: ExternalDraftRunner
    public var executable: String?
    public var arguments: [String]
    public var shellCommand: String?
    public var displayCommand: String
    public var observedEndpoints: [ExternalListenerEndpoint]
    public var portPolicy: ExternalDraftPortPolicy
    public var commandReviewComplete: Bool
    public var sourceHadRedactions: Bool
    public var sourceWasSanitized: Bool

    public init(
        id: UUID = UUID(),
        sourceObservationID: UUID,
        name: String,
        description: String,
        projectDirectory: String,
        runner: ExternalDraftRunner,
        executable: String?,
        arguments: [String],
        shellCommand: String?,
        displayCommand: String,
        observedEndpoints: [ExternalListenerEndpoint],
        portPolicy: ExternalDraftPortPolicy = ExternalDraftPortPolicy(),
        commandReviewComplete: Bool,
        sourceHadRedactions: Bool,
        sourceWasSanitized: Bool
    ) {
        self.id = id
        self.sourceObservationID = sourceObservationID
        self.name = name
        self.description = description
        self.projectDirectory = projectDirectory
        self.runner = runner
        self.executable = executable
        self.arguments = arguments
        self.shellCommand = shellCommand
        self.displayCommand = displayCommand
        self.observedEndpoints = observedEndpoints
        self.portPolicy = portPolicy
        self.commandReviewComplete = commandReviewComplete
        self.sourceHadRedactions = sourceHadRedactions
        self.sourceWasSanitized = sourceWasSanitized
    }

    public var blockers: [ExternalDraftBlocker] {
        var result: [ExternalDraftBlocker] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.nameRequired)
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.descriptionRequired)
        }
        if projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.projectDirectoryRequired)
        }
        switch runner {
        case .process:
            if executable?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                result.append(.commandUnavailable)
            }
        case .shell:
            if shellCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                result.append(.commandUnavailable)
            }
        }
        if sourceHadRedactions
            || ExternalCommandRedactor.containsRedactionMarker(displayCommand)
            || arguments.contains(where: ExternalCommandRedactor.containsRedactionMarker)
            || shellCommand.map(ExternalCommandRedactor.containsRedactionMarker) == true {
            result.append(.redactedCommand)
        }
        if sourceWasSanitized { result.append(.sanitizedCommand) }
        if !commandReviewComplete { result.append(.commandReviewRequired) }
        if portPolicy.mode == .reviewRequired { result.append(.portPolicyReviewRequired) }
        if portPolicy.mode == .fixed,
           !(1...65_535).contains(portPolicy.fixedPort ?? 0) {
            result.append(.portPolicyReviewRequired)
        }
        if portPolicy.mode == .automatic, !explicitlyConsumesManagedPort {
            result.append(.managedPortConsumptionRequired)
        }
        var seen = Set<ExternalDraftBlocker>()
        return result.filter { seen.insert($0).inserted }
    }

    public var canSave: Bool { blockers.isEmpty }

    /// Add Launcher may assign a fresh port only when the reviewed definition proves how that
    /// allocation reaches the command. Expo is the one exception because ProcessSupervisor
    /// deterministically injects its managed `--port` flag at launch time.
    public var explicitlyConsumesManagedPort: Bool {
        if isRecognizedExpoCommand { return true }
        switch runner {
        case .process:
            return arguments.contains { argument in
                argument.contains("${PORT}") || argument.contains("${CODEX_PORT}")
            }
        case .shell:
            guard let shellCommand else { return false }
            return shellCommand.range(
                of: #"\$(?:\{(?:CODEX_)?PORT\}|(?:CODEX_)?PORT\b)"#,
                options: .regularExpression
            ) != nil
        }
    }

    private var isRecognizedExpoCommand: Bool {
        let executableName = executable.map {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased()
        } ?? ""
        if executableName == "expo" { return true }
        if executableName == "npx", arguments.contains(where: { $0.lowercased() == "expo" }) {
            return true
        }
        return shellCommand?.range(
            of: #"(^|\s)(npx\s+)?expo(\s|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

public enum ExternalLauncherDraftProposal {
    public static func make(from observation: ExternalProcessObservation) -> ExternalLauncherDraft {
        let command = observation.command
        let directory = observation.workingDirectory ?? ""
        let baseName = URL(fileURLWithPath: directory).lastPathComponent
        let executableName = command.executable.map { URL(fileURLWithPath: $0).lastPathComponent }
        let rawName = [baseName, executableName].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " ")
        let suggestedName = String((rawName.isEmpty ? "Detected listener" : rawName).prefix(80))
        let ports = observation.endpoints.map(\.port).sorted().map(String.init).joined(separator: ", ")
        let description = ports.isEmpty
            ? "Start the detected local process"
            : "Start the detected local process on observed port\(observation.endpoints.count == 1 ? "" : "s") \(ports)"

        let shell = command.shellCommand
        let safeSource = command.isSafeDraftSource
        return ExternalLauncherDraft(
            sourceObservationID: observation.id,
            name: suggestedName,
            description: description,
            projectDirectory: directory,
            runner: shell == nil ? .process : .shell,
            executable: safeSource && shell == nil ? command.executable : nil,
            arguments: safeSource && shell == nil ? command.arguments : [],
            shellCommand: safeSource ? shell : nil,
            displayCommand: command.displayCommand,
            observedEndpoints: observation.endpoints,
            commandReviewComplete: safeSource,
            sourceHadRedactions: command.redactionApplied,
            sourceWasSanitized: command.contentSanitized
        )
    }
}
