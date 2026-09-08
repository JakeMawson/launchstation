import Foundation

/// A numeric dotted version used by Launch Station's signed-release updater.
///
/// The Homebrew cask and packaged application both require numeric dotted versions, so the
/// updater deliberately declines tags such as a prerelease suffix instead of guessing an order.
public struct AppUpdateVersion: Codable, Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let parsed = parts.compactMap { Int($0) }
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parsed.count == parts.count,
              parsed.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppUpdateVersion, rhs: AppUpdateVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// A bounded, display-only projection of the GitHub latest-release response.
///
/// Its tag and notes are never used to construct a shell command, filesystem path, or install URL.
public struct AppUpdateRelease: Codable, Equatable, Sendable {
    public var tagName: String
    public var name: String?
    public var releaseNotes: String?
    public var publishedAt: Date?
    public var isPrerelease: Bool

    public init(
        tagName: String,
        name: String? = nil,
        releaseNotes: String? = nil,
        publishedAt: Date? = nil,
        isPrerelease: Bool = false
    ) {
        self.tagName = tagName
        self.name = name
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
    }

    public var version: AppUpdateVersion? { AppUpdateVersion(tagName) }

    public var displayVersion: String { version?.description ?? tagName }

    public var conciseNotes: String {
        let lines = normalizedNotes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let summary = lines.prefix(2).joined(separator: " ")
        return summary.isEmpty ? "No release notes were provided for this version." : summary
    }

    public var normalizedNotes: String {
        let trimmed = (releaseNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(16_000))
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case releaseNotes = "body"
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        if let rawDate = try container.decodeIfPresent(String.self, forKey: .publishedAt) {
            publishedAt = ISO8601DateFormatter().date(from: rawDate)
        } else {
            publishedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagName, forKey: .tagName)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)
        if let publishedAt {
            try container.encode(ISO8601DateFormatter().string(from: publishedAt), forKey: .publishedAt)
        }
        try container.encode(isPrerelease, forKey: .isPrerelease)
    }
}
