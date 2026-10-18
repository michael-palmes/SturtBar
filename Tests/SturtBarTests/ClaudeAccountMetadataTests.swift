import Foundation
import Testing
@testable import SturtBarCore

struct ClaudeAccountMetadataTests {
    @Test
    func `only account and organisation changes affect the opaque account key`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("account.json")
        var reader = ClaudeAccountMetadata(url: url)
        func read() -> String? {
            reader.read()
        }
        func write(_ account: String, _ organisation: String, _ extra: String) throws {
            let data = Data("""
            {"oauthAccount":{"accountUuid":"\(account)","organizationUuid":"\(organisation)","emailAddress":"\(extra)"}}
            """.utf8)
            try data.write(to: url, options: .atomic)
        }
        try write("a", "org", "ignored")
        let original = try #require(read())
        #expect(original.count == 64)
        try write("a", "org", "different-unused-value")
        #expect(read() == original)
        try write("a", "another-org", "ignored")
        #expect(read() != original)
        try write("b", "org", "ignored")
        #expect(read() != original)
        try Data("{unfinished".utf8).write(to: url, options: .atomic)
        #expect(read() == nil)
        try write("a", "org", "ignored")
        #expect(read() == original)
        try FileManager.default.removeItem(at: url)
        #expect(read() == nil)
    }
}
