// SettingsStoreTests.swift — RefreshFrequency mapping, quota-warning threshold defaults
// (salvaged legacy loader semantics), and change callbacks.

import Foundation
import Testing
@testable import SturtBar

@MainActor
struct RefreshFrequencyTests {
    @Test
    func `frequencies map to the legacy durations`() {
        #expect(RefreshFrequency.manual.seconds == nil)
        #expect(RefreshFrequency.oneMinute.seconds == 60)
        #expect(RefreshFrequency.twoMinutes.seconds == 120)
        #expect(RefreshFrequency.fiveMinutes.seconds == 300)
        #expect(RefreshFrequency.fifteenMinutes.seconds == 900)
        #expect(RefreshFrequency.thirtyMinutes.seconds == 1800)
        #expect(RefreshFrequency.manual.interval == nil)
        #expect(RefreshFrequency.fiveMinutes.interval == .seconds(300))
        #expect(RefreshFrequency.default == .fiveMinutes)
    }

    @Test
    func `all legacy cases survive raw-value round-trips`() {
        for frequency in RefreshFrequency.allCases {
            #expect(RefreshFrequency(rawValue: frequency.rawValue) == frequency)
        }
        #expect(RefreshFrequency.allCases.count == 6)
    }
}

@MainActor
struct SettingsStoreTests {
    private func makeSettings(_ suiteName: String) -> SettingsStore {
        makeTestSettings(suiteName: suiteName)
    }

    @Test
    func `defaults match the legacy loader semantics`() {
        let settings = self.makeSettings("sturtbar-settings-defaults")
        #expect(settings.refreshFrequency == .fiveMinutes)
        #expect(settings.sessionQuotaNotificationsEnabled)
        #expect(!settings.quotaWarningNotificationsEnabled) // opt-in master switch
        #expect(settings.quotaWarningSoundEnabled)
        #expect(settings.quotaWarningThresholds == [50, 20])
        #expect(settings.quotaWarningThresholds(.session) == [50, 20])
        #expect(settings.quotaWarningThresholds(.weekly) == [50, 20])
        #expect(settings.quotaWarningWindowEnabled(.session))
        #expect(settings.quotaWarningWindowEnabled(.weekly))
        #expect(settings.costUsageEnabled)
        #expect(settings.costUsageHistoryDays == 30)
        #expect(settings.menuBarDisplayMode == .hidden)
        #expect(!settings.resetTimesShowAbsolute) // countdown by default
        #expect(!settings.usageBarsShowUsed) // remaining by default
    }

    @Test
    func `display toggles persist and reload`() throws {
        let suite = "sturtbar-settings-display-toggles"
        let settings = self.makeSettings(suite)
        settings.resetTimesShowAbsolute = true
        settings.usageBarsShowUsed = true

        let reloaded = try SettingsStore(userDefaults: #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.resetTimesShowAbsolute)
        #expect(reloaded.usageBarsShowUsed)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test
    func `menu bar display mode persists and reloads`() throws {
        let suite = "sturtbar-settings-display-mode"
        let settings = self.makeSettings(suite)
        settings.menuBarDisplayMode = .percent

        let reloaded = try SettingsStore(userDefaults: #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.menuBarDisplayMode == .percent)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test
    func `refresh frequency persists and reloads`() throws {
        let suite = "sturtbar-settings-persist"
        let settings = self.makeSettings(suite)
        settings.refreshFrequency = .fifteenMinutes

        let reloaded = try SettingsStore(userDefaults: #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.refreshFrequency == .fifteenMinutes)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test
    func `setting global thresholds mirrors into both windows`() {
        let settings = self.makeSettings("sturtbar-settings-mirror")
        settings.setQuotaWarningThresholds(.session, thresholds: [80])
        #expect(settings.quotaWarningThresholds(.session) == [80])
        #expect(settings.quotaWarningThresholds(.weekly) == [50, 20])

        settings.quotaWarningThresholds = [60, 30]
        #expect(settings.quotaWarningThresholds(.session) == [60, 30])
        #expect(settings.quotaWarningThresholds(.weekly) == [60, 30])
    }

    @Test
    func `thresholds are sanitized clamped deduped and sorted descending`() {
        let settings = self.makeSettings("sturtbar-settings-sanitize")
        settings.quotaWarningThresholds = [120, -5, 20, 20, 50]
        #expect(settings.quotaWarningThresholds == [99, 50, 20, 0])

        settings.setQuotaWarningThresholds(.weekly, thresholds: [])
        #expect(settings.quotaWarningThresholds(.weekly) == [50, 20]) // empty → defaults
    }

    @Test
    func `per-window thresholds fall back to the global list on first load`() throws {
        let suite = "sturtbar-settings-fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set([70, 40], forKey: "sturtbar.quotaWarningThresholds")

        let settings = SettingsStore(userDefaults: defaults)
        #expect(settings.quotaWarningThresholds == [70, 40])
        #expect(settings.quotaWarningThresholds(.session) == [70, 40])
        #expect(settings.quotaWarningThresholds(.weekly) == [70, 40])
        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `window enablement persists independently`() throws {
        let suite = "sturtbar-settings-windows"
        let settings = self.makeSettings(suite)
        settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        #expect(settings.quotaWarningWindowEnabled(.session))
        #expect(!settings.quotaWarningWindowEnabled(.weekly))

        let reloaded = try SettingsStore(userDefaults: #require(UserDefaults(suiteName: suite)))
        #expect(!reloaded.quotaWarningWindowEnabled(.weekly))
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test
    func `history days clamp to 1 through 365`() {
        let settings = self.makeSettings("sturtbar-settings-historydays")
        settings.costUsageHistoryDays = 0
        #expect(settings.costUsageHistoryDays == 1)
        settings.costUsageHistoryDays = 9999
        #expect(settings.costUsageHistoryDays == 365)
    }

    @Test
    func `every settings-pane control round-trips through UserDefaults`() throws {
        // One write per SettingsView control (non-default values), then a cold reload.
        let suite = "sturtbar-settings-pane-roundtrip"
        let settings = self.makeSettings(suite)
        settings.refreshFrequency = .thirtyMinutes
        settings.menuBarDisplayMode = .both
        settings.resetTimesShowAbsolute = true
        settings.usageBarsShowUsed = true
        settings.costUsageEnabled = false
        settings.costUsageHistoryDays = 14
        settings.sessionQuotaNotificationsEnabled = false
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningSoundEnabled = false
        settings.setQuotaWarningWindowEnabled(.session, enabled: false)
        settings.setQuotaWarningThresholds(.session, thresholds: [70, 35])
        settings.setQuotaWarningThresholds(.weekly, thresholds: [40])

        let reloaded = try SettingsStore(userDefaults: #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.refreshFrequency == .thirtyMinutes)
        #expect(reloaded.menuBarDisplayMode == .both)
        #expect(reloaded.resetTimesShowAbsolute)
        #expect(reloaded.usageBarsShowUsed)
        #expect(!reloaded.costUsageEnabled)
        #expect(reloaded.costUsageHistoryDays == 14)
        #expect(!reloaded.sessionQuotaNotificationsEnabled)
        #expect(reloaded.quotaWarningNotificationsEnabled)
        #expect(!reloaded.quotaWarningSoundEnabled)
        #expect(!reloaded.quotaWarningWindowEnabled(.session))
        #expect(reloaded.quotaWarningWindowEnabled(.weekly))
        #expect(reloaded.quotaWarningThresholds(.session) == [70, 35])
        #expect(reloaded.quotaWarningThresholds(.weekly) == [40])
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test
    func `refresh frequency change fires the scheduler callback`() {
        let settings = self.makeSettings("sturtbar-settings-callback")
        var received: [RefreshFrequency] = []
        settings.onRefreshFrequencyChange = { received.append($0) }

        settings.refreshFrequency = .manual
        settings.refreshFrequency = .manual // no-op: unchanged
        settings.refreshFrequency = .oneMinute
        #expect(received == [.manual, .oneMinute])
    }

    @Test
    func `cost setting changes fire the cost callback`() {
        let settings = self.makeSettings("sturtbar-settings-costcallback")
        var fired = 0
        settings.onCostSettingsChange = { fired += 1 }

        settings.costUsageEnabled = false
        settings.costUsageHistoryDays = 7
        settings.costUsageHistoryDays = 7 // no-op
        #expect(fired == 2)
    }
}
