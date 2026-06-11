import Foundation
import Synchronization

public enum KeychainAccessGate {
    private static let flagKey = "debugDisableKeychainAccess"
    @TaskLocal private static var taskOverrideValue: Bool?
    private static let overrideMutex = Mutex<Bool?>(nil)

    public static var isDisabled: Bool {
        get {
            if let taskOverrideValue { return taskOverrideValue }
            #if DEBUG
            if Self.forcesDisabledUnderTests {
                return true
            }
            #endif
            if let overrideValue = overrideMutex.withLock({ $0 }) { return overrideValue }
            if UserDefaults.standard.bool(forKey: Self.flagKey) { return true }
            return false
        }
        set {
            overrideMutex.withLock { $0 = newValue }
        }
    }

    #if DEBUG
    private static var forcesDisabledUnderTests: Bool {
        TestEnvironment.isRunningUnderTests
            && ProcessInfo.processInfo.environment["STURTBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
    }
    #endif

    static func withTaskOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () throws -> T) rethrows -> T
    {
        try self.$taskOverrideValue.withValue(disabled) {
            try operation()
        }
    }

    static func withTaskOverrideForTesting<T>(
        _ disabled: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverrideValue.withValue(disabled) {
            try await operation()
        }
    }

    static var currentOverrideForTesting: Bool? {
        self.taskOverrideValue ?? overrideMutex.withLock { $0 }
    }

    #if DEBUG
    static func resetOverrideForTesting() {
        self.overrideMutex.withLock { $0 = nil }
    }
    #endif
}
