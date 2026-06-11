// ProcessEnvironment.swift — test-process detection (Phase 4b).

import AppKit
import Foundation

/// Test-process detection (legacy `LaunchAtLoginManager.isRunningTests` port). Used to keep
/// window presentation and SMAppService/launchd calls out of headless `swift test` runs.
enum ProcessEnvironment {
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["TESTING_LIBRARY_VERSION"] != nil { return true }
        if env["SWIFT_TESTING"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()
}
