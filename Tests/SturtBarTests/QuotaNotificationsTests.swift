// QuotaNotificationsTests.swift — quota notification delivery layer (Phase 3b).
//
// Ports the remaining legacy QuotaWarningNotificationLogicTests / SessionQuotaNotificationLogicTests
// cases the 3a port left behind, updated for multi-provider parity (decision 15): dedup ids are
// provider-scoped and the provider opens the title as the plain statement of what happened.
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
import SturtBarCore
import Testing
@testable import SturtBar

@MainActor
struct QuotaNotificationsTests {
    /// Fixed clock for reset-time copy; formatted output goes through the same formatter the
    /// popover uses, so expectations interpolate it rather than hard-coding a timezone.
    private static let now = Date(timeIntervalSince1970: 1_000_000_000)
    private static let resetsAt = Date(timeIntervalSince1970: 1_000_000_000 + 3 * 3600)
    private static var resetText: String {
        UsageFormatter.resetDescription(from: self.resetsAt, now: self.now)
    }

    // MARK: - Copy (plain provider titles, data-first bodies)

    @Test
    func `quota warning copy leads with provider and current remaining`() {
        let delivery = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 12.4, resetsAt: nil),
            provider: .claude,
            soundEnabled: true)

        #expect(delivery.title == "Claude session running low")
        #expect(delivery.body == "12% of the session remains. Shoaling water ahead.")
    }

    @Test
    func `quota warning copy includes the reset time when the window carries one`() {
        let delivery = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(
                window: .session,
                threshold: 20,
                currentRemaining: 12.4,
                resetsAt: Self.resetsAt),
            provider: .claude,
            soundEnabled: true,
            now: Self.now)

        #expect(delivery.body == "12% of the session remains; resets \(Self.resetText). Shoaling water ahead.")
    }

    @Test
    func `quota warning copy clamps current remaining`() {
        let delivery = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .weekly, threshold: 50, currentRemaining: -3, resetsAt: nil),
            provider: .codex,
            soundEnabled: true)

        #expect(delivery.title == "Codex weekly limit nearing")
        #expect(delivery.body == "0% of the week remains. The week's drawing in.")
    }

    @Test
    func `session depleted copy names the provider and states the reset`() {
        let claude = QuotaNotifier.delivery(
            for: .sessionDepleted(resetsAt: Self.resetsAt),
            provider: .claude,
            soundEnabled: true,
            now: Self.now)
        #expect(claude.title == "Claude session limit reached")
        #expect(claude.body == "Hard aground. Resets \(Self.resetText); you'll get word.")

        let codex = QuotaNotifier.delivery(for: .sessionDepleted(resetsAt: nil), provider: .codex, soundEnabled: true)
        #expect(codex.title == "Codex session limit reached")
        #expect(codex.body == "Hard aground. You'll get word when the session resets.")
    }

    @Test
    func `session restored copy names the provider`() {
        let delivery = QuotaNotifier.delivery(for: .sessionRestored, provider: .claude, soundEnabled: true)
        #expect(delivery.title == "Claude session reset")
        #expect(delivery.body == "Tide's turned. Full passage restored.")
    }

    // MARK: - Dedup id prefixes (provider-scoped: same kind replaces per provider, never across)

    @Test
    func `id prefixes are stable and provider-scoped`() {
        #expect(
            QuotaNotifier.delivery(for: .sessionDepleted(resetsAt: nil), provider: .claude, soundEnabled: true)
                .idPrefix == "claude-session-depleted")
        #expect(
            QuotaNotifier.delivery(for: .sessionDepleted(resetsAt: nil), provider: .codex, soundEnabled: true)
                .idPrefix == "codex-session-depleted")
        #expect(
            QuotaNotifier.delivery(for: .sessionRestored, provider: .claude, soundEnabled: true)
                .idPrefix == "claude-session-restored")
        #expect(
            QuotaNotifier.delivery(
                for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 12, resetsAt: nil),
                provider: .claude,
                soundEnabled: true).idPrefix == "quota-warning-claude-session-20")
        #expect(
            QuotaNotifier.delivery(
                for: .warningThresholdCrossed(window: .weekly, threshold: 50, currentRemaining: 45, resetsAt: nil),
                provider: .codex,
                soundEnabled: true).idPrefix == "quota-warning-codex-weekly-50")
    }

    @Test
    func `id prefix does not vary with current remaining`() {
        let first = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 19, resetsAt: nil),
            provider: .claude,
            soundEnabled: true)
        let second = QuotaNotifier.delivery(
            for: .warningThresholdCrossed(window: .session, threshold: 20, currentRemaining: 3, resetsAt: nil),
            provider: .claude,
            soundEnabled: true)
        #expect(first.idPrefix == second.idPrefix)
    }

    // MARK: - Sound flag (legacy parity)

    @Test
    func `threshold warnings play the alert sound only when enabled and never the notification sound`() {
        let crossing = QuotaCrossing.warningThresholdCrossed(
            window: .session,
            threshold: 20,
            currentRemaining: 12,
            resetsAt: nil)

        let soundOn = QuotaNotifier.delivery(for: crossing, provider: .claude, soundEnabled: true)
        #expect(soundOn.playsAlertSound)
        #expect(!soundOn.notificationSoundEnabled) // legacy posted warnings with soundEnabled: false

        let soundOff = QuotaNotifier.delivery(for: crossing, provider: .claude, soundEnabled: false)
        #expect(!soundOff.playsAlertSound)
        #expect(!soundOff.notificationSoundEnabled)
    }

    @Test
    func `session transitions keep the default notification sound regardless of the warning toggle`() {
        for crossing in [QuotaCrossing.sessionDepleted(resetsAt: nil), .sessionRestored] {
            let delivery = QuotaNotifier.delivery(for: crossing, provider: .codex, soundEnabled: false)
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
