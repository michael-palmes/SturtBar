import Foundation

// Single entry point for Codex cost data. Mirror of `ClaudeCostFetcher`, but the
// scan reads local `~/.codex/sessions` JSONL instead of `~/.claude` transcripts.
//
// Public API:
//   CodexCostFetcher.loadTokenSnapshot(now:bypassScanGate:historyDays:) async throws(CancellationError) -> CostUsageTokenSnapshot?
//   CodexCostFetcher.refreshPricingCatalogIfNeeded(now:) async
//
// Pricing refresh reuses the SAME shared models.dev pipeline as Claude — no new
// network endpoint. Non-cancellation failures are swallowed into nil (cost is
// optional eye-candy and must never surface errors).
public struct CodexCostFetcher: Sendable {
    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil) {
        self.scannerOptions = cacheRoot.map { CostUsageScanner.Options(cacheRoot: $0) }
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    /// Refreshes the shared models.dev pricing catalog if the cached copy is stale.
    /// Offline/no-op safe; never throws.
    public func refreshPricingCatalogIfNeeded(now: Date = Date()) async {
        let cacheRoot = self.scannerOptions?.cacheRoot
        await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot)
    }

    /// Loads a Codex token-usage snapshot for the rolling history window ending at `now`.
    ///
    /// - Parameters:
    ///   - bypassScanGate: When `true`, zeros `refreshMinIntervalSeconds` so the
    ///     scanner re-runs regardless of its TTL.
    /// - Returns: `nil` when no usage data is found in the window.
    /// - Throws: `CancellationError` only.
    public func loadTokenSnapshot(
        now: Date = Date(),
        bypassScanGate: Bool = false,
        historyDays: Int = 30) async throws(CancellationError) -> CostUsageTokenSnapshot?
    {
        try await Self.loadTokenSnapshot(
            now: now,
            bypassScanGate: bypassScanGate,
            historyDays: historyDays,
            scannerOptions: self.scannerOptions)
    }

    static func loadTokenSnapshot(
        now: Date = Date(),
        bypassScanGate: Bool = false,
        historyDays: Int = 30,
        scannerOptions overrideScannerOptions: CostUsageScanner
            .Options? = nil) async throws(CancellationError) -> CostUsageTokenSnapshot?
    {
        let clampedHistoryDays = max(1, min(365, historyDays))
        let until = now
        // Rolling window is inclusive: 30-day display starts 29 days before `now`.
        let since = Calendar.current.date(byAdding: .day, value: -(clampedHistoryDays - 1), to: now) ?? now

        var options = overrideScannerOptions ?? CostUsageScanner.Options()
        if bypassScanGate {
            options.refreshMinIntervalSeconds = 0
        }

        let checkCancellation: CostUsageScanner.CancellationCheck = {
            try Task.checkCancellation()
        }
        do { try Task.checkCancellation() } catch { throw CancellationError() }

        let daily: CostUsageDailyReport
        do {
            daily = try CostUsageScanner.loadCodexDailyReport(
                since: since,
                until: until,
                now: now,
                options: options,
                checkCancellation: checkCancellation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        do { try Task.checkCancellation() } catch { throw CancellationError() }

        guard !daily.data.isEmpty else { return nil }

        // The session/today-selection logic is provider-agnostic; reuse it.
        return ClaudeCostFetcher.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
    }
}
