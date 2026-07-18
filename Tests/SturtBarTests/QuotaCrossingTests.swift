// QuotaCrossingTests.swift — salvaged quota state-machine coverage.
//
// Ported from legacy CodexBarTests (state-machine-relevant cases only):
//   - QuotaWarningNotificationLogicTests → QuotaCrossingLogicTests (crossing/fired/clear logic;
//     the notification-copy/localization tests stay with Phase 3b's notifier)
//   - SessionQuotaNotificationLogicTests → SessionQuotaLogicTests (transitions; copy tests → 3b)
//   - UsageStoreSessionQuotaTransitionTests → QuotaTransitionMachineTests, de-keyed to the
//     single-provider machine (provider-override / hidePersonalInfo / sound tests → 3b or dropped
//     with the config file)

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

// MARK: - Pure logic (legacy QuotaWarningNotificationLogicTests)

struct QuotaCrossingLogicTests {
    @Test
    func `does nothing without crossing`() {
        let crossed = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: 60,
            currentRemaining: 55,
            thresholds: [50, 20],
            alreadyFired: [])
        #expect(crossed == nil)
    }

    @Test
    func `detects downward crossing`() {
        let crossed = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: 55,
            currentRemaining: 45,
            thresholds: [50, 20],
            alreadyFired: [])
        #expect(crossed == 50)
    }

    @Test
    func `skips already fired thresholds`() {
        let crossed = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: 55,
            currentRemaining: 45,
            thresholds: [50, 20],
            alreadyFired: [50])
        #expect(crossed == nil)
    }

    @Test
    func `chooses most severe threshold when crossing several at once`() {
        let crossed = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: 80,
            currentRemaining: 10,
            thresholds: [50, 20],
            alreadyFired: [])
        #expect(crossed == 20)
    }

    @Test
    func `startup below threshold warns once at most severe threshold`() {
        let crossed = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: nil,
            currentRemaining: 10,
            thresholds: [50, 20],
            alreadyFired: [])
        #expect(crossed == 20)
    }

    @Test
    func `warning marks threshold and higher thresholds fired`() {
        let fired = QuotaCrossingLogic.firedThresholdsAfterWarning(threshold: 20, thresholds: [50, 20])
        #expect(fired == [50, 20])
    }

    @Test
    func `recovery clears only thresholds below current remaining`() {
        let cleared = QuotaCrossingLogic.thresholdsToClear(currentRemaining: 30, alreadyFired: [50, 20])
        #expect(cleared == [20])
    }

    @Test
    func `zero threshold does not warn`() {
        let crossed = QuotaCrossingLogic.crossedThreshold(
            previousRemaining: 10,
            currentRemaining: 0,
            thresholds: [10, 0],
            alreadyFired: [10])
        #expect(crossed == nil)
        #expect(QuotaCrossingLogic.firedThresholdsAfterWarning(threshold: 10, thresholds: [10, 0]) == [10])
    }

    @Test
    func `threshold sanitization clamps dedupes and sorts`() {
        #expect(QuotaWarningThresholds.sanitized([]) == [50, 20])
        #expect(QuotaWarningThresholds.sanitized([120, -1, 20, 20, 50]) == [99, 50, 20, 0])
        #expect(QuotaWarningThresholds.active([50, 20, 0]) == [50, 20])
    }
}

// MARK: - Pure logic (legacy SessionQuotaNotificationLogicTests)

struct SessionQuotaLogicTests {
    @Test
    func `does nothing without previous value`() {
        #expect(SessionQuotaLogic.transition(previousRemaining: nil, currentRemaining: 0) == .none)
    }

    @Test
    func `detects depleted transition`() {
        #expect(SessionQuotaLogic.transition(previousRemaining: 12, currentRemaining: 0) == .depleted)
    }

    @Test
    func `detects restored transition`() {
        #expect(SessionQuotaLogic.transition(previousRemaining: 0, currentRemaining: 5) == .restored)
    }

    @Test
    func `ignores non transitions`() {
        #expect(SessionQuotaLogic.transition(previousRemaining: 0, currentRemaining: 0) == .none)
        #expect(SessionQuotaLogic.transition(previousRemaining: 10, currentRemaining: 10) == .none)
        #expect(SessionQuotaLogic.transition(previousRemaining: 10, currentRemaining: 9) == .none)
    }

    @Test
    func `treats tiny positive remaining as depleted`() {
        #expect(SessionQuotaLogic.transition(previousRemaining: 0, currentRemaining: 0.00001) == .none)
    }
}

// MARK: - Machine (legacy UsageStoreSessionQuotaTransitionTests, de-keyed)

struct QuotaTransitionMachineTests {
    private func makeConfiguration(
        sessionNotifications: Bool = true,
        warningNotifications: Bool = true,
        sessionEnabled: Bool = true,
        weeklyEnabled: Bool = true,
        thresholds: [Int] = [50, 20]) -> QuotaTransitionMachine.Configuration
    {
        QuotaTransitionMachine.Configuration(
            sessionQuotaNotificationsEnabled: sessionNotifications,
            quotaWarningNotificationsEnabled: warningNotifications,
            sessionWarningEnabled: sessionEnabled,
            weeklyWarningEnabled: weeklyEnabled,
            sessionThresholds: thresholds,
            weeklyThresholds: thresholds)
    }

    @Test
    func `five hour primary emits depleted then restored`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(warningNotifications: false)

        var events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 20), configuration: config)
        #expect(events.isEmpty)
        events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 100), configuration: config)
        #expect(events == [.sessionDepleted(resetsAt: nil)])
        events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 30), configuration: config)
        #expect(events == [.sessionRestored])
    }

    @Test
    func `startup depleted emits once`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(warningNotifications: false)

        var events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 100), configuration: config)
        #expect(events == [.sessionDepleted(resetsAt: nil)])
        events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 100), configuration: config)
        #expect(events.isEmpty)
    }

    @Test
    func `weekly primary fallback does not emit session depletion`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(warningNotifications: false)
        let weekly = 7 * 24 * 60

        _ = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 20, primaryWindowMinutes: weekly),
            configuration: config)
        let events = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 100, primaryWindowMinutes: weekly),
            configuration: config)
        #expect(events.isEmpty)
    }

    @Test
    func `spend limit snapshot emits neither depletion nor warnings`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration()

        // Baseline with a real session window, then a spend-limit snapshot at 100% used.
        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 20), configuration: config)
        let events = machine.process(
            snapshot: makeUsageSnapshot(
                primaryUsedPercent: 100,
                primaryWindowMinutes: nil,
                primaryWindowKind: .spendLimit),
            configuration: config)
        #expect(events.isEmpty)
        // The pseudo-window also resets the baselines (legacy primary == nil semantics).
        #expect(machine.sessionDepletionLastRemaining == nil)
        #expect(machine.sessionWarning == QuotaTransitionMachine.WindowState())
    }

    @Test
    func `session notifications disabled tracks baseline without events`() {
        var machine = QuotaTransitionMachine()
        let disabled = self.makeConfiguration(sessionNotifications: false, warningNotifications: false)
        let enabled = self.makeConfiguration(warningNotifications: false)

        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 20), configuration: disabled)
        var events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 100), configuration: disabled)
        #expect(events.isEmpty)

        // Baseline kept current while disabled: enabling now and recovering emits restored.
        events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 10), configuration: enabled)
        #expect(events == [.sessionRestored])
    }

    @Test
    func `warning posts once per downward threshold crossing`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration()

        var events: [QuotaCrossing] = []
        for used in [40.0, 55, 60] {
            events += machine.process(
                snapshot: makeUsageSnapshot(primaryUsedPercent: used),
                configuration: config)
        }
        #expect(events == [
            .warningThresholdCrossed(window: .session, threshold: 50, currentRemaining: 45, resetsAt: nil),
        ])
    }

    @Test
    func `crossing multiple thresholds posts most severe only`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration()

        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 10), configuration: config)
        let events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 85), configuration: config)
        #expect(events == [
            .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 15, resetsAt: nil),
        ])
    }

    @Test
    func `warning recovers and can fire again`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(thresholds: [50])

        var thresholds: [Int] = []
        for used in [40.0, 55, 10, 55] {
            for case let .warningThresholdCrossed(_, threshold, _, _) in machine.process(
                snapshot: makeUsageSnapshot(primaryUsedPercent: used),
                configuration: config)
            {
                thresholds.append(threshold)
            }
        }
        #expect(thresholds == [50, 50])
    }

    @Test
    func `warning notifications switch off emits nothing and freezes warning state`() {
        var machine = QuotaTransitionMachine()
        let off = self.makeConfiguration(sessionNotifications: false, warningNotifications: false)

        let events = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 90), configuration: off)
        #expect(events.isEmpty)
        #expect(machine.sessionWarning.lastRemaining == nil) // frozen, not advanced
    }

    @Test
    func `session only config ignores weekly crossings`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(weeklyEnabled: false, thresholds: [50])

        _ = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 40, secondaryUsedPercent: 40),
            configuration: config)
        let events = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 60, secondaryUsedPercent: 60),
            configuration: config)
        #expect(events == [
            .warningThresholdCrossed(window: .session, threshold: 50, currentRemaining: 40, resetsAt: nil),
        ])
    }

    @Test
    func `weekly only config ignores session crossings`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(sessionEnabled: false, thresholds: [50])

        _ = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 40, secondaryUsedPercent: 40),
            configuration: config)
        let events = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 60, secondaryUsedPercent: 60),
            configuration: config)
        #expect(events == [
            .warningThresholdCrossed(window: .weekly, threshold: 50, currentRemaining: 40, resetsAt: nil),
        ])
    }

    @Test
    func `both windows fire when both cross`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(thresholds: [50])

        _ = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 40, secondaryUsedPercent: 40),
            configuration: config)
        let events = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 55, secondaryUsedPercent: 55),
            configuration: config)
        #expect(events == [
            .warningThresholdCrossed(window: .session, threshold: 50, currentRemaining: 45, resetsAt: nil),
            .warningThresholdCrossed(window: .weekly, threshold: 50, currentRemaining: 45, resetsAt: nil),
        ])
    }

    @Test
    func `disabling a window clears its fired state`() {
        var machine = QuotaTransitionMachine()
        let enabled = self.makeConfiguration(thresholds: [50])
        let sessionDisabled = self.makeConfiguration(sessionEnabled: false, thresholds: [50])

        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 40), configuration: enabled)
        let fired = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 60), configuration: enabled)
        #expect(fired.count == 1)

        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 60), configuration: sessionDisabled)
        #expect(machine.sessionWarning == QuotaTransitionMachine.WindowState())

        // Re-enabling re-arms: the first sample is a fresh baseline, still below the threshold,
        // so it fires again (legacy startup-below-threshold semantics).
        let refired = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 60), configuration: enabled)
        #expect(refired == [
            .warningThresholdCrossed(window: .session, threshold: 50, currentRemaining: 40, resetsAt: nil),
        ])
    }

    @Test
    func `missing weekly window clears weekly state`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration(thresholds: [50])

        _ = machine.process(
            snapshot: makeUsageSnapshot(primaryUsedPercent: 40, secondaryUsedPercent: 55),
            configuration: config)
        #expect(machine.weeklyWarning.lastRemaining == 45)

        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 40), configuration: config)
        #expect(machine.weeklyWarning == QuotaTransitionMachine.WindowState())
    }
}

// MARK: - Store integration

@MainActor
struct UsageStoreQuotaCrossingTests {
    @Test
    func `successful refreshes emit crossings through the callback`() async {
        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 40)),
            .success(makeUsageSnapshot(primaryUsedPercent: 60)),
            .success(makeUsageSnapshot(primaryUsedPercent: 100)),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-tests-quota-callback") { _, _ in try script.next() }
        ts.settings.quotaWarningNotificationsEnabled = true

        var providers: [UsageProviderKind] = []
        var crossings: [QuotaCrossing] = []
        ts.store.onQuotaThresholdCrossing = { provider, crossing in
            providers.append(provider)
            crossings.append(crossing)
        }

        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .manual)

        // Per-snapshot event order: depletion machine first, then warnings.
        #expect(crossings == [
            .warningThresholdCrossed(window: .session, threshold: 50, currentRemaining: 40, resetsAt: nil),
            .sessionDepleted(resetsAt: nil),
            .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 0, resetsAt: nil),
        ])
        #expect(providers == [.claude, .claude, .claude])
    }

    @Test
    func `codex crossings are tagged codex and tracked by a separate machine`() async {
        let codexScript = FetchScript([
            .success(makeCodexSnapshot(primaryUsedPercent: 40, secondaryUsedPercent: nil)),
            .success(makeCodexSnapshot(primaryUsedPercent: 60, secondaryUsedPercent: nil)),
            .success(makeCodexSnapshot(primaryUsedPercent: 100, secondaryUsedPercent: nil)),
        ])
        let ts = makeTestStore(
            suiteName: "sturtbar-tests-quota-codex",
            codexFetch: { try await codexScript.next() },
            fetch: { _, _ in
                // Claude stays flat at 10% — its machine must emit nothing while codex crosses.
                makeUsageSnapshot(primaryUsedPercent: 10)
            })
        ts.settings.codexProviderEnabled = true
        ts.settings.quotaWarningNotificationsEnabled = true

        var events: [(UsageProviderKind, QuotaCrossing)] = []
        ts.store.onQuotaThresholdCrossing = { events.append(($0, $1)) }

        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .manual)

        // Same sequence the Claude machine produces for 40→60→100 — but tagged codex, proving
        // the lanes run separate machines off the shared threshold configuration.
        #expect(events.map(\.0) == [.codex, .codex, .codex])
        #expect(events.map(\.1) == [
            .warningThresholdCrossed(window: .session, threshold: 50, currentRemaining: 40, resetsAt: nil),
            .sessionDepleted(resetsAt: nil),
            .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 0, resetsAt: nil),
        ])
    }

    @Test
    func `failed refreshes emit no crossings`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-quota-failures") { _, _ in
            throw ClaudeUsageError.fetch(.serverError(500, nil))
        }
        ts.settings.quotaWarningNotificationsEnabled = true

        var crossings: [QuotaCrossing] = []
        ts.store.onQuotaThresholdCrossing = { _, crossing in crossings.append(crossing) }
        await ts.store.refresh(trigger: .manual)
        #expect(crossings.isEmpty)
    }
}

// MARK: - Named extra windows

struct NamedWindowWarningTests {
    private func makeConfiguration(weeklyEnabled: Bool = true) -> QuotaTransitionMachine.Configuration {
        QuotaTransitionMachine.Configuration(
            sessionQuotaNotificationsEnabled: false,
            quotaWarningNotificationsEnabled: true,
            sessionWarningEnabled: false,
            weeklyWarningEnabled: weeklyEnabled,
            sessionThresholds: [50, 20],
            weeklyThresholds: [50, 20])
    }

    private func snapshot(fableUsed: Double) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            opus: nil,
            modelWeeklyWindows: [
                NamedRateWindow(
                    id: "model-weekly-fable",
                    title: "Fable",
                    window: RateWindow(
                        usedPercent: fableUsed,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_000_000_000),
            loginMethod: nil)
    }

    @Test
    func `named window crossing fires on the weekly thresholds with its title`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration()

        var events = machine.process(snapshot: self.snapshot(fableUsed: 40), configuration: config)
        #expect(events.isEmpty)

        events = machine.process(snapshot: self.snapshot(fableUsed: 55), configuration: config)
        #expect(events == [
            .namedWindowThresholdCrossed(title: "Fable", threshold: 50, currentRemaining: 45, resetsAt: nil),
        ])

        // Fired threshold stays quiet while remaining keeps falling short of the next one.
        events = machine.process(snapshot: self.snapshot(fableUsed: 56), configuration: config)
        #expect(events.isEmpty)
    }

    @Test
    func `named window re-arms after its reset`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration()

        _ = machine.process(snapshot: self.snapshot(fableUsed: 40), configuration: config)
        _ = machine.process(snapshot: self.snapshot(fableUsed: 55), configuration: config)

        // The carve-out resets: remaining recovers above the threshold, re-arming it.
        var events = machine.process(snapshot: self.snapshot(fableUsed: 5), configuration: config)
        #expect(events.isEmpty)
        events = machine.process(snapshot: self.snapshot(fableUsed: 55), configuration: config)
        #expect(events == [
            .namedWindowThresholdCrossed(title: "Fable", threshold: 50, currentRemaining: 45, resetsAt: nil),
        ])
    }

    @Test
    func `weekly toggle off keeps named windows silent and clears their state`() {
        var machine = QuotaTransitionMachine()
        let off = self.makeConfiguration(weeklyEnabled: false)

        _ = machine.process(snapshot: self.snapshot(fableUsed: 40), configuration: off)
        let events = machine.process(snapshot: self.snapshot(fableUsed: 55), configuration: off)
        #expect(events.isEmpty)
        #expect(machine.namedWindowWarnings.isEmpty)
    }

    @Test
    func `vanished named windows drop their state`() {
        var machine = QuotaTransitionMachine()
        let config = self.makeConfiguration()

        _ = machine.process(snapshot: self.snapshot(fableUsed: 55), configuration: config)
        #expect(machine.namedWindowWarnings.keys.contains("model-weekly-fable"))

        // The carve-out disappears (promo over): its state is pruned.
        _ = machine.process(snapshot: makeUsageSnapshot(primaryUsedPercent: 10), configuration: config)
        #expect(machine.namedWindowWarnings.isEmpty)
    }

    @Test
    @MainActor
    func `named window delivery names the allowance`() {
        let delivery = QuotaNotifier.delivery(
            for: .namedWindowThresholdCrossed(title: "Fable", threshold: 50, currentRemaining: 45, resetsAt: nil),
            provider: .claude,
            soundEnabled: false)
        #expect(delivery.idPrefix == "quota-warning-claude-fable-50")
        #expect(delivery.title == "Claude Fable limit nearing")
        #expect(delivery.body == "45% of the Fable allowance remains.")
    }
}
