import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

struct ClaudeCredentialFileExclusionTests {
    @Test(arguments: [ClaudeOAuthKeychainPromptMode.never, .onlyOnUserAction], [Interaction.background, .userInitiated])
    func `excluded files do not block consented reconnect`(
        mode: ClaudeOAuthKeychainPromptMode, interaction: Interaction) async throws
    {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.credentials("old-file-token").write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let observation = ClaudeCredentialObservation(
            accountKey: "current-account", file: "old-file", keychain: "current-item")
        let requests = Mutex(0)
        try await self.withIsolatedStorage(file: file) {
            _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
            var entry = ClaudeOAuthCredentialsStore.CacheEntry(data: Data(), storedAt: Date())
            entry.binding = ClaudeCredentialBinding(observation: observation, excludedFile: "old-file")
            KeychainCacheStore.store(key: .oauthClaude, entry: entry)
            var operations = ClaudeCredentialSession.Operations()
            operations.observe = { _ in observation }
            let session = ClaudeCredentialSession(
                operations: operations,
                metadata: ClaudeAccountMetadata(url: file.appendingPathExtension("account")))
            try await self.withPermissionSimulation(
                mode: mode,
                handler: { _ in
                    requests.withLock { $0 += 1 }
                    return .notNow
                }, operation: {
                    await ClaudeUsageService.$credentialSessionOverride.withValue(session) {
                        await #expect(throws: ClaudeUsageError.self) {
                            try await ClaudeCredentialEvents.$forceCheck.withValue(true) {
                                try await ClaudeUsageService(environment: [:]).fetchUsage(interaction: interaction)
                            }
                        }
                    }
                })
        }
        #expect(requests.withLock { $0 } == (mode == .onlyOnUserAction && interaction == .userInitiated ? 1 : 0))
    }

    @Test(arguments: [401, 500])
    func `fetch failure and relaunch retain the excluded file`(statusCode: Int) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.credentials("old-file-token").write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let observation = ClaudeCredentialObservation(
            accountKey: "current-account", file: "old-file", keychain: "current-item")
        let tokens = Mutex<[String]>([])
        try await self.withIsolatedStorage(file: file) {
            _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
            let data = self.credentials("current-token")
            let record = try ClaudeOAuthCredentialRecord(
                credentials: ClaudeOAuthCredentials.parse(data: data), source: .claudeKeychain, cacheData: data)
            ClaudeOAuthCredentialsStore.commitRecord(
                record, binding: ClaudeCredentialBinding(observation: observation, excludedFile: "old-file"))
            let fetch: @Sendable (String) async throws -> OAuthUsageResponse = { token in
                tokens.withLock { $0.append(token) }
                if statusCode == 401 { throw ClaudeOAuthFetchError.unauthorized }
                throw ClaudeOAuthFetchError.serverError(statusCode, nil)
            }
            try await ClaudeUsageService.$fetchOAuthUsageOverride.withValue(fetch) {
                for _ in 0..<3 {
                    var operations = ClaudeCredentialSession.Operations()
                    operations.observe = { _ in observation }
                    let session = ClaudeCredentialSession(
                        operations: operations,
                        metadata: ClaudeAccountMetadata(url: file.appendingPathExtension("account")))
                    await ClaudeUsageService.$credentialSessionOverride.withValue(session) {
                        await #expect(throws: ClaudeUsageError.self) {
                            try await ClaudeUsageService(environment: [:]).fetchUsage(interaction: .background)
                        }
                    }
                    let cache = try #require(ClaudeOAuthCredentialsStore.sessionCache())
                    #expect(cache.binding?.excludedFile == "old-file")
                    #expect(cache.binding?.invalidated == false)
                }
            }
            #expect(tokens.withLock { $0 } == ["current-token"])
            if case let .found(entry) = KeychainCacheStore.load(
                key: .oauthClaude, as: ClaudeOAuthCredentialsStore.CacheEntry.self)
            {
                #expect(entry.data.isEmpty)
            } else {
                Issue.record("Expected the credential binding to remain cached")
            }
        }
    }

    @Test(arguments: [false, true])
    func `failed renewal cannot recover from an excluded file`(hasCache: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.credentials("old-file-token").write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = CredentialSessionFixture()
        fixture.state.withLock {
            $0.observation.file = "old-file"
            $0.binding = ClaudeCredentialBinding(observation: $0.observation, excludedFile: "old-file")
            $0.observation.keychain = "renewed-item"
            $0.readFailure = true
        }
        try await self.withIsolatedStorage(file: file) {
            _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
            if hasCache {
                let data = self.credentials("current-cached-token")
                let record = try ClaudeOAuthCredentialRecord(
                    credentials: ClaudeOAuthCredentials.parse(data: data),
                    source: .claudeKeychain,
                    cacheData: data)
                try ClaudeOAuthCredentialsStore.commitRecord(
                    record, binding: #require(fixture.state.withLock { $0.binding }))
            }
            let session = fixture.session()
            do {
                let record = try await session.load(force: true, allowPrompt: false, observer: fixture.observer) {
                    try ClaudeOAuthCredentialsStore.loadForUsage(environment: [:], allowKeychainPrompt: false)
                }
                #expect(hasCache)
                #expect(record.credentials.accessToken == "current-cached-token")
            } catch ClaudeOAuthCredentialsError.claudeKeychainAccessRequired {
                #expect(!hasCache)
            }
            #expect(fixture.state.withLock { $0.events.allSatisfy { !$0.invalidatesUsage } })
        }
    }

    private func credentials(_ token: String) -> Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"\(token)","scopes":["user:profile"],
        "expiresAt":\(Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000))}}
        """.utf8)
    }

    private func withPermissionSimulation(
        mode: ClaudeOAuthKeychainPromptMode,
        handler: @escaping @Sendable (KeychainPromptContext) -> KeychainPromptDecision,
        operation: () async throws -> Void) async throws
    {
        let preflight: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in .interactionRequired }
        try await withOAuthSeams(
            promptMode: mode,
            load: nil,
            fetch: { _ in
                Issue.record("Unexpected usage request before reconnect")
                throw ClaudeOAuthFetchError.unauthorized
            }, operation: {
                try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                    try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                        try await ClaudeOAuthCredentialsStore.$taskClaudeKeychainDataOverride
                            .withValue(self.credentials("current-token")) {
                                try await ClaudeOAuthCredentialsStore.$taskClaudeKeychainFingerprintOverride
                                    .withValue(.init(modifiedAt: 1, createdAt: 1, persistentRefHash: "fixture")) {
                                        try await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                            preflight)
                                        {
                                            try await KeychainPromptHandler.withHandlerForTesting(
                                                handler, operation: operation)
                                        }
                                    }
                            }
                    }
                }
            })
    }

    private func withIsolatedStorage(file: URL, operation: () async throws -> Void) async rethrows {
        try await KeychainCacheStore.withServiceOverrideForTesting("sturtbar-file-exclusion-\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(file) {
                            try await ClaudeOAuthCredentialsStore.$managesFreshness.withValue(true) {
                                try await operation()
                            }
                        }
                    }
                }
            }
        }
    }
}
