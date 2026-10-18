import Foundation

actor ClaudeCredentialSession {
    struct Operations {
        var observe: @Sendable (String?) -> ClaudeCredentialObservation = {
            ClaudeOAuthCredentialsStore.observeCredentials(accountKey: $0)
        }

        var cache: @Sendable () -> ClaudeCachedCredential? = { ClaudeOAuthCredentialsStore.sessionCache() }
        var bind: @Sendable (ClaudeCredentialBinding) -> Void = { ClaudeOAuthCredentialsStore.bindCache($0) }
        var commit: @Sendable (ClaudeOAuthCredentialRecord, ClaudeCredentialBinding) -> Void = {
            ClaudeOAuthCredentialsStore.commitRecord($0, binding: $1)
        }

        var fresh: @Sendable (Bool, Bool) throws -> ClaudeOAuthCredentialRecord = {
            try ClaudeOAuthCredentialsStore.loadFreshRecord(includeFile: $0, allowPrompt: $1)
        }

        var now: @Sendable () -> Date = { Date() }
    }

    private let operations: Operations
    private var metadata: ClaudeAccountMetadata
    private var baseline: ClaudeCredentialObservation?
    private var binding: ClaudeCredentialBinding?
    private var checkedAt: Date?
    private var generation = UUID()
    private var initialised = false
    private var legacyCache: ClaudeCachedCredential?
    private var pending = false
    private var lastFreshAttempt: Date?

    init(operations: Operations = Operations(), metadata: ClaudeAccountMetadata = ClaudeAccountMetadata()) {
        self.operations = operations
        self.metadata = metadata
    }

    func currentAccountKey() -> String? {
        self.metadata.read()
    }

    func currentGeneration() -> UUID {
        self.generation
    }

    func load(
        force: Bool,
        allowPrompt: Bool,
        observer: ClaudeCredentialEvents.Handler?,
        fallback: @Sendable () async throws -> ClaudeOAuthCredentialRecord) async throws -> ClaudeOAuthCredentialRecord
    {
        try Task.checkCancellation()
        self.initialise()
        let observation = self.observe(force: force)
        let changed = self.changed(observation)
        if changed || self.pending {
            await self.invalidate(observation, observer: observer)
        }
        let sourceChanged = (self.binding?.observation ?? self.baseline)
            .map { observation.sourceChanged(from: $0) } ?? false
        let canRetry = force || self.lastFreshAttempt.map { self.operations.now().timeIntervalSince($0) >= 60 } != false
        let requiresFresh = changed || self.pending || (canRetry && (sourceChanged || self.legacyCache != nil))
        self.baseline = self.mergingKnownState(observation)
        try Task.checkCancellation()
        if self.pending, observation.removed { throw ClaudeOAuthCredentialsError.notFound }

        let record = try await self.read(
            observation: observation, fresh: requiresFresh, allowPrompt: allowPrompt, fallback: fallback)
        try Task.checkCancellation()
        let direct = record.source == .claudeKeychain || record.source == .credentialsFile
        if direct {
            let after = self.observe(force: true)
            if after.accountChanged(from: observation) || after.sourceChanged(from: observation) {
                if self.changed(after) || self.pending {
                    await self.invalidate(after, observer: observer)
                } else {
                    self.baseline = self.mergingKnownState(after)
                    self.lastFreshAttempt = nil
                }
                throw ClaudeOAuthCredentialsError.signInChanging
            }
            let readableSource = record.source == .claudeKeychain
                ? after.keychainAvailable && after.keychain != nil : after.fileAvailable && after.file != nil
            if readableSource {
                if self.binding.map({ after.sourceChanged(from: $0.observation) }) == true {
                    self.generation = UUID()
                }
                self.binding = ClaudeCredentialBinding(observation: after)
                self.operations.commit(record, ClaudeCredentialBinding(observation: after))
                self.legacyCache = nil
                self.pending = false
            }
        }
        if let observer { await observer(self.context(invalidatesUsage: false)) }
        try Task.checkCancellation()
        return try ClaudeOAuthCredentialsStore.validateExpiry(record)
    }

    private func read(
        observation: ClaudeCredentialObservation,
        fresh: Bool,
        allowPrompt: Bool,
        fallback: @Sendable () async throws -> ClaudeOAuthCredentialRecord) async throws -> ClaudeOAuthCredentialRecord
    {
        do {
            if fresh {
                self.lastFreshAttempt = self.operations.now()
                do {
                    let includeFile = self.binding?.excludedFile == nil || self.binding?.excludedFile != observation
                        .file
                    let record = try self.operations.fresh(includeFile, allowPrompt)
                    if !record.credentials.isExpired || self.pending { return record }
                } catch {
                    guard !self.pending else { throw error }
                }
            }
            return try await fallback()
        } catch let error as ClaudeOAuthCredentialsError {
            guard !observation.removed else { throw error }
            switch error {
            case .notFound:
                throw ClaudeOAuthCredentialsError.claudeKeychainAccessRequired(
                    underlying: nil, reason: .accessLost)
            case .decodeFailed, .missingOAuth, .missingAccessToken:
                throw ClaudeOAuthCredentialsError.signInChanging
            default: throw error
            }
        }
    }

    func validateResponse(generation: UUID? = nil, observer: ClaudeCredentialEvents.Handler?) async -> Bool {
        let current = self.observe(force: true)
        guard self.changed(current) else {
            let sourceChanged = self.baseline.map { current.sourceChanged(from: $0) } ?? false
            self.baseline = self.mergingKnownState(current)
            return !sourceChanged && (generation == nil || generation == self.generation)
        }
        await self.invalidate(current, observer: observer)
        return false
    }

    private func initialise() {
        guard !self.initialised else { return }
        self.initialised = true
        let cache = self.operations.cache()
        self.binding = cache?.binding
        self.baseline = self.binding?.observation
        self.pending = self.binding?.invalidated == true
        self.legacyCache = self.binding == nil ? cache : nil
    }

    private func observe(force: Bool) -> ClaudeCredentialObservation {
        let now = self.operations.now()
        if !force, let checkedAt = self.checkedAt, now.timeIntervalSince(checkedAt) < 60,
           let baseline = self.baseline
        {
            return baseline
        }
        self.checkedAt = now
        return self.operations.observe(self.metadata.read())
    }

    private func mergingKnownState(_ current: ClaudeCredentialObservation) -> ClaudeCredentialObservation {
        guard let previous = self.baseline else { return current }
        var result = current
        if result.accountKey == nil { result.accountKey = previous.accountKey }
        if !result.fileAvailable {
            result.file = previous.file
            result.fileAvailable = previous.fileAvailable
        }
        if !result.keychainAvailable {
            result.keychain = previous.keychain
            result.keychainAvailable = previous.keychainAvailable
        }
        return result
    }

    private func changed(_ current: ClaudeCredentialObservation) -> Bool {
        if self.legacyCache != nil, current.removed { return true }
        if let legacy = self.legacyCache,
           let modified = current.newestModification, modified > legacy.storedAt
        {
            return true
        }
        guard let previous = self.baseline else { return false }
        if current.accountChanged(from: previous) { return true }
        guard current.sourceChanged(from: previous) else { return false }
        if current.removed { return true }
        return current.accountKey == nil || previous.accountKey == nil
    }

    private func invalidate(
        _ observation: ClaudeCredentialObservation,
        observer: ClaudeCredentialEvents.Handler?) async
    {
        let old = self.baseline
        let newChange = !self.pending || old?.accountChanged(from: observation) == true
            || old.map { observation.sourceChanged(from: $0) } == true
        if newChange {
            self.generation = UUID()
        }
        var excludedFile = self.binding?.excludedFile
        if newChange, old?.file == observation.file { excludedFile = observation.file }
        if let legacy = self.legacyCache, let modified = observation.fileModification, modified <= legacy.storedAt {
            excludedFile = observation.file
        }
        self.binding = ClaudeCredentialBinding(observation: observation, invalidated: true, excludedFile: excludedFile)
        self.pending = true
        self.baseline = observation
        if let binding { self.operations.bind(binding) }
        if let observer { await observer(self.context(invalidatesUsage: true)) }
    }

    private func context(invalidatesUsage: Bool) -> ClaudeCredentialContext {
        ClaudeCredentialContext(
            accountKey: self.binding?.observation.accountKey,
            sourceFingerprint: self.binding?.observation.fingerprint,
            generation: self.generation,
            invalidatesUsage: invalidatesUsage)
    }
}
