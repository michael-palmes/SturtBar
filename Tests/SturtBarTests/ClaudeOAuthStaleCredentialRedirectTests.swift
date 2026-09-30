import Foundation
import Testing
@testable import SturtBarCore

/// Pins what an expired record means once SturtBar stops refreshing: when Claude Code's keychain item
/// changed since SturtBar last read it but cannot be read silently, the renewed token is there and the
/// remedy is Keychain access; when the item is unchanged, SturtBar waits for Claude Code to renew it.
@Suite(.serialized)
struct ClaudeOAuthStaleCredentialRedirectTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
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

    private func withStaleFileHarness<T>(
        fileData: Data,
        keychainFingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?,
        storedFingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?,
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
                                        try ClaudeOAuthCredentialsStore
                                            .withClaudeKeychainFingerprintStoreOverrideForTesting(
                                                .init(fingerprint: storedFingerprint))
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
    }

    @Test
    func `expired file redirects to keychain access when claude keychain item changed`() throws {
        let renewed = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 200,
            createdAt: 200,
            persistentRefHash: "new-item")
        let lastRead = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 100,
            createdAt: 100,
            persistentRefHash: "old-item")
        let staleFile = self.makeCredentialsData(
            accessToken: "stale",
            expiresAt: Date(timeIntervalSinceNow: -3600))

        try self.withStaleFileHarness(
            fileData: staleFile,
            keychainFingerprint: renewed,
            storedFingerprint: lastRead)
        {
            do {
                _ = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case let .claudeKeychainAccessRequired(_, reason) = error else {
                    Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                    return
                }
                #expect(reason == .accessLost)
            }
        }
    }

    @Test
    func `expired file waits for claude code when claude keychain item is unchanged`() throws {
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 200,
            createdAt: 200,
            persistentRefHash: "same-item")
        let staleFile = self.makeCredentialsData(
            accessToken: "stale",
            expiresAt: Date(timeIntervalSinceNow: -3600))

        try self.withStaleFileHarness(
            fileData: staleFile,
            keychainFingerprint: fingerprint,
            storedFingerprint: fingerprint)
        {
            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: [:],
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true)
            #expect(record.credentials.accessToken == "stale")
            #expect(record.source == .credentialsFile)

            do {
                _ = try ClaudeOAuthCredentialsStore.loadForUsage(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.tokenExpired")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case .tokenExpired(source: .credentialsFile) = error else {
                    Issue.record("Expected .tokenExpired(.credentialsFile), got \(error)")
                    return
                }
            }
        }
    }

    @Test
    func `expired file is still returned when no claude keychain item exists`() throws {
        let staleFile = self.makeCredentialsData(
            accessToken: "stale",
            expiresAt: Date(timeIntervalSinceNow: -3600))

        try self.withStaleFileHarness(fileData: staleFile, keychainFingerprint: nil, storedFingerprint: nil) {
            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: [:],
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true)
            #expect(record.credentials.accessToken == "stale")
            #expect(record.source == .credentialsFile)
        }
    }

    // MARK: - Nothing readable anywhere (the notFound redirect)

    /// Like `withStaleFileHarness` but with no credentials file, exercising the final-throw redirect in `loadRecord`.
    private func withMissingFileHarness<T>(
        keychainFingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?,
        promptMode: ClaudeOAuthKeychainPromptMode,
        operation: () throws -> T) throws -> T
    {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        return try InteractionContext.$current.withValue(.background) {
            try KeychainCacheStore.withServiceOverrideForTesting(service) {
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
                                try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                    .securityFramework)
                                {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
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
    func `nothing readable under never redirects to keychain access when item exists`() throws {
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 400,
            createdAt: 400,
            persistentRefHash: "unreadable-item")
        try self.withMissingFileHarness(keychainFingerprint: fingerprint, promptMode: .never) {
            do {
                _ = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case let .claudeKeychainAccessRequired(_, reason) = error else {
                    Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                    return
                }
                #expect(reason == .promptsDisabled)
            }
        }
    }

    @Test
    func `nothing readable without a keychain item still throws notFound`() throws {
        try self.withMissingFileHarness(keychainFingerprint: nil, promptMode: .never) {
            do {
                _ = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.notFound")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case .notFound = error else {
                    Issue.record("Expected .notFound, got \(error)")
                    return
                }
            }
        }
    }

    @Test
    func `nothing readable in background with prompts allowed redirects with accessLost`() throws {
        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 500,
            createdAt: 500,
            persistentRefHash: "acl-item")
        try self.withMissingFileHarness(keychainFingerprint: fingerprint, promptMode: .onlyOnUserAction) {
            do {
                _ = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case let .claudeKeychainAccessRequired(_, reason) = error else {
                    Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                    return
                }
                #expect(reason == .accessLost)
            }
        }
    }
}
