import Foundation
import Testing
@testable import SturtBarCore

/// Pins every built-in Codex rate (per million tokens). gpt-5.5 and newer were checked against
/// OpenAI's pricing page and models.dev in September 2026.
struct CostUsageCodexPricingTableTests {
    private struct Rates {
        let input: Double
        let output: Double
        let cacheRead: Double?
        var longContext: (input: Double, output: Double, cacheRead: Double)?
    }

    private static let expected: [String: Rates] = [
        "gpt-5": Rates(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5-codex": Rates(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5-mini": Rates(input: 0.25, output: 2, cacheRead: 0.025),
        "gpt-5-nano": Rates(input: 0.05, output: 0.4, cacheRead: 0.005),
        "gpt-5-pro": Rates(input: 15, output: 120, cacheRead: nil),
        "gpt-5.1": Rates(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5.1-codex": Rates(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5.1-codex-max": Rates(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5.1-codex-mini": Rates(input: 0.25, output: 2, cacheRead: 0.025),
        "gpt-5.2": Rates(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.2-codex": Rates(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.2-pro": Rates(input: 21, output: 168, cacheRead: nil),
        "gpt-5.3-codex": Rates(input: 1.75, output: 14, cacheRead: 0.175),
        "gpt-5.3-codex-spark": Rates(input: 0, output: 0, cacheRead: 0),
        "gpt-5.4": Rates(input: 2.5, output: 15, cacheRead: 0.25, longContext: (5, 22.5, 0.5)),
        "gpt-5.4-mini": Rates(input: 0.75, output: 4.5, cacheRead: 0.075),
        "gpt-5.4-nano": Rates(input: 0.2, output: 1.25, cacheRead: 0.02),
        "gpt-5.4-pro": Rates(input: 30, output: 180, cacheRead: nil),
        "gpt-5.5": Rates(input: 5, output: 30, cacheRead: 0.5, longContext: (10, 45, 1)),
        "gpt-5.5-pro": Rates(input: 30, output: 180, cacheRead: nil),
        "gpt-5.6-sol": Rates(input: 4, output: 20, cacheRead: 0.4, longContext: (8, 30, 0.8)),
        "gpt-5.6-terra": Rates(input: 2, output: 12, cacheRead: 0.2, longContext: (4, 18, 0.4)),
        "gpt-5.6-luna": Rates(input: 0.2, output: 1.2, cacheRead: 0.02, longContext: (0.4, 1.8, 0.04)),
        "gpt-6-astra": Rates(input: 10, output: 50, cacheRead: 1, longContext: (20, 75, 2)),
    ]

    private static func isClose(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): abs(lhs - rhs) <= max(abs(rhs), 1e-12) * 1e-9
        default: false
        }
    }

    @Test
    func `every built-in codex key has expected rates`() {
        #expect(Set(CostUsagePricing.codexTable.keys) == Set(Self.expected.keys))
        for (model, rates) in Self.expected {
            let pricing = CostUsagePricing.codexTable[model]
            #expect(Self.isClose(pricing?.inputCostPerToken, rates.input / 1e6), "\(model) input")
            #expect(Self.isClose(pricing?.outputCostPerToken, rates.output / 1e6), "\(model) output")
            #expect(
                Self.isClose(pricing?.cacheReadInputCostPerToken, rates.cacheRead.map { $0 / 1e6 }),
                "\(model) cached")
            if let long = rates.longContext {
                #expect(pricing?.thresholdTokens == 272_000, "\(model) threshold")
                #expect(Self.isClose(pricing?.inputCostPerTokenAboveThreshold, long.input / 1e6), "\(model) long input")
                #expect(
                    Self.isClose(pricing?.outputCostPerTokenAboveThreshold, long.output / 1e6),
                    "\(model) long output")
                #expect(
                    Self.isClose(pricing?.cacheReadInputCostPerTokenAboveThreshold, long.cacheRead / 1e6),
                    "\(model) long cached")
            } else {
                #expect(pricing?.thresholdTokens == nil, "\(model) threshold")
            }
        }
    }

    @Test
    func `the unsuffixed gpt 5 6 name prices as sol`() {
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.6") == "gpt-5.6-sol")
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5.6") == "gpt-5.6-sol")
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6",
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 100_000)
        #expect(Self.isClose(cost, 0.4 + 2))
    }

    @Test
    func `codex models without a public price stay unpriced`() {
        for model in ["codex-auto-review", "gpt-reserve"] {
            let cost = CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 10,
                cachedInputTokens: 0,
                outputTokens: 1)
            #expect(cost == nil, "\(model)")
            #expect(!CostUsagePricing.isUnlistedModel(model), "\(model)")
        }
    }
}
