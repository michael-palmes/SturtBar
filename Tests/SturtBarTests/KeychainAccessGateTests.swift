import Foundation
import Testing
@testable import SturtBarCore

@Suite("KeychainAccessGate", .serialized)
struct KeychainAccessGateTests {
    @Test
    func `process keeps keychain access disabled despite false global override set in test process`() {
        guard ProcessInfo.processInfo.environment["STURTBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1" else { return }
        KeychainAccessGate.resetOverrideForTesting()
        defer { KeychainAccessGate.resetOverrideForTesting() }

        KeychainAccessGate.isDisabled = false

        // Under tests the forcesDisabledUnderTests path overrides the explicit setter
        #expect(KeychainAccessGate.isDisabled)
    }

    @Test
    func `task override to false allows keychain access`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(KeychainAccessGate.isDisabled == false)
        }
    }

    @Test
    func `task override to true disables keychain access`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            #expect(KeychainAccessGate.isDisabled == true)
        }
    }

    @Test
    func `currentOverrideForTesting reflects task override`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            #expect(KeychainAccessGate.currentOverrideForTesting == true)
        }
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(KeychainAccessGate.currentOverrideForTesting == false)
        }
    }
}
