// SemanticVersion.swift: parses and compares release version strings for the updater.
//
// Strict on purpose: pre-release suffixes and malformed tags fail to parse, and an unparseable
// version is never offered as an update (fail closed, downgrade guard included).

import Foundation

public struct SemanticVersion: Equatable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts "1.2.0", "v1.2.0" or "1.2"; rejects suffixes ("1.2.0-beta.1") and anything malformed.
    public init?(string: String) {
        var raw = Substring(string)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            raw = raw.dropFirst()
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isWholeNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String {
        "\(self.major).\(self.minor).\(self.patch)"
    }
}
