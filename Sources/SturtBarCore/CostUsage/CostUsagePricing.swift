import Foundation

/// Claude pricing tables + models.dev catalog lookup (Phase 2b).
///
/// Lookup order for claudeCostUSD:
///  1. Historical-tariff check (uses built-in tables; short-circuits for models
///     that have pre-cutover long-context pricing).
///  2. models.dev catalog (injected or loaded from cache) — covers new models
///     not yet in the built-in tables.
///  3. Built-in table fallback — offline safety net, pinned by tests.
///
/// Call sites pass the catalog explicitly to avoid a per-row file load.
enum CostUsagePricing {
    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    private struct ClaudeCostTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation1h: Int
        let output: Int
    }

    /// Precompiled regex for vertex version suffix (-v1:0 style) and date suffix (-20250514 style).
    private static let vertexVersionRegex = makeRegex(pattern: #"-v\d+:\d+$"#)

    private static let dateSuffixRegex = makeRegex(pattern: #"-\d{8}$"#)

    /// Claude Code tags extended-context sessions, e.g. `claude-opus-5[1m]`; the price is the base model's.
    private static let contextTagRegex = makeRegex(pattern: #"\[\d+[a-z]\]$"#)

    private static let fallbackRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "$^", options: [])
        } catch {
            fatalError("Failed to build fallback regex: \(error)")
        }
    }()

    /// Mirrors `LogRedactor.makeRegex`: the literal patterns above always compile, and a
    /// hypothetical failure degrades to a never-matching regex (no suffix stripping) over a crash.
    private static func makeRegex(pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern)) ?? self.fallbackRegex
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagRange = NSRange(trimmed.startIndex..., in: trimmed)
        if let tag = contextTagRegex.firstMatch(in: trimmed, range: tagRange),
           let range = Range(tag.range, in: trimmed)
        {
            trimmed.removeSubrange(range)
        }

        // Fast path: if the trimmed form already is a known key, return immediately.
        if self.claudeTable[trimmed] != nil || self.claudeHistoricalLongContextTable[trimmed] != nil {
            return trimmed
        }

        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let vMatch = vertexVersionRegex.firstMatch(in: trimmed, range: range) {
            let matchRange = Range(vMatch.range, in: trimmed)!
            trimmed.removeSubrange(matchRange)
        }

        let range2 = NSRange(trimmed.startIndex..., in: trimmed)
        if let dateMatch = dateSuffixRegex.firstMatch(in: trimmed, range: range2) {
            let matchRange = Range(dateMatch.range, in: trimmed)!
            let base = String(trimmed[..<matchRange.lowerBound])
            if self.claudeTable[base] != nil {
                return base
            }
        }

        return trimmed
    }

    /// The models.dev provider ID for Anthropic-hosted Claude models.
    static let claudeModelsDevProviderID = "anthropic"

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheCreationInputTokens1h: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil) -> Double?
    {
        let tokens = ClaudeCostTokens(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            cacheCreation1h: cacheCreationInputTokens1h,
            output: outputTokens)
        let key = self.normalizeClaudeModel(model)

        // 1. Historical-tariff check: models with a pre-cutover long-context tier use built-in
        //    tables only — models.dev may carry the post-cutover flat rates, which would be wrong
        //    for historical rows.
        if let pricingDate,
           let historicalPricing = self.claudeHistoricalLongContextTable[key],
           let currentPricing = self.claudeTable[key]
        {
            return self.claudeCostUSD(
                pricing: pricingDate < self.claudeFullContextStandardPricingCutoff
                    ? historicalPricing
                    : currentPricing,
                tokens: tokens)
        }

        // 2. models.dev catalog lookup — covers models added after this binary shipped.
        if let lookup = self.modelsDevLookup(
            providerID: self.claudeModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog)
        {
            return self.claudeCostUSD(pricing: lookup.pricing, tokens: tokens)
        }

        // 3. Built-in table fallback.
        guard let pricing = self.claudeTable[key] else { return nil }
        return self.claudeCostUSD(
            pricing: pricing,
            tokens: tokens)
    }

    static func modelsDevCatalog(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCatalog? {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
    }

    private static func modelsDevLookup(
        providerID: String,
        model: String,
        catalog: ModelsDevCatalog?) -> ModelsDevPricingLookup?
    {
        if let catalog {
            return catalog.pricing(providerID: providerID, modelID: model)
        }
        // No catalog injected — fall through to the built-in table.
        // Call sites load the catalog once and thread it down; per-row cache loads
        // are intentionally avoided here.
        return nil
    }

    private static func claudeCostUSD(
        pricing: ModelsDevPricingInfo,
        tokens: ClaudeCostTokens) -> Double
    {
        self.claudeCostUSD(
            pricing: ClaudePricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheCreationInputCostPerToken: pricing.cacheCreationInputCostPerToken ?? pricing.inputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken,
                thresholdTokens: pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheCreationInputCostPerTokenAboveThreshold: pricing.cacheCreationInputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            tokens: tokens)
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        tokens: ClaudeCostTokens) -> Double
    {
        let input = max(0, tokens.input)
        let cacheRead = max(0, tokens.cacheRead)
        let cacheCreationTotal = max(0, tokens.cacheCreation)
        let cacheCreation1h = min(max(0, tokens.cacheCreation1h), cacheCreationTotal)
        let cacheCreation5m = cacheCreationTotal - cacheCreation1h
        let usesLongContextRates = pricing.thresholdTokens.map {
            CostUsageMath.sum(input, cacheRead, cacheCreationTotal) > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let cacheCreation5mRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken
            : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation5m) * cacheCreation5mRate
            + Double(cacheCreation1h) * inputRate * 2
            + Double(max(0, tokens.output)) * outputRate
    }

    // MARK: - Codex

    /// Codex/OpenAI per-token pricing. Ported from CodexBar's `CostUsagePricing` (the table this
    /// app was trimmed from). The `priority*` fields carry real OpenAI priority-tier rates and are
    /// retained verbatim for fidelity, but SturtBar prices every turn at the standard rates — it
    /// never reads the SQLite priority map, so Spark/priority turns are charged as standard.
    struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let displayLabel: String?

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let priorityInputCostPerToken: Double?
        let priorityOutputCostPerToken: Double?
        let priorityCacheReadInputCostPerToken: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double?,
            displayLabel: String?,
            thresholdTokens: Int? = nil,
            inputCostPerTokenAboveThreshold: Double? = nil,
            outputCostPerTokenAboveThreshold: Double? = nil,
            cacheReadInputCostPerTokenAboveThreshold: Double? = nil,
            priorityInputCostPerToken: Double? = nil,
            priorityOutputCostPerToken: Double? = nil,
            priorityCacheReadInputCostPerToken: Double? = nil)
        {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.displayLabel = displayLabel
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
            self.priorityInputCostPerToken = priorityInputCostPerToken
            self.priorityOutputCostPerToken = priorityOutputCostPerToken
            self.priorityCacheReadInputCostPerToken = priorityCacheReadInputCostPerToken
        }
    }

    /// Precompiled regex for Codex date suffixes (-YYYY-MM-DD style).
    private static let codexDateSuffixRegex = makeRegex(pattern: #"-\d{4}-\d{2}-\d{2}$"#)

    /// The models.dev provider ID for OpenAI-hosted Codex models.
    static let codexModelsDevProviderID = "openai"

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fast path: already a known key.
        if self.codexTable[trimmed] != nil {
            return trimmed
        }

        if trimmed.hasPrefix("openai/") {
            trimmed = String(trimmed.dropFirst("openai/".count))
        }

        if self.codexTable[trimmed] != nil {
            return trimmed
        }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let dateMatch = codexDateSuffixRegex.firstMatch(in: trimmed, range: range) {
            let matchRange = Range(dateMatch.range, in: trimmed)!
            let base = String(trimmed[..<matchRange.lowerBound])
            if self.codexTable[base] != nil {
                return base
            }
        }

        return trimmed
    }

    /// Estimated Codex cost in USD. Lookup order mirrors `claudeCostUSD`:
    ///  1. models.dev catalog (injected) — covers models added after this binary shipped, with the
    ///     built-in long-context threshold layered on top.
    ///  2. Built-in table fallback — offline safety net, pinned by tests.
    /// Priority pricing is intentionally not applied (SturtBar reads no priority metadata).
    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        modelsDevCatalog: ModelsDevCatalog? = nil) -> Double?
    {
        let key = self.normalizeCodexModel(model)

        // 1. models.dev catalog lookup — keep the built-in threshold so long-context tiers still apply.
        if let lookup = self.modelsDevLookup(
            providerID: self.codexModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog)
        {
            return self.codexCostUSD(
                pricing: lookup.pricing,
                thresholdTokens: self.codexTable[key]?.thresholdTokens,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens)
        }

        // 2. Built-in table fallback.
        guard let pricing = self.codexTable[key] else { return nil }
        return self.codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }

    private static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> Double
    {
        let cached = min(max(0, cachedInputTokens), max(0, inputTokens))
        let nonCached = max(0, inputTokens - cached)
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken

        let usesLongContextRates = pricing.thresholdTokens.map { max(0, inputTokens) > $0 } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cachedInputRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? cachedRate
            : cachedRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return (Double(nonCached) * inputRate)
            + (Double(cached) * cachedInputRate)
            + (Double(max(0, outputTokens)) * outputRate)
    }

    private static func codexCostUSD(
        pricing: ModelsDevPricingInfo,
        thresholdTokens: Int? = nil,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int) -> Double
    {
        self.codexCostUSD(
            pricing: CodexPricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken,
                displayLabel: nil,
                thresholdTokens: thresholdTokens ?? pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens)
    }
}
