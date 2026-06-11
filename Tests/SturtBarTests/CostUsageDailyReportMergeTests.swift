import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageDailyReportMergeTests {
    @Test
    func `merged report sums overlapping day totals and model breakdowns`() {
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 10,
                    cacheCreationTokens: nil,
                    totalTokens: 130,
                    costUSD: 1.25,
                    modelsUsed: ["claude-sonnet-4-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-sonnet-4-5",
                            costUSD: 1.25,
                            totalTokens: 130,
                            standardCostUSD: 0.75,
                            priorityCostUSD: 0.50,
                            standardTokens: 80,
                            priorityTokens: 50),
                    ]),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 100,
                totalOutputTokens: 20,
                cacheReadTokens: 10,
                cacheCreationTokens: nil,
                totalTokens: 130,
                totalCostUSD: 1.25))
        let additional = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 50,
                    outputTokens: 10,
                    cacheReadTokens: 5,
                    cacheCreationTokens: 2,
                    totalTokens: 67,
                    costUSD: 0.75,
                    modelsUsed: ["claude-sonnet-4-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-sonnet-4-5",
                            costUSD: 0.75,
                            totalTokens: 67,
                            standardCostUSD: 0.25,
                            priorityCostUSD: 0.50,
                            standardTokens: 20,
                            priorityTokens: 47),
                    ]),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 50,
                totalOutputTokens: 10,
                cacheReadTokens: 5,
                cacheCreationTokens: 2,
                totalTokens: 67,
                totalCostUSD: 0.75))

        let merged = native.merged(with: additional)
        #expect(merged.data.count == 1)
        #expect(merged.data.first?.inputTokens == 150)
        #expect(merged.data.first?.outputTokens == 30)
        #expect(merged.data.first?.cacheReadTokens == 15)
        #expect(merged.data.first?.cacheCreationTokens == 2)
        #expect(merged.data.first?.totalTokens == 197)
        #expect(abs((merged.data.first?.costUSD ?? 0) - 2.0) < 0.000001)
        #expect(merged.data.first?.modelBreakdowns == [
            CostUsageDailyReport.ModelBreakdown(
                modelName: "claude-sonnet-4-5",
                costUSD: 2.0,
                totalTokens: 197,
                standardCostUSD: 1.0,
                priorityCostUSD: 1.0,
                standardTokens: 100,
                priorityTokens: 97),
        ])
        #expect(merged.summary?.totalTokens == 197)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 2.0) < 0.000001)
    }

    @Test
    func `merged report unions days and orders model breakdowns deterministically`() {
        let first = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil,
                    totalTokens: 30,
                    costUSD: 0.30,
                    modelsUsed: ["claude-sonnet-4-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-sonnet-4-5",
                            costUSD: 0.30,
                            totalTokens: 30),
                    ]),
            ],
            summary: nil)
        let second = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-05",
                    inputTokens: nil,
                    outputTokens: nil,
                    cacheReadTokens: nil,
                    cacheCreationTokens: nil,
                    totalTokens: 40,
                    costUSD: 0.40,
                    modelsUsed: ["claude-opus-4-5", "claude-sonnet-4-5"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-opus-4-5",
                            costUSD: 0.40,
                            totalTokens: 40),
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "claude-sonnet-4-5",
                            costUSD: 0.00,
                            totalTokens: 0),
                    ]),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([first, second])
        #expect(merged.data.map(\.date) == ["2026-04-04", "2026-04-05"])
        #expect(merged.data.last?.modelBreakdowns?.map(\.modelName) == ["claude-opus-4-5", "claude-sonnet-4-5"])
        #expect(merged.summary?.totalTokens == 70)
        #expect(abs((merged.summary?.totalCostUSD ?? 0) - 0.70) < 0.000001)
    }

    @Test
    func `merged report includes derived totals when another same day entry has explicit total`() {
        let explicit = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 70,
                    outputTokens: 30,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: ["claude-opus-4-5"],
                    modelBreakdowns: nil),
            ],
            summary: nil)
        let derived = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-04-04",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 3,
                    cacheCreationTokens: 2,
                    totalTokens: nil,
                    costUSD: 0.25,
                    modelsUsed: ["claude-haiku-4-5"],
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([explicit, derived])
        #expect(merged.data.first?.totalTokens == 120)
        #expect(merged.summary?.totalTokens == 120)
        #expect(abs((merged.data.first?.costUSD ?? 0) - 1.25) < 0.000001)
    }
}
