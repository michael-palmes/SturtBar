import Foundation

public struct ClaudeCredentialContext: Sendable, Equatable {
    public let accountKey: String?
    public let sourceFingerprint: String?
    public let generation: UUID
    public let invalidatesUsage: Bool

    public init(accountKey: String?, sourceFingerprint: String?, generation: UUID, invalidatesUsage: Bool) {
        self.accountKey = accountKey
        self.sourceFingerprint = sourceFingerprint
        self.generation = generation
        self.invalidatesUsage = invalidatesUsage
    }
}

struct ClaudeCredentialObservation: Codable, Equatable {
    var accountKey: String?
    var file: String?
    var keychain: String?
    var fileAvailable = true
    var keychainAvailable = true
    var newestModification: Date?
    var fileModification: Date?

    var fingerprint: String {
        "file=\(self.file ?? "nil")|keychain=\(self.keychain ?? "nil")"
    }

    func sourceChanged(from previous: Self) -> Bool {
        (self.fileAvailable && previous.fileAvailable && self.file != previous.file)
            || (self.keychainAvailable && previous.keychainAvailable && self.keychain != previous.keychain)
    }

    func accountChanged(from previous: Self) -> Bool {
        guard let current = self.accountKey, let old = previous.accountKey else { return false }
        return current != old
    }

    var removed: Bool {
        self.fileAvailable && self.keychainAvailable && self.file == nil && self.keychain == nil
    }
}

struct ClaudeCredentialBinding: Codable {
    var observation: ClaudeCredentialObservation
    var invalidated = false
    var excludedFile: String?
}

struct ClaudeCachedCredential {
    let binding: ClaudeCredentialBinding?
    let storedAt: Date
}

public enum ClaudeCredentialEvents {
    public typealias Handler = @Sendable (ClaudeCredentialContext) async -> Void
    @TaskLocal public static var handler: Handler?
    @TaskLocal public static var forceCheck = false
}
