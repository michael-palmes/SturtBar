import Foundation
import Testing
@testable import SturtBarCore

@Suite("KeychainCacheStore", .serialized)
struct KeychainCacheStoreTests {
    struct TestEntry: Codable, Equatable {
        let value: String
        let storedAt: Date
    }

    @Test("tests suppress real keychain access by default")
    func sSuppressRealKeychainAccessByDefault() {
        guard ProcessInfo.processInfo.environment["STURTBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1" else { return }

        #expect(KeychainCacheStore.canUseRealKeychainForTesting == false)
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "implicit", storedAt: Date(timeIntervalSince1970: 0))

        // Hold an explicit test-store ref for the round trip: the explicit/implicit store selection
        // depends on a global refcount that concurrently running suites toggle, so an unscoped
        // store()/load() pair can land in different stores. Real-keychain suppression (the property
        // under test) is already pinned by the canUseRealKeychainForTesting assertion above.
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected test cache entry without real keychain access")
        }
    }

    @Test("gate-false task override exposes real keychain access")
    func gateFalseTaskOverrideExposesRealKeychainAccess() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(KeychainCacheStore.canUseRealKeychainForTesting == true)
        }
    }

    @Test("stores and loads entry")
    func storesAndLoadsEntry() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let storedAt = Date(timeIntervalSince1970: 0)
        let entry = TestEntry(value: "alpha", storedAt: storedAt)

        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected keychain cache entry")
        }
    }

    @Test("overwrites existing entry")
    func overwritesExistingEntry() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let first = TestEntry(value: "first", storedAt: Date(timeIntervalSince1970: 1))
        let second = TestEntry(value: "second", storedAt: Date(timeIntervalSince1970: 2))

        KeychainCacheStore.store(key: key, entry: first)
        KeychainCacheStore.store(key: key, entry: second)
        defer { KeychainCacheStore.clear(key: key) }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == second)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected overwritten keychain cache entry")
        }
    }

    @Test("clear removes entry")
    func clearRemovesEntry() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))

        KeychainCacheStore.store(key: key, entry: entry)
        KeychainCacheStore.clear(key: key)

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case .missing:
            break
        case .found, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected keychain cache entry to be cleared")
        }
    }

    @Test("clear reports whether an entry was removed")
    func clearReportsWhetherEntryWasRemoved() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)

        #expect(KeychainCacheStore.clear(key: key) == true)
        #expect(KeychainCacheStore.clear(key: key) == false)
    }

    @Test("oauthClaude key has expected category and identifier")
    func oauthClaudeKeyHasExpectedShape() {
        let key = KeychainCacheStore.Key.oauthClaude
        #expect(key.category == "oauth")
        #expect(key.identifier == "claude")
        #expect(key.account == "oauth.claude")
    }

    #if os(macOS)
    @Test(
        "suppressed-UI read failures are treated as temporarily unavailable",
        arguments: [errSecInteractionNotAllowed, errSecAuthFailed])
    func suppressedUIReadFailureIsTemporarilyUnavailable(status: OSStatus) {
        // With the legacy ACL prompt suppressed, a locked keychain reports errSecInteractionNotAllowed
        // and a binary that isn't on the item's ACL reports errSecAuthFailed. Both must fall back
        // (temporarilyUnavailable), not be surfaced as an invalid/corrupt cache.
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let result: KeychainCacheStore.LoadResult<TestEntry> = KeychainCacheStore.loadResultForKeychainReadFailure(
            status: status,
            key: key)

        switch result {
        case .temporarilyUnavailable:
            break
        case .found, .missing, .invalid:
            #expect(Bool(false), "Expected suppressed-UI read failure to be retry-later")
        }
    }

    @Test("legacy keychain UI is suppressed during a wrapped read and restored afterward")
    func legacyKeychainUISuppressedThenRestored() {
        // Proves the SecKeychainSetUserInteractionAllowed toggle actually flips the process-wide
        // legacy-ACL prompt off for the cache read and puts the prior value back. This is what stops
        // the "SturtBar wants to access key 'SturtBar Cache'" dialog for a non-matching binary; the
        // real prompt-vs-silent behavior is covered by the packaged-app live run.
        let probe = KeychainCacheStore.legacyKeychainUIProbeForTesting()
        #expect(probe.insideAllowed == false)
        #expect(probe.afterAllowed == true)
    }

    @Test("delete interaction not allowed is non-fatal")
    func deleteInteractionNotAllowedIsNonFatal() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        #expect(KeychainCacheStore.clearResultForKeychainDeleteStatus(errSecInteractionNotAllowed, key: key) == false)
    }

    @Test("load failure override bypasses test store without affecting store or clear")
    func loadFailureOverrideBypassesTestStore() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "stored", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)
        defer { KeychainCacheStore.clear(key: key) }

        KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
            case .temporarilyUnavailable:
                break
            case .found, .missing, .invalid:
                #expect(Bool(false), "Expected override to run before test store")
            }
        }

        switch KeychainCacheStore.load(key: key, as: TestEntry.self) {
        case let .found(loaded):
            #expect(loaded == entry)
        case .missing, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected override not to mutate test store")
        }
    }

    @Test("cache ACL trusts bundled app and CLI helper")
    func cacheACLTrustsBundledAppAndCLIHelper() {
        let root = URL(fileURLWithPath: "/Applications/SturtBar.app")
        let executable = root.appendingPathComponent("Contents/MacOS/SturtBar")
        let helper = root.appendingPathComponent("Contents/Helpers/SturtBarCLI")
        let existing = Set([
            root.path,
            executable.path,
            helper.path,
        ])

        let paths = KeychainCacheStore.trustedApplicationPathsForCacheAccess(
            bundleURL: root,
            executableURL: executable,
            fileExists: { existing.contains($0) })

        #expect(paths == [
            root.path,
            helper.path,
            executable.path,
        ])
    }
    #endif
}
