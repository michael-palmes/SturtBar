import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageReplacedFileTests {
    @Test
    func `a replaced transcript is reparsed instead of appended to`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 21)
        let iso = env.isoString(for: day)
        func entry(id: String, input: Int) -> [String: Any] {
            [
                "message": [
                    "model": "claude-opus-5",
                    "id": id,
                    "usage": [
                        "input_tokens": input,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                ],
                "requestId": "req_\(id)",
                "type": "assistant",
                "timestamp": iso,
                "sessionId": "session_replaced",
            ]
        }
        let url = try env.writeClaudeProjectFile(
            relativePath: "project-a/replaced.jsonl",
            contents: env.jsonl([entry(id: "msg_old", input: 100)]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let first = CostUsageScanner.loadDailyReport(since: day, until: day, now: day, options: options)
        #expect(first.data.first?.inputTokens == 100)

        let replacement = try env.jsonl([entry(id: "msg_new_a", input: 7000), entry(id: "msg_new_b", input: 200)])
        try Data(replacement.utf8).write(to: url, options: .atomic)

        let second = CostUsageScanner.loadDailyReport(since: day, until: day, now: day, options: options)
        #expect(second.data.first?.inputTokens == 7200)
    }
}
