// UpdateChecksum.swift: SHA-256 hashing and checksum-file parsing for downloaded updates.

import CryptoKit
import Foundation

public enum UpdateChecksum {
    /// Streamed SHA-256 so the download never loads fully into memory.
    public static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Parses `shasum -a 256` output ("<hex>  <name>") and returns the digest for the named asset.
    public static func expectedHex(inChecksumFile contents: String, assetName: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let hex = fields.first, let rawName = fields.last else { continue }
            // shasum prefixes binary-mode names with "*".
            let name = rawName.hasPrefix("*") ? String(rawName.dropFirst()) : String(rawName)
            guard name == assetName else { continue }
            return Self.normalisedHex(String(hex))
        }
        return nil
    }

    /// Accepts a bare hex digest or GitHub's "sha256:<hex>" asset digest form; nil when malformed.
    public static func normalisedHex(_ raw: String) -> String? {
        var value = raw.lowercased()
        if value.hasPrefix("sha256:") {
            value = String(value.dropFirst("sha256:".count))
        }
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    /// Fail-closed comparison: a malformed expected digest never matches.
    public static func matches(fileURL: URL, expectedHex: String) throws -> Bool {
        guard let expected = normalisedHex(expectedHex) else { return false }
        return try Self.sha256Hex(of: fileURL) == expected
    }
}
