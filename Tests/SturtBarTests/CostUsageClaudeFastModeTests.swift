import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageClaudeFastModeTests {
    private static func cost(_ model: String, isFast: Bool) -> Double? {
        CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 1_000_000,
            isFast: isFast)
    }

    @Test
    func `fast mode doubles opus 5, opus 5 5 and opus 4 8`() {
        #expect(Self.cost("claude-opus-5", isFast: true) == 60)
        #expect(Self.cost("claude-opus-5-5", isFast: true) == 48)
        #expect(Self.cost("claude-opus-4-8", isFast: true) == 60)
        #expect(Self.cost("claude-opus-5", isFast: false) == 30)
    }

    @Test
    func `fast mode without a published rate stays unpriced`() {
        #expect(Self.cost("claude-fable-5-1", isFast: true) == nil)
        #expect(Self.cost("claude-mystery-9", isFast: true) == nil)
    }

    @Test
    func `fast turns are priced and split out in the day breakdown`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 23)
        let iso = env.isoString(for: day)
        func entry(id: String, speed: String) -> [String: Any] {
            [
                "message": [
                    "model": "claude-opus-5-5",
                    "id": id,
                    "usage": [
                        "input_tokens": 1_000_000,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 0,
                        "speed": speed,
                    ],
                ],
                "requestId": "req_\(id)",
                "type": "assistant",
                "timestamp": iso,
                "sessionId": "session_fast",
            ]
        }
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/fast.jsonl",
            contents: env.jsonl([entry(id: "msg_std", speed: "standard"), entry(id: "msg_fast", speed: "fast")]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(since: day, until: day, now: day, options: options)

        let breakdown = try #require(report.data.first?.modelBreakdowns?.first)
        #expect(abs((breakdown.costUSD ?? 0) - 12) < 1e-9)
        #expect(abs((breakdown.priorityCostUSD ?? 0) - 8) < 1e-9)
        #expect(abs((breakdown.standardCostUSD ?? 0) - 4) < 1e-9)
        #expect(breakdown.priorityTokens == 1_000_000)
        #expect(breakdown.standardTokens == 1_000_000)
    }
}
