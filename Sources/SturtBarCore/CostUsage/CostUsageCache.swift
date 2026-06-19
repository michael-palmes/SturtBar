import Foundation

/// Which provider's cost cache to read/write. Each provider gets its own cache
/// file so their per-file/day maps never collide.
enum CostUsageCacheProvider {
    case claude
    case codex

    /// Per-provider cache filename (carries its own artifact version).
    var fileName: String {
        switch self {
        case .claude: "claude-v4.json"
        case .codex: "codex-v1.json"
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
        return decoded
    }

    static func save(cache: CostUsageCache, cacheRoot: URL? = nil, provider: CostUsageCacheProvider = .claude) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot, provider: provider)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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

struct CostUsageCache: Codable {
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
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var claudeRows: [CostUsageScanner.ClaudeUsageRow]?
}
