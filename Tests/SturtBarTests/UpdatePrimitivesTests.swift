// UpdatePrimitivesTests.swift — SemanticVersion parsing/ordering, check-policy gating, and
// checksum hashing/parsing for the updater.

import Foundation
import Testing
@testable import SturtBarCore

struct SemanticVersionTests {
    @Test
    func `parses plain and v-prefixed versions`() {
        #expect(SemanticVersion(string: "1.2.0") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion(string: "v1.2.0") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion(string: "V2.0") == SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion(string: "3") == SemanticVersion(major: 3, minor: 0, patch: 0))
    }

    @Test
    func `rejects suffixes and malformed strings`() {
        #expect(SemanticVersion(string: "1.2.0-beta.1") == nil)
        #expect(SemanticVersion(string: "1.2.0.4") == nil)
        #expect(SemanticVersion(string: "1..0") == nil)
        #expect(SemanticVersion(string: "dev") == nil)
        #expect(SemanticVersion(string: "") == nil)
        #expect(SemanticVersion(string: "1.2 ") == nil)
    }

    @Test
    func `orders numerically, not lexically`() throws {
        let v1_2_0 = try #require(SemanticVersion(string: "1.2.0"))
        #expect(try #require(SemanticVersion(string: "1.10.0")) > SemanticVersion(string: "1.9.0")!)
        #expect(try #require(SemanticVersion(string: "2.0.0")) > SemanticVersion(string: "1.99.99")!)
        #expect(try #require(SemanticVersion(string: "1.2.1")) > v1_2_0)
        #expect(!(v1_2_0 > v1_2_0))
        #expect(SemanticVersion(string: "1.2") == v1_2_0)
        #expect("\(v1_2_0)" == "1.2.0")
    }
}

struct UpdateCheckPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func `the enabled flag is a hard gate`() {
        #expect(!UpdateCheckPolicy.shouldCheck(now: self.now, lastCheckedAt: nil, enabled: false))
        #expect(UpdateCheckPolicy.shouldCheck(now: self.now, lastCheckedAt: nil, enabled: true))
    }

    @Test
    func `checks fire only past the 20 hour minimum`() {
        let nineteenHoursAgo = self.now.addingTimeInterval(-19 * 3600)
        let twentyOneHoursAgo = self.now.addingTimeInterval(-21 * 3600)
        #expect(!UpdateCheckPolicy.shouldCheck(now: self.now, lastCheckedAt: nineteenHoursAgo, enabled: true))
        #expect(UpdateCheckPolicy.shouldCheck(now: self.now, lastCheckedAt: twentyOneHoursAgo, enabled: true))
    }

    @Test
    func `next delay targets the daily re-arm with a one minute floor`() {
        #expect(UpdateCheckPolicy.nextCheckDelay(now: self.now, lastCheckedAt: nil) == 60)
        let justChecked = UpdateCheckPolicy.nextCheckDelay(now: self.now, lastCheckedAt: self.now)
        #expect(justChecked == UpdateCheckPolicy.rearmInterval)
        let longOverdue = UpdateCheckPolicy.nextCheckDelay(
            now: self.now,
            lastCheckedAt: self.now.addingTimeInterval(-3 * 24 * 3600))
        #expect(longOverdue == 60)
    }
}

struct UpdateChecksumTests {
    /// SHA-256("abc"), a NIST test vector.
    private static let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-checksum-\(UUID().uuidString)", isDirectory: false)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test
    func `hashes a file with a known vector`() throws {
        let url = try self.tempFile("abc")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try UpdateChecksum.sha256Hex(of: url) == Self.abcDigest)
        #expect(try UpdateChecksum.matches(fileURL: url, expectedHex: Self.abcDigest))
        #expect(try !UpdateChecksum.matches(fileURL: url, expectedHex: String(repeating: "0", count: 64)))
    }

    @Test
    func `parses shasum output including binary-mode names`() {
        let contents = """
        \(Self.abcDigest)  SturtBar-9.9.9.zip
        1111111111111111111111111111111111111111111111111111111111111111 *SturtBar-9.9.9.dmg
        """
        #expect(UpdateChecksum.expectedHex(inChecksumFile: contents, assetName: "SturtBar-9.9.9.zip")
            == Self.abcDigest)
        #expect(UpdateChecksum.expectedHex(inChecksumFile: contents, assetName: "SturtBar-9.9.9.dmg")
            == String(repeating: "1", count: 64))
        #expect(UpdateChecksum.expectedHex(inChecksumFile: contents, assetName: "missing.zip") == nil)
    }

    @Test
    func `normalises GitHub digests and fails closed on malformed input`() {
        #expect(UpdateChecksum.normalisedHex("sha256:\(Self.abcDigest)") == Self.abcDigest)
        #expect(UpdateChecksum.normalisedHex(Self.abcDigest.uppercased()) == Self.abcDigest)
        #expect(UpdateChecksum.normalisedHex("sha256:short") == nil)
        #expect(UpdateChecksum.normalisedHex(String(repeating: "z", count: 64)) == nil)
        #expect(UpdateChecksum.normalisedHex("") == nil)
    }
}
