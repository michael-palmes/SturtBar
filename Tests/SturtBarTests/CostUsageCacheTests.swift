import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageCacheTests {
    @Test
    func `cache file URL uses claude artifact version 4`() {
        let root = URL(fileURLWithPath: "/tmp/sturtbar-cost-cache", isDirectory: true)
        let url = CostUsageCacheIO.cacheFileURL(cacheRoot: root)
        #expect(url.lastPathComponent == "claude-v4.json")
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
        #expect(url.lastPathComponent == "claude-v4.json")
    }

    private func makeTemporaryCacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-cost-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
