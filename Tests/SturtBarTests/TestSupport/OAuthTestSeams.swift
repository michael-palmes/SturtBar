import Foundation
import Testing
@testable import SturtBarCore

// MARK: - Shared OAuth test seam helpers

/// Wraps the common TaskLocal seams used in ClaudeUsageService flow tests:
/// prompt mode override, isolated keychain-denied store, and the service's
/// credential/usage overrides.
func withOAuthSeams<T>(
    promptMode: ClaudeOAuthKeychainPromptMode = .onlyOnUserAction,
    hasCachedCredentials: Bool? = nil,
    load: (@Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials)?,
    fetch: (@Sendable (String) async throws -> OAuthUsageResponse)?,
    operation: () async throws -> T) async throws -> T
{
    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(promptMode) {
        try await ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(.init()) {
            try await ClaudeUsageService.$hasCachedCredentialsOverride.withValue(hasCachedCredentials) {
                try await ClaudeUsageService.$loadOAuthCredentialsOverride.withValue(load) {
                    try await ClaudeUsageService.$fetchOAuthUsageOverride.withValue(fetch) {
                        try await operation()
                    }
                }
            }
        }
    }
}

/// Wraps state mutated by `ClaudeOAuthCredentialsStore.invalidateCache()` (memory cache and
/// keychain cache) in isolated test stores, preventing cross-test contamination.
func withIsolatedCacheStores<T>(operation: () async throws -> T) async throws -> T {
    let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
    return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        return try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
            try await operation()
        }
    }
}
