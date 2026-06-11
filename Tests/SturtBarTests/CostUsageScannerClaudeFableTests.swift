import Foundation
import Testing
@testable import SturtBarCore

/// Ported from CodexBar CostUsageScannerClaudeFableTests.
/// Phase 2b: models.dev catalog repricing halves re-enabled.
struct CostUsageScannerClaudeFableTests {
    @Test
    func `claude fable 5 issue row gets priced`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fable-5.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-fable-5",
                        "id": "msg_fable_5",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 10,
                            "cache_read_input_tokens": 20,
                            "output_tokens": 5,
                        ],
                    ],
                    "requestId": "req_fable_5",
                    "type": "assistant",
                    "timestamp": iso,
                    "sessionId": "session_fable_5",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].model == "claude-fable-5")
        let expected = 0.001395
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
    }

    @Test
    func `claude transcript refusal remains priced without billing provenance`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fable-5-refusal.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-fable-5",
                        "id": "msg_fable_5_refusal",
                        "type": "message",
                        "role": "assistant",
                        "stop_reason": "refusal",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 10,
                            "cache_read_input_tokens": 20,
                            "output_tokens": 0,
                        ],
                    ],
                    "requestId": "req_fable_5_refusal",
                    "type": "assistant",
                    "timestamp": iso,
                    "sessionId": "session_fable_5_refusal",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].input == 100)
        #expect(parsed.rows[0].cacheCreate == 10)
        #expect(parsed.rows[0].cacheRead == 20)
        #expect(parsed.rows[0].output == 0)
        let expected = 0.001145
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
        #expect(parsed.rows[0].costPriced == true)
    }

    @Test
    func `claude fable 5 prices one hour cache creation tokens`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fable-5-cache-ttl.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-fable-5",
                        "id": "msg_fable_5_cache_ttl",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 30,
                            "cache_creation": [
                                "ephemeral_5m_input_tokens": 10,
                                "ephemeral_1h_input_tokens": 20,
                            ],
                            "cache_read_input_tokens": 20,
                            "output_tokens": 5,
                        ],
                    ],
                    "requestId": "req_fable_5_cache_ttl",
                    "type": "assistant",
                    "timestamp": iso,
                    "sessionId": "session_fable_5_cache_ttl",
                ],
            ]))

        let parsed = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)

        #expect(parsed.rows.count == 1)
        #expect(parsed.rows[0].cacheCreate == 30)
        #expect(parsed.rows[0].cacheCreate1h == 20)
        let expected = 0.001795
        #expect(abs((Double(parsed.rows[0].costNanos) / 1_000_000_000) - expected) < 0.000000001)
    }

    @Test
    func `claude cached rows preserve one hour writes for deferred pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/custom-cache-ttl.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-custom-cache-model",
                        "id": "msg_custom_cache_ttl",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 100,
                            "cache_creation_input_tokens": 30,
                            "cache_creation": [
                                "ephemeral_5m_input_tokens": 10,
                                "ephemeral_1h_input_tokens": 20,
                            ],
                            "cache_read_input_tokens": 20,
                            "output_tokens": 5,
                        ],
                    ],
                    "requestId": "req_custom_cache_ttl",
                    "type": "assistant",
                    "timestamp": iso,
                    "sessionId": "session_custom_cache_ttl",
                ],
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let unpriced = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(unpriced.summary?.totalCostUSD == nil)

        let expectedDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let cached = CostUsageCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(cached.days[expectedDayKey]?["claude-custom-cache-model"]?[safe: 7] == 20)

        // Phase 2b: models.dev repricing half — save a catalog for the custom model
        // and expect the cached row to reprice on the next loadDailyReport call.
        let catalogJSON = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-custom-cache-model": {
                "id": "claude-custom-cache-model",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75
                }
              }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(catalogJSON.utf8))
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: env.cacheRoot)

        let repriced = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        // Now that the catalog covers the model, cost should be non-nil.
        let cost = repriced.summary?.totalCostUSD
        #expect(cost != nil)
        // Verify 1h cache tokens are repriced correctly. Kept as sub-expressions: the
        // five-term literal sum blows the type-checker budget on CI's toolchain as one expression.
        let inputCost = 100.0 * 3e-6
        let cacheReadCost = 20.0 * 0.3e-6
        let cacheCreate5mCost = 10.0 * 3.75e-6
        let cacheCreate1hCost = 20.0 * 2 * 3e-6 // 1h cache writes price at 2× input
        let outputCost = 5.0 * 15e-6
        let expectedCost = inputCost + cacheReadCost + cacheCreate5mCost + cacheCreate1hCost + outputCost
        #expect(abs((cost ?? 0) - expectedCost) < 1e-12)
    }

    @Test
    func `claude deferred pricing preserves request long context boundaries`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/custom-threshold.jsonl",
            contents: env.jsonl([
                Self.claudeUsageEvent(
                    model: "claude-custom-threshold-model",
                    messageID: "msg_custom_threshold_1",
                    requestID: "req_custom_threshold_1",
                    inputTokens: 150_000,
                    timestamp: iso),
                Self.claudeUsageEvent(
                    model: "claude-custom-threshold-model",
                    messageID: "msg_custom_threshold_2",
                    requestID: "req_custom_threshold_2",
                    inputTokens: 150_000,
                    timestamp: iso),
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let unpriced = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        // The rows are for an unknown model so they are unpriced; summary is present
        // (data array has an entry) but totalCostUSD is nil.
        let summary = try #require(unpriced.summary, "expected a non-nil summary — row fell outside range (TZ bug?)")
        #expect(summary.totalCostUSD == nil)

        // Phase 2b: save a threshold catalog and expect per-request long-context
        // boundaries to hold (each 150k-token request is below 200k, so standard rates apply).
        let catalogJSON = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-custom-threshold-model": {
                "id": "claude-custom-threshold-model",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5
                  }
                }
              }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(catalogJSON.utf8))
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: env.cacheRoot)

        let repriced = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        let cost = repriced.summary?.totalCostUSD
        #expect(cost != nil)
        // Both requests are below the 200k threshold; each is priced at standard rates.
        // 2 requests × 150_000 input × 3e-6 = 0.9
        let expectedCost = 2.0 * 150_000.0 * 3e-6
        #expect(abs((cost ?? 0) - expectedCost) < 1e-9)
    }

    @Test
    func `claude cached historical rows keep original tariff`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 12)
        let iso = env.isoString(for: day)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/sonnet-46-historical.jsonl",
            contents: env.jsonl([
                [
                    "message": [
                        "model": "claude-sonnet-4-6",
                        "id": "msg_sonnet_46_historical",
                        "type": "message",
                        "role": "assistant",
                        "usage": [
                            "input_tokens": 240_000,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                    ],
                    "requestId": "req_sonnet_46_historical",
                    "type": "assistant",
                    "timestamp": iso,
                    "sessionId": "session_sonnet_46_historical",
                ],
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let initial = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(abs((initial.summary?.totalCostUSD ?? 0) - 1.44) < 0.000000001)

        // Phase 2b: save a standard sonnet-4-6 catalog (no threshold tier since this
        // is after the pricing cutover) and confirm the historical tariff is preserved.
        // The historical-tariff check in claudeCostUSD short-circuits before the
        // models.dev lookup for rows with a pricingDate before the cutover.
        let catalog = try Self.anthropicSonnet46StandardCatalog()
        ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let cached = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        #expect(abs((cached.summary?.totalCostUSD ?? 0) - 1.44) < 0.000000001)
    }

    @Test
    func `claude cached rows reprice after models dev catalog changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        let model = "claude-custom-repricing-model"
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/custom-repricing.jsonl",
            contents: env.jsonl([
                Self.claudeUsageEvent(
                    model: model,
                    messageID: "msg_custom_repricing",
                    requestID: "req_custom_repricing",
                    inputTokens: 240_000,
                    timestamp: iso),
            ]))
        // Seed with a threshold catalog (input >200k → long-context rates: 20/M).
        let premiumCatalog = try Self.anthropicThresholdModelsDevCatalog(model: model)
        ModelsDevCache.save(catalog: premiumCatalog, fetchedAt: day, cacheRoot: env.cacheRoot)

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let premium = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        // 240k tokens above 200k threshold → long context input rate 20/M = 4.8
        #expect(abs((premium.summary?.totalCostUSD ?? 0) - 4.8) < 1e-9)

        // Replace the catalog with a flat (no threshold) version: input 10/M.
        let flatCatalog = try Self.anthropicModelsDevCatalog(model: model)
        ModelsDevCache.save(catalog: flatCatalog, fetchedAt: day.addingTimeInterval(1), cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        let repriced = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        // Flat input rate 10/M → 240_000 × 10e-6 = 2.4
        #expect(abs((repriced.summary?.totalCostUSD ?? 0) - 2.4) < 1e-9)
    }

    private static func claudeUsageEvent(
        model: String,
        messageID: String,
        requestID: String,
        inputTokens: Int,
        timestamp: String) -> [String: Any]
    {
        [
            "message": [
                "model": model,
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "usage": [
                    "input_tokens": inputTokens,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                ],
            ],
            "requestId": requestID,
            "type": "assistant",
            "timestamp": timestamp,
            "sessionId": "session_\(requestID)",
        ]
    }

    // MARK: - Catalog helpers (ported from legacy CostUsageScannerClaudeFableTests)

    private static func anthropicModelsDevCatalog(model: String) throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": {
                  "input": 10,
                  "output": 50,
                  "cache_read": 1,
                  "cache_write": 12.5
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func anthropicThresholdModelsDevCatalog(model: String) throws -> ModelsDevCatalog {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "\(model)": {
                "id": "\(model)",
                "cost": {
                  "input": 10,
                  "output": 50,
                  "cache_read": 1,
                  "cache_write": 12.5,
                  "context_over_200k": {
                    "input": 20,
                    "output": 75,
                    "cache_read": 2,
                    "cache_write": 25
                  }
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func anthropicSonnet46StandardCatalog() throws -> ModelsDevCatalog {
        let json = """
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
                  "cache_write": 3.75
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}
