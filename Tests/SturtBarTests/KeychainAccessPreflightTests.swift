import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

@Suite("KeychainAccessPreflight", .serialized)
struct KeychainAccessPreflightTests {
    @Test
    func `KeychainPromptContext only exposes claudeOAuth kind`() {
        // The only kind that survived the trim is .claudeOAuth
        let ctx = KeychainPromptContext(kind: .claudeOAuth, service: "Claude Code-credentials", account: nil)
        if case .claudeOAuth = ctx.kind {
            // correct — no-op
        } else {
            #expect(Bool(false), "Expected .claudeOAuth kind")
        }
    }

    @Test
    func `checkGenericPassword returns notFound when gate is disabled`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let outcome = KeychainAccessPreflight.checkGenericPassword(
                service: "com.test.service",
                account: nil)
            #expect(outcome == .notFound)
        }
    }

    @Test
    func `checkGenericPassword override is respected in debug builds`() {
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

    @Test
    func `KeychainPromptHandler task handler fires before global handler`() {
        let globalFired = Mutex(false)
        let taskFired = Mutex(false)
        KeychainPromptHandler.handler = { _ in
            globalFired.withLock { $0 = true }
            return .proceed
        }
        defer { KeychainPromptHandler.handler = nil }

        let decision = KeychainPromptHandler.withHandlerForTesting { _ in
            taskFired.withLock { $0 = true }
            return .notNow
        } operation: {
            KeychainPromptHandler.requestApproval(
                KeychainPromptContext(kind: .claudeOAuth, service: "svc", account: nil))
        }

        #expect(taskFired.withLock { $0 } == true)
        #expect(globalFired.withLock { $0 } == false)
        #expect(decision == .notNow)
    }

    @Test
    func `KeychainPromptHandler global handler fires when no task handler`() {
        let globalFired = Mutex(false)
        KeychainPromptHandler.handler = { _ in
            globalFired.withLock { $0 = true }
            return .proceed
        }
        defer { KeychainPromptHandler.handler = nil }

        let decision = KeychainPromptHandler.requestApproval(
            KeychainPromptContext(kind: .claudeOAuth, service: "svc", account: nil))

        #expect(globalFired.withLock { $0 } == true)
        #expect(decision == .proceed)
    }

    @Test
    func `KeychainPromptHandler defaults to proceed with no handler installed`() {
        // Headless and test runs must never block on a missing UX layer.
        let decision = KeychainPromptHandler.requestApproval(
            KeychainPromptContext(kind: .claudeOAuth, service: "svc", account: nil))
        #expect(decision == .proceed)
    }
}
