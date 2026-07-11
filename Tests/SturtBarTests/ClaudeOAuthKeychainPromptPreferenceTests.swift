import Foundation
import Testing
@testable import SturtBarCore

/// The stored prompt mode is the opt-in switch for Keychain prompts: unset means never.
struct ClaudeOAuthKeychainPromptPreferenceTests {
    private func makeSuite() -> (defaults: UserDefaults, teardown: () -> Void) {
        let name = "sturtbar-prompt-mode-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test
    func `stored mode defaults to never on a fresh suite`() {
        let (defaults, teardown) = self.makeSuite()
        defer { teardown() }
        #expect(ClaudeOAuthKeychainPromptPreference.storedMode(userDefaults: defaults) == .never)
    }

    @Test
    func `setStoredMode round-trips every mode and nil removes`() {
        let (defaults, teardown) = self.makeSuite()
        defer { teardown() }

        for mode in ClaudeOAuthKeychainPromptMode.allCases {
            ClaudeOAuthKeychainPromptPreference.setStoredMode(mode, userDefaults: defaults)
            #expect(ClaudeOAuthKeychainPromptPreference.storedMode(userDefaults: defaults) == mode)
        }

        ClaudeOAuthKeychainPromptPreference.setStoredMode(nil, userDefaults: defaults)
        #expect(defaults.string(forKey: "claudeOAuthKeychainPromptMode") == nil)
        #expect(ClaudeOAuthKeychainPromptPreference.storedMode(userDefaults: defaults) == .never)
    }

    @Test
    func `fallback mode returns the stored mode under the shipped CLI strategy`() {
        let (defaults, teardown) = self.makeSuite()
        defer { teardown() }

        // The shipped strategy hardcodes current() to .always, so the stored mode reaches behaviour via the fallback
        // accessor.
        ClaudeOAuthKeychainPromptPreference.setStoredMode(.never, userDefaults: defaults)
        ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityCLIExperimental) {
            #expect(
                ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode(
                    userDefaults: defaults) == .never)
            #expect(ClaudeOAuthKeychainPromptPreference.current(userDefaults: defaults) == .always)
        }
    }
}
