// UsageStoreResetBoundaryRefreshTests.swift: candidate selection and store scheduling.

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

@MainActor
struct UsageStoreResetBoundaryRefreshTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_000_000_000)

    private nonisolated static func snapshot(
        primaryResetIn: TimeInterval?,
        secondaryResetIn: TimeInterval? = nil,
        updatedAt: Date = now.addingTimeInterval(-60)) -> ProviderUsageSnapshot
    {
        ProviderUsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 5 * 60,
                resetsAt: primaryResetIn.map { Self.now.addingTimeInterval($0) },
                resetDescription: nil),
            secondary: secondaryResetIn.map {
                RateWindow(
                    usedPercent: 50,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: Self.now.addingTimeInterval($0),
                    resetDescription: nil)
            },
            opus: nil,
            updatedAt: updatedAt,
            loginMethod: nil)
    }

    private static func candidate(
        snapshots: [ProviderUsageSnapshot?],
        intervalSeconds: TimeInterval?,
        attempted: Set<Date> = [],
        timing: ResetBoundaryTiming = ResetBoundaryTiming()) -> UsageStore.ResetBoundaryCandidate?
    {
        UsageStore.nextResetBoundaryCandidate(
            snapshots: snapshots,
            intervalSeconds: intervalSeconds,
            attempted: attempted,
            timing: timing,
            now: self.now)
    }

    @Test
    func `picks the earliest boundary within the interval horizon`() throws {
        let result = try #require(Self.candidate(
            snapshots: [Self.snapshot(primaryResetIn: 120, secondaryResetIn: 200)],
            intervalSeconds: 300))
        // Earliest reset (120s) + grace (60s) = 180s from now.
        #expect(result.boundary == Self.now.addingTimeInterval(180))
        #expect(result.refreshAt == result.boundary)
    }

    @Test
    func `skips boundaries the next tick covers anyway`() {
        // Reset at 400s + 60s grace = 460s, beyond a 300s interval: the tick's job.
        #expect(Self.candidate(
            snapshots: [Self.snapshot(primaryResetIn: 400)],
            intervalSeconds: 300) == nil)
    }

    @Test
    func `manual cadence schedules any upcoming boundary`() throws {
        let result = try #require(Self.candidate(
            snapshots: [Self.snapshot(primaryResetIn: 7200)],
            intervalSeconds: nil))
        #expect(result.boundary == Self.now.addingTimeInterval(7260))
    }

    @Test
    func `a stale past reset fires after the minimum delay and dedups`() throws {
        // The boundary itself has already passed, so it fires soon (minimum delay), once.
        let stale = Self.snapshot(primaryResetIn: -600, updatedAt: Self.now.addingTimeInterval(-900))
        let result = try #require(Self.candidate(snapshots: [stale], intervalSeconds: 300))
        #expect(result.refreshAt == Self.now.addingTimeInterval(5))

        #expect(Self.candidate(
            snapshots: [stale],
            intervalSeconds: 300,
            attempted: [result.boundary]) == nil)
    }

    @Test
    func `data refreshed past the boundary produces no candidate`() {
        // updatedAt is after boundary+grace: the reading already reflects the reset.
        let fresh = Self.snapshot(primaryResetIn: -600, updatedAt: Self.now)
        #expect(Self.candidate(snapshots: [fresh], intervalSeconds: 300) == nil)
    }

    @Test
    func `disabled lanes contribute nothing`() {
        #expect(Self.candidate(snapshots: [nil, nil], intervalSeconds: 300) == nil)
    }

    @Test
    func `store schedules and fires the boundary refresh`() async throws {
        let clock = TestClock(start: Self.now)
        // Snapshot data predates the passed boundary, so the boundary refresh has data to gain.
        let stale = Self.snapshot(primaryResetIn: -600, updatedAt: Self.now.addingTimeInterval(-900))
        let script = FetchScript([.success(stale)])
        let ts = makeTestStore(suiteName: "sturtbar-tests-reset-boundary", clock: clock) { _, _ in
            try script.next()
        }
        ts.store.resetBoundaryTiming = ResetBoundaryTiming(graceSeconds: 0.01, minimumDelaySeconds: 0.01)

        await ts.store.refresh(trigger: .manual)
        let fetchesBefore = await ts.recorder.fetchCount
        #expect(ts.store.scheduledResetBoundaryAt != nil)

        // Let the one-shot fire; the gate needs the last success to be >=30s old.
        clock.advance(by: 60)
        try await Task.sleep(for: .seconds(0.4))

        #expect(await ts.recorder.fetchCount == fetchesBefore + 1)
        // The fired boundary is recorded, so re-planning does not loop on the same instant.
        #expect(ts.store.attemptedResetBoundaryRefreshes.count == 1)
    }

    @Test
    func `disabling the provider cancels the scheduled boundary refresh`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-reset-boundary-cancel") { _, _ in
            Self.snapshot(primaryResetIn: -600, updatedAt: Self.now.addingTimeInterval(-900))
        }
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.scheduledResetBoundaryAt != nil)

        ts.settings.claudeProviderEnabled = false
        ts.store.providerEnabledDidChange(.claude, enabled: false)
        #expect(ts.store.scheduledResetBoundaryAt == nil)
    }
}
