import Foundation

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

enum KeychainNoUIQuery {
    private static let uiFailPolicy = KeychainNoUIQuery.resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Keep explicit UI-fail policy for legacy keychain behavior on macOS where
        // `interactionNotAllowed` alone can still surface Allow/Deny prompts.
        query[kSecUseAuthenticationUI as String] = self.uiFailPolicy as CFString
    }

    static func uiFailPolicyForTesting() -> String {
        self.uiFailPolicy
    }

    private typealias SetUserInteractionAllowedFunction = @convention(c) (UInt8) -> OSStatus
    private typealias GetUserInteractionAllowedFunction = @convention(c) (UnsafeMutablePointer<UInt8>?) -> OSStatus

    private nonisolated(unsafe) static let securityFrameworkHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/Security.framework/Security",
        RTLD_NOW)

    /// Suppresses the legacy login-keychain dialog, which `apply(to:)` does not, then restores the prior setting.
    static func withoutLegacyKeychainUI<T>(_ body: () -> T) -> T {
        guard let setInteraction = self.setUserInteractionAllowed,
              let getInteraction = self.getUserInteractionAllowed
        else {
            return body()
        }
        var previous: UInt8 = 1
        _ = getInteraction(&previous)
        guard setInteraction(0) == errSecSuccess else { return body() }
        defer { _ = setInteraction(previous) }
        return body()
    }

    private static var setUserInteractionAllowed: SetUserInteractionAllowedFunction? {
        guard let securityFrameworkHandle,
              let symbol = dlsym(securityFrameworkHandle, "SecKeychainSetUserInteractionAllowed")
        else { return nil }
        return unsafeBitCast(symbol, to: SetUserInteractionAllowedFunction.self)
    }

    private static var getUserInteractionAllowed: GetUserInteractionAllowedFunction? {
        guard let securityFrameworkHandle,
              let symbol = dlsym(securityFrameworkHandle, "SecKeychainGetUserInteractionAllowed")
        else { return nil }
        return unsafeBitCast(symbol, to: GetUserInteractionAllowedFunction.self)
    }

    #if DEBUG
    /// The process-wide legacy interaction flag; nil when the deprecated getter cannot be resolved.
    static func legacyKeychainUIAllowedForTesting() -> Bool? {
        guard let getInteraction = self.getUserInteractionAllowed else { return nil }
        var state: UInt8 = 1
        guard getInteraction(&state) == errSecSuccess else { return nil }
        return state != 0
    }
    #endif

    private static func resolveUIFailPolicy() -> String {
        // Resolve the Security symbol at runtime to preserve the true constant value
        // without directly referencing deprecated API at compile time.
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
#endif
