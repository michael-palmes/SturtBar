import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageUnpricedTests {
    @Test
    func `a day with an unpriced model keeps its priced portion`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 20)
        let iso = env.isoString(for: day)
        func entry(id: String, model: String) -> [String: Any] {
            [
                "message": [
                    "model": model,
                    "id": id,
                    "usage": [
                        "input_tokens": 1_000_000,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                ],
                "requestId": "req_\(id)",
                "type": "assistant",
                "timestamp": iso,
                "sessionId": "session_unpriced",
            ]
        }
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/mixed.jsonl",
            contents: env.jsonl([
                entry(id: "msg_priced", model: "claude-opus-5-5"),
                entry(id: "msg_unknown", model: "claude-mystery-9"),
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(since: day, until: day, now: day, options: options)

        let dayEntry = try #require(report.data.first)
        #expect(abs((dayEntry.costUSD ?? 0) - 4) < 1e-9)
        #expect(dayEntry.unpricedTokens == 1_000_000)
        let mystery = try #require(dayEntry.modelBreakdowns?.first { $0.modelName == "claude-mystery-9" })
        #expect(mystery.costUSD == nil)
        #expect(mystery.unpricedTokens == 1_000_000)
        let opus = try #require(dayEntry.modelBreakdowns?.first { $0.modelName == "claude-opus-5-5" })
        #expect(opus.unpricedTokens == nil)

        let snapshot = ClaudeCostFetcher.tokenSnapshot(from: report, now: day)
        #expect(snapshot.isPartial)
        #expect(snapshot.isSessionPartial)
        #expect(snapshot.unpricedModels == [CostUsageUnpricedModel(modelName: "claude-mystery-9", tokens: 1_000_000)])
        #expect(abs((snapshot.last30DaysCostUSD ?? 0) - 4) < 1e-9)
    }

    @Test
    func `a fully priced snapshot is not partial`() {
        let report = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-09-20",
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15,
                    costUSD: 0.01,
                    modelsUsed: ["claude-opus-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(modelName: "claude-opus-5", costUSD: 0.01, totalTokens: 15),
                    ]),
            ],
            summary: nil)

        let snapshot = ClaudeCostFetcher.tokenSnapshot(from: report, now: Date())

        #expect(!snapshot.isPartial)
        #expect(snapshot.unpricedModels == nil)
    }

    @Test
    func `a snapshot saved before unpriced tracking still decodes`() throws {
        let json = """
        {
          "sessionTokens": 15,
          "sessionCostUSD": 0.01,
          "last30DaysTokens": 15,
          "last30DaysCostUSD": 0.01,
          "currencyCode": "USD",
          "historyDays": 30,
          "daily": [
            {
              "date": "2026-09-20",
              "totalTokens": 15,
              "costUSD": 0.01,
              "modelBreakdowns": [{ "modelName": "claude-opus-5", "costUSD": 0.01 }]
            }
          ],
          "updatedAt": 780000000
        }
        """
        let snapshot = try JSONDecoder().decode(CostUsageTokenSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.unpricedModels == nil)
        #expect(snapshot.sessionUnpricedTokens == nil)
        #expect(snapshot.daily.first?.unpricedTokens == nil)
        #expect(!snapshot.isPartial)
    }

    @Test
    func `unpriced tokens survive an encode and decode round trip`() throws {
        let breakdown = CostUsageDailyReport.ModelBreakdown(
            modelName: "claude-mystery-9",
            costUSD: nil,
            totalTokens: 42,
            unpricedTokens: 42)
        let data = try JSONEncoder().encode(breakdown)
        let decoded = try JSONDecoder().decode(CostUsageDailyReport.ModelBreakdown.self, from: data)

        #expect(decoded == breakdown)
        #expect(CostUsageDailyReport.ModelBreakdown(modelName: "m", costUSD: 1, unpricedTokens: 0)
            .unpricedTokens == nil)
    }
}
