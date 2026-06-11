import Foundation
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
    private struct TestStoreKey: Hashable {
        let service: String
        let account: String
    }

    private nonisolated(unsafe) static var testStore: [TestStoreKey: Data]?
    private nonisolated(unsafe) static var implicitTestStore: [TestStoreKey: Data] = [:]
    private nonisolated(unsafe) static var testStoreRefCount = 0

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
        let status = self.withoutLegacyKeychainUI {
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

        let updateStatus = self.withoutLegacyKeychainUI {
            SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        }
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecInteractionNotAllowed {
            self.log.info("Keychain cache update skipped — keychain locked (e.g. after wake) (\(key.account))")
            return
        }
        if updateStatus != errSecItemNotFound {
            self.log.error("Keychain cache update failed (\(key.account)): \(updateStatus)")
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = self.cacheLabel
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let access = self.cacheAccessControl() {
            addQuery[kSecAttrAccess as String] = access
        }

        let addStatus = self.withoutLegacyKeychainUI {
            SecItemAdd(addQuery as CFDictionary, nil)
        }
        if addStatus != errSecSuccess {
            self.log.error("Keychain cache add failed (\(key.account)): \(addStatus)")
        }
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
        let deleteStatus = self.withoutLegacyKeychainUI {
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
    static func loadResultForKeychainReadFailure<Entry>(
        status: OSStatus,
        key: Key) -> LoadResult<Entry>
    {
        switch status {
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed:
            // No prompt was shown because `withoutLegacyKeychainUI` suppresses the legacy ACL dialog.
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

    private typealias SetUserInteractionAllowedFunction = @convention(c) (UInt8) -> OSStatus
    private typealias GetUserInteractionAllowedFunction = @convention(c) (UnsafeMutablePointer<UInt8>?) -> OSStatus

    /// Runs `body` with legacy Keychain Services UI suppressed process-wide, restoring the prior
    /// setting afterward. This is the ONLY lever that governs the legacy login-keychain ACL prompt
    /// ("… wants to access key 'SturtBar Cache' … Allow / Always Allow / Deny"): the modern
    /// LocalAuthentication flags in `KeychainNoUIQuery` only suppress data-protection-keychain UI,
    /// not this older file-based dialog. With UI off, a binary not on the item's ACL gets
    /// `errSecInteractionNotAllowed` instead of a prompt — so the self-cache read falls back silently
    /// to the Claude Code keychain. A binary that IS on the ACL (the same notarized app reading its
    /// own item in production) needs no interaction and still succeeds. The window is kept to a single
    /// SecItem call; the prior value is saved/restored rather than forced back to "allowed" so we never
    /// clobber an outer suppression. No-op when the deprecated symbols cannot be resolved.
    private static func withoutLegacyKeychainUI<T>(_ body: () -> T) -> T {
        guard
            let setSymbol = self.securitySymbol(named: "SecKeychainSetUserInteractionAllowed"),
            let getSymbol = self.securitySymbol(named: "SecKeychainGetUserInteractionAllowed")
        else {
            return body()
        }
        let setInteraction = unsafeBitCast(setSymbol, to: SetUserInteractionAllowedFunction.self)
        let getInteraction = unsafeBitCast(getSymbol, to: GetUserInteractionAllowedFunction.self)

        var previous: UInt8 = 1
        _ = getInteraction(&previous)
        guard setInteraction(0) == errSecSuccess else { return body() }
        defer { _ = setInteraction(previous) }
        return body()
    }

    #if DEBUG
    /// Captures the legacy keychain interaction-allowed flag from inside the suppression wrapper and
    /// again after it returns, so a test can assert the toggle both flips and restores. `nil` when the
    /// deprecated getter symbol is unavailable. Returns `(true, true)` shaped values otherwise.
    static func legacyKeychainUIProbeForTesting() -> (insideAllowed: Bool?, afterAllowed: Bool?) {
        func currentAllowed() -> Bool? {
            guard let getSymbol = self.securitySymbol(named: "SecKeychainGetUserInteractionAllowed") else {
                return nil
            }
            let getInteraction = unsafeBitCast(getSymbol, to: GetUserInteractionAllowedFunction.self)
            var state: UInt8 = 1
            guard getInteraction(&state) == errSecSuccess else { return nil }
            return state != 0
        }
        let inside = self.withoutLegacyKeychainUI { currentAllowed() }
        return (inside, currentAllowed())
    }
    #endif
    #endif

    private static func loadFromTestStore<Entry: Codable>(
        key: Key,
        as type: Entry.Type) -> LoadResult<Entry>?
    {
        self.testStoreLock.lock()
        defer { self.testStoreLock.unlock() }
        guard let store = self.testStore ?? (self.shouldUseImplicitTestStore ? self.implicitTestStore : nil)
        else { return nil }
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
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
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
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
        let testKey = TestStoreKey(service: self.serviceName, account: key.account)
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
