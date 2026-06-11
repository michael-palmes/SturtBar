// CostScanner.swift — on-demand cost scan actor.
//
// Wraps ClaudeCostFetcher. Cost scans are ON-DEMAND only (menu open / manual refresh /
// cost-setting change) — never on the interval tick. A cold daily rescan can take 10s+ on heavy
// histories, so the store publishes progress state (`UsageStore.costScanState`) and never blocks
// on this actor from the UI path.
//
// Gating:
//   - 60s min-gap between scans, measured from the last scan START. "Refresh now" (manual)
//     bypasses the gap via `bypassGate`, which also bypasses the scanner-level TTL
//     (`ClaudeCostFetcher.loadTokenSnapshot(bypassScanGate: true)`). Neither path ever forces a
//     full cache rescan (`Options.forceRescan` stays off).
//   - Concurrent requests join the in-flight scan (single-flight); a joining bypass request does
//     not restart the scan — the in-flight result is at most seconds old.
//   - Pricing: `refreshPricingCatalogIfNeeded` runs before every gate-passing scan. It is the ONLY
//     network access in the cost subsystem, is best-effort/non-throwing, and self-limits with its
//     own TTL, so per-scan invocation is the actor's "own cadence".
//
// Priority: callers (UsageStore) invoke this from `Task(priority: .utility)`; the actor inherits
// that priority for the scan work.

import Foundation
import SturtBarCore

enum CostScanResult: Sendable, Equatable {
    /// A scan ran; nil snapshot means "no usage data in the window".
    case scanned(CostUsageTokenSnapshot?)
    /// The 60s min-gap suppressed the scan; callers keep their previous snapshot.
    case skipped
    /// The scan (or the task awaiting it) was cancelled — app shutdown; discard quietly.
    case cancelled
}

actor CostScanner {
    typealias ScanOperation = @Sendable (
        _ now: Date,
        _ bypassScanGate: Bool,
        _ historyDays: Int) async throws(CancellationError) -> CostUsageTokenSnapshot?

    private let scanOperation: ScanOperation
    private let refreshPricing: @Sendable (_ now: Date) async -> Void
    private let minimumGap: TimeInterval
    private var lastScanStartedAt: Date?
    private var inFlight: Task<CostScanResult, Never>?

    private static let log = SturtBarLog.logger("cost-scanner")
    /// Default 60s minimum gap between scans (measured from scan START, not completion).
    private static let defaultMinimumGapSeconds: TimeInterval = 60

    /// Production entry: wraps a `ClaudeCostFetcher`.
    init(fetcher: ClaudeCostFetcher = ClaudeCostFetcher(), minimumGap: TimeInterval = defaultMinimumGapSeconds) {
        self.scanOperation = { now, bypassScanGate, historyDays throws(CancellationError) in
            try await fetcher.loadTokenSnapshot(
                now: now,
                bypassScanGate: bypassScanGate,
                historyDays: historyDays)
        }
        self.refreshPricing = { now in
            await fetcher.refreshPricingCatalogIfNeeded(now: now)
        }
        self.minimumGap = minimumGap
    }

    /// Test seam: injects the scan implementation; pricing refresh becomes a no-op unless provided.
    init(
        minimumGap: TimeInterval = defaultMinimumGapSeconds,
        refreshPricing: @escaping @Sendable (_ now: Date) async -> Void = { _ in },
        scanOperation: @escaping ScanOperation)
    {
        self.scanOperation = scanOperation
        self.refreshPricing = refreshPricing
        self.minimumGap = minimumGap
    }

    /// Runs (or joins) a cost scan.
    /// - Parameters:
    ///   - bypassGate: bypasses the 60s min-gap AND the scanner TTL (manual "refresh now").
    ///   - historyDays: rolling window size (settings.costUsageHistoryDays).
    ///   - now: injected clock for tests.
    func scan(bypassGate: Bool, historyDays: Int, now: Date = Date()) async -> CostScanResult {
        if let inFlight = self.inFlight {
            return await inFlight.value
        }

        if !bypassGate,
           let last = self.lastScanStartedAt,
           now.timeIntervalSince(last) < self.minimumGap
        {
            return .skipped
        }

        self.lastScanStartedAt = now
        let operation = self.scanOperation
        let refreshPricing = self.refreshPricing
        // Same self-clearing pattern as ClaudeUsageClient: the slot empties before the result is
        // observable, so joiners can never re-join a completed scan.
        let task = Task {
            defer { self.inFlight = nil }
            let signpostID = Signposts.scan.makeSignpostID()
            let signpostState = Signposts.scan.beginInterval("scan", id: signpostID)
            defer { Signposts.scan.endInterval("scan", signpostState) }

            await refreshPricing(now)
            do throws(CancellationError) {
                let snapshot = try await operation(now, bypassGate, historyDays)
                return CostScanResult.scanned(snapshot)
            } catch {
                Self.log.debug("Cost scan cancelled")
                return CostScanResult.cancelled
            }
        }
        self.inFlight = task
        return await task.value
    }

    /// Cancels the in-flight scan, if any (app shutdown). The scan surfaces as `.cancelled` to
    /// joiners. The single-flight task is unstructured (so joiners share it without one joiner's
    /// cancellation killing it), which is why shutdown cancellation is an explicit call instead of
    /// structured propagation.
    func cancelInFlight() {
        self.inFlight?.cancel()
    }
}
