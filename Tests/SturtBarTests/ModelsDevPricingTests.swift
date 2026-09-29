import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SturtBarCore

/// Ported from CodexBar's ModelsDevPricingTests.
/// The fixture (models-dev-subset.json) was copied to Tests/SturtBarTests/Fixtures/
/// and Package.swift was updated to include resources: [.copy("Fixtures")].
struct ModelsDevPricingTests {
    @Test
    func `parses models dev subset`() throws {
        let catalog = try Self.fixtureCatalog()

        #expect(catalog.providers["openai"]?.name == "OpenAI")
        #expect(catalog.providers["anthropic"]?.models["claude-sonnet-4-6"]?.cost?.cacheWrite == 3.75)
        #expect(catalog.providers["anthropic"]?.models["claude-sonnet-4-6"]?.limit?.context == 1_000_000)
    }

    @Test
    func `looks up pricing by provider and model`() throws {
        let catalog = try Self.fixtureCatalog()

        let openAI = try #require(catalog.pricing(providerID: "openai", modelID: "shared-model"))
        let anthropic = try #require(catalog.pricing(providerID: "anthropic", modelID: "shared-model"))

        #expect(openAI.pricing.inputCostPerToken == 1 / 1_000_000.0)
        #expect(openAI.pricing.outputCostPerToken == 2 / 1_000_000.0)
        #expect(anthropic.pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(anthropic.pricing.outputCostPerToken == 4 / 1_000_000.0)
    }

    @Test
    func `does not fall back across providers`() throws {
        let catalog = try Self.fixtureCatalog()

        #expect(catalog.pricing(providerID: "openai", modelID: "claude-sonnet-4-6") == nil)
        #expect(catalog.pricing(providerID: "anthropic", modelID: "gpt-4o-mini") == nil)
    }

    @Test
    func `supports provider scoped alias normalization`() throws {
        let catalog = try Self.fixtureCatalog()

        let anthropic = try #require(catalog.pricing(
            providerID: "anthropic",
            modelID: "anthropic.us-east-1.claude-sonnet-4-6-v1:0"))
        let vertex = try #require(catalog.pricing(
            providerID: "google-vertex-anthropic",
            modelID: "claude-sonnet-4-6"))

        #expect(anthropic.normalizedModelID == "claude-sonnet-4-6")
        #expect(vertex.normalizedModelID == "claude-sonnet-4-6@default")
        #expect(vertex.pricing.inputCostPerToken == 3.1 / 1_000_000.0)
    }

    @Test
    func `converts models dev per million token prices to per token prices`() throws {
        let pricing = try #require(try Self.fixtureCatalog().pricing(
            providerID: "anthropic",
            modelID: "claude-sonnet-4-6")?
            .pricing)

        #expect(pricing.inputCostPerToken == 3 / 1_000_000.0)
        #expect(pricing.outputCostPerToken == 15 / 1_000_000.0)
        #expect(pricing.cacheReadInputCostPerToken == 0.3 / 1_000_000.0)
        #expect(pricing.cacheCreationInputCostPerToken == 3.75 / 1_000_000.0)
        #expect(pricing.thresholdTokens == 200_000)
        #expect(pricing.inputCostPerTokenAboveThreshold == 6 / 1_000_000.0)
        #expect(pricing.outputCostPerTokenAboveThreshold == 22.5 / 1_000_000.0)
        #expect(pricing.cacheReadInputCostPerTokenAboveThreshold == 0.6 / 1_000_000.0)
        #expect(pricing.cacheCreationInputCostPerTokenAboveThreshold == 7.5 / 1_000_000.0)
    }

    @Test
    func `stale cache is still readable`() throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let load = ModelsDevCache.load(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root)

        #expect(load.artifact != nil)
        #expect(load.isStale)
        #expect(load.error == nil)
    }

    @Test
    func `pipeline lookup reads cached pricing`() throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `network failure preserves last valid cache`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(result: .failure(MockError.failed))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `refresh updates cache when fetched catalog renames model key but keeps id`() async throws {
        let root = try Self.cacheRoot()
        let old = Date(timeIntervalSince1970: 1)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: old, cacheRoot: root)

        let renamedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini-renamed": {
                "id": "gpt-4o-mini",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": { "input": 99, "output": 99 }
              },
              "shared-model": {
                "id": "shared-model",
                "cost": { "input": 99, "output": 99 }
              }
            }
          },
          "google-vertex-anthropic": {
            "id": "google-vertex-anthropic",
            "models": {
              "claude-sonnet-4-6-renamed": {
                "id": "claude-sonnet-4-6@default",
                "cost": { "input": 99, "output": 99 }
              }
            }
          }
        }
        """.utf8)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: MockTransport(
                result: .success((renamedCatalog, Self.response(status: 200))))))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))

        #expect(lookup.normalizedModelID == "gpt-4o-mini")
        #expect(lookup.pricing.inputCostPerToken == 99 / 1_000_000.0)
    }

    @Test
    func `refresh accepts a catalog that dropped unrelated models`() async throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: Date(timeIntervalSince1970: 1),
            cacheRoot: root)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL,
            cacheRoot: root,
            client: Self.client(Self.freshCatalogJSON))

        #expect(ModelsDevPricingPipeline.lookup(providerID: "openai", modelID: "gpt-4o-mini", cacheRoot: root) == nil)
        let opus = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "anthropic",
            modelID: "claude-opus-5-5",
            cacheRoot: root))
        #expect(opus.pricing.inputCostPerToken == 4 / 1_000_000.0)
    }

    @Test
    func `refresh keeps only the anthropic and openai providers`() async throws {
        let root = try Self.cacheRoot()

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL,
            cacheRoot: root,
            client: Self.client(Self.freshCatalogJSON))

        let catalog = try #require(ModelsDevCache.load(now: Self.afterTTL, cacheRoot: root).artifact?.catalog)
        #expect(Set(catalog.providers.keys) == ["anthropic", "openai"])
    }

    @Test
    func `refresh rejects a catalog without priced models for both providers`() async throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(
            catalog: Self.fixtureCatalog(),
            fetchedAt: Date(timeIntervalSince1970: 1),
            cacheRoot: root)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL,
            cacheRoot: root,
            client: Self.client("""
            {
              "anthropic": {
                "id": "anthropic",
                "models": { "claude-opus-5-5": { "id": "claude-opus-5-5", "cost": { "input": 4, "output": 20 } } }
              },
              "openai": { "id": "openai", "models": { "gpt-9": { "id": "gpt-9" } } }
            }
            """))

        let lookup = try #require(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-4o-mini",
            cacheRoot: root))
        #expect(lookup.pricing.inputCostPerToken == 0.15 / 1_000_000.0)
    }

    @Test
    func `refresh backs off for a day after any attempt`() async throws {
        let root = try Self.cacheRoot()
        let failing = TrackingTransport(result: .failure(MockError.failed))

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL,
            cacheRoot: root,
            client: ModelsDevClient(transport: failing))
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL.addingTimeInterval(60 * 60),
            cacheRoot: root,
            client: ModelsDevClient(transport: failing))
        #expect(failing.calls == 1)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL.addingTimeInterval(ModelsDevPricingPipeline.attemptBackoffSeconds + 1),
            cacheRoot: root,
            client: ModelsDevClient(transport: failing))
        #expect(failing.calls == 2)
    }

    @Test
    func `eager refresh fetches a fresh catalog at most every six hours`() async throws {
        let root = try Self.cacheRoot()
        let fetchedAt = Date(timeIntervalSince1970: 1_000_000)
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: fetchedAt, cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))
        let client = ModelsDevClient(transport: transport)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: fetchedAt.addingTimeInterval(60 * 60),
            cacheRoot: root,
            client: client)
        #expect(transport.calls == 0)

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: fetchedAt.addingTimeInterval(60 * 60),
            cacheRoot: root,
            eager: true,
            client: client)
        #expect(transport.calls == 0)

        let afterEagerBackoff = fetchedAt.addingTimeInterval(ModelsDevPricingPipeline.eagerAttemptBackoffSeconds + 1)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: afterEagerBackoff,
            cacheRoot: root,
            eager: true,
            client: client)
        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: afterEagerBackoff.addingTimeInterval(60),
            cacheRoot: root,
            eager: true,
            client: client)
        #expect(transport.calls == 1)
    }

    @Test
    func `only models no table lists count as unlisted`() {
        func snapshot(_ model: String) -> CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [],
                updatedAt: Date(),
                unpricedModels: [CostUsageUnpricedModel(modelName: model, tokens: 1)])
        }
        #expect(snapshot("claude-mystery-9").hasUnlistedModels)
        #expect(!snapshot("codex-auto-review").hasUnlistedModels)
        #expect(!snapshot("claude-opus-4-8").hasUnlistedModels)
        #expect(!snapshot("gpt-5.5").hasUnlistedModels)
    }

    @Test
    func `concurrent refreshes fetch once`() async throws {
        let root = try Self.cacheRoot()
        let transport = TrackingTransport(result: .success((
            Data(Self.freshCatalogJSON.utf8),
            Self.response(status: 200))))
        let client = ModelsDevClient(transport: transport)

        async let first: Void = ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL,
            cacheRoot: root,
            client: client)
        async let second: Void = ModelsDevPricingPipeline.refreshIfNeeded(
            now: Self.afterTTL,
            cacheRoot: root,
            client: client)
        _ = await (first, second)

        #expect(transport.calls == 1)
    }

    @Test
    func `saving the v2 cache removes the v1 file`() throws {
        let root = try Self.cacheRoot()
        let legacy = ModelsDevCache.cacheFileURL(cacheRoot: root, version: 1)
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy)

        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test
    func `fresh cache does not refresh`() async throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)
        let transport = TrackingTransport(result: .failure(MockError.failed))

        await ModelsDevPricingPipeline.refreshIfNeeded(
            now: Date(),
            cacheRoot: root,
            client: ModelsDevClient(transport: transport))

        #expect(transport.calls == 0)
    }

    @Test
    func `corrupt cache is ignored safely`() throws {
        let root = try Self.cacheRoot()
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let load = ModelsDevCache.load(cacheRoot: root)

        #expect(load.artifact == nil)
        #expect(load.isStale)
        #expect(load.error == .invalidJSON)
    }

    @Test
    func `serves decoded catalog from memo while the file is unchanged`() throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)

        // Pin a whole-second modification date so the memo key round-trips deterministically.
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)

        // Prime the in-memory memo with a successful decode.
        let primed = ModelsDevCache.load(cacheRoot: root)
        let cachedArtifact = try #require(primed.artifact)

        // Corrupt the file contents while preserving its size and modification date.
        let size = try #require(
            (FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber).intValue
        try Data(repeating: 0, count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)

        let reloaded = ModelsDevCache.load(cacheRoot: root)

        #expect(reloaded.error == nil)
        #expect(reloaded.artifact == cachedArtifact)
    }

    @Test
    func `saving a new catalog invalidates the memo`() throws {
        let root = try Self.cacheRoot()
        try ModelsDevCache.save(catalog: Self.fixtureCatalog(), fetchedAt: Date(), cacheRoot: root)
        #expect(ModelsDevCache.load(cacheRoot: root).artifact?.catalog?.providers["openai"] != nil)

        // Overwriting the cache must drop the memo so the next load reflects the freshly written catalog.
        ModelsDevCache.save(catalog: ModelsDevCatalog(providers: [:]), fetchedAt: Date(), cacheRoot: root)
        let reloaded = ModelsDevCache.load(cacheRoot: root)

        #expect(reloaded.error == nil)
        #expect(reloaded.artifact?.catalog?.providers.isEmpty == true)
    }

    @Test
    func `serves a failed load from memo while the file is unchanged`() throws {
        let root = try Self.cacheRoot()
        let url = ModelsDevCache.cacheFileURL(cacheRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let validData = try Self.encodedArtifactData()

        // Write invalid JSON of the same size as a valid encoding, with a pinned modification date.
        let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data(repeating: 0x7B, count: validData.count).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)
        #expect(ModelsDevCache.load(cacheRoot: root).error == .invalidJSON)

        // Replace the bytes with a valid encoding of identical size + modification date.
        try validData.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)
        let reloaded = ModelsDevCache.load(cacheRoot: root)

        #expect(reloaded.error == .invalidJSON)
        #expect(reloaded.artifact == nil)
    }

    @Test
    func `client fetches with mock transport`() async throws {
        let data = try Self.fixtureData()
        let client = ModelsDevClient(transport: MockTransport(result: .success((data, Self.response(status: 200)))))

        let catalog = try await client.fetchCatalog()

        #expect(catalog.providers["google-vertex-anthropic"]?.models["claude-sonnet-4-6@default"]?.cost?.input == 3.1)
    }

    @Test
    func `client reports http and json failures`() async throws {
        let data = try Self.fixtureData()
        let httpClient = ModelsDevClient(transport: MockTransport(result: .success((data, Self.response(status: 500)))))
        let jsonClient = ModelsDevClient(transport: MockTransport(
            result: .success((Data("not json".utf8), Self.response(status: 200)))))

        await #expect(throws: ModelsDevClient.Error.httpStatus(500)) {
            _ = try await httpClient.fetchCatalog()
        }
        await #expect(throws: ModelsDevClient.Error.invalidJSON) {
            _ = try await jsonClient.fetchCatalog()
        }
    }

    // MARK: - Helpers

    private static let afterTTL = Date(timeIntervalSince1970: 1 + ModelsDevCache.ttlSeconds + 1)

    private static let freshCatalogJSON = """
    {
      "openai": {
        "id": "openai",
        "models": { "gpt-6-astra": { "id": "gpt-6-astra", "cost": { "input": 10, "output": 50 } } }
      },
      "anthropic": {
        "id": "anthropic",
        "models": { "claude-opus-5-5": { "id": "claude-opus-5-5", "cost": { "input": 4, "output": 20 } } }
      },
      "google-vertex-anthropic": {
        "id": "google-vertex-anthropic",
        "models": {
          "claude-opus-5-5@default": { "id": "claude-opus-5-5@default", "cost": { "input": 4, "output": 20 } }
        }
      }
    }
    """

    private static func client(_ json: String) -> ModelsDevClient {
        ModelsDevClient(transport: MockTransport(result: .success((Data(json.utf8), self.response(status: 200)))))
    }

    private static func fixtureData() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "models-dev-subset",
            withExtension: "json",
            subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func fixtureCatalog() throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: self.fixtureData())
    }

    private static func encodedArtifactData() throws -> Data {
        let artifact = try ModelsDevCacheArtifact(
            version: ModelsDevCache.artifactVersion,
            fetchedAt: Date(timeIntervalSince1970: 0),
            catalog: self.fixtureCatalog())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(artifact)
    }

    private static func catalog(_ json: String) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-modelsdev-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://models.dev/api.json")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
    }
}

private enum MockError: Error {
    case failed
}

private struct MockTransport: ModelsDevHTTPTransport {
    let result: Result<(Data, URLResponse), Error>

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try self.result.get()
    }
}

private final class TrackingTransport: ModelsDevHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let result: Result<(Data, URLResponse), Error>

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    var calls: Int {
        self.lock.withLock { self.count }
    }

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        self.lock.withLock { self.count += 1 }
        try await Task.sleep(for: .milliseconds(20))
        return try self.result.get()
    }
}
