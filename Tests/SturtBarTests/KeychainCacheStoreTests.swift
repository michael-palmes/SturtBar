import Foundation
import Testing
@testable import SturtBarCore

@Suite("KeychainCacheStore", .serialized)
struct KeychainCacheStoreTests {
    struct TestEntry: Codable, Equatable {
        let value: String
        let storedAt: Date
    }

    @Test
    func `tests suppress real keychain access by default`() {
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

    @Test
    func `gate-false task override exposes real keychain access`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(KeychainCacheStore.canUseRealKeychainForTesting == true)
        }
    }

    @Test
    func `stores and loads entry`() {
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

    @Test
    func `overwrites existing entry`() {
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

    @Test
    func `clear removes entry`() {
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

    @Test
    func `clear reports whether an entry was removed`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let entry = TestEntry(value: "gone", storedAt: Date(timeIntervalSince1970: 0))
        KeychainCacheStore.store(key: key, entry: entry)

        #expect(KeychainCacheStore.clear(key: key) == true)
        #expect(KeychainCacheStore.clear(key: key) == false)
    }

    @Test
    func `oauthClaude key has expected category and identifier`() {
        let key = KeychainCacheStore.Key.oauthClaude
        #expect(key.category == "oauth")
        #expect(key.identifier == "claude")
        #expect(key.account == "oauth.claude")
    }

    #if os(macOS)
    @Test(
        arguments: [errSecInteractionNotAllowed, errSecAuthFailed])
    func `suppressed-UI read failures are treated as temporarily unavailable`(status: OSStatus) {
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

    @Test
    func `delete interaction not allowed is non-fatal`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        #expect(KeychainCacheStore.clearResultForKeychainDeleteStatus(errSecInteractionNotAllowed, key: key) == false)
    }

    @Test
    func `load failure override bypasses test store without affecting store or clear`() {
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

    private final class WriteCalls {
        var names: [String] = []
    }

    private func writer(
        update: OSStatus,
        delete: OSStatus = errSecSuccess,
        add: OSStatus = errSecSuccess,
        calls: WriteCalls) -> KeychainCacheStore.ItemWriter
    {
        KeychainCacheStore.ItemWriter(
            update: {
                calls.names.append("update")
                return update
            },
            delete: {
                calls.names.append("delete")
                return delete
            },
            add: {
                calls.names.append("add")
                return add
            })
    }

    private func ownTestService() -> String {
        "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
    }

    @Test
    func `write updates in place and adds a missing item`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let updated = WriteCalls()
        #expect(
            KeychainCacheStore.write(
                key: key,
                service: self.ownTestService(),
                using: self.writer(update: errSecSuccess, calls: updated)) == .written)
        #expect(updated.names == ["update"])

        let added = WriteCalls()
        #expect(
            KeychainCacheStore.write(
                key: key,
                service: self.ownTestService(),
                using: self.writer(update: errSecItemNotFound, calls: added)) == .written)
        #expect(added.names == ["update", "add"])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed])
    func `rejected update deletes and re-adds sturtbar's own item`(status: OSStatus) {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let calls = WriteCalls()

        let outcome = KeychainCacheStore.write(
            key: key,
            service: self.ownTestService(),
            using: self.writer(update: status, calls: calls))

        #expect(outcome == .repaired)
        #expect(calls.names == ["update", "delete", "add"])
    }

    @Test
    func `locked keychain gives up without spending the repair`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let service = self.ownTestService()
        let locked = WriteCalls()

        let outcome = KeychainCacheStore.write(
            key: key,
            service: service,
            using: self.writer(update: errSecInteractionNotAllowed, delete: errSecInteractionNotAllowed, calls: locked))

        #expect(outcome == .locked)
        #expect(locked.names == ["update", "delete"])

        let unlocked = WriteCalls()
        #expect(
            KeychainCacheStore.write(
                key: key,
                service: service,
                using: self.writer(update: errSecAuthFailed, calls: unlocked)) == .repaired)
        #expect(unlocked.names == ["update", "delete", "add"])
    }

    @Test
    func `repair runs at most once per item per launch`() {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let service = self.ownTestService()
        let first = WriteCalls()
        #expect(
            KeychainCacheStore.write(
                key: key,
                service: service,
                using: self.writer(update: errSecAuthFailed, add: errSecAuthFailed, calls: first)) == .failed)
        #expect(first.names == ["update", "delete", "add"])

        let second = WriteCalls()
        #expect(
            KeychainCacheStore.write(
                key: key,
                service: service,
                using: self.writer(update: errSecAuthFailed, calls: second)) == .failed)
        #expect(second.names == ["update"])
    }

    @Test(arguments: ["Claude Code-credentials", "com.michaelpalmes.sturtbar.cachex", ""])
    func `write never touches another service`(service: String) {
        let key = KeychainCacheStore.Key(category: "test", identifier: UUID().uuidString)
        let calls = WriteCalls()

        let outcome = KeychainCacheStore.write(
            key: key,
            service: service,
            using: self.writer(update: errSecAuthFailed, calls: calls))

        #expect(outcome == .failed)
        #expect(calls.names.isEmpty)
        #expect(!KeychainCacheStore.isOwnCacheService(service))
    }

    @Test
    func `own cache service covers the shipped name and test overrides`() {
        #expect(KeychainCacheStore.isOwnCacheService("com.michaelpalmes.sturtbar.cache"))
        #expect(KeychainCacheStore.isOwnCacheService(self.ownTestService()))
    }

    @Test
    func `cache ACL trusts bundled app and CLI helper`() {
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
