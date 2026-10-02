import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageOverflowTests {
    @Test
    func `saturating add clamps instead of trapping`() {
        #expect(CostUsageMath.add(Int.max, 1) == Int.max)
        #expect(CostUsageMath.add(Int.max - 5, 3) == Int.max - 2)
        #expect(CostUsageMath.add(Int.min, -1) == Int.min)
        #expect(CostUsageMath.sum(Int.max, Int.max, 7) == Int.max)
    }

    @Test
    func `token counts reject non-finite and negative values`() {
        #expect(CostUsageMath.tokenCount(NSNumber(value: 42)) == 42)
        #expect(CostUsageMath.tokenCount(NSNumber(value: -3)) == 0)
        #expect(CostUsageMath.tokenCount(NSNumber(value: Double.nan)) == 0)
        #expect(CostUsageMath.tokenCount(NSNumber(value: Double.infinity)) == 0)
        #expect(CostUsageMath.tokenCount(NSNumber(value: 1e300)) == Int.max)
        #expect(CostUsageMath.tokenCount("12") == 0)
        #expect(CostUsageMath.tokenCount(nil) == 0)
    }

    @Test
    func `nanodollar conversion refuses values it cannot represent`() {
        #expect(CostUsageMath.nanos(fromUSD: 1.5) == 1_500_000_000)
        #expect(CostUsageMath.nanos(fromUSD: 1e12) == nil)
        #expect(CostUsageMath.nanos(fromUSD: .infinity) == nil)
        #expect(CostUsageMath.nanos(fromUSD: -1) == nil)
    }

    @Test
    func `claude report survives absurd token counts`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        func entry(id: String, input: Any) -> [String: Any] {
            [
                "message": [
                    "model": "claude-opus-4-8",
                    "id": id,
                    "usage": [
                        "input_tokens": input,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1e300,
                    ],
                ],
                "requestId": "req_\(id)",
                "type": "assistant",
                "timestamp": iso,
                "sessionId": "session_overflow",
            ]
        }
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/overflow.jsonl",
            contents: env.jsonl([
                entry(id: "msg_a", input: Int.max),
                entry(id: "msg_b", input: Int.max),
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(since: day, until: day, now: day, options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == Int.max)
        #expect(report.data[0].outputTokens == Int.max)
        #expect(report.summary?.totalTokens == Int.max)
    }
}
