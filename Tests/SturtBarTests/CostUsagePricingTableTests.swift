import Foundation
import Testing
@testable import SturtBarCore

/// Pins every built-in Claude rate to Anthropic's published per-million-token prices.
struct CostUsagePricingTableTests {
    private struct Rates {
        let input: Double
        let output: Double
        let cacheWrite: Double
        let cacheRead: Double
    }

    private static let expectedClaude: [String: Rates] = {
        let opus45To48 = Rates(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)
        let opus4 = Rates(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        let sonnet4 = Rates(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
        let haiku45 = Rates(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)
        return [
            "claude-fable-5": Rates(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1),
            "claude-fable-5-1": Rates(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25),
            "claude-opus-5": Rates(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
            "claude-opus-5-5": Rates(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2),
            "claude-opus-4-8": opus45To48,
            "claude-opus-4-7": opus45To48,
            "claude-opus-4-6": opus45To48,
            "claude-opus-4-6-20260205": opus45To48,
            "claude-opus-4-5": opus45To48,
            "claude-opus-4-5-20251101": opus45To48,
            "claude-opus-4-1": opus4,
            "claude-opus-4-20250514": opus4,
            "claude-sonnet-5": Rates(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2),
            "claude-sonnet-4-6": sonnet4,
            "claude-sonnet-4-5": sonnet4,
            "claude-sonnet-4-5-20250929": sonnet4,
            "claude-sonnet-4-20250514": sonnet4,
            "claude-haiku-4-5": haiku45,
            "claude-haiku-4-5-20251001": haiku45,
        ]
    }()

    private static func isClose(_ lhs: Double?, _ rhs: Double) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= max(abs(rhs), 1e-12) * 1e-9
    }

    @Test
    func `every built-in claude key has expected rates`() {
        #expect(Set(CostUsagePricing.claudeTable.keys) == Set(Self.expectedClaude.keys))
        for (model, expected) in Self.expectedClaude {
            let pricing = CostUsagePricing.claudeTable[model]
            #expect(Self.isClose(pricing?.inputCostPerToken, expected.input / 1e6), "\(model) input")
            #expect(Self.isClose(pricing?.outputCostPerToken, expected.output / 1e6), "\(model) output")
            #expect(
                Self.isClose(pricing?.cacheCreationInputCostPerToken, expected.cacheWrite / 1e6),
                "\(model) cache write")
            #expect(Self.isClose(pricing?.cacheReadInputCostPerToken, expected.cacheRead / 1e6), "\(model) cache read")
        }
    }

    @Test
    func `current claude models carry no long context tier`() {
        for model in ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5"] {
            #expect(CostUsagePricing.claudeTable[model]?.thresholdTokens == nil, "\(model)")
        }
    }

    @Test
    func `opus 5 5 is not priced as opus 5`() {
        func cost(_ model: String) -> Double? {
            CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 1_000_000,
                cacheReadInputTokens: 1_000_000,
                cacheCreationInputTokens: 1_000_000,
                outputTokens: 1_000_000)
        }
        #expect(Self.isClose(cost("claude-opus-5-5"), 4 + 0.2 + 5 + 20))
        #expect(Self.isClose(cost("claude-opus-5"), 5 + 0.5 + 6.25 + 25))
        #expect(Self.isClose(cost("claude-opus-5-5-20261001"), 4 + 0.2 + 5 + 20))
        #expect(Self.isClose(cost("anthropic.claude-opus-5-5"), 4 + 0.2 + 5 + 20))
    }

    @Test
    func `fable 5 1 cache reads cost a fortieth of input`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5-1",
            inputTokens: 0,
            cacheReadInputTokens: 1_000_000,
            cacheCreationInputTokens: 0,
            outputTokens: 0)
        #expect(Self.isClose(cost, 0.25))
    }

    @Test
    func `one hour cache writes cost twice input on current models`() {
        let expected = ["claude-fable-5-1": 20.0, "claude-opus-5-5": 8, "claude-opus-5": 10, "claude-sonnet-5": 4]
        for (model, rate) in expected {
            let cost = CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 0,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 1_000_000,
                cacheCreationInputTokens1h: 1_000_000,
                outputTokens: 0)
            #expect(Self.isClose(cost, rate), "\(model)")
        }
    }

    @Test
    func `context tags price as the base model`() {
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-5[1m]") == "claude-opus-5")
        #expect(CostUsagePricing.normalizeClaudeModel(" claude-fable-5-1[1m] ") == "claude-fable-5-1")
        #expect(ModelsDevModelIDNormalizer.candidates("claude-opus-5-5[1m]").first == "claude-opus-5-5")
        let tagged = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-5[1m]",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0)
        #expect(Self.isClose(tagged, 5))
    }
}
