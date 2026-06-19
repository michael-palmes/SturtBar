import Foundation
import Testing
@testable import SturtBarCore

/// Ported from CodexBar's CostUsagePricingTests. Covers Claude and Codex cost
/// cases; the models.dev catalog-injection path is exercised for both providers.
struct CostUsagePricingTests {
    @Test
    func `normalizes claude opus41 dated variants`() {
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-4-1-20250805") == "claude-opus-4-1")
    }

    @Test
    func `claude cost supports opus41 dated variant`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-1-20250805",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func `claude cost supports opus46 dated variant`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-6-20260205",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func `claude cost supports opus47`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-7",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        let expected = (10.0 * 5e-6) + (5.0 * 2.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost supports opus48`() {
        // No catalog injected — exercises the built-in fallback table.
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-8",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        let expected = (10.0 * 5e-6) + (5.0 * 2.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost supports fable5 bundled fallback`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 10,
            outputTokens: 5)
        let expected = (100.0 * 1e-5) + (20.0 * 1e-6) + (10.0 * 1.25e-5) + (5.0 * 5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost preserves historical sonnet46 long context pricing`() {
        // Historical-tariff short-circuit uses built-in tables only; no catalog needed.
        let historical = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_359_999))
        let current = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_360_000))

        #expect(historical == 1.44)
        #expect(current == 0.72)
    }

    @Test
    func `claude cost ignores stale sonnet46 threshold catalog after cutover`() throws {
        // The catalog carries a long-context tier for claude-sonnet-4-6, but
        // pricingDate is AFTER the cutover so the historical-tariff short-circuit
        // fires and uses the built-in flat-rate table — the catalog is irrelevant.
        // Passing it explicitly confirms the short-circuit beats catalog lookup.
        let staleCatalog = try Self.catalog("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_360_000),
            modelsDevCatalog: staleCatalog)

        #expect(cost == 0.72)
    }

    @Test
    func `claude cost prices one hour cache writes separately`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 30,
            cacheCreationInputTokens1h: 20,
            outputTokens: 5)
        let expected = (100.0 * 1e-5)
            + (20.0 * 1e-6)
            + (10.0 * 1.25e-5)
            + (20.0 * 2e-5)
            + (5.0 * 5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost applies long context rates across cache write durations`() throws {
        let cacheRoot = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-threshold-model": {
                "id": "claude-threshold-model",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-threshold-model",
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 240_000,
            cacheCreationInputTokens1h: 120_000,
            outputTokens: 0,
            modelsDevCatalog: ModelsDevCache.load(cacheRoot: cacheRoot).artifact?.catalog)
        let expected = (120_000.0 * 12e-6)
            + (120_000.0 * 7.5e-6)
        #expect(cost == expected)
    }

    @Test
    func `claude sonnet46 uses standard pricing across full context`() {
        // No catalog — uses built-in table which has no long-context tier for sonnet-4-6.
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 240_000,
            outputTokens: 0)
        #expect(cost == 240_000.0 * 3.75e-6)
    }

    @Test
    func `claude cost returns nil for unknown models`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "glm-4.6",
            inputTokens: 100,
            cacheReadInputTokens: 500,
            cacheCreationInputTokens: 0,
            outputTokens: 40)
        #expect(cost == nil)
    }

    @Test
    func `claude cost prefers models dev cache with threshold pricing`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)

        // Pass catalog explicitly (Phase 2b: threading test).
        let catalog = ModelsDevCache.load(cacheRoot: root).artifact?.catalog
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 200_010,
            cacheReadInputTokens: 5,
            cacheCreationInputTokens: 5,
            outputTokens: 5,
            modelsDevCatalog: catalog)

        let expected = (200_010.0 * 6e-6)
            + (5.0 * 0.6e-6)
            + (5.0 * 7.5e-6)
            + (5.0 * 22.5e-6)
        #expect(cost == expected)
    }

    @Test
    func `claude cost falls back to built-in table when models dev misses provider model`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 10, "output": 20, "cache_read": 1 }
              }
            }
          }
        }
        """)

        // Anthropic provider absent; falls back to built-in table.
        let catalog = ModelsDevCache.load(cacheRoot: root).artifact?.catalog
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: catalog)

        let expected = 100.0 * 3e-6
        #expect(cost == expected)
    }

    @Test
    func `claude cost returns nil for completely unknown model even with catalog`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-known-model": {
                "id": "claude-known-model",
                "cost": { "input": 1, "output": 2 }
              }
            }
          }
        }
        """)
        let catalog = ModelsDevCache.load(cacheRoot: root).artifact?.catalog
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-completely-unknown",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCatalog: catalog)
        #expect(cost == nil)
    }

    // MARK: - Codex

    @Test
    func `normalizes codex model openai prefix and dated suffix`() {
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5.1-codex-2025-01-01") == "gpt-5.1-codex")
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5.1-codex") == "gpt-5.1-codex")
    }

    @Test
    func `codex cost prices gpt51 codex from built-in table`() {
        // No catalog injected — exercises the built-in fallback table.
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.1-codex",
            inputTokens: 1000,
            cachedInputTokens: 200,
            outputTokens: 500)
        // cached clamps to input; non-cached input at input rate, cached at cache-read rate.
        let expected = (800.0 * 1.25e-6) + (200.0 * 1.25e-7) + (500.0 * 1e-5)
        #expect(cost == expected)
    }

    @Test
    func `codex cost clamps cached tokens to input`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.1-codex",
            inputTokens: 100,
            cachedInputTokens: 500,
            outputTokens: 0)
        // cached = min(500, 100) = 100 ⇒ non-cached = 0.
        let expected = 100.0 * 1.25e-7
        #expect(cost == expected)
    }

    @Test
    func `codex cost applies above-threshold rates for gpt55 long context`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 300_000,
            cachedInputTokens: 0,
            outputTokens: 10000)
        // 300k input > 272k threshold ⇒ above-threshold input/output rates.
        let expected = (300_000.0 * 1e-5) + (10000.0 * 4.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `codex cost uses standard rates below gpt55 threshold`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 100_000,
            cachedInputTokens: 0,
            outputTokens: 10000)
        let expected = (100_000.0 * 5e-6) + (10000.0 * 3e-5)
        #expect(cost == expected)
    }

    @Test
    func `codex cost is zero for spark research preview`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex-spark",
            inputTokens: 1000,
            cachedInputTokens: 100,
            outputTokens: 500)
        #expect(cost == 0.0)
    }

    @Test
    func `codex cost returns nil for unknown models`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-nonexistent",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 40)
        #expect(cost == nil)
    }

    @Test
    func `codex cost prefers injected models dev catalog`() throws {
        let catalog = try Self.catalog("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.1-codex": {
                "id": "gpt-5.1-codex",
                "cost": { "input": 2, "output": 12, "cache_read": 0.2 }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.1-codex",
            inputTokens: 1000,
            cachedInputTokens: 200,
            outputTokens: 500,
            modelsDevCatalog: catalog)
        // Catalog ($/M tokens) overrides the built-in table: input 2e-6, output 1.2e-5, cache_read 2e-7.
        let expected = (800.0 * 2e-6) + (200.0 * 2e-7) + (500.0 * 1.2e-5)
        #expect(cost == expected)
    }

    // MARK: - Helpers

    private static func seedModelsDevCache(_ json: String) throws -> URL {
        let root = try Self.cacheRoot()
        let catalog = try Self.catalog(json)
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: root)
        return root
    }

    private static func catalog(_ json: String) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
