#if os(macOS)
import LocalAuthentication
import Security
#endif
import Synchronization

public struct KeychainPromptContext: Sendable {
    public enum Kind: Sendable {
        case claudeOAuth
    }

    public let kind: Kind
    public let service: String
    public let account: String?

    public init(kind: Kind, service: String, account: String?) {
        self.kind = kind
        self.service = service
        self.account = account
    }
}

/// The user's decision at the pre-prompt explainer shown before an OS keychain dialog.
public enum KeychainPromptDecision: Sendable, Equatable {
    case proceed
    case notNow
}

public enum KeychainPromptHandler {
    final class HandlerStore: @unchecked Sendable {
        let handler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision

        init(handler: @escaping @Sendable (KeychainPromptContext) -> KeychainPromptDecision) {
            self.handler = handler
        }
    }

    @TaskLocal private static var taskHandlerStore: HandlerStore?
    private static let handlerMutex = Mutex<(@Sendable (KeychainPromptContext) -> KeychainPromptDecision)?>(nil)

    public static var handler: (@Sendable (KeychainPromptContext) -> KeychainPromptDecision)? {
        get { handlerMutex.withLock { $0 } }
        set { handlerMutex.withLock { $0 = newValue } }
    }

    /// Asks the installed handler to explain the upcoming dialog and return the decision; no handler means proceed.
    public static func requestApproval(_ context: KeychainPromptContext) -> KeychainPromptDecision {
        if let taskHandlerStore {
            return taskHandlerStore.handler(context)
        }
        return self.handlerMutex.withLock { $0 }?(context) ?? .proceed
    }

    #if DEBUG
    static func withHandlerForTesting<T>(
        _ handler: (@Sendable (KeychainPromptContext) -> KeychainPromptDecision)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskHandlerStore.withValue(handler.map(HandlerStore.init(handler:))) {
            try operation()
        }
    }

    static func withHandlerForTesting<T>(
        _ handler: (@Sendable (KeychainPromptContext) -> KeychainPromptDecision)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskHandlerStore.withValue(handler.map(HandlerStore.init(handler:))) {
            try await operation()
        }
    }
    #endif
}

public enum KeychainAccessPreflight {
    public enum Outcome: Sendable, Equatable {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    private static let log = SturtBarLog.logger("keychain.preflight")

    #if DEBUG
    final class CheckGenericPasswordOverrideStore: @unchecked Sendable {
        let check: (String, String?) -> Outcome

        init(check: @escaping (String, String?) -> Outcome) {
            self.check = check
        }
    }

    @TaskLocal private static var taskCheckGenericPasswordOverrideStore: CheckGenericPasswordOverrideStore?

    static func withCheckGenericPasswordOverrideForTesting<T>(
        _ override: ((String, String?) -> Outcome)?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskCheckGenericPasswordOverrideStore.withValue(
            override.map(CheckGenericPasswordOverrideStore.init(check:)))
        {
            try operation()
        }
    }

    static func withCheckGenericPasswordOverrideForTesting<T>(
        _ override: ((String, String?) -> Outcome)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskCheckGenericPasswordOverrideStore.withValue(
            override.map(CheckGenericPasswordOverrideStore.init(check:)))
        {
            try await operation()
        }
    }
    #endif

    public static func checkGenericPassword(service: String, account: String?) -> Outcome {
        #if os(macOS)
        #if DEBUG
        if let override = self.taskCheckGenericPasswordOverrideStore {
            return override.check(service, account)
        }
        #endif
        guard !KeychainAccessGate.isDisabled else { return .notFound }
        let query = self.makeGenericPasswordPreflightQuery(service: service, account: account)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            self.log.debug("Keychain preflight allowed", metadata: ["service": service])
            return .allowed
        case errSecItemNotFound:
            self.log.debug(
                "Keychain preflight not found",
                metadata: ["service": service])
            return .notFound
        case errSecInteractionNotAllowed:
            self.log.info(
                "Keychain preflight requires interaction",
                metadata: ["service": service])
            return .interactionRequired
        default:
            self.log.warning(
                "Keychain preflight failed",
                metadata: ["service": service, "status": "\(status)"])
            return .failure(Int(status))
        }
        #else
        return .notFound
        #endif
    }

    #if os(macOS)
    static func makeGenericPasswordPreflightQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Preflight should never trigger UI. Avoid requesting the secret payload (`kSecReturnData`) because
            // some macOS configurations have been observed to show the legacy keychain prompt unless the query
            // is strictly non-interactive.
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
    #endif
}
