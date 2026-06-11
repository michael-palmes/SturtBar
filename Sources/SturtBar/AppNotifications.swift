// AppNotifications.swift — UNUserNotificationCenter wrapper.
//
// Ported from legacy CodexBar/AppNotifications.swift (Phase 3b). Changes vs legacy:
//   - Identifier prefix `codexbar-` → `sturtbar-`, and the per-post UUID suffix is GONE: the
//     identifier is now exactly `sturtbar-<idPrefix>`, so re-posting the same kind of
//     notification REPLACES the previous one in Notification Center instead of stacking
//     (dedup-by-replace; the 3a review flagged legacy's startup-depleted stacking).
//   - Authorization is requested lazily on the FIRST notification attempt (legacy additionally
//     called `requestAuthorizationOnStartup()` from the app delegate at launch — dropped; the
//     `requestAuthorizationIfNeeded()` entry point remains for the Phase 4 notification-settings
//     toggle to call when the user opts in).
//   - The `isRunningUnderTests` bundle guard is kept verbatim: UNUserNotificationCenter requires
//     a real app bundle, and both `swift test` and `swift run` execute without one. Tests must
//     never touch the center — they cover the request-building layer (QuotaNotifications).

import Foundation
import SturtBarCore
@preconcurrency import UserNotifications

@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private let centerProvider: @Sendable () -> UNUserNotificationCenter
    private let logger = SturtBarLog.logger("notifications")
    private var authorizationTask: Task<Bool, Never>?

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
    }

    /// Requests authorization if not yet determined. Safe to call from the notification-settings
    /// toggle; never called at launch.
    func requestAuthorizationIfNeeded() {
        guard !Self.isRunningUnderTests else { return }
        _ = self.ensureAuthorizationTask()
    }

    func post(
        idPrefix: String,
        title: String,
        body: String,
        badge: NSNumber? = nil,
        soundEnabled: Bool = true)
    {
        guard !Self.isRunningUnderTests else { return }
        let center = self.centerProvider()
        let logger = self.logger

        Task { @MainActor in
            let granted = await self.ensureAuthorized()
            guard granted else {
                logger.debug("not authorized; skipping post", metadata: ["prefix": idPrefix])
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = soundEnabled ? .default : nil
            content.badge = badge

            // Stable identifier: same-prefix posts replace the previous delivery (dedup).
            let request = UNNotificationRequest(
                identifier: "sturtbar-\(idPrefix)",
                content: content,
                trigger: nil)

            logger.info("posting", metadata: ["prefix": idPrefix])
            do {
                try await center.add(request)
            } catch {
                let errorText = String(describing: error)
                logger.error("failed to post", metadata: ["prefix": idPrefix, "error": errorText])
            }
        }
    }

    // MARK: - Private

    private func ensureAuthorizationTask() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let task = Task { @MainActor in
            await self.requestAuthorization()
        }
        self.authorizationTask = task
        return task
    }

    private func ensureAuthorized() async -> Bool {
        await self.ensureAuthorizationTask().value
    }

    private func requestAuthorization() async -> Bool {
        if let existing = await self.notificationAuthorizationStatus() {
            if existing == .authorized || existing == .provisional {
                return true
            }
            if existing == .denied {
                return false
            }
        }

        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func notificationAuthorizationStatus() async -> UNAuthorizationStatus? {
        let center = self.centerProvider()
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static var isRunningUnderTests: Bool {
        // Swift Testing doesn't always set XCTest env vars, and removing XCTest imports from
        // the test target can make NSClassFromString("XCTestCase") return nil. If we're not
        // running inside an app bundle, treat it as "tests/headless" to avoid crashes when
        // accessing UNUserNotificationCenter.
        if Bundle.main.bundleURL.pathExtension != "app" { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
}
