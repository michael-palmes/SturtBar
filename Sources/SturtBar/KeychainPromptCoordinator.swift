// KeychainPromptCoordinator.swift — explains the upcoming OS keychain prompt before it appears.
//
// Ported from legacy CodexBar/KeychainPromptCoordinator.swift, trimmed to the Claude OAuth case
// (the browser-cookie handler and the 14 other provider token messages are gone with their
// providers). `L(...)` localization → literals; CodexBar copy → SturtBar.
//
// How it fires: SturtBarCore's credentials store preflights the Claude Code keychain entry
// (KeychainAccessPreflight) and calls `KeychainPromptHandler.notify` ONLY when the very next read
// would trigger the OS keychain dialog AND the core prompt-policy gates allow prompting at all
// (user-initiated flows / the one-time startup bootstrap). The coordinator is purely the UX
// layer: it never decides WHETHER to prompt, it only shows the explainer first.
//
// Blocking is intentional: `notify` is called synchronously immediately before the keychain read,
// so the handler must not return until the user dismisses the alert — otherwise the OS prompt
// would race ahead of the explanation. Handler closures are `@Sendable` and arrive from the
// usage-fetch actor (off the main thread); `DispatchQueue.main.sync` parks that cooperative
// thread until the alert closes, exactly like legacy. The NSLock serializes overlapping notifies.

import AppKit
import SturtBarCore

enum KeychainPromptCoordinator {
    private static let promptLock = NSLock()
    private static let log = SturtBarLog.logger("keychain-prompt")

    // Canonical trust moment per BRAND.md §3.3; sentence case per §4.3, the claim stays plain.
    private static let title = "Keychain access required"
    private static let claudeOAuthMessage =
        "SturtBar will ask macOS Keychain for the Claude Code OAuth token " +
        "so it can fetch your Claude usage. It reads the token; it never changes it. " +
        "Click OK to continue."

    static func install() {
        KeychainPromptHandler.handler = { context in
            self.presentKeychainPrompt(context)
        }
    }

    private static func presentKeychainPrompt(_ context: KeychainPromptContext) {
        self.log.info("Keychain prompt requested", metadata: ["kind": "\(context.kind)"])
        switch context.kind {
        case .claudeOAuth:
            self.presentAlert(title: self.title, message: self.claudeOAuthMessage)
        }
    }

    private static func presentAlert(title: String, message: String) {
        self.promptLock.lock()
        defer { self.promptLock.unlock() }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.showAlert(title: title, message: message)
            }
            return
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.showAlert(title: title, message: message)
            }
        }
    }

    @MainActor
    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}
