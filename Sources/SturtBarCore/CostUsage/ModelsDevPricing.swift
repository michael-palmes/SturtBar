import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// models.dev pricing catalog: fetch (https://models.dev/api.json), cache under
// ~/Library/Caches/SturtBar, and lookup. Only the anthropic and openai providers are kept.

struct ModelsDevPricingInfo: Codable, Equatable {
    var providerID: String
    var providerName: String?
    var modelID: String
    var modelName: String?
    var inputCostPerToken: Double
    var outputCostPerToken: Double
    var cacheReadInputCostPerToken: Double?
    var cacheCreationInputCostPerToken: Double?
    var contextWindow: Int?
    var thresholdTokens: Int?
    var inputCostPerTokenAboveThreshold: Double?
    var outputCostPerTokenAboveThreshold: Double?
    var cacheReadInputCostPerTokenAboveThreshold: Double?
    var cacheCreationInputCostPerTokenAboveThreshold: Double?
}

struct ModelsDevPricingLookup: Equatable {
    var pricing: ModelsDevPricingInfo
    var normalizedModelID: String
}

struct ModelsDevCatalog: Codable, Equatable {
    var providers: [String: ModelsDevProvider]

    init(providers: [String: ModelsDevProvider]) {
        self.providers = providers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ModelsDevAnyCodingKey.self)
        if let providersKey = ModelsDevAnyCodingKey(stringValue: "providers"),
           let decoded = try? container.decode([String: ModelsDevProvider].self, forKey: providersKey)
        {
            self.providers = decoded.reduce(into: [:]) { result, item in
                var provider = item.value
                provider.mapKey = provider.mapKey ?? item.key
                let providerID = ModelsDevProvider.normalizeProviderID(provider.id ?? item.key)
                result[providerID] = provider
            }
            return
        }

        var providers: [String: ModelsDevProvider] = [:]

        for key in container.allKeys {
            guard var provider = try? container.decode(ModelsDevProvider.self, forKey: key) else { continue }
            provider.mapKey = key.stringValue
            let providerID = ModelsDevProvider.normalizeProviderID(provider.id ?? key.stringValue)
            providers[providerID] = provider
        }

        self.providers = providers
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ModelsDevAnyCodingKey.self)
        try container.encode(self.providers, forKey: ModelsDevAnyCodingKey(stringValue: "providers")!)
    }

    func pricing(providerID rawProviderID: String, modelID rawModelID: String) -> ModelsDevPricingLookup? {
        let providerID = ModelsDevProvider.normalizeProviderID(rawProviderID)
        return self.providers[providerID]?.pricing(modelID: rawModelID)
    }

    func retaining(providerIDs: Set<String>) -> ModelsDevCatalog {
        ModelsDevCatalog(providers: self.providers.filter { providerIDs.contains($0.key) })
    }

    func hasPricedModels(providerID: String) -> Bool {
        self.providers[ModelsDevProvider.normalizeProviderID(providerID)]?.models.values
            .contains(where: \.isPriceable) ?? false
    }
}

private struct ModelsDevAnyCodingKey: CodingKey {
    var intValue: Int?
    var stringValue: String

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }

    init?(stringValue: String) {
        self.intValue = nil
        self.stringValue = stringValue
    }
}

struct ModelsDevProvider: Codable, Equatable {
    var id: String?
    var name: String?
    var models: [String: ModelsDevModel]
    var mapKey: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case models
    }

    init(id: String?, name: String?, models: [String: ModelsDevModel], mapKey: String? = nil) {
        self.id = id
        self.name = name
        self.models = models
        self.mapKey = mapKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)

        let modelContainer = try container.nestedContainer(keyedBy: ModelsDevAnyCodingKey.self, forKey: .models)
        var models: [String: ModelsDevModel] = [:]
        for key in modelContainer.allKeys {
            guard let model = try? modelContainer.decode(ModelsDevModel.self, forKey: key) else { continue }
            models[key.stringValue] = model
        }
        self.models = models
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.id, forKey: .id)
        try container.encodeIfPresent(self.name, forKey: .name)
        try container.encode(self.models, forKey: .models)
    }

    static func normalizeProviderID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func pricing(modelID rawModelID: String) -> ModelsDevPricingLookup? {
        let candidates = ModelsDevModelIDNormalizer.candidates(rawModelID)
        for candidate in candidates {
            if let model = self.models[candidate],
               let pricing = model.pricing(providerID: self.id ?? self.mapKey ?? "", providerName: self.name)
            {
                return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: candidate)
            }
        }

        for candidate in candidates {
            if let match = self.models.values.first(where: { $0.normalizedID == candidate }),
               let pricing = match.pricing(providerID: self.id ?? self.mapKey ?? "", providerName: self.name)
            {
                return ModelsDevPricingLookup(pricing: pricing, normalizedModelID: match.normalizedID)
            }
        }

        return nil
    }
}

struct ModelsDevModel: Codable, Equatable {
    var id: String
    var name: String?
    var cost: ModelsDevCost?
    var limit: ModelsDevLimit?

    var normalizedID: String {
        ModelsDevModelIDNormalizer.normalize(self.id)
    }

    var isPriceable: Bool {
        self.cost?.input != nil && self.cost?.output != nil
    }

    func pricing(providerID: String, providerName: String?) -> ModelsDevPricingInfo? {
        guard let input = self.cost?.input, let output = self.cost?.output else { return nil }

        // models.dev publishes USD per 1M tokens. SturtBar cost math uses USD per token.
        let unit = 1_000_000.0
        let contextOver200K = self.cost?.contextOver200K
        return ModelsDevPricingInfo(
            providerID: ModelsDevProvider.normalizeProviderID(providerID),
            providerName: providerName,
            modelID: self.id,
            modelName: self.name,
            inputCostPerToken: input / unit,
            outputCostPerToken: output / unit,
            cacheReadInputCostPerToken: self.cost?.cacheRead.map { $0 / unit },
            cacheCreationInputCostPerToken: self.cost?.cacheWrite.map { $0 / unit },
            contextWindow: self.limit?.context,
            thresholdTokens: contextOver200K == nil ? nil : 200_000,
            inputCostPerTokenAboveThreshold: contextOver200K?.input.map { $0 / unit },
            outputCostPerTokenAboveThreshold: contextOver200K?.output.map { $0 / unit },
            cacheReadInputCostPerTokenAboveThreshold: contextOver200K?.cacheRead.map { $0 / unit },
            cacheCreationInputCostPerTokenAboveThreshold: contextOver200K?.cacheWrite.map { $0 / unit })
    }
}

struct ModelsDevCost: Codable, Equatable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
    var contextOver200K: ModelsDevContextOver200KCost?

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case contextOver200K = "context_over_200k"
    }
}

struct ModelsDevContextOver200KCost: Codable, Equatable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?

    private enum CodingKeys: String, CodingKey {
        case input
        case output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
}

struct ModelsDevLimit: Codable, Equatable {
    var context: Int?
}

enum ModelsDevModelIDNormalizer {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func candidates(_ raw: String) -> [String] {
        var candidates: [String] = []

        func append(_ value: String) {
            let normalized = self.normalize(value)
            guard !normalized.isEmpty, !candidates.contains(normalized) else { return }
            candidates.append(normalized)
        }

        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let contextTag = trimmed.range(of: #"\[\d+[a-z]\]$"#, options: .regularExpression) {
            trimmed.removeSubrange(contextTag)
        }
        append(trimmed)

        if trimmed.hasPrefix("openai/") {
            append(String(trimmed.dropFirst("openai/".count)))
        }

        if trimmed.hasPrefix("anthropic.") {
            append(String(trimmed.dropFirst("anthropic.".count)))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                append(tail)
            }
        }

        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            if let atSign = candidate.firstIndex(of: "@") {
                let base = String(candidate[..<atSign])
                append(base)
                let suffix = String(candidate[candidate.index(after: atSign)...])
                if suffix.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
                    append("\(base)-\(suffix)")
                }
            } else if candidate.hasPrefix("claude-") {
                append("\(candidate)@default")
            }

            if let dated = candidate.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
                append(String(candidate[..<dated.lowerBound]))
            }
            if let compactDate = candidate.range(of: #"-\d{8}$"#, options: .regularExpression) {
                append(String(candidate[..<compactDate.lowerBound]))
            }
            if let version = candidate.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
                var base = candidate
                base.removeSubrange(version)
                append(base)
            }

            index += 1
        }

        return candidates
    }
}

struct ModelsDevCacheArtifact: Codable, Equatable {
    var version: Int
    var fetchedAt: Date?
    var lastAttemptAt: Date?
    var catalog: ModelsDevCatalog?
}

struct ModelsDevCacheLoadResult: Equatable {
    var artifact: ModelsDevCacheArtifact?
    var isStale: Bool
    var error: ModelsDevCache.Error?
}

/// In-memory memo for the decoded models.dev catalog, keyed by file path + on-disk identity.
///
/// `ModelsDevCache.load` is called once per usage row whenever a cost lookup is performed without a
/// pre-resolved catalog. Without this memo, scanning a large `~/.claude` history re-reads and
/// re-decodes the ~800 KB catalog JSON for every row, pegging the CPU and freezing the menu bar.
///
/// The full load *outcome* is memoized, not just successful decodes: a corrupt or wrong-version cache
/// is read and decode-attempted exactly as expensively as a valid one, so caching only successes
/// would leave the per-row storm in place whenever the cache is unreadable.
private final class ModelsDevCacheMemo: @unchecked Sendable {
    enum Outcome {
        case decoded(ModelsDevCacheArtifact)
        case failure(ModelsDevCache.Error)
    }

    private struct Entry {
        let modificationDate: Date?
        let size: Int?
        let outcome: Outcome
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func outcome(path: String, modificationDate: Date?, size: Int?) -> Outcome? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[path],
              entry.modificationDate == modificationDate,
              entry.size == size
        else {
            return nil
        }
        return entry.outcome
    }

    func store(path: String, modificationDate: Date?, size: Int?, outcome: Outcome) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[path] = Entry(modificationDate: modificationDate, size: size, outcome: outcome)
    }

    func invalidate(path: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeValue(forKey: path)
    }
}

enum ModelsDevCache {
    enum Error: Swift.Error, Equatable {
        case unreadable
        case invalidVersion
        case invalidJSON
    }

    static let artifactVersion = 2
    static let ttlSeconds: TimeInterval = 24 * 60 * 60

    private static let memo = ModelsDevCacheMemo()

    private static func fileMetadata(at url: URL) -> (modificationDate: Date?, size: Int?) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, nil)
        }
        let modificationDate = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.intValue
        return (modificationDate, size)
    }

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("SturtBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil, version: Int = Self.artifactVersion) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("model-pricing", isDirectory: true)
            .appendingPathComponent("models-dev-v\(version).json", isDirectory: false)
    }

    static func load(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCacheLoadResult {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let metadata = Self.fileMetadata(at: url)

        // Staleness depends on `now`, so the result is always rebuilt; only the read+decode outcome is memoized.
        if let outcome = Self.memo.outcome(
            path: url.path,
            modificationDate: metadata.modificationDate,
            size: metadata.size)
        {
            return Self.result(for: outcome, now: now)
        }

        let outcome = Self.readOutcome(at: url)
        Self.memo.store(
            path: url.path,
            modificationDate: metadata.modificationDate,
            size: metadata.size,
            outcome: outcome)
        return Self.result(for: outcome, now: now)
    }

    private static func readOutcome(at url: URL) -> ModelsDevCacheMemo.Outcome {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ModelsDevCacheArtifact.self, from: data) else {
            return .failure(.invalidJSON)
        }
        guard decoded.version == Self.artifactVersion else {
            return .failure(.invalidVersion)
        }
        return .decoded(decoded)
    }

    private static func result(for outcome: ModelsDevCacheMemo.Outcome, now: Date) -> ModelsDevCacheLoadResult {
        switch outcome {
        case let .decoded(artifact):
            ModelsDevCacheLoadResult(
                artifact: artifact,
                isStale: artifact.catalog == nil
                    || artifact.fetchedAt.map { now.timeIntervalSince($0) > Self.ttlSeconds } ?? true,
                error: nil)
        case let .failure(error):
            ModelsDevCacheLoadResult(artifact: nil, isStale: true, error: error)
        }
    }

    static func save(catalog: ModelsDevCatalog, fetchedAt: Date = Date(), cacheRoot: URL? = nil) {
        let artifact = ModelsDevCacheArtifact(
            version: Self.artifactVersion,
            fetchedAt: fetchedAt,
            lastAttemptAt: fetchedAt,
            catalog: catalog)
        self.save(artifact: artifact, cacheRoot: cacheRoot)
    }

    /// Stamps a fetch attempt before any network call, keeping whatever catalog is already cached.
    static func recordAttempt(at date: Date, cacheRoot: URL? = nil) {
        var artifact = self.load(now: date, cacheRoot: cacheRoot).artifact
            ?? ModelsDevCacheArtifact(version: Self.artifactVersion)
        artifact.lastAttemptAt = date
        self.save(artifact: artifact, cacheRoot: cacheRoot)
    }

    static func save(artifact: ModelsDevCacheArtifact, cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(artifact) else { return }

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            // The on-disk catalog changed; drop the memo so the next load decodes the fresh file.
            Self.memo.invalidate(path: url.path)
            try? FileManager.default.removeItem(at: self.cacheFileURL(cacheRoot: cacheRoot, version: 1))
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

protocol ModelsDevHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionModelsDevTransport: ModelsDevHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

struct ModelsDevClient {
    enum Error: Swift.Error, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case invalidJSON
    }

    var url: URL
    var transport: any ModelsDevHTTPTransport

    init(
        url: URL = URL(string: "https://models.dev/api.json")!,
        transport: any ModelsDevHTTPTransport = URLSessionModelsDevTransport())
    {
        self.url = url
        self.transport = transport
    }

    func fetchCatalog() async throws -> ModelsDevCatalog {
        var request = URLRequest(url: self.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        let (data, response) = try await self.transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Error.httpStatus(http.statusCode) }

        do {
            return try JSONDecoder().decode(ModelsDevCatalog.self, from: data)
        } catch {
            throw Error.invalidJSON
        }
    }
}

enum ModelsDevPricingPipeline {
    static func lookup(
        providerID: String,
        modelID: String,
        now: Date = Date(),
        cacheRoot: URL? = nil) -> ModelsDevPricingLookup?
    {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot)
            .artifact?
            .catalog?
            .pricing(providerID: providerID, modelID: modelID)
    }

    static let retainedProviderIDs: Set<String> = [
        CostUsagePricing.claudeModelsDevProviderID,
        CostUsagePricing.codexModelsDevProviderID,
    ]
    static let attemptBackoffSeconds: TimeInterval = 24 * 60 * 60

    static func refreshIfNeeded(
        now: Date = Date(),
        cacheRoot: URL? = nil,
        client: ModelsDevClient = ModelsDevClient()) async
    {
        let key = ModelsDevCache.cacheFileURL(cacheRoot: cacheRoot).path
        await ModelsDevRefreshCoordinator.shared.run(key: key) {
            await Self.refreshNow(now: now, cacheRoot: cacheRoot, client: client)
        }
    }

    private static func refreshNow(now: Date, cacheRoot: URL?, client: ModelsDevClient) async {
        let load = ModelsDevCache.load(now: now, cacheRoot: cacheRoot)
        guard load.isStale else { return }
        if let lastAttempt = load.artifact?.lastAttemptAt,
           now >= lastAttempt,
           now.timeIntervalSince(lastAttempt) < Self.attemptBackoffSeconds
        {
            return
        }

        ModelsDevCache.recordAttempt(at: now, cacheRoot: cacheRoot)
        guard let fetched = try? await client.fetchCatalog() else { return }
        let catalog = fetched.retaining(providerIDs: Self.retainedProviderIDs)
        guard Self.retainedProviderIDs.allSatisfy(catalog.hasPricedModels(providerID:)) else { return }
        ModelsDevCache.save(catalog: catalog, fetchedAt: now, cacheRoot: cacheRoot)
    }
}

/// Joins concurrent refreshes of the same cache file, so the Claude and Codex scans fetch once.
actor ModelsDevRefreshCoordinator {
    static let shared = ModelsDevRefreshCoordinator()

    private var inFlight: [String: Task<Void, Never>] = [:]

    func run(key: String, _ operation: @escaping @Sendable () async -> Void) async {
        if let existing = self.inFlight[key] {
            await existing.value
            return
        }
        let task = Task { await operation() }
        self.inFlight[key] = task
        await task.value
        self.inFlight[key] = nil
    }
}
