import Foundation
import Security
import Synchronization
import Testing
@testable import SturtBarCore

/// The prompt mode governs reads that can show the macOS dialog, never silent no-UI reads.
@Suite(.serialized)
struct ClaudeOAuthSilentKeychainReadTests {
    private func gate(
        _ mode: ClaudeOAuthKeychainPromptMode,
        prompt: Bool,
        interaction: Interaction,
        bootstrap: Bool,
        keychainDisabled: Bool = false) -> Bool
    {
        ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(keychainDisabled) {
            InteractionContext.$current.withValue(interaction) {
                ClaudeOAuthCredentialsStore.$allowBackgroundPromptBootstrap.withValue(bootstrap) {
                    ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                        mode: mode,
                        allowKeychainPrompt: prompt)
                }
            }
        }
    }

    private func makeCredentialsData(accessToken: String) -> Data {
        let millis = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """
        return Data(json.utf8)
    }

    /// Isolated caches, no credentials file and a stubbed Claude Code item: nothing reaches the real keychain.
    private func withStubbedClaudeKeychain<T>(data: Data, operation: () throws -> T) throws -> T {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let keychain = ClaudeOAuthCredentialsStore.ClaudeKeychainOverrideStore(
            data: data,
            fingerprint: .init(modifiedAt: 1, createdAt: 1, persistentRefHash: "ref1"))
        let preflightAllowed: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in .allowed }

        return try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                return try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        try ClaudeOAuthCredentialsStore.withClaudeKeychainFingerprintStoreOverrideForTesting(.init()) {
                            try ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(keychain) {
                                try ClaudeOAuthKeychainAccessGate.withShouldAllowPromptOverrideForTesting(true) {
                                    try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                        preflightAllowed)
                                    {
                                        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                                            tempDir.appendingPathComponent("credentials.json"))
                                        {
                                            try operation()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func expectKeychainAccessRequired(
        _ operation: () throws -> ClaudeOAuthCredentialRecord,
        reason expected: ClaudeKeychainAccessRequiredReason)
    {
        do {
            let record = try operation()
            Issue.record("Expected .claudeKeychainAccessRequired, got a record from \(record.source)")
        } catch let error as ClaudeOAuthCredentialsError {
            guard case let .claudeKeychainAccessRequired(_, reason) = error, reason == expected else {
                Issue.record("Expected .claudeKeychainAccessRequired(\(expected)), got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test(arguments: [Interaction.background, .userInitiated], [false, true])
    func `never allows silent reads and blocks every prompt`(interaction: Interaction, bootstrap: Bool) {
        #expect(self.gate(.never, prompt: false, interaction: interaction, bootstrap: bootstrap))
        #expect(!self.gate(.never, prompt: true, interaction: interaction, bootstrap: bootstrap))
    }

    @Test(arguments: [Interaction.background, .userInitiated], [false, true])
    func `only on user action allows silent reads and prompts only on a user action or bootstrap`(
        interaction: Interaction,
        bootstrap: Bool)
    {
        #expect(self.gate(.onlyOnUserAction, prompt: false, interaction: interaction, bootstrap: bootstrap))
        let canPrompt = interaction == .userInitiated || bootstrap
        #expect(self.gate(.onlyOnUserAction, prompt: true, interaction: interaction, bootstrap: bootstrap) == canPrompt)
    }

    @Test(arguments: [Interaction.background, .userInitiated], [false, true])
    func `always allows silent reads and prompts`(interaction: Interaction, bootstrap: Bool) {
        #expect(self.gate(.always, prompt: false, interaction: interaction, bootstrap: bootstrap))
        #expect(self.gate(.always, prompt: true, interaction: interaction, bootstrap: bootstrap))
    }

    @Test(arguments: ClaudeOAuthKeychainPromptMode.allCases, [false, true])
    func `disabled keychain access blocks silent reads and prompts`(mode: ClaudeOAuthKeychainPromptMode, prompt: Bool) {
        #expect(!self.gate(mode, prompt: prompt, interaction: .userInitiated, bootstrap: true, keychainDisabled: true))
    }

    @Test(arguments: [ClaudeOAuthKeychainPromptMode.never, .onlyOnUserAction])
    func `prompt opt-out no longer blocks no-UI reads under the Security.framework reader`(
        mode: ClaudeOAuthKeychainPromptMode) throws
    {
        let data = self.makeCredentialsData(accessToken: "silent-token")
        let record = try self.withStubbedClaudeKeychain(data: data) {
            try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
                    try InteractionContext.$current.withValue(.background) {
                        try ClaudeOAuthCredentialsStore.loadRecord(environment: [:], allowKeychainPrompt: false)
                    }
                }
            }
        }

        #expect(record.credentials.accessToken == "silent-token")
        #expect(record.source == .claudeKeychain)
    }

    @Test
    func `silent token reads suppress the legacy keychain dialog and prompt reads do not`() {
        let reads = Mutex<[String]>([])
        let copy: @Sendable ([String: Any]) -> (status: OSStatus, result: AnyObject?) = { query in
            let legacyUI = KeychainNoUIQuery.legacyKeychainUIAllowedForTesting().map(String.init) ?? "unknown"
            let noUIFlags = query[kSecUseAuthenticationUI as String] != nil
            reads.withLock { $0.append("legacyUI=\(legacyUI) noUIFlags=\(noUIFlags)") }
            return (errSecItemNotFound, nil)
        }

        ClaudeOAuthCredentialsStore.$taskClaudeKeychainDataCopyOverride.withValue(copy) {
            _ = ClaudeOAuthCredentialsStore.copyClaudeKeychainData([:], allowKeychainPrompt: false)
            _ = ClaudeOAuthCredentialsStore.copyClaudeKeychainData([:], allowKeychainPrompt: true)
        }

        #expect(reads.withLock { $0 } == ["legacyUI=false noUIFlags=true", "legacyUI=true noUIFlags=false"])
        #expect(KeychainNoUIQuery.legacyKeychainUIAllowedForTesting() == true)
    }

    @Test
    func `never mode blocks the prompt path even on a user action`() throws {
        let data = self.makeCredentialsData(accessToken: "prompt-token")
        let preAlerts = Mutex(0)
        let handler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
            preAlerts.withLock { $0 += 1 }
            return .proceed
        }

        try self.withStubbedClaudeKeychain(data: data) {
            KeychainPromptHandler.withHandlerForTesting(handler) {
                ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                    ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                        InteractionContext.$current.withValue(.userInitiated) {
                            self.expectKeychainAccessRequired({
                                try ClaudeOAuthCredentialsStore.loadRecord(environment: [:], allowKeychainPrompt: true)
                            }, reason: .promptsDisabled)
                        }
                    }
                }
            }
        }

        #expect(preAlerts.withLock { $0 } == 0)
    }

    @Test(arguments: [ClaudeOAuthKeychainPromptMode.never, .onlyOnUserAction])
    func `prompt opt-out keeps the Security.framework fallback closed behind the security CLI reader`(
        mode: ClaudeOAuthKeychainPromptMode) throws
    {
        let data = self.makeCredentialsData(accessToken: "fallback-should-stay-closed")
        let expected: ClaudeKeychainAccessRequiredReason = mode == .never ? .promptsDisabled : .accessLost

        try self.withStubbedClaudeKeychain(data: data) {
            ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityCLIExperimental) {
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(mode) {
                    InteractionContext.$current.withValue(.background) {
                        ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.nonZeroExit) {
                            self.expectKeychainAccessRequired({
                                try ClaudeOAuthCredentialsStore.loadRecord(environment: [:], allowKeychainPrompt: false)
                            }, reason: expected)
                        }
                    }
                }
            }
        }
    }
}
