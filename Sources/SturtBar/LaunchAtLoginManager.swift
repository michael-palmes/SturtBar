// LaunchAtLoginManager.swift — SMAppService-backed login item (Phase 4b).
//
// Ported from legacy CodexBar/LaunchAtLoginManager.swift, trimmed to essentials. The system is
// the source of truth (no UserDefaults mirror): `isEnabled` reads SMAppService status directly,
// so drift via System Settings is impossible. Under `swift run` (no app bundle) `register()`
// throws — the settings toggle reads the state back after every set, so it snaps to reality.

import AppKit
import ServiceManagement
import SturtBarCore

enum LaunchAtLoginManager {
    private static let log = SturtBarLog.logger("launch-at-login")

    static var isEnabled: Bool {
        guard !ProcessEnvironment.isRunningTests else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        guard !ProcessEnvironment.isRunningTests else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Expected when running outside a bundle (`swift run`); harmless otherwise.
            Self.log.error("Failed to update login item: \(error.localizedDescription)")
        }
    }
}
