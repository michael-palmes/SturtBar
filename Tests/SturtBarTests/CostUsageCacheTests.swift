import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageCacheTests {
    @Test
    func `cache file URL uses claude artifact version 5`() {
        let root = URL(fileURLWithPath: "/tmp/sturtbar-cost-cache", isDirectory: true)
        let url = CostUsageCacheIO.cacheFileURL(cacheRoot: root)
        #expect(url.lastPathComponent == "claude-v5.json")
    }

    @Test
    func `cache save and load round-trips correctly`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        var cache = CostUsageCache()
        cache.lastScanUnixMs = 123
        cache.days = ["2026-05-18": ["claude-sonnet-4-5": [1, 2, 3]]]

        CostUsageCacheIO.save(cache: cache, cacheRoot: root)

        let loaded = CostUsageCacheIO.load(cacheRoot: root)
        #expect(loaded.lastScanUnixMs == 123)
        #expect(loaded.days["2026-05-18"]?["claude-sonnet-4-5"] == [1, 2, 3])
    }

    @Test
    func `load returns empty cache when file is missing`() {
        let root = URL(fileURLWithPath: "/tmp/sturtbar-cost-cache-missing-\(UUID().uuidString)", isDirectory: true)
        let loaded = CostUsageCacheIO.load(cacheRoot: root)
        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.files.isEmpty)
        #expect(loaded.days.isEmpty)
    }

    @Test
    func `load rejects cache with wrong version`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let badVersion = """
        {
          "version": 99,
          "lastScanUnixMs": 999,
          "files": {},
          "days": {}
        }
        """
        try badVersion.write(to: url, atomically: false, encoding: .utf8)

        let loaded = CostUsageCacheIO.load(cacheRoot: root)
        #expect(loaded.lastScanUnixMs == 0)
        #expect(loaded.days.isEmpty)
    }

    @Test
    func `load accepts cache without producer key`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = CostUsageCacheIO.cacheFileURL(cacheRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let payload = """
        {
          "version": 1,
          "lastScanUnixMs": 999,
          "files": {},
          "days": {
            "2026-05-18": {
              "claude-sonnet-4-5": [1, 0, 0]
            }
          }
        }
        """
        try payload.write(to: url, atomically: false, encoding: .utf8)

        let loaded = CostUsageCacheIO.load(cacheRoot: root)
        #expect(loaded.lastScanUnixMs == 999)
        #expect(loaded.days["2026-05-18"]?["claude-sonnet-4-5"] == [1, 0, 0])
    }

    @Test
    func `default cache root uses SturtBar directory`() {
        let url = CostUsageCacheIO.cacheFileURL()
        #expect(url.path.contains("SturtBar"))
        #expect(url.path.contains("cost-usage"))
        #expect(url.lastPathComponent == "claude-v5.json")
    }

    @Test
    func `saving the claude cache removes the superseded v4 file`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("cost-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("claude-v4.json")
        let codex = dir.appendingPathComponent("codex-v1.json")
        try Data("{}".utf8).write(to: legacy)
        try Data("{}".utf8).write(to: codex)

        CostUsageCacheIO.save(cache: CostUsageCache(), cacheRoot: root)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: codex.path))
    }

    @Test
    func `a cache built in another time zone is discarded`() throws {
        let root = try self.makeTemporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var cache = CostUsageCache()
        cache.lastScanUnixMs = 42
        CostUsageCacheIO.save(cache: cache, cacheRoot: root)
        #expect(CostUsageCacheIO.load(cacheRoot: root).lastScanUnixMs == 42)

        let url = CostUsageCacheIO.cacheFileURL(cacheRoot: root)
        var stored = try JSONDecoder().decode(CostUsageCache.self, from: Data(contentsOf: url))
        let otherZone = TimeZone.current.identifier == "Pacific/Chatham" ? "Asia/Kolkata" : "Pacific/Chatham"
        stored.timeZoneIdentifier = otherZone
        try JSONEncoder().encode(stored).write(to: url)

        #expect(CostUsageCacheIO.load(cacheRoot: root).lastScanUnixMs == 0)
    }

    private func makeTemporaryCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-cost-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

struct CostUsageCacheWriteTests {
    @Test
    func `a scan that finds nothing new leaves the cache file alone`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 25)
        let iso = env.isoString(for: day)
        func entry(_ id: String) -> [String: Any] {
            [
                "message": [
                    "model": "claude-opus-5",
                    "id": id,
                    "usage": [
                        "input_tokens": 10,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                        "output_tokens": 1,
                    ],
                ],
                "requestId": "req_\(id)",
                "type": "assistant",
                "timestamp": iso,
                "sessionId": "session_write",
            ]
        }
        let log = try env.writeClaudeProjectFile(relativePath: "p/write.jsonl", contents: env.jsonl([entry("msg_1")]))
        var options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(since: day, until: day, now: day, options: options)

        let cacheURL = CostUsageCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: cacheURL.path)

        _ = CostUsageScanner.loadDailyReport(since: day, until: day, now: day.addingTimeInterval(120), options: options)
        let afterIdle = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        #expect(afterIdle == pinned)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(env.jsonl([entry("msg_2")]).utf8))
        try handle.close()
        _ = CostUsageScanner.loadDailyReport(since: day, until: day, now: day.addingTimeInterval(240), options: options)
        let afterAppend = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        #expect(afterAppend != pinned)
    }
}
