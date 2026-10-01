import Foundation
import Testing
@testable import SturtBarCore

/// A stored reader value the app does not recognise must not switch off the shipped /usr/bin/security reader.
struct ClaudeOAuthKeychainReadStrategyPreferenceTests {
    private static let userDefaultsKey = "claudeOAuthKeychainReadStrategy"

    private func makeSuite() -> (defaults: UserDefaults, teardown: () -> Void) {
        let name = "sturtbar-read-strategy-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test(arguments: ["bogus", "SecurityFramework", ""])
    func `unknown stored reader falls back to the security CLI default`(raw: String) {
        let (defaults, teardown) = self.makeSuite()
        defer { teardown() }
        defaults.set(raw, forKey: Self.userDefaultsKey)

        #expect(ClaudeOAuthKeychainReadStrategyPreference.current(userDefaults: defaults) == .securityCLIExperimental)
    }

    @Test(arguments: ClaudeOAuthKeychainReadStrategy.allCases)
    func `known stored reader is honoured`(strategy: ClaudeOAuthKeychainReadStrategy) {
        let (defaults, teardown) = self.makeSuite()
        defer { teardown() }
        defaults.set(strategy.rawValue, forKey: Self.userDefaultsKey)

        #expect(ClaudeOAuthKeychainReadStrategyPreference.current(userDefaults: defaults) == strategy)
    }
}
