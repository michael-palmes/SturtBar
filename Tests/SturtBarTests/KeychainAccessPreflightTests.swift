import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

@Suite("KeychainAccessPreflight", .serialized)
struct KeychainAccessPreflightTests {
    @Test("KeychainPromptContext only exposes claudeOAuth kind")
    func promptContextOnlyExposesClaudeOAuth() {
        // The only kind that survived the trim is .claudeOAuth
        let ctx = KeychainPromptContext(kind: .claudeOAuth, service: "Claude Code-credentials", account: nil)
        if case .claudeOAuth = ctx.kind {
            // correct — no-op
        } else {
            #expect(Bool(false), "Expected .claudeOAuth kind")
        }
    }

    @Test("checkGenericPassword returns notFound when gate is disabled")
    func checkGenericPasswordReturnsNotFoundWhenGateDisabled() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let outcome = KeychainAccessPreflight.checkGenericPassword(
                service: "com.test.service",
                account: nil)
            #expect(outcome == .notFound)
        }
    }

    @Test("checkGenericPassword override is respected in debug builds")
    func checkGenericPasswordOverrideIsRespected() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                .allowed
            } operation: {
                let outcome = KeychainAccessPreflight.checkGenericPassword(
                    service: "com.test.override",
                    account: "acct")
                #expect(outcome == .allowed)
            }
        }
    }

    @Test("KeychainPromptHandler task handler fires before global handler")
    func promptHandlerTaskHandlerFiresBeforeGlobal() {
        let globalFired = Mutex(false)
        let taskFired = Mutex(false)
        KeychainPromptHandler.handler = { _ in globalFired.withLock { $0 = true } }
        defer { KeychainPromptHandler.handler = nil }

        KeychainPromptHandler.withHandlerForTesting { _ in
            taskFired.withLock { $0 = true }
        } operation: {
            KeychainPromptHandler.notify(
                KeychainPromptContext(kind: .claudeOAuth, service: "svc", account: nil))
        }

        #expect(taskFired.withLock { $0 } == true)
        #expect(globalFired.withLock { $0 } == false)
    }

    @Test("KeychainPromptHandler global handler fires when no task handler")
    func promptHandlerGlobalHandlerFiresWhenNoTaskHandler() {
        let globalFired = Mutex(false)
        KeychainPromptHandler.handler = { _ in globalFired.withLock { $0 = true } }
        defer { KeychainPromptHandler.handler = nil }

        KeychainPromptHandler.notify(
            KeychainPromptContext(kind: .claudeOAuth, service: "svc", account: nil))

        #expect(globalFired.withLock { $0 } == true)
    }
}
