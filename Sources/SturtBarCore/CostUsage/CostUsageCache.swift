import Foundation

/// Which provider's cost cache to read/write. Each provider gets its own cache
/// file so their per-file/day maps never collide.
enum CostUsageCacheProvider {
    case claude
    case codex

    /// Per-provider cache filename (carries its own artifact version).
    var fileName: String {
        switch self {
        case .claude: "claude-v5.json"
        case .codex: "codex-v2.json"
        }
    }

    /// Superseded cache files for this provider only, deleted on the next save.
    var legacyFileNames: [String] {
        switch self {
        case .claude: ["claude-v4.json"]
        case .codex: ["codex-v1.json"]
        }
    }
}

enum CostUsageCacheIO {
    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("SturtBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil, provider: CostUsageCacheProvider = .claude) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(provider.fileName, isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil, provider: CostUsageCacheProvider = .claude) -> CostUsageCache {
        let url = self.cacheFileURL(cacheRoot: cacheRoot, provider: provider)
        if let decoded = self.loadCache(at: url) { return decoded }
        return CostUsageCache()
    }

    private static func loadCache(at url: URL) -> CostUsageCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data)
        else { return nil }
        guard decoded.version == 1 else { return nil }
        // Day keys are local calendar days, so a cache built in another time zone is rebuilt.
        if let zone = decoded.timeZoneIdentifier, zone != TimeZone.current.identifier { return nil }
        return decoded
    }

    /// Saves only when the scan changed something beyond its timestamp, sparing a multi-megabyte rewrite.
    static func saveIfChanged(
        cache: CostUsageCache,
        loaded: CostUsageCache,
        cacheRoot: URL? = nil,
        provider: CostUsageCacheProvider = .claude)
    {
        var unchanged = cache
        unchanged.lastScanUnixMs = loaded.lastScanUnixMs
        unchanged.timeZoneIdentifier = loaded.timeZoneIdentifier
        guard unchanged != loaded || loaded.timeZoneIdentifier == nil else { return }
        self.save(cache: cache, cacheRoot: cacheRoot, provider: provider)
    }

    static func save(cache: CostUsageCache, cacheRoot: URL? = nil, provider: CostUsageCacheProvider = .claude) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot, provider: provider)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for legacy in provider.legacyFileNames {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(legacy, isDirectory: false))
        }

        var cache = cache
        cache.timeZoneIdentifier = TimeZone.current.identifier
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

struct CostUsageCache: Codable, Equatable {
    var version: Int = 1
    var lastScanUnixMs: Int64 = 0
    var scanSinceKey: String?
    var scanUntilKey: String?

    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]

    /// dayKey -> model -> packed usage
    var days: [String: [String: [Int]]] = [:]

    /// rootPath -> mtime (for Claude roots)
    var roots: [String: Int64]?

    var timeZoneIdentifier: String?
}

struct CostUsageFileUsage: Codable, Equatable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
    /// File-system identity; a change means the file was replaced, not appended to.
    var fileIdentifier: UInt64?
}
