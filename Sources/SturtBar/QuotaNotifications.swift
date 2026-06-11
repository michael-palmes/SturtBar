// QuotaNotifications.swift — maps QuotaCrossing events to user notifications.
//
// Ported from legacy CodexBar/SessionQuotaNotifications.swift (the delivery layer; the pure
// transition logic moved to QuotaWarnings.swift in Phase 3a). Changes vs legacy:
//   - Copy rewritten as Notices to Mariners in the Keeper's voice (BRAND.md §3.3): no provider
//     name in this flavour copy. The provider segment is also dropped from the dedup id prefixes
//     (`session-claude-depleted` → `session-depleted`).
//   - `accountDisplayName` body variant dropped: `ClaudeUsageSnapshot` carries no account
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
    struct Delivery: Equatable, Sendable {
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
    /// station's dry maritime register. Provider names are dropped from this flavour copy (the
    /// user knows which coast they sail); numbers stay exact and prominent.
    static func delivery(for crossing: QuotaCrossing, soundEnabled: Bool) -> Delivery {
        switch crossing {
        case .sessionDepleted:
            Delivery(
                idPrefix: "session-depleted",
                title: "Notice to Mariners: aground",
                body: "Session spent. Nothing in or out until it refloats; you'll get word when it does.",
                notificationSoundEnabled: true,
                playsAlertSound: false)
        case .sessionRestored:
            Delivery(
                idPrefix: "session-restored",
                title: "Notice to Mariners: tide's turned",
                body: "Session refloated. Full passage restored.",
                notificationSoundEnabled: true,
                playsAlertSound: false)
        case let .warningThresholdCrossed(window, threshold, currentRemaining):
            Delivery(
                idPrefix: "quota-warning-\(window.rawValue)-\(threshold)",
                title: Self.warningTitle(window),
                body: "\(Self.percentText(currentRemaining)) of the \(Self.windowNoun(window)) remains.",
                notificationSoundEnabled: false,
                playsAlertSound: soundEnabled)
        }
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

    func post(_ crossing: QuotaCrossing, soundEnabled: Bool) {
        let delivery = Self.delivery(for: crossing, soundEnabled: soundEnabled)
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
