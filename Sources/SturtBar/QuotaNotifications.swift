// QuotaNotifications.swift — maps QuotaCrossing events to user notifications.
//
// Ported from legacy CodexBar/SessionQuotaNotifications.swift (the delivery layer; the pure
// transition logic moved to QuotaWarnings.swift in Phase 3a). Changes vs legacy:
//   - Copy per BRAND.md §3.3: the title states the provider and the fact plainly, the body
//     leads with the numbers (reset time included when the window reports one) and closes with
//     one short Keeper clause. Dedup id prefixes are provider-scoped
//     (`claude-session-depleted`, `quota-warning-codex-weekly-50`).
//   - `accountDisplayName` body variant dropped: `ProviderUsageSnapshot` carries no account
//     identity, so the legacy hidePersonalInfo/account-name copy paths are unreachable.
//   - Startup-depleted parity: like legacy, the quota machine starts each launch with a fresh
//     baseline, so an already-depleted session re-fires "session depleted" once per launch. The
//     stable `sturtbar-session-depleted` identifier makes the re-fire REPLACE the previous
//     notification instead of stacking (dedup via id-prefix replace).
//   - Sound parity: threshold warnings play an NSSound (Glass, falling back to Ping) when the
//     `quotaWarningSoundEnabled` setting is on, and always post the UNNotification silently
//     (legacy behavior — the sound toggle never controlled the notification's own sound).
//     Session depleted/restored notifications keep the default notification sound.
//
// `delivery(for:soundEnabled:)` is the pure, testable layer; `post` is the only side-effecting
// path and never runs under tests (AppNotifications bundle guard + NSSound is harmless-nil there).

import AppKit
import Foundation
import SturtBarCore

@MainActor
final class QuotaNotifier {
    /// Fully-resolved notification request: pure function of (crossing, sound setting).
    struct Delivery: Equatable {
        var idPrefix: String
        var title: String
        var body: String
        /// Whether the UNNotification itself carries the default sound.
        var notificationSoundEnabled: Bool
        /// Whether the app plays the separate alert NSSound (threshold warnings only).
        var playsAlertSound: Bool
    }

    private let logger = SturtBarLog.logger("quota-notifications")

    init() {}

    /// Notices to Mariners (BRAND.md §3.3): the title carries the provider and the plain fact,
    /// the body leads with the numbers and closes with one Keeper clause (accuracy beats theme,
    /// hard boundary 7). Dedup ids are provider-scoped so a Claude notice never replaces a
    /// Codex one.
    static func delivery(
        for crossing: QuotaCrossing,
        provider: UsageProviderKind,
        soundEnabled: Bool,
        now: Date = .init()) -> Delivery
    {
        switch crossing {
        case let .sessionDepleted(resetsAt):
            Delivery(
                idPrefix: "\(provider.rawValue)-session-depleted",
                title: "\(provider.displayName) session limit reached",
                body: Self.depletedBody(resetsAt: resetsAt, now: now),
                notificationSoundEnabled: true,
                playsAlertSound: false)
        case .sessionRestored:
            Delivery(
                idPrefix: "\(provider.rawValue)-session-restored",
                title: "\(provider.displayName) session reset",
                body: "Tide's turned. Full passage restored.",
                notificationSoundEnabled: true,
                playsAlertSound: false)
        case let .warningThresholdCrossed(window, threshold, currentRemaining, resetsAt):
            Delivery(
                idPrefix: "quota-warning-\(provider.rawValue)-\(window.rawValue)-\(threshold)",
                title: "\(provider.displayName) \(Self.warningTitleSuffix(window))",
                body: Self.thresholdBody(
                    currentRemaining: currentRemaining,
                    noun: Self.windowNoun(window),
                    flavour: Self.warningFlavour(window),
                    resetsAt: resetsAt,
                    now: now),
                notificationSoundEnabled: false,
                playsAlertSound: soundEnabled)
        case let .namedWindowThresholdCrossed(title, threshold, currentRemaining, resetsAt):
            // Named extra windows carry their own title; no flavour line, the allowance name is enough.
            Delivery(
                idPrefix: "quota-warning-\(provider.rawValue)-\(Self.slug(title))-\(threshold)",
                title: "\(provider.displayName) \(title) limit nearing",
                body: Self.thresholdBody(
                    currentRemaining: currentRemaining,
                    noun: "\(title) allowance",
                    flavour: nil,
                    resetsAt: resetsAt,
                    now: now),
                notificationSoundEnabled: false,
                playsAlertSound: soundEnabled)
        }
    }

    private static func depletedBody(resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else {
            return "Hard aground. You'll get word when the session resets."
        }
        return "Hard aground. Resets \(UsageFormatter.resetDescription(from: resetsAt, now: now)); "
            + "you'll get word."
    }

    private static func thresholdBody(
        currentRemaining: Double,
        noun: String,
        flavour: String?,
        resetsAt: Date?,
        now: Date) -> String
    {
        var body = "\(Self.percentText(currentRemaining)) of the \(noun) remains"
        if let resetsAt {
            body += "; resets \(UsageFormatter.resetDescription(from: resetsAt, now: now))"
        }
        body += "."
        if let flavour {
            body += " \(flavour)"
        }
        return body
    }

    private static func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static func warningTitleSuffix(_ window: QuotaWindow) -> String {
        switch window {
        case .session: "session running low"
        case .weekly: "weekly limit nearing"
        }
    }

    private static func warningFlavour(_ window: QuotaWindow) -> String {
        switch window {
        case .session: "Shoaling water ahead."
        case .weekly: "The week's drawing in."
        }
    }

    private static func windowNoun(_ window: QuotaWindow) -> String {
        switch window {
        case .session: "session"
        case .weekly: "week"
        }
    }

    func post(_ crossing: QuotaCrossing, provider: UsageProviderKind, soundEnabled: Bool) {
        let delivery = Self.delivery(for: crossing, provider: provider, soundEnabled: soundEnabled)
        self.logger.info("enqueuing", metadata: ["prefix": delivery.idPrefix])
        if delivery.playsAlertSound {
            (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
        }
        AppNotifications.shared.post(
            idPrefix: delivery.idPrefix,
            title: delivery.title,
            body: delivery.body,
            soundEnabled: delivery.notificationSoundEnabled)
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(min(100, max(0, value)).rounded()))%"
    }
}
