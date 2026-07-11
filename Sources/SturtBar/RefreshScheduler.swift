// RefreshScheduler.swift — interval refresh loop + wake-from-sleep refreshes.
//
// A plain Task.sleep loop on the ContinuousClock: when the lid is closed past a tick boundary,
// the elapsed sleep completes on wake and fires a refresh (the store's min-gap policy decides
// whether it actually fetches). A separate NSWorkspace.didWakeNotification observer fires
// `.wake` for the same reason — both paths are cheap no-ops when data is fresh.
//
// `start(interval: nil)` = manual cadence: no loop, wake observer stays active.

import AppKit
import Foundation
import SturtBarCore

@MainActor
final class RefreshScheduler {
    private let refresh: @MainActor (RefreshTrigger) async -> Void
    private var loopTask: Task<Void, Never>?
    private nonisolated(unsafe) var wakeObserver: (any NSObjectProtocol)?

    // nonisolated: also used from the @Sendable wake-notification closure.
    private nonisolated static let log = SturtBarLog.logger("refresh-scheduler")

    /// Production entry: drives the store. The store is captured weakly — the scheduler must
    /// never keep the app state alive.
    convenience init(store: UsageStore) {
        self.init(refresh: { [weak store] trigger in
            await store?.refresh(trigger: trigger)
        })
        self.registerWakeObserver()
    }

    /// Test seam: injects the refresh sink; no wake observer is registered.
    init(refresh: @escaping @MainActor (RefreshTrigger) async -> Void) {
        self.refresh = refresh
    }

    /// (Re)starts the interval loop. nil interval = manual cadence (no loop).
    func start(interval: Duration?) {
        self.stop()
        guard let interval else {
            Self.log.info("Refresh loop not started (manual cadence)")
            return
        }
        Self.log.info("Refresh loop started", metadata: ["interval": "\(interval)"])
        let refresh = self.refresh
        self.loopTask = Task {
            var skippedPreviousTick = false
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        until: .now + interval,
                        tolerance: interval / 10,
                        clock: .continuous)
                } catch {
                    return // cancelled
                }
                let decision = Self.tickDecision(
                    isPowerConstrained: Self.isCurrentlyPowerConstrained(),
                    skippedPreviousTick: skippedPreviousTick)
                skippedPreviousTick = decision.skipped
                guard decision.refresh else {
                    Self.log.debug("Interval tick skipped (Low Power Mode or thermal pressure)")
                    continue
                }
                await refresh(.interval)
            }
        }
    }

    // MARK: - Power-aware cadence

    /// Skips every other tick under Low Power Mode or thermal pressure, doubling the effective interval.
    nonisolated static func tickDecision(
        isPowerConstrained: Bool,
        skippedPreviousTick: Bool) -> (refresh: Bool, skipped: Bool)
    {
        if isPowerConstrained, !skippedPreviousTick {
            return (refresh: false, skipped: true)
        }
        return (refresh: true, skipped: false)
    }

    nonisolated static func isPowerConstrained(
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> Bool
    {
        if lowPowerModeEnabled { return true }
        switch thermalState {
        case .serious, .critical: return true
        case .nominal, .fair: return false
        @unknown default: return false
        }
    }

    private nonisolated static func isCurrentlyPowerConstrained() -> Bool {
        let processInfo = ProcessInfo.processInfo
        return self.isPowerConstrained(
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState)
    }

    func stop() {
        self.loopTask?.cancel()
        self.loopTask = nil
    }

    private func registerWakeObserver() {
        let refresh = self.refresh
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main)
        { _ in
            Self.log.debug("System woke; triggering refresh")
            Task { @MainActor in
                await refresh(.wake)
            }
        }
    }

    deinit {
        // Task.cancel() is Sendable/nonisolated; NotificationCenter removal is thread-safe.
        self.loopTask?.cancel()
        if let wakeObserver = self.wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}
