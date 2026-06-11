import Foundation

// MARK: - Links

/// Claude provider links and display metadata (inlined from the legacy provider descriptor).
public enum ClaudeLinks {
    public static let displayName = "Claude"
    public static let dashboardURL = "https://console.anthropic.com/settings/billing"
    public static let subscriptionDashboardURL = "https://claude.ai/settings/usage"
    public static let statusPageURL = "https://status.claude.com/"
}

// MARK: - Errors

public enum ClaudeUsageError: LocalizedError, Sendable {
    case parseFailed(String)
    case oauthFailed(String)
    /// The OAuth token is missing a required scope (e.g. `user:profile`). This is a permanent
    /// user-action state: the user must re-generate credentials via `claude setup-token`.
    case scopeUnsatisfied(message: String)
    /// Typed pass-through of credential store failures. Needs-reauth is derived from
    /// `.noRefreshToken` / `.refreshFailed(kind: .terminal, _)` — never from message strings.
    case credentials(ClaudeOAuthCredentialsError)
    /// Typed pass-through of usage endpoint failures (401/403/429/5xx/network).
    case fetch(ClaudeOAuthFetchError)

    public var errorDescription: String? {
        switch self {
        case let .parseFailed(details):
            "Could not parse Claude usage: \(details)"
        case let .oauthFailed(details):
            details
        case let .scopeUnsatisfied(message):
            message
        case let .credentials(error):
            error.errorDescription
        case let .fetch(error):
            error.errorDescription
        }
    }

    /// True when the underlying failure means the user must re-authenticate in Claude Code.
    /// Phase 3 maps this → `needsReauth` UX.
    /// Callers should additionally consult `ClaudeOAuthRefreshFailureGate.currentBlockStatus()`,
    /// which is the persistent needs-reauth authority across fetch attempts.
    public var indicatesAuthenticationRequired: Bool {
        switch self {
        case .scopeUnsatisfied:
            true
        case let .credentials(error):
            switch error {
            case .noRefreshToken:
                true
            case .refreshFailed(kind: .terminal, message: _):
                true
            default:
                false
            }
        default:
            false
        }
    }

    /// True when no Claude credentials exist at all and the user needs to run `claude` to log in.
    /// Phase 3 maps this → "run claude to log in" UX.
    public var indicatesCredentialsMissing: Bool {
        guard case let .credentials(error) = self else { return false }
        switch error {
        case .notFound, .missingOAuth, .missingAccessToken, .decodeFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - ClaudeUsageService

/// Fetches Claude usage via the OAuth usage endpoint.
///
/// Synchronous keychain work happens inside the credentials store (prompts, /usr/bin/security
/// spawn); this service is designed to be wrapped in an actor (`ClaudeUsageClient`) in a later
/// phase, so its public API is async and Sendable-clean.
public struct ClaudeUsageService: Sendable {
    private struct Configuration: Sendable {
        let environment: [String: String]
        let allowStartupBootstrapPrompt: Bool
    }

    private let configuration: Configuration
    private let transport: any HTTPTransport
    private static let log = SturtBarLog.logger("claude-usage")

    var environment: [String: String] {
        self.configuration.environment
    }

    var allowStartupBootstrapPrompt: Bool {
        self.configuration.allowStartupBootstrapPrompt
    }

    /// Creates a new ClaudeUsageService.
    /// - Parameters:
    ///   - transport: HTTP transport used for the usage endpoint (injectable for tests).
    ///   - environment: Process environment (default: current process environment).
    ///   - allowStartupBootstrapPrompt: Allows one background keychain prompt during app startup
    ///     when no cached credentials exist and the prompt policy is `onlyOnUserAction`.
    public init(
        transport: any HTTPTransport = HTTPClient.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowStartupBootstrapPrompt: Bool = false)
    {
        self.transport = transport
        self.configuration = Configuration(
            environment: environment,
            allowStartupBootstrapPrompt: allowStartupBootstrapPrompt)
    }

    /// Loads the latest Claude usage snapshot.
    /// - Parameters:
    ///   - interaction: Drives keychain prompt policy; background fetches never prompt and respect
    ///     the cooldown; user-initiated fetches may prompt and bypass the cooldown.
    ///   - phase: Refresh phase; `.startup` activates the one-time bootstrap prompt override when
    ///     passed explicitly. The default `.regular` leaves any ambient `RefreshContext.$current`
    ///     binding from the caller untouched, so startup-bootstrap code that binds the TaskLocal
    ///     itself still works without passing the parameter.
    public func fetchUsage(
        interaction: Interaction,
        phase: RefreshPhase = .regular) async throws -> ClaudeUsageSnapshot
    {
        try await InteractionContext.$current.withValue(interaction) {
            if phase != .regular {
                try await RefreshContext.$current.withValue(phase) {
                    try await OAuthExecutor(service: self).load(allowUnauthorizedRetry: true)
                }
            } else {
                try await OAuthExecutor(service: self).load(allowUnauthorizedRetry: true)
            }
        }
    }

    // MARK: - Keychain prompt policy

    struct ClaudeOAuthKeychainPromptPolicy {
        let mode: ClaudeOAuthKeychainPromptMode
        let interaction: Interaction

        var canPromptNow: Bool {
            switch self.mode {
            case .never:
                false
            case .onlyOnUserAction:
                self.interaction == .userInitiated
            case .always:
                true
            }
        }

        /// Respect the Keychain prompt cooldown for background operations to avoid spamming system dialogs.
        /// User actions (menu open / refresh / settings) are allowed to bypass the cooldown.
        var shouldRespectKeychainPromptCooldown: Bool {
            self.interaction != .userInitiated
        }

        var interactionLabel: String {
            self.interaction == .userInitiated ? "user" : "background"
        }
    }

    static func currentClaudeOAuthInteractivePromptPolicy() -> ClaudeOAuthKeychainPromptPolicy {
        let policy = ClaudeOAuthKeychainPromptPolicy(
            mode: ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode(),
            interaction: InteractionContext.current)

        // User actions should be able to immediately retry a Security.framework fallback repair after a background
        // cooldown was recorded, even when /usr/bin/security is the primary reader.
        if policy.interaction == .userInitiated {
            if ClaudeOAuthKeychainAccessGate.clearDenied() {
                Self.log.info("Claude OAuth keychain cooldown cleared by user action")
            }
        }
        return policy
    }

    // MARK: - Testing seams

    #if DEBUG
    @TaskLocal static var loadOAuthCredentialsOverride: (@Sendable (
        [String: String],
        Bool,
        Bool) async throws -> ClaudeOAuthCredentials)?
    @TaskLocal static var fetchOAuthUsageOverride: (@Sendable (String) async throws -> OAuthUsageResponse)?
    @TaskLocal static var hasCachedCredentialsOverride: Bool?
    #endif

    // MARK: - OAuth executor

    private struct OAuthExecutor {
        let service: ClaudeUsageService

        func load(allowUnauthorizedRetry: Bool) async throws -> ClaudeUsageSnapshot {
            do {
                let promptPolicy = ClaudeUsageService.currentClaudeOAuthInteractivePromptPolicy()
                let hasCache = self.resolveHasCache()

                let startupBootstrapOverride = self.shouldAllowStartupBootstrapPrompt(
                    policy: promptPolicy,
                    hasCache: hasCache)
                let allowKeychainPrompt = (promptPolicy.canPromptNow || startupBootstrapOverride) && !hasCache
                ClaudeUsageService.logOAuthBootstrapPromptDecision(
                    allowKeychainPrompt: allowKeychainPrompt,
                    policy: promptPolicy,
                    hasCache: hasCache,
                    startupBootstrapOverride: startupBootstrapOverride)

                let credentials = try await ClaudeOAuthCredentialsStore.$allowBackgroundPromptBootstrap
                    .withValue(startupBootstrapOverride) {
                        try await ClaudeUsageService.loadOAuthCredentials(
                            environment: self.service.environment,
                            allowKeychainPrompt: allowKeychainPrompt,
                            respectKeychainPromptCooldown: promptPolicy.shouldRespectKeychainPromptCooldown)
                    }

                try self.validateRequiredOAuthScope(credentials)
                let usage = try await self.service.fetchOAuthUsage(accessToken: credentials.accessToken)
                return try ClaudeUsageService.mapOAuthUsage(usage, credentials: credentials, now: Date())
            } catch let error as CancellationError {
                throw error
            } catch let error as ClaudeUsageError {
                throw error
            } catch let error as ClaudeOAuthCredentialsError {
                throw ClaudeUsageError.credentials(error)
            } catch let error as ClaudeOAuthFetchError {
                if case .rateLimited = error {
                    throw ClaudeUsageError.fetch(error)
                }
                ClaudeOAuthCredentialsStore.invalidateCache()
                if case .unauthorized = error, allowUnauthorizedRetry {
                    // Auth-recovery UX: the cached access token was rejected (e.g. superseded by a
                    // re-login in Claude Code). Reload credentials from the source of truth — now
                    // prompt-eligible because the cache was invalidated — and retry exactly once.
                    ClaudeUsageService.log.info(
                        "Claude OAuth usage fetch unauthorized; invalidated cache and retrying once")
                    return try await self.load(allowUnauthorizedRetry: false)
                }
                if case let .serverError(statusCode, body) = error,
                   statusCode == 403,
                   body?.contains("user:profile") ?? false
                {
                    throw ClaudeUsageError.scopeUnsatisfied(
                        message: "Claude OAuth token does not meet scope requirement 'user:profile'. "
                            + "Run `claude setup-token` to re-generate credentials.")
                }
                throw ClaudeUsageError.fetch(error)
            } catch {
                throw ClaudeUsageError.oauthFailed(error.localizedDescription)
            }
        }

        /// Resolves whether cached credentials already exist.
        ///
        /// **DEBUG seam contract (load-override-set ⇒ hasCache defaults false)**:
        /// 1. `hasCachedCredentialsOverride` explicitly set   → use that value (test controls)
        /// 2. `loadOAuthCredentialsOverride` is non-nil       → treat as no-cache (the override
        ///    supplies its own credentials, so the real keychain state is irrelevant)
        /// 3. Otherwise                                        → query the real credentials store
        private func resolveHasCache() -> Bool {
            #if DEBUG
            if let explicit = ClaudeUsageService.hasCachedCredentialsOverride {
                return explicit
            }
            if ClaudeUsageService.loadOAuthCredentialsOverride != nil {
                return false
            }
            #endif
            return ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: self.service.environment)
        }

        private func shouldAllowStartupBootstrapPrompt(
            policy: ClaudeOAuthKeychainPromptPolicy,
            hasCache: Bool) -> Bool
        {
            guard self.service.allowStartupBootstrapPrompt else { return false }
            guard !hasCache else { return false }
            guard ClaudeOAuthKeychainPromptPreference.securityFrameworkFallbackMode() == .onlyOnUserAction else {
                return false
            }
            guard policy.interaction == .background else { return false }
            return RefreshContext.current == .startup
        }

        private func validateRequiredOAuthScope(_ credentials: ClaudeOAuthCredentials) throws {
            guard credentials.scopes.contains("user:profile") else {
                let scopes = credentials.scopes.joined(separator: ", ")
                let detail = scopes.isEmpty
                    ? "Claude OAuth token missing 'user:profile' scope."
                    : "Claude OAuth token missing 'user:profile' scope (has: \(scopes))."
                throw ClaudeUsageError.scopeUnsatisfied(
                    message: detail + " Run `claude setup-token` to re-generate credentials.")
            }
        }
    }

    // MARK: - Store / endpoint access

    private static func logOAuthBootstrapPromptDecision(
        allowKeychainPrompt: Bool,
        policy: ClaudeOAuthKeychainPromptPolicy,
        hasCache: Bool,
        startupBootstrapOverride: Bool)
    {
        guard allowKeychainPrompt else { return }
        self.log.info(
            "Claude OAuth keychain prompt allowed (bootstrap)",
            metadata: [
                "interaction": policy.interactionLabel,
                "promptMode": policy.mode.rawValue,
                "hasCache": "\(hasCache)",
                "startupBootstrapOverride": "\(startupBootstrapOverride)",
            ])
    }

    private static func loadOAuthCredentials(
        environment: [String: String],
        allowKeychainPrompt: Bool,
        respectKeychainPromptCooldown: Bool) async throws -> ClaudeOAuthCredentials
    {
        #if DEBUG
        if let override = loadOAuthCredentialsOverride {
            return try await override(environment, allowKeychainPrompt, respectKeychainPromptCooldown)
        }
        #endif
        return try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
            environment: environment,
            allowKeychainPrompt: allowKeychainPrompt,
            respectKeychainPromptCooldown: respectKeychainPromptCooldown)
    }

    private func fetchOAuthUsage(accessToken: String) async throws -> OAuthUsageResponse {
        #if DEBUG
        if let override = Self.fetchOAuthUsageOverride {
            return try await override(accessToken)
        }
        #endif
        return try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: accessToken, transport: self.transport)
    }

    // MARK: - OAuth usage mapping

    private static let weeklyWindowMinutes = 7 * 24 * 60

    private static func mapOAuthUsage(
        _ usage: OAuthUsageResponse,
        credentials: ClaudeOAuthCredentials,
        now: Date = Date()) throws -> ClaudeUsageSnapshot
    {
        func makeWindow(_ window: OAuthUsageWindow?, windowMinutes: Int?) -> RateWindow? {
            guard let window,
                  let utilization = window.utilization
            else { return nil }
            let resetDate = ClaudeOAuthUsageFetcher.parseISO8601Date(window.resetsAt)
            let resetDescription = resetDate.map(Self.formatResetDate)
            return RateWindow(
                usedPercent: utilization,
                windowMinutes: windowMinutes,
                resetsAt: resetDate,
                resetDescription: resetDescription)
        }

        let loginMethod = ClaudePlan.oauthLoginMethod(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier)
        let primary = makeWindow(usage.fiveHour, windowMinutes: 5 * 60)
            ?? makeWindow(usage.sevenDay, windowMinutes: Self.weeklyWindowMinutes)
            ?? makeWindow(usage.sevenDayOAuthApps, windowMinutes: Self.weeklyWindowMinutes)
            ?? makeWindow(usage.sevenDaySonnet, windowMinutes: Self.weeklyWindowMinutes)
            ?? makeWindow(usage.sevenDayOpus, windowMinutes: Self.weeklyWindowMinutes)
        let treatAsSpendLimit = primary == nil && usage.extraUsage?.isEnabled == true
        let providerCost = Self.oauthExtraUsageCost(
            usage.extraUsage,
            loginMethod: loginMethod,
            treatAsSpendLimit: treatAsSpendLimit,
            now: now)

        guard let primary else {
            if let spendLimit = Self.oauthSpendLimitWindow(from: providerCost, extraUsage: usage.extraUsage) {
                return ClaudeUsageSnapshot(
                    primary: spendLimit,
                    primaryWindowKind: .spendLimit,
                    secondary: nil,
                    opus: nil,
                    extraRateWindows: Self.oauthExtraRateWindows(from: usage),
                    providerCost: providerCost,
                    updatedAt: now,
                    loginMethod: loginMethod)
            }
            throw ClaudeUsageError.parseFailed("missing session data")
        }

        let weekly = makeWindow(usage.sevenDay, windowMinutes: Self.weeklyWindowMinutes)
        let modelSpecific = makeWindow(
            usage.sevenDaySonnet ?? usage.sevenDayOpus,
            windowMinutes: Self.weeklyWindowMinutes)
        let extraRateWindows = Self.oauthExtraRateWindows(from: usage)

        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: weekly,
            opus: modelSpecific,
            extraRateWindows: extraRateWindows,
            providerCost: providerCost,
            updatedAt: now,
            loginMethod: loginMethod)
    }

    private static func oauthExtraUsageCost(
        _ extra: OAuthExtraUsage?,
        loginMethod: String?,
        treatAsSpendLimit: Bool = false,
        now: Date = Date()) -> ProviderCostSnapshot?
    {
        guard let extra, extra.isEnabled == true else { return nil }
        guard let used = extra.usedCredits,
              let limit = extra.monthlyLimit
        else { return nil }
        let currency = extra.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = (currency?.isEmpty ?? true) ? "USD" : currency!
        let isSpendLimit = treatAsSpendLimit || ClaudePlan.fromCompatibilityLoginMethod(loginMethod) == .enterprise
        // Claude's OAuth API returns values in cents (minor units); always convert to dollars.
        let normalizedUsed = used / 100.0
        let normalizedLimit = limit / 100.0
        return ProviderCostSnapshot(
            used: normalizedUsed,
            limit: normalizedLimit,
            currencyCode: code,
            period: isSpendLimit ? "Spend limit" : "Monthly cap",
            resetsAt: nil,
            updatedAt: now)
    }

    private static func oauthSpendLimitWindow(
        from providerCost: ProviderCostSnapshot?,
        extraUsage: OAuthExtraUsage?) -> RateWindow?
    {
        guard let providerCost,
              providerCost.limit > 0
        else { return nil }
        let usedPercent = extraUsage?.utilization ?? (providerCost.used / providerCost.limit) * 100
        let used = UsageFormatter.currencyString(providerCost.used, currencyCode: providerCost.currencyCode)
        let limit = UsageFormatter.currencyString(providerCost.limit, currencyCode: providerCost.currencyCode)
        return RateWindow(
            usedPercent: min(100, max(0, usedPercent)),
            windowMinutes: nil,
            resetsAt: providerCost.resetsAt,
            resetDescription: "\(providerCost.period ?? "Spend limit"): \(used) / \(limit)")
    }

    private static func oauthExtraRateWindows(from usage: OAuthUsageResponse) -> [NamedRateWindow] {
        let definitions: [(id: String, title: String, window: OAuthUsageWindow?, sourceKey: String?)] = [
            (
                id: "claude-routines",
                title: "Daily Routines",
                window: usage.sevenDayRoutines,
                sourceKey: usage.sevenDayRoutinesSourceKey),
        ]
        if let routinesKey = usage.sevenDayRoutinesSourceKey {
            Self.log.debug("Claude OAuth extra usage key matched: routines=\(routinesKey)")
        }
        return definitions.compactMap { definition in
            let utilization: Double
            let resetDate: Date?
            if let window = definition.window, let parsedUtilization = window.utilization {
                utilization = parsedUtilization
                resetDate = ClaudeOAuthUsageFetcher.parseISO8601Date(window.resetsAt)
            } else if definition.sourceKey != nil {
                // Keep product bars visible when the API returns a known key with null payload.
                utilization = 0
                resetDate = nil
            } else {
                return nil
            }
            let resetDescription = resetDate.map(Self.formatResetDate)
            return NamedRateWindow(
                id: definition.id,
                title: definition.title,
                window: RateWindow(
                    usedPercent: utilization,
                    windowMinutes: Self.weeklyWindowMinutes,
                    resetsAt: resetDate,
                    resetDescription: resetDescription))
        }
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

#if DEBUG
extension ClaudeUsageService {
    public static func _mapOAuthUsageForTesting(
        _ data: Data,
        rateLimitTier: String? = nil,
        subscriptionType: String? = nil,
        now: Date = Date()) throws -> ClaudeUsageSnapshot
    {
        let usage = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        let creds = ClaudeOAuthCredentials(
            accessToken: "test",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600),
            scopes: [],
            rateLimitTier: rateLimitTier,
            subscriptionType: subscriptionType)
        return try Self.mapOAuthUsage(usage, credentials: creds, now: now)
    }
}
#endif
