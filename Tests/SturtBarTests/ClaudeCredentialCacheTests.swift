import Foundation
import Testing
@testable import SturtBarCore

struct ClaudeCredentialCacheTests {
    @Test
    func `account bindings and tokens survive memory and persisted cache reads in both directions`() throws {
        let service = "sturtbar-switch-cache-\(UUID())"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(file) {
                    try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        for account in ["a", "b", "a"] {
                            let data = Data("""
                            {"claudeAiOauth":{"accessToken":"token-\(account)","scopes":["user:profile"],
                            "expiresAt":\(Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000))}}
                            """.utf8)
                            let record = try ClaudeOAuthCredentialRecord(
                                credentials: ClaudeOAuthCredentials.parse(data: data),
                                source: .claudeKeychain,
                                cacheData: data)
                            let binding = ClaudeCredentialBinding(observation: ClaudeCredentialObservation(
                                accountKey: account, keychain: "item-\(account)"))
                            ClaudeOAuthCredentialsStore.commitRecord(record, binding: binding)
                            try ClaudeOAuthCredentialsStore.$managesFreshness.withValue(true) {
                                let memory = try ClaudeOAuthCredentialsStore.loadForUsage(environment: [:])
                                #expect(memory.source == .memoryCache)
                                #expect(memory.credentials.accessToken == "token-\(account)")
                                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                                    let persisted = try ClaudeOAuthCredentialsStore.loadForUsage(environment: [:])
                                    #expect(persisted.source == .cacheKeychain)
                                    #expect(persisted.credentials.accessToken == "token-\(account)")
                                }
                            }
                            #expect(ClaudeOAuthCredentialsStore.sessionCache()?.binding?.observation
                                .accountKey == account)
                        }
                        let invalidated = ClaudeCredentialBinding(
                            observation: ClaudeCredentialObservation(accountKey: "c", keychain: "item-c"),
                            invalidated: true)
                        ClaudeOAuthCredentialsStore.bindCache(invalidated)
                        #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:]) == false)
                        #expect(ClaudeOAuthCredentialsStore.sessionCache()?.binding?.invalidated == true)
                    }
                }
            }
        }
    }

    @Test
    func `legacy credential cache decodes without an account binding`() throws {
        let data = Data("""
        {"data":"e30=","storedAt":1000}
        """.utf8)
        let entry = try JSONDecoder().decode(ClaudeOAuthCredentialsStore.CacheEntry.self, from: data)
        #expect(entry.binding == nil)
        #expect(entry.owner == nil)
        #expect(entry.data == Data("{}".utf8))
    }
}
