// QuotaWarnings.swift — quota crossing/transition state machine.
//
// Salvaged from legacy CodexBar:
//   - Sources/CodexBar/UsageStore.swift ~746-925 (handleSessionQuotaTransition /
//     handleQuotaWarningTransitions and their per-provider state dicts)
//   - Sources/CodexBar/SessionQuotaNotifications.swift (SessionQuotaNotificationLogic /
//     QuotaWarningNotificationLogic pure functions, minus notification copy)
//   - Sources/CodexBarCore/Config/CodexBarConfig.swift (QuotaWarningWindow, QuotaWarningThresholds)
//
// Rebuild changes vs legacy:
//   - De-keyed from `[UsageProvider: …]` / `[QuotaWarningStateKey: …]` dicts to scalars — SturtBar
//     monitors a single provider (Claude).
//   - Copilot secondary-window fallback dropped (Copilot-only behavior).
//   - Spend-limit snapshots: legacy mapped them to `primary == nil`; the rebuild maps them to a
//     primary window with `primaryWindowKind == .spendLimit`. Both machines must ignore that
//     pseudo-window, so `sessionRateWindow`/`warningRateWindow` treat it as nil (state clears).
//   - `accountDisplayName` dropped from crossing events: `ClaudeUsageSnapshot` carries no account
//     identity. Phase 3b can re-attach identity at notification time if it ever lands.
//   - The machine emits `QuotaCrossing` EVENTS instead of posting notifications; Phase 3b wires
//     `UsageStore.onQuotaThresholdCrossing` into the notifier.

import Foundation
import SturtBarCore

// MARK: - Types

/// Rate windows the warning machine tracks (legacy `QuotaWarningWindow`).
enum QuotaWindow: String, Codable, CaseIterable, Equatable {
    case session
    case weekly
}

/// A quota event the app surfaces to the user (Phase 3b: notifications).
enum QuotaCrossing: Equatable {
    /// Remaining quota dropped to/below a configured warning threshold.
    case warningThresholdCrossed(window: QuotaWindow, threshold: Int, currentRemaining: Double)
    /// The session window hit 0% remaining.
    case sessionDepleted
    /// The session window recovered from 0% remaining.
    case sessionRestored
}

// MARK: - Thresholds

/// Threshold sanitization (port of legacy `QuotaWarningThresholds`).
enum QuotaWarningThresholds {
    static let defaults = [50, 20]
    static let allowedRange = 0...99

    /// Clamps to 0...99, dedupes, sorts descending; empty input falls back to defaults.
    static func sanitized(_ raw: [Int]) -> [Int] {
        guard !raw.isEmpty else { return self.defaults }
        let unique = Set(raw.map(self.clamped))
        let sorted = unique.sorted(by: >)
        return sorted.isEmpty ? self.defaults : sorted
    }

    /// Sanitized thresholds that can actually fire (0 disables a slot, it never warns).
    static func active(_ raw: [Int]) -> [Int] {
        self.sanitized(raw).filter { $0 > 0 }
    }

    /// Resolves the settings-UI upper/lower pair into a threshold list (port of legacy
    /// `QuotaWarningThresholds.resolved`): both empty falls back to defaults; a missing lower
    /// becomes 0 (disabled slot) when the upper sits below the default lower.
    static func resolved(upper: Int?, lower: Int?) -> [Int] {
        guard upper != nil || lower != nil else { return self.defaults }
        let resolvedUpper = self.clamped(upper ?? self.defaults[0])
        let lowerDefault = resolvedUpper < self.defaults[1] ? 0 : self.defaults[1]
        let resolvedLower = self.clamped(lower ?? lowerDefault)
        return self.sanitized([resolvedUpper, resolvedLower])
    }

    static func clamped(_ value: Int) -> Int {
        min(max(value, self.allowedRange.lowerBound), self.allowedRange.upperBound)
    }
}

// MARK: - Pure transition logic

/// Session depleted/restored detection (port of legacy `SessionQuotaNotificationLogic`).
enum SessionQuotaLogic {
    enum Transition: Equatable {
        case none
        case depleted
        case restored
    }

    static let depletedThreshold: Double = 0.0001

    static func isDepleted(_ remaining: Double?) -> Bool {
        guard let remaining else { return false }
        return remaining <= self.depletedThreshold
    }

    static func transition(previousRemaining: Double?, currentRemaining: Double?) -> Transition {
        guard let currentRemaining else { return .none }
        guard let previousRemaining else { return .none }

        let wasDepleted = previousRemaining <= self.depletedThreshold
        let isDepleted = currentRemaining <= self.depletedThreshold

        if !wasDepleted, isDepleted { return .depleted }
        if wasDepleted, !isDepleted { return .restored }
        return .none
    }
}

/// Threshold crossing detection + de-dup bookkeeping (port of legacy `QuotaWarningNotificationLogic`,
/// minus notification copy). The fired-set semantics prevent notification spam:
///   - a threshold fires at most once until remaining recovers ABOVE it (`thresholdsToClear`),
///   - crossing several thresholds in one refresh fires only the most severe one, marking the
///     higher ones fired so they don't fire later without a recovery (`firedThresholdsAfterWarning`).
enum QuotaCrossingLogic {
    /// The threshold to warn for, if any: at/below current remaining, not already fired, and —
    /// when a previous sample exists — actually crossed downward this refresh. First sample
    /// (previousRemaining == nil, e.g. startup already below threshold) warns at the most severe
    /// eligible threshold.
    static func crossedThreshold(
        previousRemaining: Double?,
        currentRemaining: Double,
        thresholds: [Int],
        alreadyFired: Set<Int>) -> Int?
    {
        let sanitized = QuotaWarningThresholds.active(thresholds)
        let eligible = sanitized.filter { threshold in
            currentRemaining <= Double(threshold) && !alreadyFired.contains(threshold)
        }
        guard !eligible.isEmpty else { return nil }

        if let previousRemaining {
            let crossed = eligible.filter { previousRemaining > Double($0) }
            return crossed.min()
        }

        return eligible.min()
    }

    /// After warning for `threshold`, every active threshold ≥ it counts as fired (de-dup).
    static func firedThresholdsAfterWarning(threshold: Int, thresholds: [Int]) -> Set<Int> {
        Set(QuotaWarningThresholds.active(thresholds).filter { $0 >= threshold })
    }

    /// Recovery/reset detection: fired thresholds strictly below current remaining re-arm.
    static func thresholdsToClear(currentRemaining: Double, alreadyFired: Set<Int>) -> Set<Int> {
        Set(alreadyFired.filter { currentRemaining > Double($0) })
    }
}

// MARK: - QuotaTransitionMachine

/// Stateful wrapper around the pure logic above — the de-keyed port of the legacy UsageStore's
/// `lastKnownSessionRemaining` / `quotaWarningState` machinery. Owned by `UsageStore`; fed every
/// successful snapshot; returns crossing events for the store to publish.
struct QuotaTransitionMachine {
    struct WindowState: Equatable {
        var lastRemaining: Double?
        var firedThresholds: Set<Int> = []
    }

    /// Settings inputs resolved by the caller per `process` call (live settings reads).
    struct Configuration {
        var sessionQuotaNotificationsEnabled: Bool
        var quotaWarningNotificationsEnabled: Bool
        var sessionWarningEnabled: Bool
        var weeklyWarningEnabled: Bool
        var sessionThresholds: [Int]
        var weeklyThresholds: [Int]

        /// Per-window warning inputs (enabled flag + thresholds) for the warning machine.
        func warningSettings(for window: QuotaWindow) -> (enabled: Bool, thresholds: [Int]) {
            switch window {
            case .session: (self.sessionWarningEnabled, self.sessionThresholds)
            case .weekly: (self.weeklyWarningEnabled, self.weeklyThresholds)
            }
        }
    }

    /// Baseline for depleted/restored detection (legacy `lastKnownSessionRemaining[provider]`).
    private(set) var sessionDepletionLastRemaining: Double?
    /// Warning machine state (legacy `quotaWarningState[provider, window]`, de-keyed).
    private(set) var sessionWarning = WindowState()
    private(set) var weeklyWarning = WindowState()

    /// Processes one snapshot through both machines and returns the crossings to surface.
    mutating func process(snapshot: ClaudeUsageSnapshot, configuration: Configuration) -> [QuotaCrossing] {
        var crossings: [QuotaCrossing] = []
        self.processSessionDepletion(snapshot: snapshot, configuration: configuration, into: &crossings)
        self.processWarnings(snapshot: snapshot, configuration: configuration, into: &crossings)
        return crossings
    }

    // MARK: Session depleted/restored (legacy handleSessionQuotaTransition)

    /// Session-quota transitions are tied to a genuine session-scale primary window. Weekly-only
    /// primaries (7-day fallback) and spend-limit pseudo-windows never emit depletion events.
    private static func sessionRateWindow(of snapshot: ClaudeUsageSnapshot) -> RateWindow? {
        guard snapshot.primaryWindowKind == .usage else { return nil }
        guard self.isSessionWindow(snapshot.primary) else { return nil }
        return snapshot.primary
    }

    /// Legacy `isSessionWindow`: unknown duration counts as session; ≤ 6h counts as session.
    private static func isSessionWindow(_ window: RateWindow) -> Bool {
        guard let minutes = window.windowMinutes else { return true }
        return minutes <= 6 * 60
    }

    private mutating func processSessionDepletion(
        snapshot: ClaudeUsageSnapshot,
        configuration: Configuration,
        into crossings: inout [QuotaCrossing])
    {
        guard let window = Self.sessionRateWindow(of: snapshot) else {
            self.sessionDepletionLastRemaining = nil
            return
        }
        let currentRemaining = window.remainingPercent
        let previousRemaining = self.sessionDepletionLastRemaining
        // Legacy defer: the baseline updates even when notifications are disabled, so toggling
        // them on later doesn't replay a stale transition.
        defer { self.sessionDepletionLastRemaining = currentRemaining }

        guard configuration.sessionQuotaNotificationsEnabled else { return }

        guard previousRemaining != nil else {
            // Startup case: first sample already depleted warns once.
            if SessionQuotaLogic.isDepleted(currentRemaining) {
                crossings.append(.sessionDepleted)
            }
            return
        }

        switch SessionQuotaLogic.transition(
            previousRemaining: previousRemaining,
            currentRemaining: currentRemaining)
        {
        case .none:
            break
        case .depleted:
            crossings.append(.sessionDepleted)
        case .restored:
            crossings.append(.sessionRestored)
        }
    }

    // MARK: Threshold warnings (legacy handleQuotaWarningTransitions)

    private mutating func processWarnings(
        snapshot: ClaudeUsageSnapshot,
        configuration: Configuration,
        into crossings: inout [QuotaCrossing])
    {
        // Legacy semantics: master switch off freezes the warning machine (state neither
        // advances nor clears), unlike the per-window toggles below which clear state.
        guard configuration.quotaWarningNotificationsEnabled else { return }

        let sessionRateWindow = snapshot.primaryWindowKind == .usage ? snapshot.primary : nil
        self.processWarningWindow(
            window: .session,
            rateWindow: sessionRateWindow,
            configuration: configuration,
            state: &self.sessionWarning,
            into: &crossings)
        self.processWarningWindow(
            window: .weekly,
            rateWindow: snapshot.secondary,
            configuration: configuration,
            state: &self.weeklyWarning,
            into: &crossings)
    }

    private func processWarningWindow(
        window: QuotaWindow,
        rateWindow: RateWindow?,
        configuration: Configuration,
        state: inout WindowState,
        into crossings: inout [QuotaCrossing])
    {
        let settings = configuration.warningSettings(for: window)
        guard settings.enabled else {
            state = WindowState()
            return
        }
        guard let rateWindow else {
            state = WindowState()
            return
        }

        let currentRemaining = rateWindow.remainingPercent
        let cleared = QuotaCrossingLogic.thresholdsToClear(
            currentRemaining: currentRemaining,
            alreadyFired: state.firedThresholds)
        state.firedThresholds.subtract(cleared)

        if let threshold = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: state.lastRemaining,
            currentRemaining: currentRemaining,
            thresholds: settings.thresholds,
            alreadyFired: state.firedThresholds)
        {
            state.firedThresholds.formUnion(QuotaCrossingLogic.firedThresholdsAfterWarning(
                threshold: threshold,
                thresholds: settings.thresholds))
            crossings.append(.warningThresholdCrossed(
                window: window,
                threshold: threshold,
                currentRemaining: currentRemaining))
        }

        state.lastRemaining = currentRemaining
    }
}
