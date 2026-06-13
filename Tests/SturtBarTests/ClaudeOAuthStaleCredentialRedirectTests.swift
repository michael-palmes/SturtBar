import Foundation
import Testing
@testable import SturtBarCore

/// Covers the recovery path for the "re-authenticated in Claude Code but SturtBar still asks to
/// re-authenticate" loop: when the only loadable credentials are stale and a Claude keychain item
/// exists that SturtBar cannot read silently, errors must redirect the user to grant Keychain
/// access instead of dead-ending on the stale record.
@Suite(.serialized)
struct ClaudeOAuthStaleCredentialRedirectTests {
    private func makeCredentialsData(
        accessToken: String,
        expiresAt: Date,
        refreshToken: String? = nil) -> Data
    {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let refreshField: String = {
            guard let refreshToken else { return "" }
            return ",\n            \"refreshToken\": \"\(refreshToken)\""
        }()
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]\(refreshField)
          }
        }
        """
        return Data(json.utf8)
    }

    private func withStaleFileHarness<T>(
        fileData: Data,
        keychainFingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?,
        operation: () throws -> T) throws -> T
    {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        return try InteractionContext.$current.withValue(.background) {
            try KeychainCacheStore.withServiceOverrideForTesting(service) {
                // Avoid touching the developer's real Claude keychain item: with access disabled,
                // item presence comes only from the explicit fingerprint override below (DEBUG
                // overrides are consulted before the access guard).
                try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                    KeychainCacheStore.setTestStoreForTesting(true)
                    defer { KeychainCacheStore.setTestStoreForTesting(false) }

                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }
                    return try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                            let tempDir = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                            let fileURL = tempDir.appendingPathComponent("credentials.json")
                            return try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                                try fileData.write(to: fileURL)
                                return try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                    .securityFramework)
                                {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                            data: nil,
                                            fingerprint: keychainFingerprint)
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

    @Test
    func `expired file without refresh token redirects to keychain access when claude keychain item exists`() throws {
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 200,
            createdAt: 200,
            persistentRefHash: "new-item")
        let staleFile = self.makeCredentialsData(
            accessToken: "stale",
            expiresAt: Date(timeIntervalSinceNow: -3600))

        try self.withStaleFileHarness(fileData: staleFile, keychainFingerprint: fingerprint) {
            do {
                _ = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case .claudeKeychainAccessRequired = error else {
                    Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                    return
                }
            }
        }
    }

    @Test
    func `expired file without refresh token is still returned when no claude keychain item exists`() throws {
        let staleFile = self.makeCredentialsData(
            accessToken: "stale",
            expiresAt: Date(timeIntervalSinceNow: -3600))

        try self.withStaleFileHarness(fileData: staleFile, keychainFingerprint: nil) {
            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: [:],
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true)
            #expect(record.credentials.accessToken == "stale")
            #expect(record.source == .credentialsFile)
        }
    }

    @Test
    func `expired file with refresh token is returned for refresh even when keychain item exists`() throws {
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 200,
            createdAt: 200,
            persistentRefHash: "new-item")
        let staleFile = self.makeCredentialsData(
            accessToken: "stale",
            expiresAt: Date(timeIntervalSinceNow: -3600),
            refreshToken: "refresh-1")

        try self.withStaleFileHarness(fileData: staleFile, keychainFingerprint: fingerprint) {
            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: [:],
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true)
            #expect(record.credentials.refreshToken == "refresh-1")
            #expect(record.source == .credentialsFile)
        }
    }

    /// Disables real Claude keychain access so item presence comes only from the fingerprint
    /// override (DEBUG overrides are consulted before the access guard).
    private func withIsolatedClaudeKeychain<T>(
        fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?,
        operation: () throws -> T) rethrows -> T
    {
        try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                data: nil,
                fingerprint: fingerprint)
            {
                try operation()
            }
        }
    }

    @Test
    func `terminal refresh failure redirects to keychain access when claude keychain item exists`() throws {
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 300,
            createdAt: 300,
            persistentRefHash: "new-item")
        try self.withIsolatedClaudeKeychain(fingerprint: fingerprint) {
            let original = ClaudeOAuthCredentialsError.refreshFailed(
                kind: .terminal,
                message: "HTTP 400 invalid_grant. Run `claude` to re-authenticate.")
            let redirected = ClaudeOAuthCredentialsStore.redirectTerminalRefreshFailureToKeychainAccessIfApplicable(
                original,
                recordSource: .credentialsFile)
            guard case let .claudeKeychainAccessRequired(underlying) = redirected else {
                Issue.record("Expected .claudeKeychainAccessRequired, got \(redirected)")
                return
            }
            #expect(underlying == "HTTP 400 invalid_grant. Run `claude` to re-authenticate.")
        }
    }

    @Test
    func `terminal refresh failure is unchanged without keychain item or for keychain-sourced records`() throws {
        let original = ClaudeOAuthCredentialsError.refreshFailed(
            kind: .terminal,
            message: "HTTP 400 invalid_grant.")

        // No Claude keychain item visible → keep the original error.
        try self.withIsolatedClaudeKeychain(fingerprint: nil) {
            let unchanged = ClaudeOAuthCredentialsStore.redirectTerminalRefreshFailureToKeychainAccessIfApplicable(
                original,
                recordSource: .credentialsFile)
            guard case .refreshFailed(kind: .terminal, message: _) = unchanged else {
                Issue.record("Expected unchanged .refreshFailed, got \(unchanged)")
                return
            }
        }

        // Credentials already came from the Claude keychain → access is not the blocker.
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 300,
            createdAt: 300,
            persistentRefHash: "item")
        try self.withIsolatedClaudeKeychain(fingerprint: fingerprint) {
            let unchanged = ClaudeOAuthCredentialsStore.redirectTerminalRefreshFailureToKeychainAccessIfApplicable(
                original,
                recordSource: .claudeKeychain)
            guard case .refreshFailed(kind: .terminal, message: _) = unchanged else {
                Issue.record("Expected unchanged .refreshFailed, got \(unchanged)")
                return
            }
        }

        // Transient failures must never be redirected.
        let transient = ClaudeOAuthCredentialsError.refreshFailed(kind: .transient, message: "HTTP 500")
        try self.withIsolatedClaudeKeychain(fingerprint: fingerprint) {
            let unchanged = ClaudeOAuthCredentialsStore.redirectTerminalRefreshFailureToKeychainAccessIfApplicable(
                transient,
                recordSource: .credentialsFile)
            guard case .refreshFailed(kind: .transient, message: _) = unchanged else {
                Issue.record("Expected unchanged transient .refreshFailed, got \(unchanged)")
                return
            }
        }
    }
}
