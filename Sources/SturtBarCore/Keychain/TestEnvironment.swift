import Foundation

/// Single source of truth for detecting whether code is running inside the test harness.
/// Used by `KeychainAccessGate` and `KeychainCacheStore` to keep tests off the real login keychain.
enum TestEnvironment {
    #if DEBUG
    static var isRunningUnderTests: Bool {
        let processName = ProcessInfo.processInfo.processName
        return processName == "swiftpm-testing-helper"
            || processName.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    #endif
}
