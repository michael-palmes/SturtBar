import Foundation
import Testing
@testable import SturtBarCore

struct ClaudeFreshCredentialReaderTests {
    private let credentials = Data("""
    {"claudeAiOauth":{"accessToken":"current-token","scopes":["user:profile"]}}
    """.utf8)

    @Test(arguments: [Interaction.background, .userInitiated])
    func `fresh credentials use the preferred reader with permission fallback off`(interaction: Interaction) throws {
        try self.withPreferredReader(interaction: interaction) {
            try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(self.credentials)) {
                let record = try ClaudeOAuthCredentialsStore.loadFreshRecord(includeFile: false, allowPrompt: false)
                #expect(record.credentials.accessToken == "current-token")
                #expect(record.cacheData == self.credentials)
                #expect(record.source == .claudeKeychain)
            }
        }
    }

    @Test(arguments: [Interaction.background, .userInitiated])
    func `failed preferred reads do not enable the permission fallback`(interaction: Interaction) {
        self.withPreferredReader(interaction: interaction) {
            ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.timedOut) {
                #expect(throws: ClaudeOAuthCredentialsError.self) {
                    try ClaudeOAuthCredentialsStore.loadFreshRecord(includeFile: false, allowPrompt: false)
                }
                #expect(ClaudeOAuthKeychainPromptPreference.storedMode() == .never)
            }
        }
    }

    private func withPreferredReader(interaction: Interaction, operation: () throws -> Void) rethrows {
        try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
            try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityCLIExperimental) {
                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    try InteractionContext.$current.withValue(interaction) {
                        try ClaudeOAuthCredentialsStore.withSecurityCLIReadAccountOverrideForTesting("fixture") {
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: Data("""
                                {"claudeAiOauth":{"accessToken":"fallback-token","scopes":["user:profile"]}}
                                """.utf8),
                                fingerprint: nil,
                                operation: operation)
                        }
                    }
                }
            }
        }
    }
}
