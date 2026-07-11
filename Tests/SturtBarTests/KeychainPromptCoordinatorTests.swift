import Foundation
import Testing
@testable import SturtBar

/// The one-shot consent grace window: one pre-alert auto-proceeds after Continue, so the explainer is not shown twice.
@Suite(.serialized)
struct KeychainPromptCoordinatorTests {
    @Test
    func `consent registered within the grace interval is consumed once`() {
        let now = Date()
        KeychainPromptCoordinator.registerRecentConsent(now: now)
        #expect(KeychainPromptCoordinator.consumeRecentConsent(now: now.addingTimeInterval(5)))
        // One-shot: the same consent must not cover a second preflight.
        #expect(!KeychainPromptCoordinator.consumeRecentConsent(now: now.addingTimeInterval(6)))
    }

    @Test
    func `expired consent is not consumed`() {
        let now = Date()
        KeychainPromptCoordinator.registerRecentConsent(now: now)
        let late = now.addingTimeInterval(KeychainPromptCoordinator.consentGraceInterval + 1)
        #expect(!KeychainPromptCoordinator.consumeRecentConsent(now: late))
    }

    @Test
    func `no registered consent means no consumption`() {
        // Drain any state left by other tests in this serialized suite.
        _ = KeychainPromptCoordinator.consumeRecentConsent()
        #expect(!KeychainPromptCoordinator.consumeRecentConsent())
    }
}
