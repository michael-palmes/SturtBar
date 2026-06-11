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
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        until: .now + interval,
                        tolerance: interval / 10,
                        clock: .continuous)
                } catch {
                    return // cancelled
                }
                await refresh(.interval)
            }
        }
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
