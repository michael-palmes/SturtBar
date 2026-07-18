// UpdateConsentPrompt.swift: the one-time first-run ask for daily update checks.
//
// Follows the keychain explainer pattern: plain language, literal claims, either answer persists
// a decision so the ask never repeats. Undecided means the update lane stays fully inert.

import AppKit
import SturtBarCore

enum UpdateConsentPrompt {
    /// Glanceable on purpose: one line for what it does, one bullet per safety claim.
    private static let message =
        "SturtBar asks GitHub once a day whether a newer release exists.\n\n" +
        "\u{2022} Sends no identifiers, nothing about your usage\n" +
        "\u{2022} GitHub sees only an ordinary web request\n" +
        "\u{2022} Nothing downloads or installs without your say-so\n\n" +
        "Change this any time in Settings."

    /// Shows once while the setting is undecided; called from the deferred launch task.
    @MainActor
    static func presentIfNeeded(settings: SettingsStore) {
        guard settings.updateChecksEnabled == nil else { return }
        guard !ProcessEnvironment.isRunningTests else { return }
        let alert = NSAlert()
        alert.messageText = "Check for updates daily?"
        alert.informativeText = self.message
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not now")
        NSApp.activate()
        settings.updateChecksEnabled = alert.runModal() == .alertFirstButtonReturn
    }
}
