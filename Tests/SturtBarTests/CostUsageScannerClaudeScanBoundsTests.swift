import Foundation
import Testing
@testable import SturtBarCore

/// New in the SturtBar rebuild (Phase 2a step 2): covers the two bounded-scan
/// performance changes layered on top of the ported Claude scanner.
struct CostUsageScannerClaudeScanBoundsTests {
    @Test
    func `claude scan skips files modified long before the window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 1)
        let iso = env.isoString(for: day)

        // In-window content, but the file was last modified 60 days before the
        // window start: a file cannot contain rows newer than its mtime, so the
        // scan must skip it without opening it.
        let oldFileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/stale-session.jsonl",
            contents: env.jsonl([self.assistantEntry(iso: iso, requestID: "req_old", inputTokens: 1000)]))
        let staleMtime = Calendar.current.date(byAdding: .day, value: -60, to: day) ?? day
        try FileManager.default.setAttributes(
            [.modificationDate: staleMtime],
            ofItemAtPath: oldFileURL.path)

        // Modified exactly one day before the window start: still scanned (the
        // cutoff keeps a one-day buffer for timezone skew).
        let boundaryFileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/boundary-session.jsonl",
            contents: env.jsonl([self.assistantEntry(iso: iso, requestID: "req_boundary", inputTokens: 7)]))
        let boundaryMtime = try env.makeLocalNoon(year: 2026, month: 5, day: 31)
        try FileManager.default.setAttributes(
            [.modificationDate: boundaryMtime],
            ofItemAtPath: boundaryFileURL.path)

        // Freshly modified: always scanned.
        let freshFileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/fresh-session.jsonl",
            contents: env.jsonl([self.assistantEntry(iso: iso, requestID: "req_fresh", inputTokens: 10)]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 17)

        let cache = CostUsageCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(self.cacheEntry(in: cache, for: oldFileURL) == nil)
        #expect(self.cacheEntry(in: cache, for: boundaryFileURL) != nil)
        #expect(self.cacheEntry(in: cache, for: freshFileURL) != nil)
    }

    @Test
    func `claude scan drops cached entries once their file mtime falls outside the window`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 1)
        let iso = env.isoString(for: day)

        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: env.jsonl([self.assistantEntry(iso: iso, requestID: "req_cached", inputTokens: 42)]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let firstReport = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(firstReport.data.count == 1)
        #expect(firstReport.data[0].inputTokens == 42)
        #expect(self.cacheEntry(in: CostUsageCacheIO.load(cacheRoot: env.cacheRoot), for: fileURL) != nil)

        // Backdate the file far before the window start: the next scan must
        // skip it by mtime alone and drop its cached entry.
        let staleMtime = Calendar.current.date(byAdding: .day, value: -60, to: day) ?? day
        try FileManager.default.setAttributes(
            [.modificationDate: staleMtime],
            ofItemAtPath: fileURL.path)

        let secondReport = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(secondReport.data.isEmpty)

        let cache = CostUsageCacheIO.load(cacheRoot: env.cacheRoot)
        #expect(self.cacheEntry(in: cache, for: fileURL) == nil)
    }

    @Test
    func `claude scan window is capped at 30 days`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let until = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let calendar = Calendar.current
        guard let since = calendar.date(byAdding: .day, value: -89, to: until),
              let outsideCapDay = calendar.date(byAdding: .day, value: -40, to: until),
              let capBoundaryDay = calendar.date(byAdding: .day, value: -29, to: until),
              let recentDay = calendar.date(byAdding: .day, value: -5, to: until)
        else {
            throw NSError(domain: "CostUsageScannerClaudeScanBoundsTests", code: 1)
        }

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/long-history.jsonl",
            contents: env.jsonl([
                self.assistantEntry(
                    iso: env.isoString(for: outsideCapDay),
                    requestID: "req_outside_cap",
                    inputTokens: 1000),
                self.assistantEntry(
                    iso: env.isoString(for: capBoundaryDay),
                    requestID: "req_cap_boundary",
                    inputTokens: 3),
                self.assistantEntry(
                    iso: env.isoString(for: recentDay),
                    requestID: "req_recent",
                    inputTokens: 10),
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        // A 90-day request clamps to the most recent 30 days (inclusive).
        let report = CostUsageScanner.loadDailyReport(
            since: since,
            until: until,
            now: until,
            options: options)

        let reportedDays = report.data.map(\.date)
        #expect(reportedDays.count == 2)
        #expect(reportedDays.contains(CostUsageScanner.CostUsageDayRange.dayKey(from: capBoundaryDay)))
        #expect(reportedDays.contains(CostUsageScanner.CostUsageDayRange.dayKey(from: recentDay)))
        #expect(!reportedDays.contains(CostUsageScanner.CostUsageDayRange.dayKey(from: outsideCapDay)))
        #expect(report.summary?.totalInputTokens == 13)
    }

    /// The scanner keys cache entries by the enumerator's resolved path, which
    /// carries the /private prefix for /var temp dirs on macOS.
    private func cacheEntry(in cache: CostUsageCache, for url: URL) -> CostUsageFileUsage? {
        if let entry = cache.files[url.path] { return entry }
        guard url.path.hasPrefix("/var/") else { return nil }
        return cache.files["/private" + url.path]
    }

    private func assistantEntry(iso: String, requestID: String, inputTokens: Int) -> [String: Any] {
        [
            "type": "assistant",
            "timestamp": iso,
            "requestId": requestID,
            "message": [
                "id": "msg_\(requestID)",
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": inputTokens,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                ],
            ],
        ]
    }
}
