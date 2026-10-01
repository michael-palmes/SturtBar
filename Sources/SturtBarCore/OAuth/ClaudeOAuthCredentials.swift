import Dispatch
import Foundation

#if os(macOS)
import LocalAuthentication
import Security
#endif

// swiftlint:disable type_body_length file_length
public enum ClaudeOAuthCredentialsStore {
    private static let credentialsPath = ".claude/.credentials.json"
    static let claudeKeychainService = "Claude Code-credentials"
    private static let cacheKey = KeychainCacheStore.Key.oauthClaude
    public static let environmentTokenKey = "STURTBAR_CLAUDE_OAUTH_TOKEN"
    public static let environmentScopesKey = "STURTBAR_CLAUDE_OAUTH_SCOPES"

    static let log = SturtBarLog.logger("claude-usage")
    private static let fileFingerprintKey = "ClaudeOAuthCredentialsFileFingerprintV2"
    private static let claudeKeychainPromptLock = NSLock()
    private static let claudeKeychainFingerprintKey = "ClaudeOAuthClaudeKeychainFingerprintV2"
    private static let claudeKeychainFingerprintLegacyKey = "ClaudeOAuthClaudeKeychainFingerprintV1"
    private static let claudeKeychainChangeCheckLock = NSLock()
    private nonisolated(unsafe) static var lastClaudeKeychainChangeCheckAt: Date?
    private static let claudeKeychainChangeCheckMinimumInterval: TimeInterval = 60

    struct CredentialsFileFingerprint: Codable, Equatable {
        let modifiedAtMs: Int?
        let size: Int
    }

    struct CacheEntry: Codable {
        let data: Data
        let storedAt: Date
        let owner: ClaudeOAuthCredentialOwner?

        init(data: Data, storedAt: Date, owner: ClaudeOAuthCredentialOwner? = nil) {
            self.data = data
            self.storedAt = storedAt
            self.owner = owner
        }
    }

    #if DEBUG
    @TaskLocal private static var taskCredentialsURLOverride: URL?
    #endif
    @TaskLocal static var allowBackgroundPromptBootstrap: Bool = false
    // In-memory cache (nonisolated for synchronous access)
    private static let memoryCacheLock = NSLock()
    private nonisolated(unsafe) static var cachedCredentialRecord: ClaudeOAuthCredentialRecord?
    private nonisolated(unsafe) static var cacheTimestamp: Date?
    private static let memoryCacheValidityDuration: TimeInterval = 1800

    private static func readMemoryCache() -> (record: ClaudeOAuthCredentialRecord?, timestamp: Date?) {
        #if DEBUG
        if let store = self.taskMemoryCacheStoreOverride {
            return (store.record, store.timestamp)
        }
        #endif
        self.memoryCacheLock.lock()
        defer { self.memoryCacheLock.unlock() }
        return (self.cachedCredentialRecord, self.cacheTimestamp)
    }

    private static func writeMemoryCache(record: ClaudeOAuthCredentialRecord?, timestamp: Date?) {
        #if DEBUG
        if let store = self.taskMemoryCacheStoreOverride {
            store.record = record
            store.timestamp = timestamp
            return
        }
        #endif
        self.memoryCacheLock.lock()
        self.cachedCredentialRecord = record
        self.cacheTimestamp = timestamp
        self.memoryCacheLock.unlock()
    }

    private struct CollaboratorContext {
        let allowBackgroundPromptBootstrap: Bool
        #if DEBUG
        let credentialsURLOverride: URL?
        let testingOverrides: TestingOverridesSnapshot
        #endif

        func run<T>(_ operation: () throws -> T) rethrows -> T {
            try ClaudeOAuthCredentialsStore.$allowBackgroundPromptBootstrap
                .withValue(self.allowBackgroundPromptBootstrap) {
                    #if DEBUG
                    try ClaudeOAuthCredentialsStore.withTestingOverridesSnapshotForTask(self.testingOverrides) {
                        try ClaudeOAuthCredentialsStore
                            .withCredentialsURLOverrideForTesting(self.credentialsURLOverride) {
                                try operation()
                            }
                    }
                    #else
                    try operation()
                    #endif
                }
        }

        func run<T>(_ operation: () async throws -> T) async rethrows -> T {
            try await ClaudeOAuthCredentialsStore.$allowBackgroundPromptBootstrap
                .withValue(self.allowBackgroundPromptBootstrap) {
                    #if DEBUG
                    try await ClaudeOAuthCredentialsStore.withTestingOverridesSnapshotForTask(self.testingOverrides) {
                        try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(
                            self.credentialsURLOverride)
                        {
                            try await operation()
                        }
                    }
                    #else
                    try await operation()
                    #endif
                }
        }
    }

    private static func currentCollaboratorContext() -> CollaboratorContext {
        #if DEBUG
        return CollaboratorContext(
            allowBackgroundPromptBootstrap: self.allowBackgroundPromptBootstrap,
            credentialsURLOverride: self.taskCredentialsURLOverride,
            testingOverrides: self.currentTestingOverridesSnapshotForTask)
        #else
        return CollaboratorContext(
            allowBackgroundPromptBootstrap: self.allowBackgroundPromptBootstrap)
        #endif
    }

    private struct Repository {
        let context: CollaboratorContext

        func load(environment: [String: String], allowKeychainPrompt: Bool, respectKeychainPromptCooldown: Bool) throws
            -> ClaudeOAuthCredentials
        {
            try self.loadRecord(
                environment: environment,
                allowKeychainPrompt: allowKeychainPrompt,
                respectKeychainPromptCooldown: respectKeychainPromptCooldown,
                allowClaudeKeychainRepairWithoutPrompt: true).credentials
        }

        func loadRecord(
            environment: [String: String],
            allowKeychainPrompt: Bool,
            respectKeychainPromptCooldown: Bool,
            allowClaudeKeychainRepairWithoutPrompt: Bool) throws -> ClaudeOAuthCredentialRecord
        {
            try self.context.run {
                let shouldRespectKeychainPromptCooldownForSilentProbes =
                    respectKeychainPromptCooldown || !allowKeychainPrompt

                if let credentials = ClaudeOAuthCredentialsStore.loadFromEnvironment(environment) {
                    return ClaudeOAuthCredentialRecord(
                        credentials: credentials,
                        owner: .environment,
                        source: .environment)
                }

                _ = self.invalidateCacheIfCredentialsFileChanged()

                let recovery = Recovery(context: self.context)
                let memory = ClaudeOAuthCredentialsStore.readMemoryCache()
                if let cachedRecord = memory.record,
                   let timestamp = memory.timestamp,
                   Date().timeIntervalSince(timestamp) < ClaudeOAuthCredentialsStore.memoryCacheValidityDuration,
                   !cachedRecord.credentials.isExpired
                {
                    let record = ClaudeOAuthCredentialRecord(
                        credentials: cachedRecord.credentials,
                        owner: cachedRecord.owner,
                        source: .memoryCache)
                    if recovery.shouldAttemptFreshnessSyncFromClaudeKeychain(cached: record),
                       let synced = recovery.syncWithClaudeKeychainIfChanged(
                           cached: record,
                           respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
                    {
                        return synced
                    }
                    return record
                }

                var lastError: Error?
                var expiredRecord: ClaudeOAuthCredentialRecord?
                var credentialsFileMissing = false

                switch KeychainCacheStore.load(key: ClaudeOAuthCredentialsStore.cacheKey, as: CacheEntry.self) {
                case let .found(entry):
                    if let creds = try? ClaudeOAuthCredentials.parse(data: entry.data) {
                        let owner = entry.owner ?? .claudeCLI
                        let record = ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: owner,
                            source: .cacheKeychain)
                        if creds.isExpired {
                            expiredRecord = record
                        } else {
                            if recovery.shouldAttemptFreshnessSyncFromClaudeKeychain(cached: record),
                               let synced = recovery.syncWithClaudeKeychainIfChanged(
                                   cached: record,
                                   respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
                            {
                                return synced
                            }
                            ClaudeOAuthCredentialsStore.writeMemoryCache(
                                record: ClaudeOAuthCredentialRecord(
                                    credentials: creds,
                                    owner: owner,
                                    source: .memoryCache),
                                timestamp: Date())
                            return record
                        }
                    } else {
                        KeychainCacheStore.clear(key: ClaudeOAuthCredentialsStore.cacheKey)
                    }
                case .invalid:
                    KeychainCacheStore.clear(key: ClaudeOAuthCredentialsStore.cacheKey)
                case .temporarilyUnavailable, .missing:
                    break
                }

                do {
                    let fileData = try ClaudeOAuthCredentialsStore.loadFromFile()
                    let creds = try ClaudeOAuthCredentials.parse(data: fileData)
                    let record = ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .credentialsFile)
                    if creds.isExpired {
                        expiredRecord = record
                    } else {
                        ClaudeOAuthCredentialsStore.writeMemoryCache(
                            record: ClaudeOAuthCredentialRecord(
                                credentials: creds,
                                owner: .claudeCLI,
                                source: .memoryCache),
                            timestamp: Date())
                        ClaudeOAuthCredentialsStore.saveToCacheKeychain(fileData, owner: .claudeCLI)
                        return record
                    }
                } catch let error as ClaudeOAuthCredentialsError {
                    if case .notFound = error {
                        credentialsFileMissing = true
                    } else {
                        lastError = error
                    }
                } catch {
                    lastError = error
                }

                if allowClaudeKeychainRepairWithoutPrompt, !allowKeychainPrompt {
                    if let repaired = recovery.repairFromClaudeKeychainWithoutPromptIfAllowed(
                        now: Date(),
                        respectKeychainPromptCooldown: shouldRespectKeychainPromptCooldownForSilentProbes)
                    {
                        return repaired
                    }
                }

                if let prompted = self.loadFromClaudeKeychainWithPromptIfAllowed(
                    allowKeychainPrompt: allowKeychainPrompt,
                    respectKeychainPromptCooldown: respectKeychainPromptCooldown,
                    lastError: &lastError)
                {
                    return prompted
                }

                if let expiredRecord {
                    return try self.validatedStaleRecord(
                        expiredRecord,
                        credentialsFileMissing: credentialsFileMissing)
                }
                throw self.noReadableCredentialsError(lastError: lastError)
            }
        }

        /// Dead end when nothing was readable: the recorded error, else the keychain-access remedy if an item exists,
        /// else notFound.
        private func noReadableCredentialsError(lastError: Error?) -> Error {
            if let lastError { return lastError }
            if ClaudeOAuthCredentialsStore.hasClaudeKeychainItemWithoutPrompt() {
                return ClaudeOAuthCredentialsError.claudeKeychainAccessRequired(
                    underlying: "a Claude Code keychain item exists but cannot be read without a prompt",
                    reason: ClaudeOAuthCredentialsStore.keychainAccessRequiredReason())
            }
            return ClaudeOAuthCredentialsError.notFound
        }

        /// Claude Code's item changed since the last read but is unreadable silently: the renewed token needs access.
        private func validatedStaleRecord(
            _ record: ClaudeOAuthCredentialRecord,
            credentialsFileMissing: Bool) throws -> ClaudeOAuthCredentialRecord
        {
            if record.source == .cacheKeychain, credentialsFileMissing,
               case .value(false) = ClaudeOAuthCredentialsStore.claudeKeychainItemPresenceWithoutPrompt()
            {
                // Claude Code has signed out: drop SturtBar's stale copy so the sign-in card shows.
                ClaudeOAuthCredentialsStore.log.info("Claude Code storage is gone; clearing SturtBar's cached copy")
                ClaudeOAuthCredentialsStore.clearCacheKeychain()
                throw ClaudeOAuthCredentialsError.notFound
            }
            guard self.staleRecordNeedsClaudeKeychainAccess(record) else { return record }
            throw ClaudeOAuthCredentialsError.claudeKeychainAccessRequired(
                underlying: "the token in \(record.source.humanLabel) has expired",
                reason: ClaudeOAuthCredentialsStore.keychainAccessRequiredReason())
        }

        private func staleRecordNeedsClaudeKeychainAccess(_ record: ClaudeOAuthCredentialRecord) -> Bool {
            guard record.source != .claudeKeychain else { return false }
            // No fingerprint on record (the /usr/bin/security reader never saves one): a change is unknowable, so wait.
            guard ClaudeOAuthCredentialsStore.loadClaudeKeychainFingerprint() != nil else { return false }
            guard ClaudeOAuthCredentialsStore.hasClaudeKeychainItemWithoutPrompt() else { return false }
            return ClaudeOAuthCredentialsStore.claudeKeychainFingerprintChangedWithoutConsuming()
        }

        private func loadFromClaudeKeychainWithPromptIfAllowed(
            allowKeychainPrompt: Bool,
            respectKeychainPromptCooldown: Bool,
            lastError: inout Error?) -> ClaudeOAuthCredentialRecord?
        {
            let shouldApplyPromptCooldown =
                ClaudeOAuthCredentialsStore.isPromptPolicyApplicable && respectKeychainPromptCooldown
            let promptAllowed =
                allowKeychainPrompt
                    && (!shouldApplyPromptCooldown || ClaudeOAuthKeychainAccessGate.shouldAllowPrompt())
            guard promptAllowed else { return nil }

            do {
                ClaudeOAuthCredentialsStore.claudeKeychainPromptLock.lock()
                defer { ClaudeOAuthCredentialsStore.claudeKeychainPromptLock.unlock() }

                let memory = ClaudeOAuthCredentialsStore.readMemoryCache()
                if let cachedRecord = memory.record,
                   let timestamp = memory.timestamp,
                   Date().timeIntervalSince(timestamp) < ClaudeOAuthCredentialsStore.memoryCacheValidityDuration,
                   !cachedRecord.credentials.isExpired
                {
                    return ClaudeOAuthCredentialRecord(
                        credentials: cachedRecord.credentials,
                        owner: cachedRecord.owner,
                        source: .memoryCache)
                }
                if case let .found(entry) = KeychainCacheStore.load(
                    key: ClaudeOAuthCredentialsStore.cacheKey,
                    as: CacheEntry.self),
                    let creds = try? ClaudeOAuthCredentials.parse(data: entry.data),
                    !creds.isExpired
                {
                    return ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: entry.owner ?? .claudeCLI,
                        source: .cacheKeychain)
                }

                let promptMode = ClaudeOAuthKeychainPromptPreference.current()
                guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                    mode: promptMode,
                    allowKeychainPrompt: allowKeychainPrompt)
                else {
                    return nil
                }

                if ClaudeOAuthCredentialsStore.shouldPreferSecurityCLIKeychainRead(),
                   let keychainData = ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
                       interaction: InteractionContext.current)
                {
                    let creds = try ClaudeOAuthCredentials.parse(data: keychainData)
                    let record = ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .claudeKeychain)
                    ClaudeOAuthCredentialsStore.writeMemoryCache(
                        record: ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .memoryCache),
                        timestamp: Date())
                    ClaudeOAuthCredentialsStore.saveToCacheKeychain(keychainData, owner: .claudeCLI)
                    return record
                }

                let shouldPreferSecurityCLIKeychainRead =
                    ClaudeOAuthCredentialsStore.shouldPreferSecurityCLIKeychainRead()
                var fallbackPromptMode = promptMode
                if shouldPreferSecurityCLIKeychainRead {
                    fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
                    let fallbackDecision = ClaudeOAuthCredentialsStore.securityFrameworkFallbackPromptDecision(
                        promptMode: fallbackPromptMode,
                        allowKeychainPrompt: allowKeychainPrompt,
                        respectKeychainPromptCooldown: respectKeychainPromptCooldown)
                    ClaudeOAuthCredentialsStore.log.debug(
                        "Claude keychain Security.framework fallback prompt policy evaluated",
                        metadata: [
                            "reader": "securityFrameworkFallback",
                            "fallbackPromptMode": fallbackPromptMode.rawValue,
                            "fallbackPromptAllowed": "\(fallbackDecision.allowed)",
                            "fallbackBlockedReason": fallbackDecision.blockedReason ?? "none",
                        ])
                    guard fallbackDecision.allowed else { return nil }
                }

                if ClaudeOAuthCredentialsStore.shouldShowClaudeKeychainPreAlert() {
                    let decision = KeychainPromptHandler.requestApproval(
                        KeychainPromptContext(
                            kind: .claudeOAuth,
                            service: ClaudeOAuthCredentialsStore.claudeKeychainService,
                            account: nil))
                    guard decision == .proceed else {
                        // Declined at the explainer: no OS dialog and no denial cooldown, so the reconnect line stays
                        // clickable.
                        ClaudeOAuthCredentialsStore.log.info("Claude keychain pre-prompt declined")
                        return nil
                    }
                }
                let keychainData: Data = if shouldPreferSecurityCLIKeychainRead {
                    try ClaudeOAuthCredentialsStore.loadFromClaudeKeychainUsingSecurityFramework(
                        promptMode: fallbackPromptMode,
                        allowKeychainPrompt: true)
                } else {
                    try ClaudeOAuthCredentialsStore.loadFromClaudeKeychain()
                }
                let creds = try ClaudeOAuthCredentials.parse(data: keychainData)
                let record = ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: .claudeCLI,
                    source: .claudeKeychain)
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: Date())
                ClaudeOAuthCredentialsStore.saveToCacheKeychain(keychainData, owner: .claudeCLI)
                return record
            } catch let error as ClaudeOAuthCredentialsError {
                if case .notFound = error {
                } else {
                    lastError = error
                }
            } catch {
                lastError = error
            }
            return nil
        }

        @discardableResult
        func invalidateCacheIfCredentialsFileChanged() -> Bool {
            self.context.run {
                let current = ClaudeOAuthCredentialsStore.currentFileFingerprint()
                let stored = ClaudeOAuthCredentialsStore.loadFileFingerprint()
                guard current != stored else { return false }
                ClaudeOAuthCredentialsStore.log.info("Claude OAuth credentials file changed; invalidating cache")

                ClaudeOAuthCredentialsStore.writeMemoryCache(record: nil, timestamp: nil)

                var shouldClearKeychainCache = false
                var shouldSaveFileFingerprint = true
                if let current {
                    if let modifiedAtMs = current.modifiedAtMs {
                        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(Double(modifiedAtMs) / 1000.0))
                        switch KeychainCacheStore.load(
                            key: ClaudeOAuthCredentialsStore.cacheKey,
                            as: CacheEntry.self)
                        {
                        case let .found(entry):
                            if entry.storedAt < modifiedAt {
                                shouldClearKeychainCache = true
                            }
                        case .missing, .invalid:
                            shouldClearKeychainCache = true
                        case .temporarilyUnavailable:
                            shouldClearKeychainCache = false
                            shouldSaveFileFingerprint = false
                        }
                    } else {
                        shouldClearKeychainCache = true
                    }
                } else {
                    shouldClearKeychainCache = true
                }

                if shouldClearKeychainCache {
                    ClaudeOAuthCredentialsStore.clearCacheKeychain()
                }
                if shouldSaveFileFingerprint {
                    ClaudeOAuthCredentialsStore.saveFileFingerprint(current)
                }
                return true
            }
        }

        func invalidateCache() {
            self.context.run {
                ClaudeOAuthCredentialsStore.writeMemoryCache(record: nil, timestamp: nil)
                ClaudeOAuthCredentialsStore.clearCacheKeychain()
            }
        }

        func hasCachedCredentials(environment: [String: String], includingExpired: Bool) -> Bool {
            self.context.run {
                /// An expired token is no use for a fetch, so it counts only when the caller asks about any saved copy.
                func counts(_ creds: ClaudeOAuthCredentials) -> Bool {
                    includingExpired || !creds.isExpired
                }

                if let creds = ClaudeOAuthCredentialsStore.loadFromEnvironment(environment), counts(creds) {
                    return true
                }

                let memory = ClaudeOAuthCredentialsStore.readMemoryCache()
                if let timestamp = memory.timestamp,
                   let cached = memory.record,
                   Date().timeIntervalSince(timestamp) < ClaudeOAuthCredentialsStore.memoryCacheValidityDuration,
                   counts(cached.credentials)
                {
                    return true
                }

                switch KeychainCacheStore.load(key: ClaudeOAuthCredentialsStore.cacheKey, as: CacheEntry.self) {
                case let .found(entry):
                    if let creds = try? ClaudeOAuthCredentials.parse(data: entry.data), counts(creds) {
                        return true
                    }
                case .temporarilyUnavailable:
                    return true
                default:
                    break
                }

                if let fileData = try? ClaudeOAuthCredentialsStore.loadFromFile(),
                   let creds = try? ClaudeOAuthCredentials.parse(data: fileData),
                   counts(creds)
                {
                    return true
                }
                return false
            }
        }
    }

    private struct Recovery {
        let context: CollaboratorContext

        func shouldAttemptFreshnessSyncFromClaudeKeychain(cached: ClaudeOAuthCredentialRecord) -> Bool {
            guard !cached.credentials.isExpired else { return false }
            guard cached.owner == .claudeCLI else { return false }
            guard ClaudeOAuthCredentialsStore.keychainAccessAllowed else { return false }

            let mode = ClaudeOAuthKeychainPromptPreference.storedMode()
            switch mode {
            case .never:
                return false
            case .onlyOnUserAction:
                if InteractionContext.current != .userInitiated {
                    if ProcessInfo.processInfo.environment["STURTBAR_DEBUG_CLAUDE_OAUTH_FLOW"] == "1" {
                        ClaudeOAuthCredentialsStore.log.debug(
                            "Claude OAuth keychain freshness sync skipped (background)",
                            metadata: ["promptMode": mode.rawValue, "owner": String(describing: cached.owner)])
                    }
                    return false
                }
                return true
            case .always:
                return true
            }
        }

        func syncWithClaudeKeychainIfChanged(
            cached: ClaudeOAuthCredentialRecord,
            respectKeychainPromptCooldown: Bool,
            now: Date = Date()) -> ClaudeOAuthCredentialRecord?
        {
            #if os(macOS)
            let mode = ClaudeOAuthKeychainPromptPreference.current()
            guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                mode: mode,
                allowKeychainPrompt: false) else { return nil }
            if ClaudeOAuthCredentialsStore.isPromptPolicyApplicable,
               respectKeychainPromptCooldown,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now)
            {
                return nil
            }

            if ClaudeOAuthCredentialsStore.shouldShowClaudeKeychainPreAlert() {
                return nil
            }

            if !ClaudeOAuthCredentialsStore.shouldCheckClaudeKeychainChange(now: now) {
                return nil
            }

            guard let currentFingerprint = ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPrompt()
            else {
                return nil
            }
            let storedFingerprint = ClaudeOAuthCredentialsStore.loadClaudeKeychainFingerprint()
            guard currentFingerprint != storedFingerprint else { return nil }

            do {
                guard let data = try ClaudeOAuthCredentialsStore.loadFromClaudeKeychainNonInteractive() else {
                    return nil
                }
                guard let keychainCreds = try? ClaudeOAuthCredentials.parse(data: data) else {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(currentFingerprint)
                    return nil
                }
                ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(currentFingerprint)

                guard keychainCreds.accessToken != cached.credentials.accessToken else { return nil }
                if keychainCreds.isExpired, !cached.credentials.isExpired { return nil }

                ClaudeOAuthCredentialsStore.log.info("Claude keychain credentials changed; syncing OAuth cache")
                let synced = ClaudeOAuthCredentialRecord(
                    credentials: keychainCreds,
                    owner: .claudeCLI,
                    source: .claudeKeychain)
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: keychainCreds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: now)
                ClaudeOAuthCredentialsStore.saveToCacheKeychain(data, owner: .claudeCLI)
                return synced
            } catch let error as ClaudeOAuthCredentialsError {
                if case let .keychainError(status) = error,
                   status == Int(errSecUserCanceled)
                   || status == Int(errSecAuthFailed)
                   || status == Int(errSecInteractionNotAllowed)
                   || status == Int(errSecNoAccessForItem)
                {
                    ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
                }
                return nil
            } catch {
                return nil
            }
            #else
            _ = cached
            _ = respectKeychainPromptCooldown
            _ = now
            return nil
            #endif
        }

        func repairFromClaudeKeychainWithoutPromptIfAllowed(
            now: Date,
            respectKeychainPromptCooldown: Bool) -> ClaudeOAuthCredentialRecord?
        {
            #if os(macOS)
            let mode = ClaudeOAuthKeychainPromptPreference.current()
            guard ClaudeOAuthCredentialsStore.shouldAllowClaudeCodeKeychainAccess(
                mode: mode,
                allowKeychainPrompt: false) else { return nil }

            if ClaudeOAuthCredentialsStore.shouldShowClaudeKeychainPreAlert() {
                return nil
            }

            if ClaudeOAuthCredentialsStore.isPromptPolicyApplicable,
               respectKeychainPromptCooldown,
               InteractionContext.current != .userInitiated,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now)
            {
                return nil
            }

            do {
                if ClaudeOAuthCredentialsStore.shouldPreferSecurityCLIKeychainRead(),
                   let securityData = ClaudeOAuthCredentialsStore.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
                       interaction: InteractionContext.current),
                   !securityData.isEmpty
                {
                    guard let creds = try? ClaudeOAuthCredentials.parse(data: securityData) else { return nil }
                    if creds.isExpired {
                        return ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .claudeKeychain)
                    }

                    ClaudeOAuthCredentialsStore.writeMemoryCache(
                        record: ClaudeOAuthCredentialRecord(
                            credentials: creds,
                            owner: .claudeCLI,
                            source: .memoryCache),
                        timestamp: now)
                    ClaudeOAuthCredentialsStore.saveToCacheKeychain(securityData, owner: .claudeCLI)

                    ClaudeOAuthCredentialsStore.log.info(
                        "Claude keychain credentials loaded without prompt; syncing OAuth cache",
                        metadata: ["interaction": InteractionContext.current == .userInitiated
                            ? "user" : "background"])
                    return ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .claudeKeychain)
                }

                guard let data = try ClaudeOAuthCredentialsStore.loadFromClaudeKeychainNonInteractive(),
                      !data.isEmpty
                else {
                    return nil
                }
                let fingerprint = ClaudeOAuthCredentialsStore.currentClaudeKeychainFingerprintWithoutPrompt()
                guard let creds = try? ClaudeOAuthCredentials.parse(data: data) else {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                    return nil
                }

                if creds.isExpired {
                    ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                    return ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .claudeKeychain)
                }

                ClaudeOAuthCredentialsStore.saveClaudeKeychainFingerprint(fingerprint)
                ClaudeOAuthCredentialsStore.writeMemoryCache(
                    record: ClaudeOAuthCredentialRecord(
                        credentials: creds,
                        owner: .claudeCLI,
                        source: .memoryCache),
                    timestamp: now)
                ClaudeOAuthCredentialsStore.saveToCacheKeychain(data, owner: .claudeCLI)

                ClaudeOAuthCredentialsStore.log.info(
                    "Claude keychain credentials loaded without prompt; syncing OAuth cache",
                    metadata: ["interaction": InteractionContext.current == .userInitiated
                        ? "user" : "background"])
                return ClaudeOAuthCredentialRecord(
                    credentials: creds,
                    owner: .claudeCLI,
                    source: .claudeKeychain)
            } catch let error as ClaudeOAuthCredentialsError {
                if case let .keychainError(status) = error,
                   status == Int(errSecUserCanceled)
                   || status == Int(errSecAuthFailed)
                   || status == Int(errSecInteractionNotAllowed)
                   || status == Int(errSecNoAccessForItem)
                {
                    ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
                }
                return nil
            } catch {
                return nil
            }
            #else
            _ = now
            _ = respectKeychainPromptCooldown
            return nil
            #endif
        }
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) throws -> ClaudeOAuthCredentials
    {
        let context = self.currentCollaboratorContext()
        return try Repository(context: context).load(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown)
    }

    public static func loadRecord(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false,
        allowClaudeKeychainRepairWithoutPrompt: Bool = true) throws -> ClaudeOAuthCredentialRecord
    {
        let context = self.currentCollaboratorContext()
        return try Repository(context: context).loadRecord(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown,
            allowClaudeKeychainRepairWithoutPrompt: allowClaudeKeychainRepairWithoutPrompt)
    }

    /// Never refreshes: an expired token throws `.tokenExpired` with no network call until Claude Code renews it.
    public static func loadForUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychainPrompt: Bool = true,
        respectKeychainPromptCooldown: Bool = false) throws -> ClaudeOAuthCredentialRecord
    {
        let record = try Repository(context: self.currentCollaboratorContext()).loadRecord(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown,
            allowClaudeKeychainRepairWithoutPrompt: true)
        let credentials = record.credentials
        let now = Date()
        var expiryMetadata = credentials.diagnosticsMetadata(now: now)
        expiryMetadata["source"] = record.source.rawValue
        expiryMetadata["owner"] = record.owner.rawValue
        expiryMetadata["allowKeychainPrompt"] = "\(allowKeychainPrompt)"
        expiryMetadata["respectPromptCooldown"] = "\(respectKeychainPromptCooldown)"
        expiryMetadata["readStrategy"] = ClaudeOAuthKeychainReadStrategyPreference.current().rawValue

        let isExpired: Bool = if let expiresAt = credentials.expiresAt {
            now >= expiresAt
        } else {
            true
        }
        guard isExpired else {
            self.log.debug("Claude OAuth credentials loaded for usage", metadata: expiryMetadata)
            return record
        }

        self.log.info("Claude OAuth credentials considered expired", metadata: expiryMetadata)
        throw ClaudeOAuthCredentialsError.tokenExpired(source: record.expirySource)
    }

    /// The blocker is the opt-out itself when prompts are off, otherwise the item's access control.
    static func keychainAccessRequiredReason() -> ClaudeKeychainAccessRequiredReason {
        ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode() == .never
            ? .promptsDisabled : .accessLost
    }

    public static func loadFromFile() throws -> Data {
        let url = self.credentialsFileURL()
        do {
            return try Data(contentsOf: url)
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                throw ClaudeOAuthCredentialsError.notFound
            }
            throw ClaudeOAuthCredentialsError.readFailed(error.localizedDescription)
        }
    }

    public static func credentialsFileFingerprintToken() -> String? {
        guard let fingerprint = self.currentFileFingerprint() else { return nil }
        let modifiedAt = fingerprint.modifiedAtMs.map(String.init) ?? "nil"
        return "\(modifiedAt):\(fingerprint.size)"
    }

    public static func authFingerprintToken() -> String {
        let file = self.credentialsFileFingerprintToken() ?? "nil"
        let keychain = self.claudeKeychainFingerprintToken() ?? "nil"
        return "file=\(file)|keychain=\(keychain)"
    }

    public static func consumeClaudeKeychainFingerprintChangeWithoutPrompt() -> Bool {
        let current: ClaudeKeychainFingerprint?
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            return false
        case let .value(fingerprint):
            current = fingerprint
        }
        let stored = self.loadClaudeKeychainFingerprint()
        guard current != stored else { return false }
        self.saveClaudeKeychainFingerprint(current)
        return true
    }

    public static func claudeKeychainFingerprintChangedWithoutConsuming() -> Bool {
        let current: ClaudeKeychainFingerprint?
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            return false
        case let .value(fingerprint):
            current = fingerprint
        }
        return current != self.loadClaudeKeychainFingerprint()
    }

    public static func claudeKeychainFingerprintToken() -> String? {
        let fingerprint: ClaudeKeychainFingerprint? = switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            self.loadClaudeKeychainFingerprint()
        case let .value(probed):
            probed
        }
        guard let fingerprint else { return nil }
        let modifiedAt = fingerprint.modifiedAt.map(String.init) ?? "nil"
        let createdAt = fingerprint.createdAt.map(String.init) ?? "nil"
        let persistentRefHash = fingerprint.persistentRefHash ?? "nil"
        return "\(modifiedAt):\(createdAt):\(persistentRefHash)"
    }

    private enum ClaudeKeychainProbe<Value> {
        case unavailable
        case value(Value)
    }

    @discardableResult
    public static func invalidateCacheIfCredentialsFileChanged() -> Bool {
        Repository(context: self.currentCollaboratorContext()).invalidateCacheIfCredentialsFileChanged()
    }

    /// Invalidate the credentials cache (call after login/logout)
    public static func invalidateCache() {
        Repository(context: self.currentCollaboratorContext()).invalidateCache()
    }

    /// Check if SturtBar has cached credentials (in memory or keychain cache)
    public static func hasCachedCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includingExpired: Bool = false) -> Bool
    {
        Repository(context: self.currentCollaboratorContext()).hasCachedCredentials(
            environment: environment,
            includingExpired: includingExpired)
    }

    private static func hasClaudeKeychainItemWithoutPrompt() -> Bool {
        if case .value(true) = self.claudeKeychainItemPresenceWithoutPrompt() { return true }
        return false
    }

    /// Whether Claude Code's keychain item exists, from a no-UI attribute probe; `.unavailable` when it can't tell.
    private static func claudeKeychainItemPresenceWithoutPrompt() -> ClaudeKeychainProbe<Bool> {
        #if DEBUG
        if let store = self.taskClaudeKeychainOverrideStore {
            return .value(!(store.data?.isEmpty ?? true) || store.fingerprint != nil)
        }
        if let data = self.taskClaudeKeychainDataOverride, !data.isEmpty {
            return .value(true)
        }
        if self.taskClaudeKeychainFingerprintOverride != nil {
            return .value(true)
        }
        #endif

        #if os(macOS)
        let candidates = self.claudeKeychainCandidatesProbeWithoutPrompt(enforcePromptPolicy: false)
        if case let .value(found) = candidates, !found.isEmpty { return .value(true) }
        let legacy = self.claudeKeychainLegacyCandidateProbeWithoutPrompt(enforcePromptPolicy: false)
        switch (candidates, legacy) {
        case (_, .value(.some)):
            return .value(true)
        case (.value, .value(.none)):
            return .value(false)
        default:
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    private static func shouldCheckClaudeKeychainChange(now: Date = Date()) -> Bool {
        #if DEBUG
        // Unit tests can supply TaskLocal overrides for the Claude keychain data/fingerprint. Those tests often run
        // concurrently with other suites, so the global throttle becomes nondeterministic. When an override is
        // present, bypass the throttle so test expectations don't depend on unrelated activity.
        if self.taskClaudeKeychainOverrideStore != nil || self.taskClaudeKeychainFingerprintOverride != nil {
            return true
        }
        #endif

        self.claudeKeychainChangeCheckLock.lock()
        defer { self.claudeKeychainChangeCheckLock.unlock() }
        if let last = self.lastClaudeKeychainChangeCheckAt,
           now.timeIntervalSince(last) < self.claudeKeychainChangeCheckMinimumInterval
        {
            return false
        }
        self.lastClaudeKeychainChangeCheckAt = now
        return true
    }

    private static func loadClaudeKeychainFingerprint() -> ClaudeKeychainFingerprint? {
        #if DEBUG
        if let store = taskClaudeKeychainFingerprintStoreOverride {
            return store.fingerprint
        }
        #endif
        // Proactively remove the legacy V1 key (it included the keychain account string, which can be identifying).
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)

        guard let data = UserDefaults.standard.data(forKey: self.claudeKeychainFingerprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ClaudeKeychainFingerprint.self, from: data)
    }

    private static func saveClaudeKeychainFingerprint(_ fingerprint: ClaudeKeychainFingerprint?) {
        #if DEBUG
        if let store = taskClaudeKeychainFingerprintStoreOverride {
            store.fingerprint = fingerprint
            return
        }
        #endif
        // Proactively remove the legacy V1 key (it included the keychain account string, which can be identifying).
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)

        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintKey)
            return
        }
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: self.claudeKeychainFingerprintKey)
        }
    }

    static func currentClaudeKeychainFingerprintWithoutPrompt() -> ClaudeKeychainFingerprint? {
        switch self.probeClaudeKeychainFingerprintWithoutPrompt() {
        case .unavailable:
            nil
        case let .value(fingerprint):
            fingerprint
        }
    }

    private static func probeClaudeKeychainFingerprintWithoutPrompt()
    -> ClaudeKeychainProbe<ClaudeKeychainFingerprint?> {
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore { return .value(store.fingerprint) }
        if let override = taskClaudeKeychainFingerprintOverride { return .value(override) }
        #endif
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else {
            return .unavailable
        }
        if self.isPromptPolicyApplicable,
           InteractionContext.current == .background,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return .unavailable
        }
        #if os(macOS)
        let candidatesProbe = self.claudeKeychainCandidatesProbeWithoutPrompt(promptMode: mode)
        let newest: ClaudeKeychainCandidate?
        switch candidatesProbe {
        case .unavailable:
            return .unavailable
        case let .value(candidates):
            if let first = candidates.first {
                newest = first
            } else {
                switch self.claudeKeychainLegacyCandidateProbeWithoutPrompt(promptMode: mode) {
                case .unavailable:
                    return .unavailable
                case let .value(candidate):
                    newest = candidate
                }
            }
        }
        guard let newest else { return .value(nil) }

        let modifiedAt = newest.modifiedAt.map { Int($0.timeIntervalSince1970) }
        let createdAt = newest.createdAt.map { Int($0.timeIntervalSince1970) }
        let persistentRefHash = Self.sha256Prefix(newest.persistentRef)
        return .value(ClaudeKeychainFingerprint(
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            persistentRefHash: persistentRefHash))
        #else
        return .unavailable
        #endif
    }

    private static func loadFromClaudeKeychainNonInteractive() throws -> Data? {
        #if os(macOS)
        let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
        if let data = self.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
            interaction: InteractionContext.current)
        {
            return data
        }

        guard self.shouldAllowSecurityFrameworkFallback(mode: fallbackPromptMode) else { return nil }

        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore { return store.data }
        if let override = taskClaudeKeychainDataOverride { return override }
        #endif

        // Keep semantics aligned with fingerprinting: if there are multiple entries, we only ever consult the newest
        // candidate (same as currentClaudeKeychainFingerprintWithoutPrompt()) to avoid syncing from a different item.
        let candidates = self.claudeKeychainCandidatesWithoutPrompt(promptMode: fallbackPromptMode)
        if let newest = candidates.first {
            if let data = try self.loadClaudeKeychainData(candidate: newest, allowKeychainPrompt: false),
               !data.isEmpty
            {
                return data
            }
            return nil
        }

        let legacyData = try self.loadClaudeKeychainLegacyData(
            allowKeychainPrompt: false,
            promptMode: fallbackPromptMode)
        if let legacyData, !legacyData.isEmpty { return legacyData }
        return nil
        #else
        return nil
        #endif
    }

    public static func loadFromClaudeKeychain() throws -> Data {
        guard self.shouldAllowClaudeCodeKeychainAccess(
            mode: ClaudeOAuthKeychainPromptPreference.current(),
            allowKeychainPrompt: true)
        else {
            throw ClaudeOAuthCredentialsError.notFound
        }
        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore, let override = store.data { return override }
        if let override = taskClaudeKeychainDataOverride { return override }
        #endif
        if let data = self.loadFromClaudeKeychainViaSecurityCLIIfEnabled(
            interaction: InteractionContext.current)
        {
            return data
        }
        if self.shouldPreferSecurityCLIKeychainRead() {
            let fallbackPromptMode = ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode()
            let fallbackDecision = self.securityFrameworkFallbackPromptDecision(
                promptMode: fallbackPromptMode,
                allowKeychainPrompt: true,
                respectKeychainPromptCooldown: false)
            self.log.debug(
                "Claude keychain Security.framework fallback prompt policy evaluated",
                metadata: [
                    "reader": "securityFrameworkFallback",
                    "fallbackPromptMode": fallbackPromptMode.rawValue,
                    "fallbackPromptAllowed": "\(fallbackDecision.allowed)",
                    "fallbackBlockedReason": fallbackDecision.blockedReason ?? "none",
                ])
            guard fallbackDecision.allowed else {
                throw ClaudeOAuthCredentialsError.notFound
            }
            return try self.loadFromClaudeKeychainUsingSecurityFramework(
                promptMode: fallbackPromptMode,
                allowKeychainPrompt: true)
        }
        return try self.loadFromClaudeKeychainUsingSecurityFramework()
    }

    private static func loadFromClaudeKeychainUsingSecurityFramework(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current(),
        allowKeychainPrompt: Bool = true) throws -> Data
    {
        #if DEBUG
        if let store = taskClaudeKeychainOverrideStore, let override = store.data { return override }
        if let override = taskClaudeKeychainDataOverride { return override }
        #endif
        #if os(macOS)
        let candidates = self.claudeKeychainCandidatesWithoutPrompt(promptMode: promptMode)
        if let newest = candidates.first {
            do {
                if let data = try self.loadClaudeKeychainData(
                    candidate: newest,
                    allowKeychainPrompt: allowKeychainPrompt,
                    promptMode: promptMode),
                    !data.isEmpty
                {
                    // Store fingerprint after a successful interactive read so we don't immediately try to
                    // "sync" in the background (which can still show UI on some systems).
                    let modifiedAt = newest.modifiedAt.map { Int($0.timeIntervalSince1970) }
                    let createdAt = newest.createdAt.map { Int($0.timeIntervalSince1970) }
                    let persistentRefHash = Self.sha256Prefix(newest.persistentRef)
                    self.saveClaudeKeychainFingerprint(
                        ClaudeKeychainFingerprint(
                            modifiedAt: modifiedAt,
                            createdAt: createdAt,
                            persistentRefHash: persistentRefHash))
                    return data
                }
            } catch let error as ClaudeOAuthCredentialsError {
                if case .keychainError = error {
                    ClaudeOAuthKeychainAccessGate.recordDenied()
                }
                throw error
            }
        }

        // Fallback: legacy query (may pick an arbitrary duplicate).
        do {
            if let data = try self.loadClaudeKeychainLegacyData(
                allowKeychainPrompt: allowKeychainPrompt,
                promptMode: promptMode),
                !data.isEmpty
            {
                // Same as above: store fingerprint after interactive read to avoid background "sync" reads.
                self.saveClaudeKeychainFingerprint(self.currentClaudeKeychainFingerprintWithoutPrompt())
                return data
            }
        } catch let error as ClaudeOAuthCredentialsError {
            if case .keychainError = error {
                ClaudeOAuthKeychainAccessGate.recordDenied()
            }
            throw error
        }
        throw ClaudeOAuthCredentialsError.notFound
        #else
        throw ClaudeOAuthCredentialsError.notFound
        #endif
    }

    #if os(macOS)
    private struct ClaudeKeychainCandidate {
        let persistentRef: Data
        let account: String?
        let modifiedAt: Date?
        let createdAt: Date?
    }

    private static func claudeKeychainCandidatesProbeWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current(),
        enforcePromptPolicy: Bool = true) -> ClaudeKeychainProbe<[ClaudeKeychainCandidate]>
    {
        if enforcePromptPolicy {
            guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: false) else {
                return .unavailable
            }
            if self.isPromptPolicyApplicable,
               InteractionContext.current == .background,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt() { return .unavailable }
        } else {
            guard self.keychainAccessAllowed else { return .unavailable }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        let (status, result, durationMs) = ClaudeOAuthKeychainQueryTiming.copyMatching(query)
        if ClaudeOAuthKeychainQueryTiming
            .backoffIfSlowNoUIQuery(durationMs, self.claudeKeychainService, self.log) { return .unavailable }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecNoAccessForItem {
            ClaudeOAuthKeychainAccessGate.recordDenied()
        }
        if status == errSecItemNotFound { return .value([]) }
        guard status == errSecSuccess else { return .unavailable }
        guard let rows = result as? [[String: Any]], !rows.isEmpty else { return .value([]) }

        let candidates: [ClaudeKeychainCandidate] = rows.compactMap { row in
            guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return nil }
            return ClaudeKeychainCandidate(
                persistentRef: persistentRef,
                account: row[kSecAttrAccount as String] as? String,
                modifiedAt: row[kSecAttrModificationDate as String] as? Date,
                createdAt: row[kSecAttrCreationDate as String] as? Date)
        }

        let sorted = candidates.sorted { lhs, rhs in
            let lhsDate = lhs.modifiedAt ?? lhs.createdAt ?? Date.distantPast
            let rhsDate = rhs.modifiedAt ?? rhs.createdAt ?? Date.distantPast
            return lhsDate > rhsDate
        }
        return .value(sorted)
    }

    private static func claudeKeychainCandidatesWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current()) -> [ClaudeKeychainCandidate]
    {
        switch self.claudeKeychainCandidatesProbeWithoutPrompt(promptMode: promptMode) {
        case .unavailable:
            []
        case let .value(candidates):
            candidates
        }
    }

    private static func claudeKeychainLegacyCandidateProbeWithoutPrompt(
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference
            .current(),
        enforcePromptPolicy: Bool = true) -> ClaudeKeychainProbe<ClaudeKeychainCandidate?>
    {
        if enforcePromptPolicy {
            guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: false) else {
                return .unavailable
            }
            if self.isPromptPolicyApplicable,
               InteractionContext.current == .background,
               !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt() { return .unavailable }
        } else {
            guard self.keychainAccessAllowed else { return .unavailable }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        let (status, result, durationMs) = ClaudeOAuthKeychainQueryTiming.copyMatching(query)
        if ClaudeOAuthKeychainQueryTiming
            .backoffIfSlowNoUIQuery(durationMs, self.claudeKeychainService, self.log) { return .unavailable }
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecNoAccessForItem {
            ClaudeOAuthKeychainAccessGate.recordDenied()
        }
        if status == errSecItemNotFound { return .value(nil) }
        guard status == errSecSuccess else { return .unavailable }
        guard let row = result as? [String: Any] else { return .value(nil) }
        guard let persistentRef = row[kSecValuePersistentRef as String] as? Data else { return .value(nil) }
        return .value(ClaudeKeychainCandidate(
            persistentRef: persistentRef,
            account: row[kSecAttrAccount as String] as? String,
            modifiedAt: row[kSecAttrModificationDate as String] as? Date,
            createdAt: row[kSecAttrCreationDate as String] as? Date))
    }

    private static func loadClaudeKeychainData(
        candidate: ClaudeKeychainCandidate,
        allowKeychainPrompt: Bool,
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current()) throws -> Data?
    {
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: allowKeychainPrompt)
        else {
            return nil
        }
        self.log.debug(
            "Claude keychain data read start",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "process": ProcessInfo.processInfo.processName,
            ])

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: candidate.persistentRef,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let (status, result) = self.copyClaudeKeychainData(query, allowKeychainPrompt: allowKeychainPrompt)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        self.log.debug(
            "Claude keychain data read result",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "process": ProcessInfo.processInfo.processName,
            ])
        switch status {
        case errSecSuccess:
            if let data = result as? Data {
                return data
            }
            return nil
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowKeychainPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        case errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }

    /// A silent read of Claude Code's secret also suppresses the legacy dialog, which `KeychainNoUIQuery` flags miss.
    static func copyClaudeKeychainData(
        _ query: [String: Any],
        allowKeychainPrompt: Bool) -> (status: OSStatus, result: AnyObject?)
    {
        guard !allowKeychainPrompt else { return self.copyClaudeKeychainItem(query) }
        var query = query
        KeychainNoUIQuery.apply(to: &query)
        return KeychainNoUIQuery.withoutLegacyKeychainUI { self.copyClaudeKeychainItem(query) }
    }

    private static func copyClaudeKeychainItem(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        #if DEBUG
        if let override = self.taskClaudeKeychainDataCopyOverride { return override(query) }
        #endif
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    private static func loadClaudeKeychainLegacyData(
        allowKeychainPrompt: Bool,
        promptMode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current()) throws -> Data?
    {
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: allowKeychainPrompt)
        else {
            return nil
        }
        self.log.debug(
            "Claude keychain legacy data read start",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "process": ProcessInfo.processInfo.processName,
            ])

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.claudeKeychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        let startedAtNs = DispatchTime.now().uptimeNanoseconds
        let (status, result) = self.copyClaudeKeychainData(query, allowKeychainPrompt: allowKeychainPrompt)
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAtNs) / 1_000_000.0
        self.log.debug(
            "Claude keychain legacy data read result",
            metadata: [
                "service": self.claudeKeychainService,
                "interactive": "\(allowKeychainPrompt)",
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "process": ProcessInfo.processInfo.processName,
            ])
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            if allowKeychainPrompt {
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(Int(status))
            }
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        case errSecNoAccessForItem:
            ClaudeOAuthKeychainAccessGate.recordDenied()
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        default:
            throw ClaudeOAuthCredentialsError.keychainError(Int(status))
        }
    }
    #endif

    private static func loadFromEnvironment(_ environment: [String: String])
        -> ClaudeOAuthCredentials?
    {
        guard
            let token = environment[self.environmentTokenKey]?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return nil
        }

        let scopes: [String] = {
            guard let raw = environment[self.environmentScopesKey] else { return ["user:profile"] }
            let parsed =
                raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            return parsed.isEmpty ? ["user:profile"] : parsed
        }()

        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: Date.distantFuture,
            scopes: scopes,
            rateLimitTier: nil)
    }

    #if DEBUG
    public static func withCredentialsURLOverrideForTesting<T>(_ url: URL?, operation: () throws -> T) rethrows -> T {
        try self.$taskCredentialsURLOverride.withValue(url) {
            try operation()
        }
    }

    public static func withCredentialsURLOverrideForTesting<T>(_ url: URL?, operation: () async throws -> T)
    async rethrows -> T {
        try await self.$taskCredentialsURLOverride.withValue(url) {
            try await operation()
        }
    }

    public static var currentCredentialsURLOverrideForTesting: URL? {
        self.taskCredentialsURLOverride
    }
    #endif

    private static func saveToCacheKeychain(_ data: Data, owner: ClaudeOAuthCredentialOwner? = nil) {
        let entry = CacheEntry(data: data, storedAt: Date(), owner: owner)
        KeychainCacheStore.store(key: self.cacheKey, entry: entry)
    }

    private static func clearCacheKeychain() {
        KeychainCacheStore.clear(key: self.cacheKey)
    }

    private static var keychainAccessAllowed: Bool {
        #if DEBUG
        if let override = self.taskKeychainAccessOverride { return !override }
        if KeychainAccessGate.currentOverrideForTesting == true { return false }
        if self.hasTaskKeychainTestingOverride { return true }
        #endif
        return !KeychainAccessGate.isDisabled
    }

    #if DEBUG
    private static var hasTaskKeychainTestingOverride: Bool {
        self.taskClaudeKeychainOverrideStore != nil
            || self.taskClaudeKeychainDataOverride != nil
            || self.taskClaudeKeychainFingerprintOverride != nil
            || self.taskSecurityCLIReadOverride != nil
            || self.taskSecurityCLIReadAccountOverride != nil
    }
    #endif

    private static var isPromptPolicyApplicable: Bool {
        ClaudeOAuthKeychainPromptPreference.isApplicable()
    }

    private static func securityFrameworkFallbackPromptDecision(
        promptMode: ClaudeOAuthKeychainPromptMode,
        allowKeychainPrompt: Bool,
        respectKeychainPromptCooldown: Bool) -> (allowed: Bool, blockedReason: String?)
    {
        guard allowKeychainPrompt else {
            return (allowed: false, blockedReason: "allowKeychainPromptFalse")
        }
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: promptMode, allowKeychainPrompt: allowKeychainPrompt)
        else {
            return (allowed: false, blockedReason: self.fallbackBlockedReason(promptMode: promptMode))
        }
        if respectKeychainPromptCooldown,
           !ClaudeOAuthKeychainAccessGate.shouldAllowPrompt()
        {
            return (allowed: false, blockedReason: "cooldown")
        }
        return (allowed: true, blockedReason: nil)
    }

    private static func fallbackBlockedReason(promptMode: ClaudeOAuthKeychainPromptMode) -> String {
        if !self.keychainAccessAllowed { return "keychainDisabled" }
        switch promptMode {
        case .never:
            return "never"
        case .onlyOnUserAction:
            return "onlyOnUserAction-background"
        case .always:
            return "disallowed"
        }
    }

    /// The prompt mode governs only reads that can show the macOS dialog; silent no-UI reads pass under every mode.
    static func shouldAllowClaudeCodeKeychainAccess(
        mode: ClaudeOAuthKeychainPromptMode = ClaudeOAuthKeychainPromptPreference.current(),
        allowKeychainPrompt: Bool) -> Bool
    {
        guard self.keychainAccessAllowed else { return false }
        switch mode {
        case .never: return !allowKeychainPrompt
        case .onlyOnUserAction:
            return !allowKeychainPrompt
                || InteractionContext.current == .userInitiated
                || self.allowBackgroundPromptBootstrap
        case .always: return true
        }
    }

    /// Behind the /usr/bin/security reader any Security.framework fallback stays opt-in, so it gates as a prompt.
    private static func shouldAllowSecurityFrameworkFallback(mode: ClaudeOAuthKeychainPromptMode) -> Bool {
        self.shouldAllowClaudeCodeKeychainAccess(
            mode: mode,
            allowKeychainPrompt: self.shouldPreferSecurityCLIKeychainRead())
    }

    static func preferredClaudeKeychainAccountForSecurityCLIRead(
        interaction: Interaction = InteractionContext.current) -> String?
    {
        // Keep the experimental background path fully on /usr/bin/security by default.
        // Account pinning requires Security.framework candidate probing, so only allow it on explicit user actions.
        guard interaction == .userInitiated else { return nil }
        #if DEBUG
        if let override = self.taskSecurityCLIReadAccountOverride { return override }
        #endif
        #if os(macOS)
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else { return nil }
        // Keep experimental mode prompt-safe: avoid Security.framework candidate probes when preflight says
        // interaction is likely.
        if self.shouldShowClaudeKeychainPreAlert() {
            return nil
        }
        guard let account = self.claudeKeychainCandidatesWithoutPrompt(promptMode: mode).first?.account,
              !account.isEmpty
        else {
            return nil
        }
        return account
        #else
        return nil
        #endif
    }

    private static func credentialsFileURL() -> URL {
        #if DEBUG
        if let override = self.taskCredentialsURLOverride { return override }
        #endif
        return self.defaultCredentialsURL()
    }

    private static func loadFileFingerprint() -> CredentialsFileFingerprint? {
        #if DEBUG
        if let store = self.taskCredentialsFileFingerprintStoreOverride { return store.load() }
        #endif
        guard let data = UserDefaults.standard.data(forKey: self.fileFingerprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(CredentialsFileFingerprint.self, from: data)
    }

    private static func saveFileFingerprint(_ fingerprint: CredentialsFileFingerprint?) {
        #if DEBUG
        if let store = self.taskCredentialsFileFingerprintStoreOverride { store.save(fingerprint); return }
        #endif
        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: self.fileFingerprintKey)
            return
        }
        if let data = try? JSONEncoder().encode(fingerprint) {
            UserDefaults.standard.set(data, forKey: self.fileFingerprintKey)
        }
    }

    private static func currentFileFingerprint() -> CredentialsFileFingerprint? {
        let url = self.credentialsFileURL()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modifiedAtMs = (attrs[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970 * 1000) }
        return CredentialsFileFingerprint(modifiedAtMs: modifiedAtMs, size: size)
    }

    #if DEBUG
    static func _resetCredentialsFileTrackingForTesting() {
        if let store = self.taskCredentialsFileFingerprintStoreOverride { store.save(nil); return }
        UserDefaults.standard.removeObject(forKey: self.fileFingerprintKey)
    }

    static func _resetClaudeKeychainChangeTrackingForTesting() {
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintKey)
        UserDefaults.standard.removeObject(forKey: self.claudeKeychainFingerprintLegacyKey)
        self.claudeKeychainChangeCheckLock.lock()
        self.lastClaudeKeychainChangeCheckAt = nil
        self.claudeKeychainChangeCheckLock.unlock()
    }

    static func _resetClaudeKeychainChangeThrottleForTesting() {
        self.claudeKeychainChangeCheckLock.lock()
        self.lastClaudeKeychainChangeCheckAt = nil
        self.claudeKeychainChangeCheckLock.unlock()
    }
    #endif

    private static func defaultCredentialsURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(self.credentialsPath)
    }
}

// swiftlint:enable type_body_length

extension ClaudeOAuthCredentialsStore {
    /// Defaults written by the retired token-refresh backoff.
    static let retiredRefreshStateKeys = [
        "claudeOAuthRefreshBackoffBlockedUntilV1",
        "claudeOAuthRefreshBackoffFailureCountV1",
        "claudeOAuthRefreshBackoffFingerprintV2",
        "claudeOAuthRefreshTerminalBlockedV1",
        "claudeOAuthRefreshTerminalReasonV1",
        "claudeOAuthRefreshTransientBlockedUntilV1",
        "claudeOAuthRefreshTransientFailureCountV1",
    ]

    /// Launch cleanup: SturtBar no longer refreshes tokens, so the backoff state it kept is dead weight.
    public static func removeRetiredRefreshState(userDefaults: UserDefaults = .standard) {
        for key in self.retiredRefreshStateKeys {
            userDefaults.removeObject(forKey: key)
        }
    }

    private static func shouldShowClaudeKeychainPreAlert() -> Bool {
        let mode = ClaudeOAuthKeychainPromptPreference.current()
        guard self.shouldAllowClaudeCodeKeychainAccess(mode: mode, allowKeychainPrompt: false) else { return false }
        return switch KeychainAccessPreflight.checkGenericPassword(service: self.claudeKeychainService, account: nil) {
        case .interactionRequired:
            true
        case .failure:
            // If preflight fails, we can't be sure whether interaction is required (or if the preflight itself
            // is impacted by a misbehaving Keychain configuration). Be conservative and show the pre-alert.
            true
        case .allowed, .notFound:
            false
        }
    }
}
