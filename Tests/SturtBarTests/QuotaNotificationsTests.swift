// QuotaNotificationsTests.swift — quota notification delivery layer (Phase 3b).
//
// Ports the remaining legacy QuotaWarningNotificationLogicTests / SessionQuotaNotificationLogicTests
// cases the 3a port left behind: the notification COPY assertions (with literal "Claude" instead
// of registry displayName lookups) plus the rebuild's dedup-id and sound-flag mapping.
//
// Dropped legacy cases, with rationale:
//   - "quota warning copy includes account when provided" + the hidePersonalInfo/account-name
//     variants: ProviderUsageSnapshot carries no account identity, so QuotaCrossing has no
//     accountDisplayName — the body variant is unreachable in the rebuild.
//   - zh-Hant/zh-Hans localization cases: the rebuild has English literals only.
//
// NO test touches UNUserNotificationCenter: only the pure `QuotaNotifier.delivery` layer is
// exercised (`AppNotifications.isRunningUnderTests` guards the real center; asserted below).

import Foundation
import Testing
@testable import SturtBar

@MainActor
struct QuotaNotificationsTests {
    // MARK: - Copy (legacy parity, "Claude" literal)

    @Test
    func `quota warning copy includes current remaining and threshold`() {
        let delivery = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 12.4),
            soundEnabled: true)

        #expect(delivery.title == "Notice to Mariners: shoaling water")
        #expect(delivery.body == "12% of the session remains.")
    }

    @Test
    func `quota warning copy clamps current remaining`() {
        let delivery = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .weekly, threshold: 50, currentRemaining: -3),
            soundEnabled: true)

        #expect(delivery.title == "Notice to Mariners: the week's drawing in")
        #expect(delivery.body == "0% of the week remains.")
    }

    @Test
    func `session depleted copy`() {
        let delivery = QuotaNotifier.delivery(for: .sessionDepleted, soundEnabled: true)
        #expect(delivery.title == "Notice to Mariners: aground")
        #expect(delivery.body == "Session spent. Nothing in or out until it refloats; you'll get word when it does.")
    }

    @Test
    func `session restored copy`() {
        let delivery = QuotaNotifier.delivery(for: .sessionRestored, soundEnabled: true)
        #expect(delivery.title == "Notice to Mariners: tide's turned")
        #expect(delivery.body == "Session refloated. Full passage restored.")
    }

    // MARK: - Dedup id prefixes (stable: same-kind posts replace, not stack)

    @Test
    func `id prefixes are stable per crossing kind`() {
        #expect(QuotaNotifier.delivery(for: .sessionDepleted, soundEnabled: true).idPrefix == "session-depleted")
        #expect(QuotaNotifier.delivery(for: .sessionRestored, soundEnabled: true).idPrefix == "session-restored")
        #expect(
            QuotaNotifier.delivery(
                for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 12),
                soundEnabled: true).idPrefix == "quota-warning-session-20")
        #expect(
            QuotaNotifier.delivery(
                for: .warningThresholdCrossed(window: .weekly, threshold: 50, currentRemaining: 45),
                soundEnabled: true).idPrefix == "quota-warning-weekly-50")
    }

    @Test
    func `id prefix does not vary with current remaining`() {
        let first = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 19),
            soundEnabled: true)
        let second = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 3),
            soundEnabled: true)
        #expect(first.idPrefix == second.idPrefix)
    }

    // MARK: - Sound flag (legacy parity)

    @Test
    func `threshold warnings play the alert sound only when enabled and never the notification sound`() {
        let crossing = QuotaCrossing.warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 12)

        let soundOn = QuotaNotifier.delivery(for: crossing, soundEnabled: true)
        #expect(soundOn.playsAlertSound)
        #expect(!soundOn.notificationSoundEnabled) // legacy posted warnings with soundEnabled: false

        let soundOff = QuotaNotifier.delivery(for: crossing, soundEnabled: false)
        #expect(!soundOff.playsAlertSound)
        #expect(!soundOff.notificationSoundEnabled)
    }

    @Test
    func `session transitions keep the default notification sound regardless of the warning toggle`() {
        for crossing in [QuotaCrossing.sessionDepleted, .sessionRestored] {
            let delivery = QuotaNotifier.delivery(for: crossing, soundEnabled: false)
            #expect(delivery.notificationSoundEnabled)
            #expect(!delivery.playsAlertSound)
        }
    }

    // MARK: - Test environment guard

    @Test
    func `notification center is guarded under tests`() {
        // The bundle guard must hold in this process, or QuotaNotifier.post / AppNotifications.post
        // would touch UNUserNotificationCenter without an app bundle and crash.
        #expect(AppNotifications.isRunningUnderTests)
    }
}
