import Foundation
import Testing
@testable import SturtBarCore

/// Pins the storage-ownership semantics of SturtBar's own keychain cache:
/// - Cache entries written by SturtBar (owner `.sturtbar`) are re-attributed to `.claudeCLI` whenever
///   Claude Code's own storage (credentials file or Keychain item) exists, because Claude Code then owns
///   the refresh-token rotation lifecycle.
/// - Without Claude CLI storage, `.sturtbar` entries stay SturtBar-owned and refresh directly.
@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreCLIStorageOwnershipTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date, refreshToken: String? = nil) -> Data {
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

    @Test
    func `load record treats sturtbar cache as claude CLI owned when credentials file exists`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauthClaude
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let fileData = self.makeCredentialsData(
                                accessToken: "claude-cli-file",
                                expiresAt: Date(timeIntervalSinceNow: 3600),
                                refreshToken: "cli-refresh-token")
                            try fileData.write(to: fileURL)

                            let cachedData = self.makeCredentialsData(
                                accessToken: "sturtbar-cache",
                                expiresAt: Date(timeIntervalSinceNow: 3600),
                                refreshToken: "cached-refresh-token")
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: cachedData,
                                    storedAt: Date(timeIntervalSinceNow: 60),
                                    owner: .sturtbar))

                            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                                environment: [:],
                                allowKeychainPrompt: false,
                                respectKeychainPromptCooldown: true,
                                allowClaudeKeychainRepairWithoutPrompt: false)

                            #expect(record.credentials.accessToken == "sturtbar-cache")
                            #expect(record.owner == .claudeCLI)
                            #expect(record.source == .cacheKeychain)
                        }
                    }
                }
            }
        }
    }

    /// Legacy CodexBar expected `.refreshDelegatedToClaudeCLI` here because the cache entry is re-owned
    /// to `.claudeCLI` when the credentials file exists. SturtBar never delegates to the CLI binary, so
    /// the same re-owned record now takes the direct refresh path guarded by ClaudeOAuthRefreshFailureGate.
    @Test
    func `load with auto refresh uses direct refresh for expired sturtbar cache when credentials file exists`()
        async throws
    {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauthClaude
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            try Data("not valid credentials".utf8).write(to: fileURL)

                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-sturtbar-with-file",
                                expiresAt: Date(timeIntervalSinceNow: -3600),
                                refreshToken: "cached-refresh-token")
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(timeIntervalSinceNow: 60),
                                    owner: .sturtbar))

                            await ClaudeOAuthRefreshFailureGate.$shouldAttemptOverride.withValue(false) {
                                do {
                                    _ = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true)
                                    Issue.record("Expected direct refresh failure when Claude CLI file is present")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case .refreshFailed = error else {
                                        Issue.record("Expected .refreshFailed, got \(error)")
                                        return
                                    }
                                } catch {
                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `load with auto refresh keeps sturtbar cache ownership without Claude CLI storage`() async throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")
            await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauthClaude
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-sturtbar-only",
                                expiresAt: Date(timeIntervalSinceNow: -3600),
                                refreshToken: "cached-refresh-token")
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(timeIntervalSinceNow: 60),
                                    owner: .sturtbar))

                            await ClaudeOAuthRefreshFailureGate.$shouldAttemptOverride.withValue(false) {
                                do {
                                    _ = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true)
                                    Issue.record("Expected direct SturtBar refresh failure")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case let .refreshFailed(kind: kind, message: _) = error else {
                                        Issue.record("Expected .refreshFailed, got \(error)")
                                        return
                                    }
                                    // shouldAttemptOverride = false forces the gate to block regardless of persisted
                                    // state. The kind is suppressed/transient/terminal depending on concurrent gate
                                    // suite activity — all three are valid gate-block paths, not HTTP errors.
                                    #expect(kind == .suppressed || kind == .transient || kind == .terminal)
                                } catch {
                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `load record treats sturtbar cache as claude CLI owned when Claude keychain item exists`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        let cacheKey = KeychainCacheStore.Key.oauthClaude
                        defer { KeychainCacheStore.clear(key: cacheKey) }

                        let cachedData = self.makeCredentialsData(
                            accessToken: "sturtbar-cache",
                            expiresAt: Date(timeIntervalSinceNow: 3600),
                            refreshToken: "cached-refresh-token")
                        KeychainCacheStore.store(
                            key: cacheKey,
                            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                data: cachedData,
                                storedAt: Date(),
                                owner: .sturtbar))

                        let keychainData = self.makeCredentialsData(
                            accessToken: "claude-keychain",
                            expiresAt: Date(timeIntervalSinceNow: 3600),
                            refreshToken: "keychain-refresh-token")

                        let record = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: keychainData,
                                fingerprint: nil)
                            {
                                try ClaudeOAuthCredentialsStore.loadRecord(
                                    environment: [:],
                                    allowKeychainPrompt: false,
                                    respectKeychainPromptCooldown: true,
                                    allowClaudeKeychainRepairWithoutPrompt: false)
                            }
                        }

                        #expect(record.credentials.accessToken == "sturtbar-cache")
                        #expect(record.owner == .claudeCLI)
                        #expect(record.source == .cacheKeychain)
                    }
                }
            }
        }
    }
}
