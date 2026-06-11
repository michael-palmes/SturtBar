import Foundation
import Testing
@testable import SturtBarCore

@Suite("KeychainAccessGate", .serialized)
struct KeychainAccessGateTests {
    @Test("process keeps keychain access disabled despite false global override set in test process")
    func processKeepsKeychainAccessDisabledDespiteFalseGlobalOverride() {
        guard ProcessInfo.processInfo.environment["STURTBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1" else { return }
        KeychainAccessGate.resetOverrideForTesting()
        defer { KeychainAccessGate.resetOverrideForTesting() }

        KeychainAccessGate.isDisabled = false

        // Under tests the forcesDisabledUnderTests path overrides the explicit setter
        #expect(KeychainAccessGate.isDisabled)
    }

    @Test("task override to false allows keychain access")
    func taskOverrideToFalseAllowsKeychainAccess() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(KeychainAccessGate.isDisabled == false)
        }
    }

    @Test("task override to true disables keychain access")
    func taskOverrideToTrueDisablesKeychainAccess() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            #expect(KeychainAccessGate.isDisabled == true)
        }
    }

    @Test("currentOverrideForTesting reflects task override")
    func currentOverrideForTestingReflectsTaskOverride() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            #expect(KeychainAccessGate.currentOverrideForTesting == true)
        }
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            #expect(KeychainAccessGate.currentOverrideForTesting == false)
        }
    }
}
