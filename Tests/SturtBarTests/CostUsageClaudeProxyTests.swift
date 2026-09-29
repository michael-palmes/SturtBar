import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageClaudeProxyTests {
    private static func entry(
        iso: String,
        messageId: String?,
        requestId: String? = nil,
        sessionId: String? = "session_proxy",
        stopReason: Any? = "end_turn",
        usage: [String: Any]) -> [String: Any]
    {
        var message: [String: Any] = ["model": "claude-opus-5", "usage": usage]
        if let messageId { message["id"] = messageId }
        if let stopReason { message["stop_reason"] = stopReason }
        var entry: [String: Any] = ["message": message, "type": "assistant", "timestamp": iso]
        if let requestId { entry["requestId"] = requestId }
        if let sessionId { entry["sessionId"] = sessionId }
        return entry
    }

    private static func parse(_ entries: [[String: Any]]) throws -> [CostUsageScanner.ClaudeUsageRow] {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 22)
        let url = try env.writeClaudeProjectFile(relativePath: "proxy/session.jsonl", contents: env.jsonl(entries))
        return CostUsageScanner.parseClaudeFile(
            fileURL: url,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all).rows
    }

    private static func iso() throws -> String {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        return try env.isoString(for: env.makeLocalNoon(year: 2026, month: 9, day: 22))
    }

    @Test
    func `repeated proxy snapshots without request ids count once`() throws {
        let iso = try Self.iso()
        let usage: (Int) -> [String: Any] = { output in
            [
                "input_tokens": 100,
                "cache_read_input_tokens": 0,
                "cache_creation_input_tokens": 0,
                "output_tokens": output,
            ]
        }
        let rows = try Self.parse([
            Self.entry(iso: iso, messageId: "msg_a", usage: usage(10)),
            Self.entry(iso: iso, messageId: "msg_a", usage: usage(50)),
            Self.entry(iso: iso, messageId: "msg_b", usage: usage(5)),
        ])

        #expect(rows.count == 2)
        #expect(rows.first { $0.messageId == "msg_a" }?.output == 50)
    }

    @Test
    func `rows without any identity stay distinct`() throws {
        let iso = try Self.iso()
        let usage: [String: Any] = ["input_tokens": 10, "output_tokens": 1]
        let rows = try Self.parse([
            Self.entry(iso: iso, messageId: nil, sessionId: nil, usage: usage),
            Self.entry(iso: iso, messageId: nil, sessionId: nil, usage: usage),
        ])

        #expect(rows.count == 2)
    }

    @Test
    func `a preliminary proxy estimate gives way to the final row`() throws {
        let iso = try Self.iso()
        let rows = try Self.parse([
            Self.entry(
                iso: iso,
                messageId: "msg_c",
                stopReason: NSNull(),
                usage: ["input_tokens": 5000, "output_tokens": 0]),
            Self.entry(
                iso: iso,
                messageId: "msg_c",
                usage: [
                    "input_tokens": 200,
                    "cache_read_input_tokens": 4800,
                    "cache_creation_input_tokens": 0,
                    "output_tokens": 60,
                ]),
        ])

        #expect(rows.count == 1)
        #expect(rows.first?.input == 200)
        #expect(rows.first?.cacheRead == 4800)
    }

    @Test
    func `a lone preliminary proxy estimate is not counted`() throws {
        let iso = try Self.iso()
        let rows = try Self.parse([
            Self.entry(
                iso: iso,
                messageId: "msg_d",
                stopReason: NSNull(),
                usage: ["input_tokens": 5000, "output_tokens": 0]),
        ])

        #expect(rows.isEmpty)
    }

    @Test
    func `a streamed claude code chunk with cache fields is still counted`() throws {
        let iso = try Self.iso()
        let rows = try Self.parse([
            Self.entry(
                iso: iso,
                messageId: "msg_e",
                requestId: "req_e",
                stopReason: NSNull(),
                usage: [
                    "input_tokens": 6,
                    "cache_read_input_tokens": 1000,
                    "cache_creation_input_tokens": 50,
                    "output_tokens": 0,
                ]),
        ])

        #expect(rows.count == 1)
    }
}
