import Foundation
import Synchronization
#if os(macOS)
import Darwin
import Security
#endif

public enum KeychainCacheStore {
    public struct Key: Hashable, Sendable {
        public let category: String
        public let identifier: String

        public init(category: String, identifier: String) {
            self.category = category
            self.identifier = identifier
        }

        var account: String {
            "\(self.category).\(self.identifier)"
        }
    }

    public enum LoadResult<Entry> {
        case found(Entry)
        case missing
        case temporarilyUnavailable
        case invalid
    }

    private static let log = SturtBarLog.logger("keychain.cache")
    private static let cacheService = "com.michaelpalmes.sturtbar.cache"
    private static let cacheLabel = "SturtBar Cache"
    @TaskLocal private static var serviceOverride: String?
    #if DEBUG && os(macOS)
    @TaskLocal private static var loadFailureStatusOverride: OSStatus?
    #endif
    private static let testStoreLock = NSLock()
    private struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    private nonisolated(unsafe) static var testStore: [ItemKey: Data]?
    private nonisolated(unsafe) static var implicitTestStore: [ItemKey: Data] = [:]
    private nonisolated(unsafe) static var testStoreRefCount = 0
    private static let repairedItems = Mutex<Set<ItemKey>>([])

    public static func load<Entry: Codable>(
        key: Key,
        as type: Entry.Type = Entry.self) -> LoadResult<Entry>
    {
        #if DEBUG && os(macOS)
        if let status = self.loadFailureStatusOverride {
            return self.loadResultForKeychainReadFailure(status: status, key: key)
        }
        #endif
        if let testResult = loadFromTestStore(key: key, as: type) {
            return testResult
        }
        guard self.canUseRealKeychain else { return .missing }
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: AnyObject?
        let status = KeychainNoUIQuery.withoutLegacyKeychainUI {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                self.log.error("Keychain cache item was empty (\(key.account))")
                return .invalid
            }
            let decoder = Self.makeDecoder()
            guard let decoded = try? decoder.decode(Entry.self, from: data) else {
                self.log.error("Failed to decode keychain cache (\(key.account))")
                return .invalid
            }
            return .found(decoded)
        default:
            return self.loadResultForKeychainReadFailure(status: status, key: key)
        }
        #else
        return .missing
        #endif
    }

    public static func store(key: Key, entry: some Codable) {
        if self.storeInTestStore(key: key, entry: entry) {
            return
        }
        guard self.canUseRealKeychain else { return }
        #if os(macOS)
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else {
            self.log.error("Failed to encode keychain cache (\(key.account))")
            return
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        KeychainNoUIQuery.apply(to: &query)

        let writer = ItemWriter(
            update: {
                KeychainNoUIQuery.withoutLegacyKeychainUI {
                    SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                }
            },
            delete: {
                KeychainNoUIQuery.withoutLegacyKeychainUI { SecItemDelete(query as CFDictionary) }
            },
            add: {
                var addQuery = query
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrLabel as String] = self.cacheLabel
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                if let access = self.cacheAccessControl() {
                    addQuery[kSecAttrAccess as String] = access
                }
                return KeychainNoUIQuery.withoutLegacyKeychainUI { SecItemAdd(addQuery as CFDictionary, nil) }
            })
        self.write(key: key, service: self.serviceName, using: writer)
        #endif
    }

    @discardableResult
    public static func clear(key: Key) -> Bool {
        if let removed = self.clearTestStore(key: key) {
            return removed
        }
        guard self.canUseRealKeychain else { return false }
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.serviceName,
            kSecAttrAccount as String: key.account,
        ]
        KeychainNoUIQuery.apply(to: &query)
        let deleteStatus = KeychainNoUIQuery.withoutLegacyKeychainUI {
            SecItemDelete(query as CFDictionary)
        }
        return self.clearResultForKeychainDeleteStatus(deleteStatus, key: key)
        #else
        return false
        #endif
    }

    public static func withServiceOverrideForTesting<T>(
        _ service: String?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$serviceOverride.withValue(service) {
            try operation()
        }
    }

    public static func withServiceOverrideForTesting<T>(
        _ service: String?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$serviceOverride.withValue(service) {
            try await operation()
        }
    }

    static var canUseRealKeychainForTesting: Bool {
        self.canUseRealKeychain
    }

    #if DEBUG && os(macOS)
    public static func withLoadFailureStatusOverrideForTesting<T>(
        _ status: OSStatus?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$loadFailureStatusOverride.withValue(status) {
            try operation()
        }
    }
    #endif

    static func setTestStoreForTesting(_ enabled: Bool) {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        if enabled {
            self.testStoreRefCount += 1
            if self.testStoreRefCount == 1 {
                self.testStore = [:]
            }
        } else {
            self.testStoreRefCount = max(0, self.testStoreRefCount - 1)
            if self.testStoreRefCount == 0 {
                self.testStore = nil
            }
        }
    }

    private static var serviceName: String {
        serviceOverride ?? self.cacheService
    }

    private static var canUseRealKeychain: Bool {
        !KeychainAccessGate.isDisabled
    }

    #if DEBUG
    private static var shouldUseImplicitTestStore: Bool {
        TestEnvironment.isRunningUnderTests && !self.canUseRealKeychain
    }
    #else
    private static var shouldUseImplicitTestStore: Bool {
        false
    }
    #endif

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    #if os(macOS)
    /// The item writes `store` makes, injectable so the repair path is testable without the real keychain.
    struct ItemWriter {
        let update: () -> OSStatus
        let delete: () -> OSStatus
        let add: () -> OSStatus
    }

    enum WriteOutcome: Equatable {
        case written
        case repaired
        case locked
        case failed
    }

    /// An own item that rejects this build (e.g. after a signature change) is replaced once per launch, without UI.
    @discardableResult
    static func write(key: Key, service: String, using writer: ItemWriter) -> WriteOutcome {
        guard self.isOwnCacheService(service) else {
            self.log.error("Keychain cache write refused outside SturtBar's own service (\(key.account))")
            return .failed
        }
        let updateStatus = writer.update()
        switch updateStatus {
        case errSecSuccess:
            return .written
        case errSecItemNotFound:
            return self.add(key: key, using: writer) ? .written : .failed
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return self.replaceRejectedItem(key: key, service: service, using: writer)
        default:
            self.log.error("Keychain cache update failed (\(key.account)): \(updateStatus)")
            return .failed
        }
    }

    static func isOwnCacheService(_ service: String) -> Bool {
        service == self.cacheService || service.hasPrefix(self.cacheService + ".")
    }

    private static func replaceRejectedItem(key: Key, service: String, using writer: ItemWriter) -> WriteOutcome {
        let itemKey = ItemKey(service: service, account: key.account)
        guard self.repairedItems.withLock({ $0.insert(itemKey).inserted }) else {
            self.log.info("Keychain cache still unwritable after this launch's repair (\(key.account))")
            return .failed
        }
        let deleteStatus = writer.delete()
        switch deleteStatus {
        case errSecSuccess, errSecItemNotFound:
            break
        case errSecInteractionNotAllowed:
            // A locked keychain refuses the delete too; leave the one repair for after it unlocks.
            self.repairedItems.withLock { _ = $0.remove(itemKey) }
            self.log.info("Keychain cache update skipped, keychain locked (\(key.account))")
            return .locked
        default:
            self.log.error("Keychain cache repair delete failed (\(key.account)): \(deleteStatus)")
            return .failed
        }
        guard self.add(key: key, using: writer) else { return .failed }
        self.log.info("Keychain cache item replaced after it rejected this build (\(key.account))")
        return .repaired
    }

    private static func add(key: Key, using writer: ItemWriter) -> Bool {
        let addStatus = writer.add()
        guard addStatus == errSecSuccess else {
            self.log.error("Keychain cache add failed (\(key.account)): \(addStatus)")
            return false
        }
        return true
    }

    static func loadResultForKeychainReadFailure<Entry>(
        status: OSStatus,
        key: Key) -> LoadResult<Entry>
    {
        switch status {
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // No prompt was shown because `KeychainNoUIQuery.withoutLegacyKeychainUI` suppresses the ACL dialog.
            // `errSecInteractionNotAllowed` = keychain locked (e.g. just after wake); `errSecAuthFailed`
            // = this binary isn't on the item's ACL (the usual case for a locally rebuilt dev binary,
            // whose code identity no longer matches). Both are benign for a best-effort cache: the
            // caller falls back to the Claude Code keychain. Info-level so the dev loop stays quiet.
            self.log.info("Keychain cache not readable without a prompt (\(key.account)); falling back")
            return .temporarilyUnavailable
        default:
            self.log.error("Keychain cache read failed (\(key.account)): \(status)")
            return .invalid
        }
    }

    static func clearResultForKeychainDeleteStatus(_ status: OSStatus, key: Key) -> Bool {
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed:
            self.log.info("Keychain cache delete temporarily unavailable (\(key.account))")
            return false
        default:
            self.log.error("Keychain cache delete failed (\(key.account)): \(status)")
            return false
        }
    }

    static func trustedApplicationPathsForCacheAccess(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]
    {
        var paths: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty, fileExists(path), !paths.contains(path) else { return }
            paths.append(path)
        }

        let appBundle = self.appBundleURL(containing: bundleURL)
            ?? executableURL.flatMap(self.appBundleURL(containing:))
        if let appBundle {
            append(appBundle.path)
            append(appBundle.appendingPathComponent("Contents/Helpers/SturtBarCLI").path)
        }
        if let executableURL {
            append(executableURL.path)
        }
        return paths
    }

    private static func appBundleURL(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func cacheAccessControl() -> SecAccess? {
        let trustedPaths = self.trustedApplicationPathsForCacheAccess()
        guard !trustedPaths.isEmpty else { return nil }

        var trustedApplications: [SecTrustedApplication] = []
        for path in trustedPaths {
            let (status, application) = self.createTrustedApplication(path: path)
            if status == errSecSuccess, let application {
                trustedApplications.append(application)
            } else {
                self.log.error("Keychain cache trusted app creation failed (\(path)): \(status)")
            }
        }
        guard !trustedApplications.isEmpty else { return nil }

        let (status, access) = self.createAccessControl(trustedApplications: trustedApplications)
        if status != errSecSuccess {
            self.log.error("Keychain cache access control creation failed: \(status)")
            return nil
        }
        return access
    }

    private typealias SecTrustedApplicationCreateFromPathFunction = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafeMutablePointer<SecTrustedApplication?>?) -> OSStatus
    private typealias SecAccessCreateFunction = @convention(c) (
        CFString,
        CFArray,
        UnsafeMutablePointer<SecAccess?>?) -> OSStatus

    private static func createTrustedApplication(path: String) -> (OSStatus, SecTrustedApplication?) {
        guard let symbol = self.securitySymbol(named: "SecTrustedApplicationCreateFromPath") else {
            return (errSecInternalComponent, nil)
        }
        let function = unsafeBitCast(symbol, to: SecTrustedApplicationCreateFromPathFunction.self)
        var application: SecTrustedApplication?
        let status = path.withCString { cPath in
            function(cPath, &application)
        }
        return (status, application)
    }

    private static func createAccessControl(trustedApplications: [SecTrustedApplication]) -> (OSStatus, SecAccess?) {
        guard let symbol = self.securitySymbol(named: "SecAccessCreate") else {
            return (errSecInternalComponent, nil)
        }
        let function = unsafeBitCast(symbol, to: SecAccessCreateFunction.self)
        var access: SecAccess?
        let status = function(self.cacheLabel as CFString, trustedApplications as CFArray, &access)
        return (status, access)
    }

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        return dlopen(securityPath, RTLD_NOW)
    }()

    private static func securitySymbol(named name: String) -> UnsafeMutableRawPointer? {
        // Resolve deprecated SecKeychain ACL helpers at runtime so release builds stay warning-free
        // while still granting the app bundle and bundled CLI prompt-free access to cache entries.
        guard let securityFrameworkHandle else { return nil }
        return dlsym(securityFrameworkHandle, name)
    }

    #endif

    private static func loadFromTestStore<Entry: Codable>(
        key: Key,
        as type: Entry.Type) -> LoadResult<Entry>?
    {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard let store = self.testStore ?? (self.shouldUseImplicitTestStore ? self.implicitTestStore : nil)
        else { return nil }
        let testKey = ItemKey(service: self.serviceName, account: key.account)
        guard let data = store[testKey] else { return .missing }
        let decoder = Self.makeDecoder()
        guard let decoded = try? decoder.decode(Entry.self, from: data) else {
            return .invalid
        }
        return .found(decoded)
    }

    private static func storeInTestStore(key: Key, entry: some Codable) -> Bool {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(entry) else { return true }
        let testKey = ItemKey(service: self.serviceName, account: key.account)
        if var store = self.testStore {
            store[testKey] = data
            self.testStore = store
            return true
        }
        if self.shouldUseImplicitTestStore {
            self.implicitTestStore[testKey] = data
            return true
        }
        return false
    }

    private static func clearTestStore(key: Key) -> Bool? {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        let testKey = ItemKey(service: self.serviceName, account: key.account)
        if var store = self.testStore {
            let removed = store.removeValue(forKey: testKey) != nil
            self.testStore = store
            return removed
        }
        if self.shouldUseImplicitTestStore {
            return self.implicitTestStore.removeValue(forKey: testKey) != nil
        }
        return nil
    }
}

extension KeychainCacheStore.LoadResult: Sendable where Entry: Sendable {}

extension KeychainCacheStore.Key {
    /// Cache key for the Claude Code OAuth credential entry.
    /// Matches `KeychainCacheStore.Key(category: "oauth", identifier: "claude")`.
    public static let oauthClaude = Self(category: "oauth", identifier: "claude")
}
