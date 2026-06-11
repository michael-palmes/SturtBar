import Foundation

// Single entry point for Claude cost data.
//
// Public API:
//   ClaudeCostFetcher.loadTokenSnapshot(now:bypassScanGate:historyDays:) async throws(CancellationError) -> CostUsageTokenSnapshot?
//   ClaudeCostFetcher.refreshPricingCatalogIfNeeded(now:) async
//
// Responsibilities:
//  1. Drive the Claude scanner (CostUsageScanner.loadDailyReportCancellable).
//  2. Build a CostUsageTokenSnapshot from the daily report (most-recent-day selection).
//
// Pricing refresh is NOT owned here. Call refreshPricingCatalogIfNeeded before
// loadTokenSnapshot whenever fresh catalog data is wanted; the Phase 3 actor
// schedules this on its own cadence.
//
// Dropped vs legacy CostUsageFetcher:
//  - provider param (Claude only)
//  - bedrock / vertex paths
//  - Pi merge
//  - codex cached-snapshot path
//  - selectCurrentSession / selectMostRecentMonth (deleted types)
public struct ClaudeCostFetcher: Sendable {
    private let scannerOptions: CostUsageScanner.Options?

    public init(cacheRoot: URL? = nil) {
        self.scannerOptions = cacheRoot.map { CostUsageScanner.Options(cacheRoot: $0) }
    }

    init(scannerOptions: CostUsageScanner.Options) {
        self.scannerOptions = scannerOptions
    }

    /// Refreshes the models.dev pricing catalog if the cached copy is stale.
    ///
    /// Callers (the Phase 3 actor) schedule this on their own cadence BEFORE
    /// loadTokenSnapshot when they want fresh pricing. Offline/no-op safe:
    /// the pipeline is best-effort and never throws.
    public func refreshPricingCatalogIfNeeded(now: Date = Date()) async {
        let cacheRoot = self.scannerOptions?.cacheRoot
        await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot)
    }

    /// Internal overload used by tests to inject a transport without making ModelsDevClient public.
    func refreshPricingCatalogIfNeeded(now: Date = Date(), client: ModelsDevClient) async {
        let cacheRoot = self.scannerOptions?.cacheRoot
        await ModelsDevPricingPipeline.refreshIfNeeded(now: now, cacheRoot: cacheRoot, client: client)
    }

    /// Loads a token-usage snapshot for the rolling history window ending at `now`.
    ///
    /// - Parameters:
    ///   - bypassScanGate: When `true`, zeros `refreshMinIntervalSeconds` so the
    ///     scanner re-runs regardless of its TTL. Does NOT force a full cache reset
    ///     (that is `Options.forceRescan`).
    ///
    /// - Returns: `nil` when no usage data is found in the window.
    ///
    /// - Throws: `CancellationError` only. Non-cancellation failures (file IO,
    ///   cache decode, per-file parse errors) are swallowed internally and result
    ///   in nil/empty data — cost is optional eye-candy and must not surface errors
    ///   to the caller.
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

        // bypassScanGate → refreshMinIntervalSeconds = 0 (triggers a rescan on TTL;
        // does NOT force a nuclear cache reset — that is forceRescan).
        if bypassScanGate {
            options.refreshMinIntervalSeconds = 0
        }

        let checkCancellation: CostUsageScanner.CancellationCheck = {
            try Task.checkCancellation()
        }
        // Rethrow as CancellationError to stay within the typed-throws contract.
        do { try Task.checkCancellation() } catch { throw CancellationError() }

        let daily: CostUsageDailyReport
        do {
            daily = try CostUsageScanner.loadDailyReportCancellable(
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
        // Rethrow as CancellationError to stay within the typed-throws contract.
        do { try Task.checkCancellation() } catch { throw CancellationError() }

        guard !daily.data.isEmpty else { return nil }

        // Build the token snapshot (port of legacy CostUsageFetcher.tokenSnapshot lines ~266-300).
        return Self.tokenSnapshot(from: daily, now: now, historyDays: clampedHistoryDays)
    }

    /// Constructs a CostUsageTokenSnapshot from a daily report.
    /// Ported verbatim from legacy CostUsageFetcher.tokenSnapshot (~:266-300).
    static func tokenSnapshot(
        from daily: CostUsageDailyReport,
        now: Date,
        historyDays: Int = 30) -> CostUsageTokenSnapshot
    {
        // Pick the most recent day; break ties by cost/tokens to keep a stable "session" row.
        let currentDay = daily.data.max { lhs, rhs in
            let lDate = CostUsageDateParser.parse(lhs.date) ?? .distantPast
            let rDate = CostUsageDateParser.parse(rhs.date) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.date < rhs.date
        }
        // Prefer summary totals when present; fall back to summing daily entries.
        let totalFromSummary = daily.summary?.totalCostUSD
        let totalFromEntries = daily.data.compactMap(\.costUSD).reduce(0, +)
        let last30DaysCostUSD = totalFromSummary ?? (totalFromEntries > 0 ? totalFromEntries : nil)
        let totalTokensFromSummary = daily.summary?.totalTokens
        let totalTokensFromEntries = daily.data.compactMap(\.totalTokens).reduce(0, +)
        let last30DaysTokens = totalTokensFromSummary ?? (totalTokensFromEntries > 0 ? totalTokensFromEntries : nil)

        return CostUsageTokenSnapshot(
            sessionTokens: currentDay?.totalTokens,
            sessionCostUSD: currentDay?.costUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            historyDays: historyDays,
            daily: daily.data,
            updatedAt: now)
    }
}
