import Foundation
import Testing
@testable import SturtBarCore

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

@Suite("KeychainNoUIQuery")
struct KeychainNoUIQueryTests {
    private func resolveSecurityUIFailValue() -> String {
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

    @Test("apply sets non-interactive context and UI-fail policy")
    func applySetNonInteractiveContextAndUIFailPolicy() {
        var query: [String: Any] = [:]

        KeychainNoUIQuery.apply(to: &query)

        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        #expect(context != nil)
        #expect(context?.interactionNotAllowed == true)

        let uiPolicy = query[kSecUseAuthenticationUI as String] as? String
        #expect(uiPolicy == self.resolveSecurityUIFailValue())
        #expect(uiPolicy == (KeychainNoUIQuery.uiFailPolicyForTesting() as String))
        #expect(uiPolicy != "kSecUseAuthenticationUIFail")
    }

    @Test("preflight query is strictly non-interactive and does not request secret data")
    func preflightQueryIsNonInteractiveAndDoesNotRequestData() {
        let query = KeychainAccessPreflight.makeGenericPasswordPreflightQuery(
            service: "test.service",
            account: "test.account")

        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect((query[kSecUseAuthenticationUI as String] as? String) == self.resolveSecurityUIFailValue())
    }

    @Test("preflight query executes without invalid UI policy")
    func preflightQueryExecutesWithoutInvalidUIPolicy() {
        let query = KeychainAccessPreflight.makeGenericPasswordPreflightQuery(
            service: "sturtbar.keychain.noui.\(UUID().uuidString)",
            account: nil)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(status == errSecItemNotFound || status == errSecInteractionNotAllowed)
    }
}
#endif
