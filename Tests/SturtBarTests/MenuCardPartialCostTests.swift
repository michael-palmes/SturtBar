import Foundation
import SturtBarCore
import Testing
@testable import SturtBar

struct MenuCardPartialCostTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test
    func `partial costs carry a plus and keep the unpriced model visible`() throws {
        let cost = CostUsageTokenSnapshot(
            sessionTokens: 2_000_000,
            sessionCostUSD: 4,
            last30DaysTokens: 3_000_000,
            last30DaysCostUSD: 9,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-09-20",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 3_000_000,
                    costUSD: 9,
                    modelsUsed: nil,
                    modelBreakdowns: [
                        .init(modelName: "claude-opus-5", costUSD: 5, totalTokens: 500_000),
                        .init(modelName: "claude-sonnet-5", costUSD: 3, totalTokens: 400_000),
                        .init(modelName: "claude-haiku-4-5", costUSD: 1, totalTokens: 100_000),
                        .init(
                            modelName: "claude-mystery-9",
                            costUSD: nil,
                            totalTokens: 2_000_000,
                            unpricedTokens: 2_000_000),
                    ],
                    unpricedTokens: 2_000_000),
            ],
            updatedAt: Self.now,
            unpricedModels: [CostUsageUnpricedModel(modelName: "claude-mystery-9", tokens: 2_000_000)],
            sessionUnpricedTokens: 2_000_000)

        let model = UsageMenuCardView.Model.make(.init(
            snapshot: nil,
            cost: cost,
            costUsageEnabled: true,
            now: Self.now))
        let section = try #require(model.costSection)

        #expect(section.summaryLine == "Cost  $4.00+ today · $9.00+ 30d")
        #expect(section.helpText == "Excludes 1 model with no known price")
        #expect(section.breakdown.map(\.id) == ["claude-opus-5", "claude-sonnet-5", "claude-mystery-9"])
        #expect(section.breakdown.last?.detail == "no price · 2M")
    }
}
