// RefreshSchedulerTests.swift — interval loop fires, stop cancels, manual cadence idles.

import Foundation
import Testing
@testable import SturtBar

@MainActor
final class TriggerCounter {
    private(set) var triggers: [RefreshTrigger] = []

    func record(_ trigger: RefreshTrigger) {
        self.triggers.append(trigger)
    }

    var count: Int {
        self.triggers.count
    }
}

@MainActor
struct RefreshSchedulerTests {
    @Test
    func `interval loop fires repeatedly`() async throws {
        let counter = TriggerCounter()
        let scheduler = RefreshScheduler(refresh: { counter.record($0) })
        scheduler.start(interval: .milliseconds(50))
        defer { scheduler.stop() }

        // Wait (bounded) until at least two ticks fired.
        for _ in 0..<200 {
            if counter.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(counter.count >= 2)
        #expect(counter.triggers.allSatisfy { $0 == .interval })
    }

    @Test
    func `stop cancels the loop`() async throws {
        let counter = TriggerCounter()
        let scheduler = RefreshScheduler(refresh: { counter.record($0) })
        scheduler.start(interval: .milliseconds(30))

        for _ in 0..<200 {
            if counter.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        scheduler.stop()
        let frozen = counter.count
        try await Task.sleep(for: .milliseconds(150))
        // At most one tick can already have passed its sleep when stop lands.
        #expect(counter.count <= frozen + 1)
    }

    @Test
    func `manual cadence starts no loop`() async throws {
        let counter = TriggerCounter()
        let scheduler = RefreshScheduler(refresh: { counter.record($0) })
        scheduler.start(interval: nil)

        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.triggers.isEmpty)
    }

    @Test
    func `restart replaces the previous loop`() async throws {
        let counter = TriggerCounter()
        let scheduler = RefreshScheduler(refresh: { counter.record($0) })
        scheduler.start(interval: .milliseconds(30))
        scheduler.start(interval: nil) // restart with manual cadence stops the first loop

        try await Task.sleep(for: .milliseconds(150))
        #expect(counter.count <= 1)
    }

    // MARK: - Power-aware cadence

    @Test
    func `power constrained ticks alternate skip and refresh`() {
        // Unconstrained: every tick refreshes.
        #expect(RefreshScheduler.tickDecision(
            isPowerConstrained: false, skippedPreviousTick: false) == (true, false))
        // Constrained: skip one tick...
        #expect(RefreshScheduler.tickDecision(
            isPowerConstrained: true, skippedPreviousTick: false) == (false, true))
        // ...but never two in a row, so the effective interval doubles rather than stalling.
        #expect(RefreshScheduler.tickDecision(
            isPowerConstrained: true, skippedPreviousTick: true) == (true, false))
        // Constraint lifted right after a skip: back to normal.
        #expect(RefreshScheduler.tickDecision(
            isPowerConstrained: false, skippedPreviousTick: true) == (true, false))
    }

    @Test
    func `power constraint maps low power mode and thermal pressure`() {
        #expect(RefreshScheduler.isPowerConstrained(lowPowerModeEnabled: true, thermalState: .nominal))
        #expect(RefreshScheduler.isPowerConstrained(lowPowerModeEnabled: false, thermalState: .serious))
        #expect(RefreshScheduler.isPowerConstrained(lowPowerModeEnabled: false, thermalState: .critical))
        #expect(!RefreshScheduler.isPowerConstrained(lowPowerModeEnabled: false, thermalState: .nominal))
        #expect(!RefreshScheduler.isPowerConstrained(lowPowerModeEnabled: false, thermalState: .fair))
    }
}
