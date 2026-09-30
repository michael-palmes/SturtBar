import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

/// SturtBar never refreshes Claude tokens: an expired one surfaces as `.tokenExpired`, and state from the retired
/// refresh path is discarded.
@Suite(.serialized)
struct ClaudeOAuthTokenExpiryTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date, refreshToken: String? = nil) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let refreshField = refreshToken.map { ", \"refreshToken\": \"\($0)\"" } ?? ""
        let json = """
        {"claudeAiOauth": {"accessToken": "\(accessToken)", "expiresAt": \(millis), \
        "scopes": ["user:profile"]\(refreshField)}}
        """
        return Data(json.utf8)
    }

    /// SturtBar never refreshes: an expired token throws `.tokenExpired` and the usage endpoint is never called.
    @Test
    func `expired token throws token expired without any http call`() async throws {
        let requests = Mutex(0)
        let service = ClaudeUsageService(
            transport: HTTPTransportHandler { _ in
                requests.withLock { $0 += 1 }
                throw URLError(.notConnectedToInternet)
            },
            environment: [:])
        try await self.withExpiredCacheEntry(accessToken: "expired-cached") {
            do {
                _ = try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    try await service.fetchUsage(interaction: .background)
                }
                Issue.record("Expected ClaudeUsageError.credentials(.tokenExpired)")
            } catch let error as ClaudeUsageError {
                guard case .credentials(.tokenExpired(source: .cacheKeychain)) = error else {
                    Issue.record("Expected .credentials(.tokenExpired(.cacheKeychain)), got \(error)")
                    return
                }
            }
        }
        #expect(requests.withLock { $0 } == 0)
    }

    @Test
    func `load for usage returns a valid cached token unchanged`() throws {
        try self.withIsolatedCache { cacheKey in
            KeychainCacheStore.store(
                key: cacheKey,
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(
                        accessToken: "valid-cached",
                        expiresAt: Date(timeIntervalSinceNow: 3600)),
                    storedAt: Date(),
                    owner: .claudeCLI))
            let record = try ClaudeOAuthCredentialsStore.loadForUsage(
                environment: [:],
                allowKeychainPrompt: false,
                respectKeychainPromptCooldown: true)
            #expect(record.credentials.accessToken == "valid-cached")
            #expect(record.expirySource == .cacheKeychain)
        }
    }

    /// After `claude /logout` only SturtBar's expired copy remains; it must not leave the card waiting forever.
    @Test
    func `expired cached copy with claude code signed out clears it and shows sign-in`() throws {
        try self.withIsolatedCache { cacheKey in
            self.storeExpiredEntry(cacheKey)
            // An empty override store is a definitive "no Claude Code keychain item".
            try ClaudeOAuthCredentialsStore.withMutableClaudeKeychainOverrideStoreForTesting(.init()) {
                do {
                    _ = try ClaudeOAuthCredentialsStore.loadForUsage(
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
            guard case .missing = KeychainCacheStore.load(
                key: cacheKey,
                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
            else {
                Issue.record("Expected SturtBar's stale copy to be cleared")
                return
            }
        }
    }

    @Test
    func `expired cached copy keeps waiting when the keychain probe cannot tell`() throws {
        try self.withIsolatedCache { cacheKey in
            self.storeExpiredEntry(cacheKey)
            do {
                _ = try ClaudeOAuthCredentialsStore.loadForUsage(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected ClaudeOAuthCredentialsError.tokenExpired")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case .tokenExpired(source: .cacheKeychain) = error else {
                    Issue.record("Expected .tokenExpired(.cacheKeychain), got \(error)")
                    return
                }
            }
            guard case .found = KeychainCacheStore.load(
                key: cacheKey,
                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
            else {
                Issue.record("Expected the cached copy to stay while Claude Code's storage is unknown")
                return
            }
        }
    }

    private func storeExpiredEntry(_ cacheKey: KeychainCacheStore.Key) {
        KeychainCacheStore.store(
            key: cacheKey,
            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                data: self.makeCredentialsData(
                    accessToken: "expired-cached",
                    expiresAt: Date(timeIntervalSinceNow: -3600)),
                storedAt: Date(),
                owner: .claudeCLI))
    }

    /// Builds of SturtBar that refreshed tokens tagged their cache entry with owner "sturtbar"; that rotated
    /// chain must be discarded, never used.
    @Test
    func `retired sturtbar owned cache entry is cleared and never used`() throws {
        struct RetiredCacheEntry: Codable {
            let data: Data
            let storedAt: Date
            let owner: String
        }
        try self.withIsolatedCache { cacheKey in
            KeychainCacheStore.store(
                key: cacheKey,
                entry: RetiredCacheEntry(
                    data: self.makeCredentialsData(
                        accessToken: "rotated-by-sturtbar",
                        expiresAt: Date(timeIntervalSinceNow: 3600),
                        refreshToken: "rotated-refresh"),
                    storedAt: Date(),
                    owner: "sturtbar"))

            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:]) == false)
            do {
                _ = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: [:],
                    allowKeychainPrompt: false,
                    respectKeychainPromptCooldown: true)
                Issue.record("Expected no usable credentials")
            } catch let error as ClaudeOAuthCredentialsError {
                guard case .notFound = error else {
                    Issue.record("Expected .notFound, got \(error)")
                    return
                }
            }
            guard case .missing = KeychainCacheStore.load(
                key: cacheKey,
                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
            else {
                Issue.record("Expected the retired cache entry to be cleared")
                return
            }
        }
    }

    @Test
    func `retired refresh state defaults are removed`() throws {
        let suite = "sturtbar-tests-retired-refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ClaudeOAuthCredentialsStore.retiredRefreshStateKeys {
            defaults.set(1, forKey: key)
        }
        defaults.set("kept", forKey: "claudeOAuthKeychainPromptMode")

        ClaudeOAuthCredentialsStore.removeRetiredRefreshState(userDefaults: defaults)

        for key in ClaudeOAuthCredentialsStore.retiredRefreshStateKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(defaults.string(forKey: "claudeOAuthKeychainPromptMode") == "kept")
    }

    /// An expired token is no use without a refresh, so it must not suppress a user-initiated Keychain read.
    @Test
    func `has cached credentials returns false for an expired cache entry`() throws {
        try self.withIsolatedCache { cacheKey in
            KeychainCacheStore.store(
                key: cacheKey,
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(
                        accessToken: "expired-with-refresh",
                        expiresAt: Date(timeIntervalSinceNow: -3600),
                        refreshToken: "refresh"),
                    storedAt: Date(),
                    owner: .claudeCLI))
            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:]) == false)
            // Still a saved copy, which keeps the startup bootstrap prompt away.
            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:], includingExpired: true))
        }
    }

    /// Isolated cache, memory cache and missing credentials file, with no Claude keychain access.
    private func withIsolatedCache(
        _ operation: (KeychainCacheStore.Key) throws -> Void) throws
    {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try InteractionContext.$current.withValue(.background) {
            try KeychainCacheStore.withServiceOverrideForTesting(service) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        let fileURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                            .appendingPathComponent("missing-credentials.json")
                        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                                    let cacheKey = KeychainCacheStore.Key.oauthClaude
                                    defer { KeychainCacheStore.clear(key: cacheKey) }
                                    try operation(cacheKey)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func withExpiredCacheEntry(
        accessToken: String,
        operation: () async throws -> Void) async throws
    {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        .appendingPathComponent("missing-credentials.json")
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            let cacheKey = KeychainCacheStore.Key.oauthClaude
                            defer { KeychainCacheStore.clear(key: cacheKey) }
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: self.makeCredentialsData(
                                        accessToken: accessToken,
                                        expiresAt: Date(timeIntervalSinceNow: -3600),
                                        refreshToken: "refresh-token"),
                                    storedAt: Date(),
                                    owner: .claudeCLI))
                            try await operation()
                        }
                    }
                }
            }
        }
    }
}
