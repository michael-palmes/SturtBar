import Foundation

/// Built-in rates, authoritative for every model listed (models.dev only fills gaps).
/// Claude rates are per million tokens, as published on Anthropic's pricing page.
extension CostUsagePricing {
    static let claudeTable: [String: ClaudePricing] = {
        let fable5 = ClaudePricing.perMillion(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1)
        let fable51 = ClaudePricing.perMillion(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25)
        let opus5 = ClaudePricing.perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)
        let opus55 = ClaudePricing.perMillion(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2)
        let opus45To48 = ClaudePricing.perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)
        let opus4 = ClaudePricing.perMillion(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        let sonnet5 = ClaudePricing.perMillion(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2)
        let sonnet46 = ClaudePricing.perMillion(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
        let sonnet4LongContext = sonnet46.withLongContext(
            threshold: 200_000,
            input: 6,
            output: 22.5,
            cacheWrite: 7.5,
            cacheRead: 0.6)
        let haiku45 = ClaudePricing.perMillion(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)
        return [
            "claude-fable-5": fable5,
            "claude-fable-5-1": fable51,
            "claude-opus-5": opus5,
            "claude-opus-5-5": opus55,
            "claude-opus-4-8": opus45To48,
            "claude-opus-4-7": opus45To48,
            "claude-opus-4-6": opus45To48,
            "claude-opus-4-6-20260205": opus45To48,
            "claude-opus-4-5": opus45To48,
            "claude-opus-4-5-20251101": opus45To48,
            "claude-opus-4-1": opus4,
            "claude-opus-4-20250514": opus4,
            "claude-sonnet-5": sonnet5,
            "claude-sonnet-4-6": sonnet46,
            "claude-sonnet-4-5": sonnet4LongContext,
            "claude-sonnet-4-5-20250929": sonnet4LongContext,
            "claude-sonnet-4-20250514": sonnet4LongContext,
            "claude-haiku-4-5": haiku45,
            "claude-haiku-4-5-20251001": haiku45,
        ]
    }()

    /// Fast mode (`usage.speed == "fast"`) as a multiple of the standard rates.
    static let claudeFastMultiplier: [String: Double] = [
        "claude-opus-5": 2,
        "claude-opus-5-5": 2,
    ]

    /// Models with no public price anywhere; never worth an early catalog refresh.
    static let knownUnpricedModels: Set<String> = ["codex-auto-review"]

    /// True when neither built-in table lists the model, so only a newer catalog could price it.
    static func isUnlistedModel(_ model: String) -> Bool {
        !self.knownUnpricedModels.contains(model)
            && self.claudeTable[self.normalizeClaudeModel(model)] == nil
            && self.codexTable[self.normalizeCodexModel(model)] == nil
    }

    static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)

    /// Pre-cutoff long-context tiers; rows dated before the cutoff use these instead of the flat rates.
    static let claudeHistoricalLongContextTable: [String: ClaudePricing] = [
        "claude-opus-4-6": ClaudePricing
            .perMillion(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5)
            .withLongContext(threshold: 200_000, input: 10, output: 37.5, cacheWrite: 12.5, cacheRead: 1),
        "claude-sonnet-4-6": ClaudePricing
            .perMillion(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
            .withLongContext(threshold: 200_000, input: 6, output: 22.5, cacheWrite: 7.5, cacheRead: 0.6),
    ]

    static let codexTable: [String: CodexPricing] = [
        "gpt-5": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5-nano": CodexPricing(
            inputCostPerToken: 5e-8,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 5e-9,
            displayLabel: nil),
        "gpt-5-pro": CodexPricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 1.2e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.1": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-max": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5.2": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-pro": CodexPricing(
            inputCostPerToken: 2.1e-5,
            outputCostPerToken: 1.68e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.3-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.3-codex-spark": CodexPricing(
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            cacheReadInputCostPerToken: 0,
            displayLabel: "Research Preview"),
        "gpt-5.4": CodexPricing(
            inputCostPerToken: 2.5e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 5e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 5e-7,
            priorityInputCostPerToken: 5e-6,
            priorityOutputCostPerToken: 3e-5,
            priorityCacheReadInputCostPerToken: 5e-7),
        "gpt-5.4-mini": CodexPricing(
            inputCostPerToken: 7.5e-7,
            outputCostPerToken: 4.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            displayLabel: nil,
            priorityInputCostPerToken: 1.5e-6,
            priorityOutputCostPerToken: 9e-6,
            priorityCacheReadInputCostPerToken: 1.5e-7),
        "gpt-5.4-nano": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil),
        "gpt-5.4-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.5": CodexPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 3e-5,
            cacheReadInputCostPerToken: 5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 4.5e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6,
            priorityInputCostPerToken: 1.25e-5,
            priorityOutputCostPerToken: 7.5e-5,
            priorityCacheReadInputCostPerToken: 1.25e-6),
        "gpt-5.5-pro": CodexPricing(
            inputCostPerToken: 3e-5,
            outputCostPerToken: 1.8e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
    ]
}

extension CostUsagePricing.ClaudePricing {
    static func perMillion(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) -> Self {
        Self(
            inputCostPerToken: input / 1_000_000,
            outputCostPerToken: output / 1_000_000,
            cacheCreationInputCostPerToken: cacheWrite / 1_000_000,
            cacheReadInputCostPerToken: cacheRead / 1_000_000,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil)
    }

    func withLongContext(
        threshold: Int,
        input: Double,
        output: Double,
        cacheWrite: Double,
        cacheRead: Double) -> Self
    {
        Self(
            inputCostPerToken: self.inputCostPerToken,
            outputCostPerToken: self.outputCostPerToken,
            cacheCreationInputCostPerToken: self.cacheCreationInputCostPerToken,
            cacheReadInputCostPerToken: self.cacheReadInputCostPerToken,
            thresholdTokens: threshold,
            inputCostPerTokenAboveThreshold: input / 1_000_000,
            outputCostPerTokenAboveThreshold: output / 1_000_000,
            cacheCreationInputCostPerTokenAboveThreshold: cacheWrite / 1_000_000,
            cacheReadInputCostPerTokenAboveThreshold: cacheRead / 1_000_000)
    }
}
