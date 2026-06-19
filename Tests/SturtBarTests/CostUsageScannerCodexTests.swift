import Foundation
import Testing
@testable import SturtBarCore

/// Codex session-log cost scanning. The scanner reads ~/.codex/sessions +
/// archived_sessions JSONL, sums each `token_count` event's per-turn delta
/// (last_token_usage, falling back to total_token_usage deltas), and prices it
/// with the built-in Codex table. No fork/priority/SQLite machinery.
struct CostUsageScannerCodexTests {
    @Test
    func `aggregates a single session token_count into a daily cost`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let ts = env.isoString(for: day)
        try env.writeSession("2026/06/10/rollout-1.jsonl", [
            env.turnContext(model: "gpt-5.1-codex"),
            env.taskStarted("turn-1"),
            env.tokenCount(ts: ts, model: "gpt-5.1-codex", input: 1000, cached: 200, output: 500),
        ])

        let report = try env.loadCodex(since: day, until: day, now: day)

        let expectedDay = CostUsageScanner.dayKeyFromTimestamp(ts)
        let entry = try #require(report.data.first { $0.date == expectedDay })
        let expectedCost = (800.0 * 1.25e-6) + (200.0 * 1.25e-7) + (500.0 * 1e-5)
        #expect(entry.costUSD == expectedCost)
        // input already includes the cached subset, so distinct tokens = input + output.
        #expect(entry.totalTokens == 1500)
    }

    @Test
    func `sums multiple token_count events and multiple models`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let ts0 = env.isoString(for: day)
        let ts1 = env.isoString(for: day.addingTimeInterval(1))
        let ts2 = env.isoString(for: day.addingTimeInterval(2))
        try env.writeSession("2026/06/10/rollout-1.jsonl", [
            env.turnContext(model: "gpt-5.1-codex"),
            env.tokenCount(ts: ts0, model: "gpt-5.1-codex", input: 1000, cached: 0, output: 500),
            env.tokenCount(ts: ts1, model: "gpt-5.1-codex", input: 2000, cached: 0, output: 100),
            env.turnContext(model: "gpt-5.5"),
            env.tokenCount(ts: ts2, model: "gpt-5.5", input: 100_000, cached: 0, output: 10000),
        ])

        let report = try env.loadCodex(since: day, until: day, now: day)
        let entry = try #require(report.data.first { $0.date == CostUsageScanner.dayKeyFromTimestamp(ts0) })

        let codexCost = (3000.0 * 1.25e-6) + (600.0 * 1e-5)
        let gpt55Cost = (100_000.0 * 5e-6) + (10000.0 * 3e-5)
        #expect(entry.costUSD == codexCost + gpt55Cost)
        // Two models present in the per-day breakdown.
        #expect((entry.modelBreakdowns?.count ?? 0) == 2)
    }

    @Test
    func `scans archived_sessions as well as sessions`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let ts = env.isoString(for: day)
        try env.writeArchived("rollout-old.jsonl", [
            env.tokenCount(ts: ts, model: "gpt-5.1-codex", input: 1000, cached: 0, output: 0),
        ])

        let report = try env.loadCodex(since: day, until: day, now: day)
        let entry = try #require(report.data.first { $0.date == CostUsageScanner.dayKeyFromTimestamp(ts) })
        #expect(entry.costUSD == 1000.0 * 1.25e-6)
    }

    @Test
    func `excludes token_count outside the requested window`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let inWindow = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let outOfWindow = try env.makeLocalNoon(year: 2026, month: 4, day: 1)
        try env.writeSession("in.jsonl", [
            env.tokenCount(ts: env.isoString(for: inWindow), model: "gpt-5.1-codex", input: 1000, cached: 0, output: 0),
        ])
        try env.writeSession("out.jsonl", [
            env.tokenCount(
                ts: env.isoString(for: outOfWindow),
                model: "gpt-5.1-codex",
                input: 9999,
                cached: 0,
                output: 0),
        ])

        let report = try env.loadCodex(since: inWindow, until: inWindow, now: inWindow)
        #expect(report.data.count == 1)
        #expect(report.data.first?.date == CostUsageScanner.dayKeyFromTimestamp(env.isoString(for: inWindow)))
    }

    @Test
    func `re-scanning the same logs does not double-count`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let ts = env.isoString(for: day)
        try env.writeSession("2026/06/10/rollout-1.jsonl", [
            env.tokenCount(ts: ts, model: "gpt-5.1-codex", input: 1000, cached: 200, output: 500),
        ])

        let first = try env.loadCodex(since: day, until: day, now: day)
        let second = try env.loadCodex(since: day, until: day, now: day)
        let firstCost = first.data.first?.costUSD
        let secondCost = second.data.first?.costUSD
        #expect(firstCost != nil)
        #expect(firstCost == secondCost)
    }

    @Test
    func `derives per-turn deltas from cumulative total_token_usage`() throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let ts0 = env.isoString(for: day)
        let ts1 = env.isoString(for: day.addingTimeInterval(1))
        // Only cumulative totals (no last_token_usage); deltas must be derived.
        try env.writeSession("totals.jsonl", [
            env.tokenCountTotalsOnly(ts: ts0, model: "gpt-5.1-codex", input: 1000, cached: 0, output: 200),
            env.tokenCountTotalsOnly(ts: ts1, model: "gpt-5.1-codex", input: 3000, cached: 0, output: 600),
        ])

        let report = try env.loadCodex(since: day, until: day, now: day)
        let entry = try #require(report.data.first { $0.date == CostUsageScanner.dayKeyFromTimestamp(ts0) })
        // Total deltas: input 3000, output 600.
        let expectedCost = (3000.0 * 1.25e-6) + (600.0 * 1e-5)
        #expect(entry.costUSD == expectedCost)
        #expect(entry.totalTokens == 3600)
    }

    @Test
    func `codex fetcher builds a token snapshot from session logs`() async throws {
        let env = try CodexScannerTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 10)
        let ts = env.isoString(for: day)
        try env.writeSession("rollout-1.jsonl", [
            env.tokenCount(ts: ts, model: "gpt-5.1-codex", input: 1000, cached: 200, output: 500),
        ])

        let fetcher = CodexCostFetcher(scannerOptions: env.options())
        let snapshot = try await fetcher.loadTokenSnapshot(now: day)

        let expectedCost = (800.0 * 1.25e-6) + (200.0 * 1.25e-7) + (500.0 * 1e-5)
        #expect(snapshot?.last30DaysCostUSD == expectedCost)
        #expect(snapshot?.sessionCostUSD == expectedCost)
        #expect(snapshot?.sessionTokens == 1500)
    }
}

// MARK: - Test environment

struct CodexScannerTestEnvironment {
    let root: URL
    let cacheRoot: URL
    let sessionsRoot: URL
    let archivedRoot: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sturtbar-codex-cost-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        self.sessionsRoot = root.appendingPathComponent("codex/sessions", isDirectory: true)
        self.archivedRoot = root.appendingPathComponent("codex/archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.sessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.archivedRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func options() -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(cacheRoot: self.cacheRoot)
        options.codexSessionsRoots = [self.sessionsRoot, self.archivedRoot]
        options.refreshMinIntervalSeconds = 0
        return options
    }

    func loadCodex(since: Date, until: Date, now: Date) throws -> CostUsageDailyReport {
        try CostUsageScanner.loadCodexDailyReport(
            since: since,
            until: until,
            now: now,
            options: self.options(),
            checkCancellation: nil)
    }

    func writeSession(_ relativePath: String, _ objects: [Any]) throws {
        try self.write(root: self.sessionsRoot, relativePath: relativePath, objects: objects)
    }

    func writeArchived(_ relativePath: String, _ objects: [Any]) throws {
        try self.write(root: self.archivedRoot, relativePath: relativePath, objects: objects)
    }

    private func write(root: URL, relativePath: String, objects: [Any]) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.jsonl(objects).write(to: url, atomically: true, encoding: .utf8)
    }

    func makeLocalNoon(year: Int, month: Int, day: Int) throws -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        guard let date = comps.date else { throw NSError(domain: "CodexScannerTestEnvironment", code: 1) }
        return date
    }

    func isoString(for date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    func jsonl(_ objects: [Any]) throws -> String {
        let lines = try objects.map { obj -> String in
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw NSError(domain: "CodexScannerTestEnvironment", code: 2)
            }
            return text
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Record builders

    func turnContext(model: String) -> [String: Any] {
        ["type": "turn_context", "payload": ["model": model]]
    }

    func taskStarted(_ turnID: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "task_started", "id": turnID]]
    }

    func tokenCount(ts: String, model: String?, input: Int, cached: Int, output: Int) -> [String: Any] {
        var info: [String: Any] = [
            "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
            "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
        ]
        if let model { info["model"] = model }
        return ["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": info]]
    }

    func tokenCountTotalsOnly(ts: String, model: String?, input: Int, cached: Int, output: Int) -> [String: Any] {
        var info: [String: Any] = [
            "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
        ]
        if let model { info["model"] = model }
        return ["type": "event_msg", "timestamp": ts, "payload": ["type": "token_count", "info": info]]
    }
}
