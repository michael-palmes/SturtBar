import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SturtBarCore

// Ported from CodexBar CostUsageFetcherTests (Claude-relevant cases only).
// Dropped: codex/bedrock/session/monthly cases.
// CostUsageFetcherCacheSnapshotTests decision: all tests in that file exercise
// the codex cached-snapshot path (loadCachedCodexTokenSnapshot) which was
// dropped in the SturtBar rebuild — not ported.
//
// The fetcher-level cancellation test is ported from legacy
// CostUsageCancellationTests (fetcher honors cancellation before token scan).
struct ClaudeCostFetcherTests {
    @Test
    func `fetcher returns nil for empty scan result`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)

        let snapshot = try await ClaudeCostFetcher.loadTokenSnapshot(
            now: day,
            scannerOptions: options)

        #expect(snapshot == nil)
    }

    @Test
    func `fetcher returns snapshot for scan with data`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": iso,
                    "requestId": "req_fetcher_1",
                    "message": [
                        "id": "msg_fetcher_1",
                        "model": "claude-sonnet-4-6",
                        "usage": [
                            "input_tokens": 200,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 50,
                        ],
                    ],
                ],
            ]))

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)

        let snapshot = try await ClaudeCostFetcher.loadTokenSnapshot(
            now: day,
            scannerOptions: options)

        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        #expect(snapshot != nil)
        #expect(snapshot?.sessionTokens == 250)
        #expect(snapshot?.daily.map(\.date) == [dayKey])
    }

    @Test
    func `fetcher token snapshot picks most recent day`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let oldDay = try env.makeLocalNoon(year: 2026, month: 6, day: 7)
        let newDay = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let isoOld = env.isoString(for: oldDay)
        let isoNew = env.isoString(for: newDay)

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/old.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": isoOld,
                    "requestId": "req_old",
                    "message": [
                        "id": "msg_old",
                        "model": "claude-sonnet-4-6",
                        "usage": [
                            "input_tokens": 500,
                            "output_tokens": 100,
                        ],
                    ],
                ],
            ]))
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/new.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": isoNew,
                    "requestId": "req_new",
                    "message": [
                        "id": "msg_new",
                        "model": "claude-sonnet-4-6",
                        "usage": [
                            "input_tokens": 100,
                            "output_tokens": 20,
                        ],
                    ],
                ],
            ]))

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)

        let snapshot = try await ClaudeCostFetcher.loadTokenSnapshot(
            now: newDay,
            historyDays: 7,
            scannerOptions: options)

        let newDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: newDay)
        #expect(snapshot?.daily.map(\.date).last == newDayKey)
        #expect(snapshot?.sessionTokens == 120)
    }

    @Test
    func `fetcher bypassScanGate sets refreshMinIntervalSeconds to zero`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": iso,
                    "requestId": "req_force_1",
                    "message": [
                        "id": "msg_force_1",
                        "model": "claude-sonnet-4-6",
                        "usage": [
                            "input_tokens": 100,
                            "output_tokens": 20,
                        ],
                    ],
                ],
            ]))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600

        // First scan populates cache.
        let first = try await ClaudeCostFetcher.loadTokenSnapshot(
            now: day,
            scannerOptions: options)
        #expect(first?.sessionTokens == 120)

        // Append more tokens — cache interval would normally skip rescan.
        try env.jsonl([
            [
                "type": "assistant",
                "timestamp": iso,
                "requestId": "req_force_2",
                "message": [
                    "id": "msg_force_2",
                    "model": "claude-sonnet-4-6",
                    "usage": [
                        "input_tokens": 200,
                        "output_tokens": 40,
                    ],
                ],
            ],
        ]).write(to: fileURL, atomically: false, encoding: .utf8)

        // bypassScanGate=true bypasses TTL and picks up the new tokens.
        let refreshed = try await ClaudeCostFetcher.loadTokenSnapshot(
            now: day.addingTimeInterval(1),
            bypassScanGate: true,
            scannerOptions: options)
        #expect(refreshed?.sessionTokens == 240)
    }

    @Test
    func `fetcher honors cancellation before token scan`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let gate = AsyncCancellationGate()
        let task = Task {
            await gate.wait()
            let options = CostUsageScanner.Options(
                claudeProjectsRoots: [env.claudeProjectsRoot],
                cacheRoot: env.cacheRoot)
            _ = try await ClaudeCostFetcher.loadTokenSnapshot(
                scannerOptions: options)
        }
        await gate.waitUntilBlocked()
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `refreshPricingCatalogIfNeeded uses injected transport and writes to cacheRoot`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        // Build a catalog payload with a known model; the transport returns it for
        // the initial stale-cache refresh.
        let catalogJSON = #"{"anthropic":{"id":"anthropic","models":"#
            + #"{"claude-test-model":{"id":"claude-test-model","cost":{"input":1,"output":2}}}}}"#
        let catalogURL = try #require(URL(string: "https://models.dev/api.json"))
        let catalogResponse = try #require(HTTPURLResponse(
            url: catalogURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil))
        let transport = MockTransport(result: .success((Data(catalogJSON.utf8), catalogResponse)))
        let fetcher = ClaudeCostFetcher(
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot))

        // Stale epoch forces a refresh; injected transport must be used (no real network).
        await fetcher.refreshPricingCatalogIfNeeded(
            now: Date(timeIntervalSince1970: ModelsDevCache.ttlSeconds + 1),
            client: ModelsDevClient(transport: transport))

        // Verify the catalog was written to the injected cacheRoot, not the real cache dir.
        let loaded = ModelsDevCache.load(cacheRoot: env.cacheRoot)
        #expect(loaded.artifact != nil)
        let lookup = loaded.artifact?.catalog.pricing(
            providerID: "anthropic",
            modelID: "claude-test-model")
        #expect(lookup != nil)
    }

    @Test
    func `tokenSnapshot selects most recent day with tie breaking`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let daily = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-06-07",
                    inputTokens: 100,
                    outputTokens: 10,
                    totalTokens: 110,
                    costUSD: 0.001,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: "2026-06-09",
                    inputTokens: 50,
                    outputTokens: 5,
                    totalTokens: 55,
                    costUSD: 0.0005,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: 150,
                totalOutputTokens: 15,
                totalTokens: 165,
                totalCostUSD: 0.0015))

        let snapshot = ClaudeCostFetcher.tokenSnapshot(from: daily, now: now, historyDays: 30)

        #expect(snapshot.sessionTokens == 55)
        #expect(snapshot.sessionCostUSD == 0.0005)
        #expect(snapshot.last30DaysTokens == 165)
        #expect(snapshot.last30DaysCostUSD == 0.0015)
        #expect(snapshot.historyDays == 30)
        #expect(snapshot.daily.count == 2)
    }

    @Test
    func `tokenSnapshot falls back to summing entries when summary is absent`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let daily = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-06-09",
                    inputTokens: 100,
                    outputTokens: 20,
                    totalTokens: 120,
                    costUSD: 0.002,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let snapshot = ClaudeCostFetcher.tokenSnapshot(from: daily, now: now, historyDays: 30)

        #expect(snapshot.last30DaysTokens == 120)
        #expect(snapshot.last30DaysCostUSD == 0.002)
    }
}

private struct MockTransport: ModelsDevHTTPTransport {
    let result: Result<(Data, URLResponse), Error>

    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        try self.result.get()
    }
}

private actor AsyncCancellationGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isOpen = false

    func wait() async {
        self.isBlocked = true
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
        if self.isOpen { return }
        await withCheckedContinuation { continuation in
            self.openContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if self.isBlocked { return }
        await withCheckedContinuation { continuation in
            self.blockedContinuation = continuation
        }
    }

    func open() {
        self.isOpen = true
        self.openContinuation?.resume()
        self.openContinuation = nil
    }
}
