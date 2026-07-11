// QuotaNotifications.swift — maps QuotaCrossing events to user notifications.
//
// Ported from legacy CodexBar/SessionQuotaNotifications.swift (the delivery layer; the pure
// transition logic moved to QuotaWarnings.swift in Phase 3a). Changes vs legacy:
//   - Copy rewritten as Notices to Mariners in the Keeper's voice (BRAND.md §3.3). With
//     multi-provider parity (decision 15) the provider name opens the BODY as functional
//     disambiguation (titles stay flavour-only), and dedup id prefixes are provider-scoped
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

    /// Notices to Mariners (BRAND.md §3.3): the Keeper signals only when it matters, in the
    /// station's dry maritime register. Titles stay provider-free flavour copy; the provider
    /// name opens the body as FUNCTIONAL disambiguation (decision 15: with two coasts tracked,
    /// "which one ran aground" is information, not flavour). Dedup ids are provider-scoped so a
    /// Claude notice never replaces a Codex one.
    static func delivery(
        for crossing: QuotaCrossing,
        provider: UsageProviderKind,
        soundEnabled: Bool) -> Delivery
    {
        switch crossing {
        case .sessionDepleted:
            Delivery(
                idPrefix: "\(provider.rawValue)-session-depleted",
                title: "Notice to Mariners: aground",
                body: "\(provider.displayName): session spent. "
                    + "Nothing in or out until it refloats; you'll get word when it does.",
                notificationSoundEnabled: true,
                playsAlertSound: false)
        case .sessionRestored:
            Delivery(
                idPrefix: "\(provider.rawValue)-session-restored",
                title: "Notice to Mariners: tide's turned",
                body: "\(provider.displayName): session refloated. Full passage restored.",
                notificationSoundEnabled: true,
                playsAlertSound: false)
        case let .warningThresholdCrossed(window, threshold, currentRemaining):
            Delivery(
                idPrefix: "quota-warning-\(provider.rawValue)-\(window.rawValue)-\(threshold)",
                title: Self.warningTitle(window),
                body: "\(provider.displayName): \(Self.percentText(currentRemaining)) "
                    + "of the \(Self.windowNoun(window)) remains.",
                notificationSoundEnabled: false,
                playsAlertSound: soundEnabled)
        case let .namedWindowThresholdCrossed(title, threshold, currentRemaining):
            // Named extra windows ride the weekly flavour; the title is functional disambiguation.
            Delivery(
                idPrefix: "quota-warning-\(provider.rawValue)-\(Self.slug(title))-\(threshold)",
                title: Self.warningTitle(.weekly),
                body: "\(provider.displayName): \(Self.percentText(currentRemaining)) "
                    + "of the \(title) allowance remains.",
                notificationSoundEnabled: false,
                playsAlertSound: soundEnabled)
        }
    }

    private static func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static func warningTitle(_ window: QuotaWindow) -> String {
        switch window {
        case .session: "Notice to Mariners: shoaling water"
        case .weekly: "Notice to Mariners: the week's drawing in"
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
