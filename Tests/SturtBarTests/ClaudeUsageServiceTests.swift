import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

// MARK: - Mapping tests

/// mapOAuthUsage coverage ported from CodexBarTests/ClaudeOAuthTests.swift and
/// CodexBarTests/ClaudeUsageTests.swift (ClaudeOAuthUsageMappingTests).
struct ClaudeOAuthUsageMappingTests {
    @Test
    func `maps OAuth usage to snapshot`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 5 }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")
        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.primary.windowMinutes == 300)
        #expect(snap.secondary?.usedPercent == 30)
        #expect(snap.opus?.usedPercent == 5)
        #expect(snap.primary.resetsAt != nil)
        #expect(snap.loginMethod == "Claude Pro")
    }

    @Test
    func `maps OAuth subscription type when rate limit tier is generic`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "default_claude_ai",
            subscriptionType: "pro")
        #expect(snap.loginMethod == "Claude Pro")
    }

    @Test
    func `ignores merged OAuth design usage window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": { "utilization": 44, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": { "utilization": 18, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.count == 1)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.title == "Daily Routines")
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 18)
    }

    @Test
    func `ignores merged OAuth omelette usage window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_cowork": { "utilization": 9, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.count == 1)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 9)
    }

    @Test
    func `maps OAuth null cowork as zero routines window`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_omelette": { "utilization": 29, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_cowork": null
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 0)
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
    }

    @Test
    func `prefers populated routines alias over null alias in mixed payload`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_design": null,
          "seven_day_omelette": { "utilization": 37, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": null,
          "seven_day_cowork": { "utilization": 14, "resets_at": "2026-01-01T00:00:00.000Z" }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.extraRateWindows.contains { $0.id == "claude-design" } == false)
        #expect(snap.extraRateWindows.first(where: { $0.id == "claude-routines" })?.window.usedPercent == 14)
    }

    @Test
    func `maps OAuth extra usage`() throws {
        // OAuth API returns values in cents (minor units), same as Web API.
        // The normalization always converts to dollars (major units).
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2050,
            "used_credits": 325
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20.5)
        #expect(snap.providerCost?.used == 3.25)
        #expect(snap.providerCost?.period == "Monthly cap")
    }

    @Test
    func `maps OAuth extra usage minor units as major units`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 520,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 5.2)
        #expect(snap.providerCost?.period == "Monthly cap")
    }

    @Test
    func `does not display spend limit 100x too high for enterprise OAuth`() throws {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 763,
            "utilization": 38.15,
            "currency": "EUR"
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(
            Data(json.utf8),
            subscriptionType: "enterprise")
        #expect(snap.loginMethod == "Claude Enterprise")
        #expect(snap.primary.usedPercent == 38.15)
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary.windowMinutes == nil)
        #expect(snap.primary.resetDescription == "Spend limit: €7.63 / €20.00")
        #expect(snap.secondary == nil)
        #expect(snap.providerCost?.period == "Spend limit")
        #expect(snap.providerCost?.currencyCode == "EUR")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 7.63)
    }

    @Test
    func `maps OAuth spend limit without plan metadata from minor units`() throws {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 2000,
            "used_credits": 763,
            "utilization": 38.15,
            "currency": "EUR"
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.loginMethod == nil)
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary.usedPercent == 38.15)
        #expect(snap.primary.resetDescription == "Spend limit: €7.63 / €20.00")
        #expect(snap.providerCost?.period == "Spend limit")
        #expect(snap.providerCost?.currencyCode == "EUR")
        #expect(snap.providerCost?.limit == 20)
        #expect(snap.providerCost?.used == 7.63)
    }

    @Test
    func `maps large enterprise OAuth spend limit from minor units`() throws {
        let json = """
        {
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 1000000,
            "used_credits": 123456,
            "utilization": 12.3456,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(
            Data(json.utf8),
            subscriptionType: "enterprise")
        #expect(snap.primaryWindowKind == .spendLimit)
        #expect(snap.primary.usedPercent == 12.3456)
        #expect(snap.primary.resetDescription == "Spend limit: $1,234.56 / $10,000.00")
        #expect(snap.providerCost?.period == "Spend limit")
        #expect(snap.providerCost?.limit == 10000)
        #expect(snap.providerCost?.used == 1234.56)
    }

    @Test
    func `normalizes high limit OAuth extra usage`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func `normalizes OAuth extra usage cents to major units`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 200000,
            "used_credits": 22200,
            "currency": "USD"
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost?.currencyCode == "USD")
        #expect(snap.providerCost?.limit == 2000)
        #expect(snap.providerCost?.used == 222)
    }

    @Test
    func `prefers opus when sonnet missing`() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day_opus": { "utilization": 42 }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.opus?.usedPercent == 42)
    }

    @Test
    func `skips extra usage when disabled`() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": {
            "is_enabled": false,
            "monthly_limit": 100,
            "used_credits": 10
          }
        }
        """
        let snap = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
        #expect(snap.providerCost == nil)
    }

    @Test
    func `oauth usage falls back to weekly window when five hour is absent`() throws {
        let json = """
        {
          "seven_day": { "utilization": 42, "resets_at": "2025-12-29T23:00:00.000Z" },
          "seven_day_sonnet": { "utilization": 17, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let snapshot = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))

        #expect(snapshot.primary.usedPercent == 42)
        #expect(snapshot.primary.windowMinutes == 7 * 24 * 60)
        #expect(snapshot.secondary?.usedPercent == 42)
        #expect(snapshot.opus?.usedPercent == 17)
    }

    @Test
    func `oauth usage falls back when five hour has no utilization`() throws {
        let json = """
        {
          "five_hour": { "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 9, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        let snapshot = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))

        #expect(snapshot.primary.usedPercent == 9)
        #expect(snapshot.primary.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `oauth usage throws when no usable windows are present`() {
        let json = "{}"

        do {
            _ = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8))
            Issue.record("Expected ClaudeUsageError.parseFailed")
        } catch let error as ClaudeUsageError {
            guard case .parseFailed = error else {
                Issue.record("Expected .parseFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }
    }

    @Test
    func `same payload and same now date produce equal snapshots`() throws {
        let json = """
        {
          "five_hour": { "utilization": 50, "resets_at": "2025-12-25T12:00:00.000Z" },
          "extra_usage": { "is_enabled": true, "monthly_limit": 2000, "used_credits": 500 }
        }
        """
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snap1 = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8), now: now)
        let snap2 = try ClaudeUsageService._mapOAuthUsageForTesting(Data(json.utf8), now: now)
        #expect(snap1 == snap2)
    }

    @Test
    func `usage snapshot survives a codable round trip`() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30, "resets_at": "2025-12-31T00:00:00.000Z" },
          "seven_day_routines": { "utilization": 18, "resets_at": "2026-01-01T00:00:00.000Z" },
          "extra_usage": { "is_enabled": true, "monthly_limit": 2050, "used_credits": 325 }
        }
        """
        let snapshot = try ClaudeUsageService._mapOAuthUsageForTesting(
            Data(json.utf8),
            rateLimitTier: "claude_pro")

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderUsageSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}

// MARK: - Executor flow tests

/// OAuth executor behavior: prompt policy flags, 429 pass-through, the 401 invalidate-and-retry-once
/// flow, startup bootstrap prompts, and typed needs-reauth derivation.
struct ClaudeUsageServiceFlowTests {
    private struct LoadCall: Equatable {
        let allowKeychainPrompt: Bool
        let respectKeychainPromptCooldown: Bool
    }

    private static func makeOAuthUsageResponse() throws -> OAuthUsageResponse {
        let json = """
        {
          "five_hour": { "utilization": 7, "resets_at": "2025-12-23T16:00:00.000Z" },
          "seven_day": { "utilization": 21, "resets_at": "2025-12-29T23:00:00.000Z" }
        }
        """
        return try ClaudeOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }

    private static func makeCredentials(
        accessToken: String = "fresh-token",
        scopes: [String] = ["user:profile"]) -> ClaudeOAuthCredentials
    {
        ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: scopes,
            rateLimitTier: nil)
    }

    private static func makeService(allowStartupBootstrapPrompt: Bool = false) -> ClaudeUsageService {
        ClaudeUsageService(
            transport: HTTPTransportHandler { _ in throw URLError(.notConnectedToInternet) },
            environment: [:],
            allowStartupBootstrapPrompt: allowStartupBootstrapPrompt)
    }

    @Test
    func `user initiated fetch loads credentials with prompt and without cooldown`() async throws {
        let usageResponse = try Self.makeOAuthUsageResponse()
        let loadCalls = Mutex<[LoadCall]>([])

        let snapshot = try await withOAuthSeams(
            load: { _, allowPrompt, respectCooldown in
                loadCalls.withLock {
                    $0.append(LoadCall(
                        allowKeychainPrompt: allowPrompt,
                        respectKeychainPromptCooldown: respectCooldown))
                }
                return Self.makeCredentials()
            },
            fetch: { _ in usageResponse },
            operation: {
                try await Self.makeService().fetchUsage(interaction: .userInitiated)
            })

        #expect(snapshot.primary.usedPercent == 7)
        #expect(snapshot.secondary?.usedPercent == 21)
        #expect(loadCalls.withLock { $0 } == [
            LoadCall(allowKeychainPrompt: true, respectKeychainPromptCooldown: false),
        ])
    }

    @Test
    func `background fetch loads credentials without prompt and with cooldown`() async throws {
        let usageResponse = try Self.makeOAuthUsageResponse()
        let loadCalls = Mutex<[LoadCall]>([])

        let snapshot = try await withOAuthSeams(
            load: { _, allowPrompt, respectCooldown in
                loadCalls.withLock {
                    $0.append(LoadCall(
                        allowKeychainPrompt: allowPrompt,
                        respectKeychainPromptCooldown: respectCooldown))
                }
                return Self.makeCredentials()
            },
            fetch: { _ in usageResponse },
            operation: {
                try await Self.makeService().fetchUsage(interaction: .background)
            })

        #expect(snapshot.primary.usedPercent == 7)
        #expect(loadCalls.withLock { $0 } == [
            LoadCall(allowKeychainPrompt: false, respectKeychainPromptCooldown: true),
        ])
    }

    @Test
    func `OAuth 429 usage fetch surfaces typed rate limit without retry`() async throws {
        let loadCount = Mutex(0)
        let fetchCount = Mutex(0)

        do {
            _ = try await withOAuthSeams(
                load: { _, _, _ in
                    loadCount.withLock { $0 += 1 }
                    return Self.makeCredentials(accessToken: "rate-limited-token")
                },
                fetch: { _ in
                    fetchCount.withLock { $0 += 1 }
                    throw ClaudeOAuthFetchError.rateLimited(retryAfter: Date().addingTimeInterval(300))
                },
                operation: {
                    try await Self.makeService().fetchUsage(interaction: .userInitiated)
                })
            Issue.record("Expected OAuth rate limit to fail with guidance")
        } catch let error as ClaudeUsageError {
            guard case let .fetch(fetchError) = error, case .rateLimited = fetchError else {
                Issue.record("Expected ClaudeUsageError.fetch(.rateLimited), got \(error)")
                return
            }
            let message = error.localizedDescription
            #expect(message.contains("rate limited"))
            #expect(message.contains("claude logout && claude login"))
            #expect(!message.contains("rate_limit_error"))
            #expect(error.indicatesAuthenticationRequired == false)
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        #expect(loadCount.withLock { $0 } == 1)
        #expect(fetchCount.withLock { $0 } == 1)
    }

    @Test
    func `oauth 401 invalidates cache and retries once with fresh credentials`() async throws {
        let usageResponse = try Self.makeOAuthUsageResponse()
        let loadCalls = Mutex<[LoadCall]>([])
        let fetchedTokens = Mutex<[String]>([])

        let snapshot = try await withIsolatedCacheStores {
            try await withOAuthSeams(
                load: { _, allowPrompt, respectCooldown in
                    loadCalls.withLock {
                        $0.append(LoadCall(
                            allowKeychainPrompt: allowPrompt,
                            respectKeychainPromptCooldown: respectCooldown))
                    }
                    return Self.makeCredentials(accessToken: "token-\(loadCalls.withLock { $0.count })")
                },
                fetch: { token in
                    let attempt = fetchedTokens.withLock { tokens in
                        tokens.append(token)
                        return tokens.count
                    }
                    if attempt == 1 {
                        throw ClaudeOAuthFetchError.unauthorized
                    }
                    return usageResponse
                },
                operation: {
                    try await Self.makeService().fetchUsage(interaction: .userInitiated)
                })
        }

        #expect(snapshot.primary.usedPercent == 7)
        // Exactly one retry: credentials reloaded once, both loads prompt-eligible for a user action.
        #expect(loadCalls.withLock { $0 } == [
            LoadCall(allowKeychainPrompt: true, respectKeychainPromptCooldown: false),
            LoadCall(allowKeychainPrompt: true, respectKeychainPromptCooldown: false),
        ])
        #expect(fetchedTokens.withLock { $0 } == ["token-1", "token-2"])
    }

    @Test
    func `oauth 401 in background retries once without keychain prompt`() async throws {
        let usageResponse = try Self.makeOAuthUsageResponse()
        let loadCalls = Mutex<[LoadCall]>([])
        let fetchCount = Mutex(0)

        let snapshot = try await withIsolatedCacheStores {
            try await withOAuthSeams(
                load: { _, allowPrompt, respectCooldown in
                    loadCalls.withLock {
                        $0.append(LoadCall(
                            allowKeychainPrompt: allowPrompt,
                            respectKeychainPromptCooldown: respectCooldown))
                    }
                    return Self.makeCredentials()
                },
                fetch: { _ in
                    let attempt = fetchCount.withLock { count in
                        count += 1
                        return count
                    }
                    if attempt == 1 {
                        throw ClaudeOAuthFetchError.unauthorized
                    }
                    return usageResponse
                },
                operation: {
                    try await Self.makeService().fetchUsage(interaction: .background)
                })
        }

        #expect(snapshot.primary.usedPercent == 7)
        #expect(loadCalls.withLock { $0 } == [
            LoadCall(allowKeychainPrompt: false, respectKeychainPromptCooldown: true),
            LoadCall(allowKeychainPrompt: false, respectKeychainPromptCooldown: true),
        ])
        #expect(fetchCount.withLock { $0 } == 2)
    }

    @Test
    func `oauth 401 fails with typed error after exactly one retry`() async throws {
        let loadCount = Mutex(0)
        let fetchCount = Mutex(0)

        do {
            _ = try await withIsolatedCacheStores {
                try await withOAuthSeams(
                    load: { _, _, _ in
                        loadCount.withLock { $0 += 1 }
                        return Self.makeCredentials(accessToken: "always-rejected")
                    },
                    fetch: { _ in
                        fetchCount.withLock { $0 += 1 }
                        throw ClaudeOAuthFetchError.unauthorized
                    },
                    operation: {
                        try await Self.makeService().fetchUsage(interaction: .userInitiated)
                    })
            }
            Issue.record("Expected ClaudeUsageError.fetch(.unauthorized)")
        } catch let error as ClaudeUsageError {
            guard case let .fetch(fetchError) = error, case .unauthorized = fetchError else {
                Issue.record("Expected ClaudeUsageError.fetch(.unauthorized), got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        #expect(loadCount.withLock { $0 } == 2)
        #expect(fetchCount.withLock { $0 } == 2)
    }

    @Test
    func `oauth bootstrap only on user action background startup allows interactive read when no cache`() async throws {
        let usageResponse = try Self.makeOAuthUsageResponse()
        let promptFlags = Mutex<[Bool]>([])
        let bootstrapFlags = Mutex<[Bool]>([])

        let snapshot = try await withOAuthSeams(
            promptMode: .onlyOnUserAction,
            hasCachedCredentials: false,
            load: { _, allowPrompt, _ in
                promptFlags.withLock { $0.append(allowPrompt) }
                bootstrapFlags.withLock {
                    $0.append(ClaudeOAuthCredentialsStore.allowBackgroundPromptBootstrap)
                }
                return Self.makeCredentials()
            },
            fetch: { _ in usageResponse },
            operation: {
                try await Self.makeService(allowStartupBootstrapPrompt: true)
                    .fetchUsage(interaction: .background, phase: .startup)
            })

        #expect(promptFlags.withLock { $0 } == [true])
        #expect(bootstrapFlags.withLock { $0 } == [true])
        #expect(snapshot.primary.usedPercent == 7)
    }

    @Test
    func `ambient startup phase binding still activates bootstrap`() async throws {
        // Proves RefreshContext.$current ambient binding is still honoured (phase: .regular default
        // defers to whatever the TaskLocal was set to by a wrapping context).
        let usageResponse = try Self.makeOAuthUsageResponse()
        let promptFlags = Mutex<[Bool]>([])

        let snapshot = try await RefreshContext.$current.withValue(.startup) {
            try await withOAuthSeams(
                promptMode: .onlyOnUserAction,
                hasCachedCredentials: false,
                load: { _, allowPrompt, _ in
                    promptFlags.withLock { $0.append(allowPrompt) }
                    return Self.makeCredentials()
                },
                fetch: { _ in usageResponse },
                operation: {
                    try await Self.makeService(allowStartupBootstrapPrompt: true)
                        .fetchUsage(interaction: .background)
                })
        }

        #expect(promptFlags.withLock { $0 } == [true])
        #expect(snapshot.primary.usedPercent == 7)
    }

    @Test
    func `oauth bootstrap stays suppressed outside startup refresh`() async throws {
        let usageResponse = try Self.makeOAuthUsageResponse()
        let promptFlags = Mutex<[Bool]>([])
        let bootstrapFlags = Mutex<[Bool]>([])

        _ = try await withOAuthSeams(
            promptMode: .onlyOnUserAction,
            hasCachedCredentials: false,
            load: { _, allowPrompt, _ in
                promptFlags.withLock { $0.append(allowPrompt) }
                bootstrapFlags.withLock {
                    $0.append(ClaudeOAuthCredentialsStore.allowBackgroundPromptBootstrap)
                }
                return Self.makeCredentials()
            },
            fetch: { _ in usageResponse },
            operation: {
                try await Self.makeService(allowStartupBootstrapPrompt: true)
                    .fetchUsage(interaction: .background)
            })

        #expect(promptFlags.withLock { $0 } == [false])
        #expect(bootstrapFlags.withLock { $0 } == [false])
    }

    @Test
    func `missing user profile scope fails before hitting the usage endpoint`() async throws {
        let fetchCount = Mutex(0)

        do {
            _ = try await withOAuthSeams(
                load: { _, _, _ in Self.makeCredentials(scopes: ["usage:read"]) },
                fetch: { _ in
                    fetchCount.withLock { $0 += 1 }
                    return try Self.makeOAuthUsageResponse()
                },
                operation: {
                    try await Self.makeService().fetchUsage(interaction: .userInitiated)
                })
            Issue.record("Expected ClaudeUsageError.scopeUnsatisfied")
        } catch let error as ClaudeUsageError {
            guard case let .scopeUnsatisfied(message) = error else {
                Issue.record("Expected .scopeUnsatisfied, got \(error)")
                return
            }
            #expect(message.contains("user:profile"))
            #expect(message.contains("usage:read"))
            #expect(error.indicatesAuthenticationRequired == true)
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }

        #expect(fetchCount.withLock { $0 } == 0)
    }

    @Test
    func `credential store errors pass through typed`() async throws {
        do {
            _ = try await withOAuthSeams(
                load: { _, _, _ in
                    throw ClaudeOAuthCredentialsError.refreshFailed(
                        kind: .terminal,
                        message: "invalid_grant")
                },
                fetch: { _ in try Self.makeOAuthUsageResponse() },
                operation: {
                    try await Self.makeService().fetchUsage(interaction: .background)
                })
            Issue.record("Expected ClaudeUsageError.credentials")
        } catch let error as ClaudeUsageError {
            guard case let .credentials(credentialsError) = error,
                  case .refreshFailed(kind: .terminal, message: _) = credentialsError
            else {
                Issue.record("Expected .credentials(.refreshFailed(kind: .terminal)), got \(error)")
                return
            }
            #expect(error.indicatesAuthenticationRequired == true)
        } catch {
            Issue.record("Expected ClaudeUsageError, got \(error)")
        }
    }

    @Test
    func `needs reauth derives from typed cases only`() {
        // indicatesAuthenticationRequired matrix
        #expect(ClaudeUsageError.credentials(.noRefreshToken(source: nil)).indicatesAuthenticationRequired == true)
        #expect(ClaudeUsageError.credentials(.refreshFailed(kind: .terminal, message: "invalid_grant"))
            .indicatesAuthenticationRequired == true)
        #expect(ClaudeUsageError.scopeUnsatisfied(message: "missing scope")
            .indicatesAuthenticationRequired == true)
        #expect(ClaudeUsageError.credentials(.refreshFailed(kind: .transient, message: "http 503"))
            .indicatesAuthenticationRequired == false)
        #expect(ClaudeUsageError.credentials(.refreshFailed(kind: .suppressed, message: "gate"))
            .indicatesAuthenticationRequired == false)
        #expect(ClaudeUsageError.credentials(.notFound).indicatesAuthenticationRequired == false)
        #expect(ClaudeUsageError.fetch(.unauthorized).indicatesAuthenticationRequired == false)
        #expect(ClaudeUsageError.parseFailed("missing session data").indicatesAuthenticationRequired == false)
        #expect(ClaudeUsageError.oauthFailed("anything").indicatesAuthenticationRequired == false)

        // indicatesCredentialsMissing matrix (Phase 3: "run claude to log in" UX)
        #expect(ClaudeUsageError.credentials(.notFound).indicatesCredentialsMissing == true)
        #expect(ClaudeUsageError.credentials(.missingOAuth).indicatesCredentialsMissing == true)
        #expect(ClaudeUsageError.credentials(.missingAccessToken).indicatesCredentialsMissing == true)
        #expect(ClaudeUsageError.credentials(.decodeFailed).indicatesCredentialsMissing == true)
        #expect(ClaudeUsageError.credentials(.noRefreshToken(source: nil)).indicatesCredentialsMissing == false)
        #expect(ClaudeUsageError.credentials(.refreshFailed(kind: .terminal, message: "x"))
            .indicatesCredentialsMissing == false)
        #expect(ClaudeUsageError.scopeUnsatisfied(message: "missing scope").indicatesCredentialsMissing == false)
        #expect(ClaudeUsageError.fetch(.unauthorized).indicatesCredentialsMissing == false)
    }
}
