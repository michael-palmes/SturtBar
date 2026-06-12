// StateTestSupport.swift — shared helpers for the Phase 3a app-state tests.

import Foundation
import Synchronization
@testable import SturtBar
@testable import SturtBarCore

// MARK: - TestLatch

/// One-shot, multi-waiter latch for deterministically holding async operations open.
actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

// MARK: - TestClock

/// Injectable wall clock for min-gap / backoff / staleness tests.
final class TestClock: Sendable {
    private let mutex: Mutex<Date>

    init(start: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        self.mutex = Mutex(start)
    }

    var now: Date {
        self.mutex.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        self.mutex.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

// MARK: - Fetch recording

struct RecordedFetch: Equatable {
    let interaction: Interaction
    let phase: RefreshPhase
}

/// Records fetch/scan invocations from @Sendable closures.
actor CallRecorder {
    private(set) var fetches: [RecordedFetch] = []
    private(set) var scans: [(bypassGate: Bool, historyDays: Int)] = []
    private(set) var codexFetchCount = 0

    func recordFetch(interaction: Interaction, phase: RefreshPhase) {
        self.fetches.append(RecordedFetch(interaction: interaction, phase: phase))
    }

    func recordScan(bypassGate: Bool, historyDays: Int) {
        self.scans.append((bypassGate, historyDays))
    }

    func recordCodexFetch() {
        self.codexFetchCount += 1
    }

    var fetchCount: Int {
        self.fetches.count
    }

    var scanCount: Int {
        self.scans.count
    }
}

// MARK: - Snapshot factories

func makeUsageSnapshot(
    primaryUsedPercent: Double = 25,
    primaryWindowMinutes: Int? = 5 * 60,
    primaryWindowKind: ProviderUsageSnapshot.PrimaryWindowKind = .usage,
    secondaryUsedPercent: Double? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000_000_000)) -> ProviderUsageSnapshot
{
    ProviderUsageSnapshot(
        primary: RateWindow(
            usedPercent: primaryUsedPercent,
            windowMinutes: primaryWindowMinutes,
            resetsAt: nil,
            resetDescription: nil),
        primaryWindowKind: primaryWindowKind,
        secondary: secondaryUsedPercent.map {
            RateWindow(usedPercent: $0, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil)
        },
        opus: nil,
        updatedAt: updatedAt,
        loginMethod: "Claude Pro")
}

/// Codex-shaped snapshot: 5h primary + weekly secondary, plan badge, nothing Claude-specific.
func makeCodexSnapshot(
    primaryUsedPercent: Double = 18,
    secondaryUsedPercent: Double? = 43,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000_000_000)) -> ProviderUsageSnapshot
{
    ProviderUsageSnapshot(
        primary: RateWindow(
            usedPercent: primaryUsedPercent,
            windowMinutes: 5 * 60,
            resetsAt: nil,
            resetDescription: nil),
        secondary: secondaryUsedPercent.map {
            RateWindow(usedPercent: $0, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil)
        },
        opus: nil,
        updatedAt: updatedAt,
        loginMethod: "Pro")
}

func makeCostSnapshot(
    sessionCostUSD: Double? = 1.25,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000_000_000)) -> CostUsageTokenSnapshot
{
    CostUsageTokenSnapshot(
        sessionTokens: 1000,
        sessionCostUSD: sessionCostUSD,
        last30DaysTokens: 50000,
        last30DaysCostUSD: 42.5,
        daily: [
            CostUsageDailyReport.Entry(
                date: "2026-06-10",
                inputTokens: 600,
                outputTokens: 400,
                totalTokens: 1000,
                costUSD: sessionCostUSD,
                modelsUsed: ["claude-fable-5"],
                modelBreakdowns: nil),
        ],
        updatedAt: updatedAt)
}

// MARK: - Store factory

@MainActor
func makeTestSettings(suiteName: String) -> SettingsStore {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return SettingsStore(userDefaults: defaults)
}

/// No-op scanner: returns `.scanned(nil)` instantly and records nothing.
func makeIdleScanner() -> CostScanner {
    CostScanner(scanOperation: { _, _, _ in nil })
}

@MainActor
struct TestStore {
    let store: UsageStore
    let settings: SettingsStore
    let clock: TestClock
    let recorder: CallRecorder
}

/// Builds a UsageStore with a scripted fetch result, an injectable clock, and no persistence.
/// The codex lane defaults to "not signed in" — irrelevant for Claude-only tests because the
/// provider is disabled by default and the store must never call a disabled provider's client.
@MainActor
func makeTestStore(
    suiteName: String,
    clock: TestClock = TestClock(),
    scanner: CostScanner? = nil,
    persistence: StatePersistence? = nil,
    blockStatus: @escaping @Sendable () -> ClaudeOAuthRefreshFailureGate.BlockStatus? = { nil },
    codexFetch: @escaping CodexUsageClient.FetchOperation = { throw CodexUsageError.credentialsMissing },
    fetch: @escaping ClaudeUsageClient.FetchOperation) -> TestStore
{
    let settings = makeTestSettings(suiteName: suiteName)
    let recorder = CallRecorder()
    let client = ClaudeUsageClient(fetchOperation: { interaction, phase in
        await recorder.recordFetch(interaction: interaction, phase: phase)
        return try await fetch(interaction, phase)
    })
    let codexClient = CodexUsageClient(fetchOperation: {
        await recorder.recordCodexFetch()
        return try await codexFetch()
    })
    let store = UsageStore(
        settings: settings,
        client: client,
        codexClient: codexClient,
        scanner: scanner ?? makeIdleScanner(),
        persistence: persistence,
        now: { clock.now },
        blockStatus: blockStatus)
    return TestStore(store: store, settings: settings, clock: clock, recorder: recorder)
}
