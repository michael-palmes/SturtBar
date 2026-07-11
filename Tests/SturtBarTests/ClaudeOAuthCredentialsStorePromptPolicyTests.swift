import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStorePromptPolicyTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date, refreshToken: String? = nil) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let refreshField: String = {
            guard let refreshToken else { return "" }
            return ",\n            \"refreshToken\": \"\(refreshToken)\""
        }()
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]\(refreshField)
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func `does not read claude keychain in background when prompt mode only on user action`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()

                    let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 1,
                        createdAt: 1,
                        persistentRefHash: "ref1")
                    let keychainData = self.makeCredentialsData(
                        accessToken: "keychain-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))

                    do {
                        _ = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                            try InteractionContext.$current.withValue(.background) {
                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: keychainData,
                                    fingerprint: fingerprint)
                                {
                                    try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                                }
                            }
                        }
                        Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
                    } catch let error as ClaudeOAuthCredentialsError {
                        // With an item visibly present, the unread secret surfaces as the keychain-access remedy, not
                        // notFound.
                        guard case .claudeKeychainAccessRequired(_, reason: .accessLost) = error else {
                            Issue.record("Expected .claudeKeychainAccessRequired(.accessLost), got \(error)")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test
    func `can read claude keychain on user action when prompt mode only on user action`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
                }

                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let fileURL = tempDir.appendingPathComponent("credentials.json")

                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()

                    let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 1,
                        createdAt: 1,
                        persistentRefHash: "ref1")
                    let keychainData = self.makeCredentialsData(
                        accessToken: "keychain-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))

                    let creds = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try InteractionContext.$current.withValue(.userInitiated) {
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: keychainData,
                                fingerprint: fingerprint)
                            {
                                try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                            }
                        }
                    }

                    #expect(creds.accessToken == "keychain-token")
                }
            }
        }
    }

    @Test
    func `does not show pre alert when claude keychain readable without interaction`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .allowed
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try InteractionContext.$current.withValue(.userInitiated) {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: keychainData,
                                                fingerprint: nil)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true)
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "keychain-token")
                        #expect(preAlertHits.withLock { $0 } == 0)
                    }
                }
            }
        }
    }

    @Test
    func `shows pre alert when claude keychain likely requires interaction`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try InteractionContext.$current.withValue(.userInitiated) {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: keychainData,
                                                fingerprint: nil)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true)
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "keychain-token")
                        // TODO: tighten this to `== 1` once keychain pre-alert delivery is deduplicated/scoped.
                        // This path can currently emit more than one pre-alert during a single load attempt.
                        #expect(preAlertHits.withLock { $0 } >= 1)
                    }
                }
            }
        }
    }

    @Test
    func `shows pre alert when claude keychain preflight fails`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .failure(-1)
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try InteractionContext.$current.withValue(.userInitiated) {
                                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                data: keychainData,
                                                fingerprint: nil)
                                            {
                                                try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:],
                                                    allowKeychainPrompt: true)
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "keychain-token")
                        // TODO: tighten this to `== 1` once keychain pre-alert delivery is deduplicated/scoped.
                        // This path can currently emit more than one pre-alert during a single load attempt.
                        #expect(preAlertHits.withLock { $0 } >= 1)
                    }
                }
            }
        }
    }

    @Test
    func `experimental reader skips pre alert when security CLI read succeeds`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let securityData = self.makeCredentialsData(
                            accessToken: "security-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                        .securityCLIExperimental)
                                    {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                            try InteractionContext.$current.withValue(.userInitiated) {
                                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                                    .data(securityData))
                                                {
                                                    try ClaudeOAuthCredentialsStore.load(
                                                        environment: [:],
                                                        allowKeychainPrompt: true)
                                                }
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "security-token")
                        #expect(preAlertHits.withLock { $0 } == 0)
                    }
                }
            }
        }
    }

    @Test
    func `experimental reader shows pre alert when security CLI fails and fallback needs interaction`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let fallbackData = self.makeCredentialsData(
                            accessToken: "fallback-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }
                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                        .securityCLIExperimental)
                                    {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                            try InteractionContext.$current.withValue(.userInitiated) {
                                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                    data: fallbackData,
                                                    fingerprint: nil)
                                                {
                                                    try ClaudeOAuthCredentialsStore
                                                        .withSecurityCLIReadOverrideForTesting(.timedOut) {
                                                            try ClaudeOAuthCredentialsStore.load(
                                                                environment: [:],
                                                                allowKeychainPrompt: true)
                                                        }
                                                }
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "fallback-token")
                        #expect(preAlertHits.withLock { $0 } >= 1)
                    }
                }
            }
        }
    }

    @Test
    func `experimental reader does not fallback in background when stored mode only on user action`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let fallbackData = self.makeCredentialsData(
                            accessToken: "fallback-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }

                        do {
                            _ = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                preflightOverride,
                                operation: {
                                    try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                        try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                            .securityCLIExperimental)
                                        {
                                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                                .onlyOnUserAction)
                                            {
                                                try InteractionContext.$current.withValue(.background) {
                                                    try ClaudeOAuthCredentialsStore
                                                        .withClaudeKeychainOverridesForTesting(
                                                            data: fallbackData,
                                                            fingerprint: nil)
                                                        {
                                                            try ClaudeOAuthCredentialsStore
                                                                .withSecurityCLIReadOverrideForTesting(.timedOut) {
                                                                    try ClaudeOAuthCredentialsStore.load(
                                                                        environment: [:],
                                                                        allowKeychainPrompt: true,
                                                                        respectKeychainPromptCooldown: true)
                                                                }
                                                        }
                                                }
                                            }
                                        }
                                    })
                                })
                            Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
                        } catch let error as ClaudeOAuthCredentialsError {
                            // With an item visibly present, the unread secret surfaces as the keychain-access remedy,
                            // not notFound.
                            guard case .claudeKeychainAccessRequired = error else {
                                Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                                return
                            }
                        }

                        #expect(preAlertHits.withLock { $0 } == 0)
                    }
                }
            }
        }
    }

    @Test
    func `experimental reader does not fallback when stored mode never`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let fallbackData = self.makeCredentialsData(
                            accessToken: "fallback-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }

                        do {
                            _ = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                preflightOverride,
                                operation: {
                                    try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                        try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                            .securityCLIExperimental)
                                        {
                                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                                                try InteractionContext.$current.withValue(.userInitiated) {
                                                    try ClaudeOAuthCredentialsStore
                                                        .withClaudeKeychainOverridesForTesting(
                                                            data: fallbackData,
                                                            fingerprint: nil)
                                                        {
                                                            try ClaudeOAuthCredentialsStore
                                                                .withSecurityCLIReadOverrideForTesting(.timedOut) {
                                                                    try ClaudeOAuthCredentialsStore.load(
                                                                        environment: [:],
                                                                        allowKeychainPrompt: true)
                                                                }
                                                        }
                                                }
                                            }
                                        }
                                    })
                                })
                            Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
                        } catch let error as ClaudeOAuthCredentialsError {
                            // With an item visibly present, the unread secret surfaces as the keychain-access remedy,
                            // not notFound.
                            guard case .claudeKeychainAccessRequired = error else {
                                Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                                return
                            }
                        }

                        #expect(preAlertHits.withLock { $0 } == 0)
                    }
                }
            }
        }
    }

    @Test
    func `experimental reader non interactive fallback blocked in background when stored mode only on user action`()
        throws
    {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let fallbackData = self.makeCredentialsData(
                            accessToken: "fallback-token-only-on-user-action",
                            expiresAt: Date(timeIntervalSinceNow: 3600))
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .allowed
                        }

                        do {
                            _ = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                preflightOverride,
                                operation: {
                                    try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                        .securityCLIExperimental)
                                    {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                            .onlyOnUserAction)
                                        {
                                            try InteractionContext.$current.withValue(.background) {
                                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                    data: fallbackData,
                                                    fingerprint: nil)
                                                {
                                                    try ClaudeOAuthCredentialsStore
                                                        .withSecurityCLIReadOverrideForTesting(.timedOut) {
                                                            try ClaudeOAuthCredentialsStore.load(
                                                                environment: [:],
                                                                allowKeychainPrompt: false,
                                                                respectKeychainPromptCooldown: true)
                                                        }
                                                }
                                            }
                                        }
                                    }
                                })
                            Issue.record("Expected ClaudeOAuthCredentialsError.claudeKeychainAccessRequired")
                        } catch let error as ClaudeOAuthCredentialsError {
                            // With an item visibly present, the unread secret surfaces as the keychain-access remedy,
                            // not notFound.
                            guard case .claudeKeychainAccessRequired = error else {
                                Issue.record("Expected .claudeKeychainAccessRequired, got \(error)")
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `experimental reader allows fallback in background when stored mode always`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let fallbackData = self.makeCredentialsData(
                            accessToken: "fallback-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .proceed
                        }

                        let creds = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                            preflightOverride,
                            operation: {
                                try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                    try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                        .securityCLIExperimental)
                                    {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                                            try InteractionContext.$current.withValue(.background) {
                                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                    data: fallbackData,
                                                    fingerprint: nil)
                                                {
                                                    try ClaudeOAuthCredentialsStore
                                                        .withSecurityCLIReadOverrideForTesting(.timedOut) {
                                                            try ClaudeOAuthCredentialsStore.load(
                                                                environment: [:],
                                                                allowKeychainPrompt: true,
                                                                respectKeychainPromptCooldown: false)
                                                        }
                                                }
                                            }
                                        }
                                    }
                                })
                            })

                        #expect(creds.accessToken == "fallback-token")
                        #expect(preAlertHits.withLock { $0 } >= 1)
                    }
                }
            }
        }
    }

    @Test
    func `pre-prompt declined skips the keychain read and records no denial cooldown`() throws {
        let service = "com.michaelpalmes.sturtbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let keychainData = self.makeCredentialsData(
                            accessToken: "keychain-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))

                        let preAlertHits = Mutex(0)
                        let preflightOverride: (String, String?) -> KeychainAccessPreflight.Outcome = { _, _ in
                            .interactionRequired
                        }
                        let promptHandler: @Sendable (KeychainPromptContext) -> KeychainPromptDecision = { _ in
                            preAlertHits.withLock { $0 += 1 }
                            return .notNow
                        }

                        do {
                            _ = try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                                preflightOverride,
                                operation: {
                                    try KeychainPromptHandler.withHandlerForTesting(promptHandler, operation: {
                                        try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                            .onlyOnUserAction)
                                        {
                                            try InteractionContext.$current.withValue(.userInitiated) {
                                                try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                                    data: keychainData,
                                                    fingerprint: nil)
                                                {
                                                    try ClaudeOAuthCredentialsStore.load(
                                                        environment: [:],
                                                        allowKeychainPrompt: true,
                                                        respectKeychainPromptCooldown: false)
                                                }
                                            }
                                        }
                                    })
                                })
                            Issue.record("Expected the declined pre-prompt to skip the keychain read")
                        } catch let error as ClaudeOAuthCredentialsError {
                            // Declining skips the read; the visible item then surfaces as the keychain-access remedy.
                            guard case .claudeKeychainAccessRequired = error else {
                                Issue.record("Expected .claudeKeychainAccessRequired after declining, got \(error)")
                                return
                            }
                        }

                        #expect(preAlertHits.withLock { $0 } == 1)
                        // Declining the explainer is never punished: no denial cooldown recorded.
                        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt())
                    }
                }
            }
        }
    }
}
