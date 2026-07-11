// KeychainPromptCoordinator.swift — explains the upcoming OS keychain prompt before it appears.
//
// Ported from legacy CodexBar/KeychainPromptCoordinator.swift, trimmed to the Claude OAuth case
// (the browser-cookie handler and the 14 other provider token messages are gone with their
// providers). `L(...)` localization → literals; CodexBar copy → SturtBar.
//
// How it fires: SturtBarCore's credentials store preflights the Claude Code keychain entry
// (KeychainAccessPreflight) and calls `KeychainPromptHandler.requestApproval` ONLY when the very
// next read would trigger the OS keychain dialog AND the core prompt-policy gates allow prompting
// at all (user-initiated flows / the one-time startup bootstrap). The coordinator is purely the UX
// layer: it never decides WHETHER a prompt is warranted, it shows the explainer first and returns
// the user's decision. "Not now" means the core skips the OS dialog entirely for this read (and
// records no denial cooldown), so declining here is never punished.
//
// Blocking is intentional: `requestApproval` is called synchronously immediately before the
// keychain read, so the handler must not return until the user dismisses the alert, otherwise
// the OS prompt would race ahead of the explanation. Handler closures are `@Sendable` and arrive
// from the usage-fetch actor (off the main thread); `DispatchQueue.main.sync` parks that
// cooperative thread until the alert closes, exactly like legacy. The NSLock serializes
// overlapping requests.

import AppKit
import SturtBarCore
import Synchronization

enum KeychainPromptCoordinator {
    private static let promptLock = NSLock()
    private static let log = SturtBarLog.logger("keychain-prompt")

    // Lets one prompted read after the opt-in Continue auto-proceed, so the same explainer is not shown twice.
    private static let recentConsentAt = Mutex<Date?>(nil)
    static let consentGraceInterval: TimeInterval = 60

    static func registerRecentConsent(now: Date = Date()) {
        self.recentConsentAt.withLock { $0 = now }
    }

    /// One-shot: consumes a grace-interval consent so only the immediate follow-up read skips the explainer.
    static func consumeRecentConsent(now: Date = Date()) -> Bool {
        self.recentConsentAt.withLock { last in
            defer { last = nil }
            guard let stamp = last else { return false }
            return now.timeIntervalSince(stamp) <= self.consentGraceInterval
        }
    }

    // Canonical trust moment per BRAND.md §3.3; sentence case per §4.3, the claim stays plain.
    private static let title = "Keychain access required"
    private static let claudeOAuthMessage =
        "Claude Code stores its sign-in token in the macOS Keychain. SturtBar is about to ask " +
        "macOS for read access to that item so it can fetch your Claude usage and limits.\n\n" +
        "If you continue, macOS will show its own Keychain dialog. Choose Always Allow to grant " +
        "ongoing read access, or Deny to refuse. If Claude Code signs in again later, macOS will " +
        "ask again.\n\n" +
        "SturtBar only reads the token and uses it with Anthropic's API to fetch usage and " +
        "refresh the token. It keeps its own refreshed copy in SturtBar's own Keychain item. " +
        "It never changes Claude Code's sign-in and never sends the token anywhere else."
    private static let continueButtonTitle = "Continue"
    private static let notNowButtonTitle = "Not now"

    static func install() {
        KeychainPromptHandler.handler = { context in
            self.presentKeychainPrompt(context)
        }
    }

    /// Opt-in consent for the card's reconnect line: the explainer plus a note that Continue enables the setting.
    @MainActor
    static func presentClaudeKeychainOptIn() -> KeychainPromptDecision {
        self.showAlert(
            title: self.title,
            message: self.claudeOAuthMessage + "\n\n"
                + "Continuing also turns on \"Ask for Keychain access when needed\" in "
                + "SturtBar's settings; you can turn it off again at any time.")
    }

    private static func presentKeychainPrompt(_ context: KeychainPromptContext) -> KeychainPromptDecision {
        self.log.info("Keychain prompt requested", metadata: ["kind": "\(context.kind)"])
        switch context.kind {
        case .claudeOAuth:
            if self.consumeRecentConsent() {
                self.log.info("Keychain pre-prompt skipped: consent given at the opt-in alert")
                return .proceed
            }
            let decision = self.presentAlert(title: self.title, message: self.claudeOAuthMessage)
            self.log.info(
                "Keychain pre-prompt decision",
                metadata: ["kind": "\(context.kind)", "decision": decision == .proceed ? "proceed" : "notNow"])
            return decision
        }
    }

    private static func presentAlert(title: String, message: String) -> KeychainPromptDecision {
        self.promptLock.lock()
        defer { self.promptLock.unlock() }

        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                self.showAlert(title: title, message: message)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.showAlert(title: title, message: message)
            }
        }
    }

    @MainActor
    private static func showAlert(title: String, message: String) -> KeychainPromptDecision {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: self.continueButtonTitle)
        alert.addButton(withTitle: self.notNowButtonTitle)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .proceed : .notNow
    }
}
