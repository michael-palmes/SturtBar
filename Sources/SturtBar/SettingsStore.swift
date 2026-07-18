// SettingsStore.swift — UserDefaults-backed app settings.
//
// Salvaged from legacy CodexBar:
//   - `RefreshFrequency` (Sources/CodexBar/SettingsStore.swift:6-39) — cases/durations ported,
//     labels inlined from en.lproj (the rebuild has no localization layer yet).
//   - Quota-warning defaults loader semantics (Sources/CodexBar/SettingsStore.swift:466-520):
//     master switch defaults OFF; thresholds default [50, 20] (sanitized: clamp 0-99, dedupe,
//     sort desc); per-window thresholds fall back to the global list; per-window enables and
//     sound default ON. Setting the global thresholds mirrors into both windows (legacy
//     `quotaWarningThresholds` setter behavior).
//
// Rebuild changes vs legacy:
//   - Fresh `sturtbar.*` defaults keys; no migration, no config file, no per-provider overrides.
//   - The legacy `isRunningTests` write-back hack is dropped; tests inject a suite-scoped
//     UserDefaults instead.

import Foundation
import Observation
import SturtBarCore

// MARK: - RefreshFrequency

enum RefreshFrequency: String, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes

    static let `default`: RefreshFrequency = .fiveMinutes

    var id: String {
        self.rawValue
    }

    /// nil = manual cadence (no timer loop).
    var seconds: TimeInterval? {
        switch self {
        case .manual: nil
        case .oneMinute: 60
        case .twoMinutes: 120
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        }
    }

    var interval: Duration? {
        self.seconds.map { .seconds($0) }
    }

    var label: String {
        switch self {
        case .manual: "Manual"
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        }
    }
}

// MARK: - SettingsStore

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let refreshFrequency = "sturtbar.refreshFrequency"
        static let claudeProviderEnabled = "sturtbar.claudeProviderEnabled"
        static let codexProviderEnabled = "sturtbar.codexProviderEnabled"
        static let menuBarProviderSource = "sturtbar.menuBarProviderSource"
        static let sessionQuotaNotificationsEnabled = "sturtbar.sessionQuotaNotificationsEnabled"
        static let quotaWarningNotificationsEnabled = "sturtbar.quotaWarningNotificationsEnabled"
        static let quotaWarningThresholds = "sturtbar.quotaWarningThresholds"
        static let quotaWarningSessionThresholds = "sturtbar.quotaWarningSessionThresholds"
        static let quotaWarningWeeklyThresholds = "sturtbar.quotaWarningWeeklyThresholds"
        static let quotaWarningSessionEnabled = "sturtbar.quotaWarningSessionEnabled"
        static let quotaWarningWeeklyEnabled = "sturtbar.quotaWarningWeeklyEnabled"
        static let quotaWarningSoundEnabled = "sturtbar.quotaWarningSoundEnabled"
        static let costUsageEnabled = "sturtbar.costUsageEnabled"
        static let costUsageHistoryDays = "sturtbar.costUsageHistoryDays"
        static let claudeDesktopSessionsEnabled = "sturtbar.claudeDesktopSessionsEnabled"
        static let menuBarDisplayMode = "sturtbar.menuBarDisplayMode"
        static let resetTimesShowAbsolute = "sturtbar.resetTimesShowAbsolute"
        static let usageBarsShowUsed = "sturtbar.usageBarsShowUsed"
        static let weeklyWorkWeekPacingEnabled = "sturtbar.weeklyWorkWeekPacingEnabled"
        static let showModelWeeklyLimits = "sturtbar.showModelWeeklyLimits"
        static let updateChecksEnabled = "sturtbar.updateChecksEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// App wiring (AppDelegate): restart the RefreshScheduler when the cadence changes.
    @ObservationIgnored var onRefreshFrequencyChange: ((RefreshFrequency) -> Void)?
    /// App wiring (AppDelegate): kick a cost rescan when cost settings change.
    @ObservationIgnored var onCostSettingsChange: (() -> Void)?
    /// App wiring (AppDelegate): wipe/kick the provider's lane in UsageStore when toggled.
    @ObservationIgnored var onProviderEnabledChange: ((UsageProviderKind, Bool) -> Void)?
    /// App wiring (AppDelegate): refresh immediately when Keychain prompts are turned ON.
    @ObservationIgnored var onClaudeKeychainPromptsChange: ((Bool) -> Void)?
    /// App wiring (AppDelegate): start or tear down the update-check lane when the gate flips.
    @ObservationIgnored var onUpdateChecksEnabledChange: ((Bool?) -> Void)?

    // MARK: Providers

    // The privacy gate (decision 6): a disabled provider performs no network calls, no file
    // reads, and no background work — UsageStore enforces this; these flags are the source of
    // truth. Claude ships ON, Codex is strictly opt-in (OFF).

    var claudeProviderEnabled: Bool {
        didSet {
            guard oldValue != self.claudeProviderEnabled else { return }
            self.defaults.set(self.claudeProviderEnabled, forKey: Keys.claudeProviderEnabled)
            self.onProviderEnabledChange?(.claude, self.claudeProviderEnabled)
        }
    }

    var codexProviderEnabled: Bool {
        didSet {
            guard oldValue != self.codexProviderEnabled else { return }
            self.defaults.set(self.codexProviderEnabled, forKey: Keys.codexProviderEnabled)
            self.onProviderEnabledChange?(.codex, self.codexProviderEnabled)
        }
    }

    /// Keychain prompt opt-in, default off. Writes the core's un-namespaced key (not Keys.*) so the fetch path reads
    /// it; off = .never, on = .onlyOnUserAction.
    var claudeKeychainPromptsEnabled: Bool {
        didSet {
            guard oldValue != self.claudeKeychainPromptsEnabled else { return }
            ClaudeOAuthKeychainPromptPreference.setStoredMode(
                self.claudeKeychainPromptsEnabled ? .onlyOnUserAction : .never,
                userDefaults: self.defaults)
            self.onClaudeKeychainPromptsChange?(self.claudeKeychainPromptsEnabled)
        }
    }

    /// Drives both the menu bar icon and its text (decisions 10+11).
    var menuBarProviderSource: MenuBarProviderSource {
        didSet { self.defaults.set(self.menuBarProviderSource.rawValue, forKey: Keys.menuBarProviderSource) }
    }

    func providerEnabled(_ provider: UsageProviderKind) -> Bool {
        switch provider {
        case .claude: self.claudeProviderEnabled
        case .codex: self.codexProviderEnabled
        }
    }

    /// Enabled providers in canonical (`allCases`) order.
    var enabledProviders: [UsageProviderKind] {
        UsageProviderKind.allCases.filter { self.providerEnabled($0) }
    }

    // MARK: Refresh cadence

    var refreshFrequency: RefreshFrequency {
        didSet {
            guard oldValue != self.refreshFrequency else { return }
            self.defaults.set(self.refreshFrequency.rawValue, forKey: Keys.refreshFrequency)
            self.onRefreshFrequencyChange?(self.refreshFrequency)
        }
    }

    // MARK: Quota notifications

    var sessionQuotaNotificationsEnabled: Bool {
        didSet {
            self.defaults.set(self.sessionQuotaNotificationsEnabled, forKey: Keys.sessionQuotaNotificationsEnabled)
        }
    }

    var quotaWarningNotificationsEnabled: Bool {
        didSet {
            self.defaults.set(self.quotaWarningNotificationsEnabled, forKey: Keys.quotaWarningNotificationsEnabled)
        }
    }

    var quotaWarningSoundEnabled: Bool {
        didSet { self.defaults.set(self.quotaWarningSoundEnabled, forKey: Keys.quotaWarningSoundEnabled) }
    }

    /// Global thresholds. Setting this mirrors into both windows (legacy semantics).
    var quotaWarningThresholds: [Int] {
        didSet {
            let sanitized = QuotaWarningThresholds.sanitized(self.quotaWarningThresholds)
            if sanitized != self.quotaWarningThresholds {
                self.quotaWarningThresholds = sanitized
                return // didSet re-enters with the sanitized value
            }
            self.quotaWarningSessionThresholds = sanitized
            self.quotaWarningWeeklyThresholds = sanitized
            self.defaults.set(sanitized, forKey: Keys.quotaWarningThresholds)
        }
    }

    private var quotaWarningSessionThresholds: [Int] {
        didSet { self.defaults.set(self.quotaWarningSessionThresholds, forKey: Keys.quotaWarningSessionThresholds) }
    }

    private var quotaWarningWeeklyThresholds: [Int] {
        didSet { self.defaults.set(self.quotaWarningWeeklyThresholds, forKey: Keys.quotaWarningWeeklyThresholds) }
    }

    private var quotaWarningSessionEnabled: Bool {
        didSet { self.defaults.set(self.quotaWarningSessionEnabled, forKey: Keys.quotaWarningSessionEnabled) }
    }

    private var quotaWarningWeeklyEnabled: Bool {
        didSet { self.defaults.set(self.quotaWarningWeeklyEnabled, forKey: Keys.quotaWarningWeeklyEnabled) }
    }

    func quotaWarningThresholds(_ window: QuotaWindow) -> [Int] {
        switch window {
        case .session: QuotaWarningThresholds.sanitized(self.quotaWarningSessionThresholds)
        case .weekly: QuotaWarningThresholds.sanitized(self.quotaWarningWeeklyThresholds)
        }
    }

    func setQuotaWarningThresholds(_ window: QuotaWindow, thresholds: [Int]) {
        let sanitized = QuotaWarningThresholds.sanitized(thresholds)
        switch window {
        case .session: self.quotaWarningSessionThresholds = sanitized
        case .weekly: self.quotaWarningWeeklyThresholds = sanitized
        }
    }

    func quotaWarningWindowEnabled(_ window: QuotaWindow) -> Bool {
        switch window {
        case .session: self.quotaWarningSessionEnabled
        case .weekly: self.quotaWarningWeeklyEnabled
        }
    }

    func setQuotaWarningWindowEnabled(_ window: QuotaWindow, enabled: Bool) {
        switch window {
        case .session: self.quotaWarningSessionEnabled = enabled
        case .weekly: self.quotaWarningWeeklyEnabled = enabled
        }
    }

    // MARK: Cost usage

    var costUsageEnabled: Bool {
        didSet {
            guard oldValue != self.costUsageEnabled else { return }
            self.defaults.set(self.costUsageEnabled, forKey: Keys.costUsageEnabled)
            self.onCostSettingsChange?()
        }
    }

    var costUsageHistoryDays: Int {
        didSet {
            let clamped = Self.clampedHistoryDays(self.costUsageHistoryDays)
            if clamped != self.costUsageHistoryDays {
                self.costUsageHistoryDays = clamped
                return // didSet re-enters with the clamped value
            }
            guard oldValue != clamped else { return }
            self.defaults.set(clamped, forKey: Keys.costUsageHistoryDays)
            self.onCostSettingsChange?()
        }
    }

    /// Opt-in: also scan Claude Desktop's local agent transcripts for cost usage. Off by default.
    var claudeDesktopSessionsEnabled: Bool {
        didSet {
            guard oldValue != self.claudeDesktopSessionsEnabled else { return }
            self.defaults.set(self.claudeDesktopSessionsEnabled, forKey: Keys.claudeDesktopSessionsEnabled)
            self.onCostSettingsChange?()
        }
    }

    // MARK: Display

    /// Text shown next to the menu bar icon (Phase 3b: drives StatusItemController's IconState).
    var menuBarDisplayMode: MenuBarDisplayMode {
        didSet { self.defaults.set(self.menuBarDisplayMode.rawValue, forKey: Keys.menuBarDisplayMode) }
    }

    /// Reset times as an absolute clock value ("Resets 2:00 PM") instead of a countdown.
    var resetTimesShowAbsolute: Bool {
        didSet { self.defaults.set(self.resetTimesShowAbsolute, forKey: Keys.resetTimesShowAbsolute) }
    }

    /// Meters fill as quota is consumed ("42% used") instead of showing what's left ("58% left").
    var usageBarsShowUsed: Bool {
        didSet { self.defaults.set(self.usageBarsShowUsed, forKey: Keys.usageBarsShowUsed) }
    }

    /// Pace the weekly window over a Monday-to-Friday working week (5 days) instead of 7 calendar
    /// days, treating weekends as zero usage. Only reshapes the pace marker and its run-out
    /// projection; the real limit and percentages are untouched.
    var weeklyWorkWeekPacingEnabled: Bool {
        didSet { self.defaults.set(self.weeklyWorkWeekPacingEnabled, forKey: Keys.weeklyWorkWeekPacingEnabled) }
    }

    /// Popover rows for model-scoped weekly limits (such as Fable). Display-time filter only:
    /// the data is still fetched, mapped and persisted while hidden, so the toggle is instant.
    var showModelWeeklyLimits: Bool {
        didSet { self.defaults.set(self.showModelWeeklyLimits, forKey: Keys.showModelWeeklyLimits) }
    }

    // MARK: Updates

    /// Hard privacy gate for the daily update check. Tri-state: nil = the first-run ask has not
    /// been answered yet (no checks run while undecided), true/false = the user's decision.
    var updateChecksEnabled: Bool? {
        didSet {
            guard oldValue != self.updateChecksEnabled else { return }
            if let value = self.updateChecksEnabled {
                self.defaults.set(value, forKey: Keys.updateChecksEnabled)
            } else {
                self.defaults.removeObject(forKey: Keys.updateChecksEnabled)
            }
            self.onUpdateChecksEnabledChange?(self.updateChecksEnabled)
        }
    }

    // MARK: Init

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults

        self.refreshFrequency = userDefaults.string(forKey: Keys.refreshFrequency)
            .flatMap(RefreshFrequency.init(rawValue:)) ?? .default

        // Absent keys reproduce today's Claude-only behavior — no migration needed.
        self.claudeProviderEnabled = userDefaults.object(forKey: Keys.claudeProviderEnabled) as? Bool ?? true
        self.codexProviderEnabled = userDefaults.object(forKey: Keys.codexProviderEnabled) as? Bool ?? false
        self.claudeKeychainPromptsEnabled =
            ClaudeOAuthKeychainPromptPreference.storedMode(userDefaults: userDefaults) != .never
        self.menuBarProviderSource = userDefaults.string(forKey: Keys.menuBarProviderSource)
            .flatMap(MenuBarProviderSource.init(rawValue:)) ?? .default

        self.sessionQuotaNotificationsEnabled =
            userDefaults.object(forKey: Keys.sessionQuotaNotificationsEnabled) as? Bool ?? true
        // Legacy default: quota-warning notifications are opt-in.
        self.quotaWarningNotificationsEnabled =
            userDefaults.object(forKey: Keys.quotaWarningNotificationsEnabled) as? Bool ?? false
        self.quotaWarningSoundEnabled =
            userDefaults.object(forKey: Keys.quotaWarningSoundEnabled) as? Bool ?? true

        // Legacy loader semantics: global defaults to [50, 20]; windows fall back to global.
        let global = QuotaWarningThresholds.sanitized(
            userDefaults.array(forKey: Keys.quotaWarningThresholds) as? [Int]
                ?? QuotaWarningThresholds.defaults)
        self.quotaWarningThresholds = global
        self.quotaWarningSessionThresholds = QuotaWarningThresholds.sanitized(
            userDefaults.array(forKey: Keys.quotaWarningSessionThresholds) as? [Int] ?? global)
        self.quotaWarningWeeklyThresholds = QuotaWarningThresholds.sanitized(
            userDefaults.array(forKey: Keys.quotaWarningWeeklyThresholds) as? [Int] ?? global)

        self.quotaWarningSessionEnabled =
            userDefaults.object(forKey: Keys.quotaWarningSessionEnabled) as? Bool ?? true
        self.quotaWarningWeeklyEnabled =
            userDefaults.object(forKey: Keys.quotaWarningWeeklyEnabled) as? Bool ?? true

        self.costUsageEnabled = userDefaults.object(forKey: Keys.costUsageEnabled) as? Bool ?? true
        self.costUsageHistoryDays = Self.clampedHistoryDays(
            userDefaults.object(forKey: Keys.costUsageHistoryDays) as? Int ?? 30)
        self.claudeDesktopSessionsEnabled =
            userDefaults.object(forKey: Keys.claudeDesktopSessionsEnabled) as? Bool ?? false

        self.menuBarDisplayMode = userDefaults.string(forKey: Keys.menuBarDisplayMode)
            .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .default
        self.resetTimesShowAbsolute = userDefaults.object(forKey: Keys.resetTimesShowAbsolute) as? Bool ?? false
        self.usageBarsShowUsed = userDefaults.object(forKey: Keys.usageBarsShowUsed) as? Bool ?? false
        self.weeklyWorkWeekPacingEnabled =
            userDefaults.object(forKey: Keys.weeklyWorkWeekPacingEnabled) as? Bool ?? false
        self.showModelWeeklyLimits =
            userDefaults.object(forKey: Keys.showModelWeeklyLimits) as? Bool ?? true
        // Absent key = undecided: the one-time first-run ask resolves it to true or false.
        self.updateChecksEnabled = userDefaults.object(forKey: Keys.updateChecksEnabled) as? Bool
    }

    private static func clampedHistoryDays(_ raw: Int) -> Int {
        max(1, min(365, raw))
    }
}
