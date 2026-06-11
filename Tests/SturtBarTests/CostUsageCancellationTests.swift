import Foundation
import Testing
@testable import SturtBarCore

/// Ported from CodexBar CostUsageCancellationTests, adapted to the Claude-only
/// scanner (the legacy cases drove the codex scanner; the fetcher-level
/// cancellation case follows with CostUsageFetcher in Phase 2b).
struct CostUsageCancellationTests {
    @Test
    func `claude scanner cancellation preserves existing cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 1, day: 2)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: self.claudeSessionContents(iso: iso, usageLineCount: 1))

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

        let cacheURL = CostUsageCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let cacheBefore = try Data(contentsOf: cacheURL)

        try self.claudeSessionContents(iso: iso, usageLineCount: 20000)
            .write(to: fileURL, atomically: true, encoding: .utf8)

        var checks = 0
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            checks += 1
            if checks >= 8 {
                throw CancellationError()
            }
        }

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadDailyReportCancellable(
                since: day,
                until: day,
                now: day,
                options: options,
                checkCancellation: checkCancellation)
        }
        #expect(checks >= 8)
        #expect(try Data(contentsOf: cacheURL) == cacheBefore)
    }

    @Test
    func `claude file parse honors cancellation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 1, day: 2)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-large.jsonl",
            contents: self.claudeSessionContents(iso: iso, usageLineCount: 20000))

        var checks = 0
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            checks += 1
            if checks >= 3 {
                throw CancellationError()
            }
        }

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.parseClaudeFileCancellable(
                fileURL: fileURL,
                range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
                providerFilter: .all,
                checkCancellation: checkCancellation)
        }
        #expect(checks >= 3)
    }

    @Test
    func `claude report build honours cancellation and leaves cache unchanged`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 1, day: 2)
        let iso = env.isoString(for: day)

        // Seed a large cache with enough rows to trigger the poll threshold (4096).
        let fileCount = 5
        for i in 0..<fileCount {
            _ = try env.writeClaudeProjectFile(
                relativePath: "project-\(i)/session.jsonl",
                contents: self.claudeSessionContents(iso: iso, usageLineCount: 1000))
        }

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        // First scan — builds and persists the cache.
        let initial = CostUsageScanner.loadDailyReport(
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(initial.data.count == 1)

        let cacheURL = CostUsageCacheIO.cacheFileURL(cacheRoot: env.cacheRoot)
        let cacheBefore = try Data(contentsOf: cacheURL)

        // Second scan uses cached data; cancel inside the report-build row loop.
        var checks = 0
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            checks += 1
            // Allow several checks so the scan completes and we reach report-build.
            if checks >= 20 {
                throw CancellationError()
            }
        }

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadDailyReportCancellable(
                since: day,
                until: day,
                now: day,
                options: options,
                checkCancellation: checkCancellation)
        }
        #expect(checks >= 20)
        // Cache must be unchanged — no partial write on cancellation.
        #expect(try Data(contentsOf: cacheURL) == cacheBefore)
    }

    private func claudeSessionContents(iso: String, usageLineCount: Int) -> String {
        (0..<usageLineCount).map { self.claudeUsageLine(iso: iso, index: $0) }
            .joined(separator: "\n") + "\n"
    }

    private func claudeUsageLine(iso: String, index: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(iso)","requestId":"req_\#(index)","#
            + #""message":{"id":"msg_\#(index)","model":"claude-sonnet-4-20250514","usage":{"#
            + #""input_tokens":10,"cache_creation_input_tokens":2,"cache_read_input_tokens":1,"output_tokens":4}}}"#
    }
}
