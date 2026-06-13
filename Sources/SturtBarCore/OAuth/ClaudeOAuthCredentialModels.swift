import Foundation

#if os(macOS)
import Security
#endif

public struct ClaudeOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let rateLimitTier: String?
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        rateLimitTier: String?,
        subscriptionType: String? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
        self.subscriptionType = subscriptionType
    }

    public var isExpired: Bool {
        guard let expiresAt else { return true }
        return Date() >= expiresAt
    }

    public var expiresIn: TimeInterval? {
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSinceNow
    }

    public static func parse(data: Data) throws -> ClaudeOAuthCredentials {
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(Root.self, from: data) else {
            throw ClaudeOAuthCredentialsError.decodeFailed
        }
        guard let oauth = root.claudeAiOauth else {
            throw ClaudeOAuthCredentialsError.missingOAuth
        }
        let accessToken = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accessToken.isEmpty else {
            throw ClaudeOAuthCredentialsError.missingAccessToken
        }
        let expiresAt = oauth.expiresAt.map { millis in
            Date(timeIntervalSince1970: millis / 1000.0)
        }
        return ClaudeOAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            scopes: oauth.scopes ?? [],
            rateLimitTier: oauth.rateLimitTier,
            subscriptionType: oauth.subscriptionType)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let rateLimitTier: String?
        let subscriptionType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken
            case refreshToken
            case expiresAt
            case scopes
            case rateLimitTier
            case subscriptionType
        }
    }
}

extension ClaudeOAuthCredentials {
    func diagnosticsMetadata(now: Date = Date()) -> [String: String] {
        let hasRefreshToken = !(self.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasUserProfileScope = self.scopes.contains("user:profile")

        var metadata: [String: String] = [
            "hasRefreshToken": "\(hasRefreshToken)",
            "scopesCount": "\(self.scopes.count)",
            "hasUserProfileScope": "\(hasUserProfileScope)",
        ]

        if let expiresAt = self.expiresAt {
            let expiresAtMs = Int(expiresAt.timeIntervalSince1970 * 1000.0)
            let expiresInSec = Int(expiresAt.timeIntervalSince(now).rounded())
            metadata["expiresAtMs"] = "\(expiresAtMs)"
            metadata["expiresInSec"] = "\(expiresInSec)"
            metadata["isExpired"] = "\(now >= expiresAt)"
        } else {
            metadata["expiresAtMs"] = "nil"
            metadata["expiresInSec"] = "nil"
            metadata["isExpired"] = "true"
        }

        return metadata
    }
}

public enum ClaudeOAuthCredentialOwner: String, Codable, Sendable {
    case claudeCLI
    case sturtbar
    case environment
}

public enum ClaudeOAuthCredentialSource: String, Sendable {
    case environment
    case memoryCache
    case cacheKeychain
    case credentialsFile
    case claudeKeychain

    /// Short human label naming where credentials were read from, for user-facing errors. Knowing
    /// the offending store is what makes "refresh token missing" actionable when debugging
    /// remotely (e.g. a stale `~/.claude/.credentials.json` shadowing a fresh keychain item).
    public var humanLabel: String {
        switch self {
        case .environment:
            "the STURTBAR_CLAUDE_OAUTH_TOKEN environment variable"
        case .memoryCache, .cacheKeychain:
            "SturtBar's cached copy"
        case .credentialsFile:
            "~/.claude/.credentials.json"
        case .claudeKeychain:
            "the Claude Code keychain item"
        }
    }
}

public struct ClaudeOAuthCredentialRecord: Sendable {
    public let credentials: ClaudeOAuthCredentials
    public let owner: ClaudeOAuthCredentialOwner
    public let source: ClaudeOAuthCredentialSource

    public init(
        credentials: ClaudeOAuthCredentials,
        owner: ClaudeOAuthCredentialOwner,
        source: ClaudeOAuthCredentialSource)
    {
        self.credentials = credentials
        self.owner = owner
        self.source = source
    }
}

public enum RefreshFailureKind: String, Sendable, Equatable {
    case terminal // invalid_grant etc. — needs re-auth in Claude Code
    case transient // network/5xx/429 on the token endpoint — retry later
    case suppressed // refresh-failure gate blocked the attempt
}

public enum ClaudeOAuthCredentialsError: LocalizedError, Sendable {
    case decodeFailed
    case missingOAuth
    case missingAccessToken
    case notFound
    case keychainError(Int)
    case readFailed(String)
    case refreshFailed(kind: RefreshFailureKind, message: String)
    case noRefreshToken(source: ClaudeOAuthCredentialSource?)
    /// The only loadable credentials are stale, but a Claude Code keychain item exists that
    /// SturtBar could not read silently — typically after a re-login in Claude Code recreated the
    /// item and reset its access control. The fix is a user-initiated refresh plus approving the
    /// Keychain prompt, not another re-login.
    case claudeKeychainAccessRequired(underlying: String?)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            return "Claude OAuth credentials are invalid."
        case .missingOAuth:
            return "Claude OAuth credentials missing. Run `claude` to authenticate."
        case .missingAccessToken:
            return "Claude OAuth access token missing. Run `claude` to authenticate."
        case .notFound:
            return "Claude OAuth credentials not found. Run `claude` to authenticate."
        case let .keychainError(status):
            #if os(macOS)
            if status == Int(errSecUserCanceled)
                || status == Int(errSecAuthFailed)
                || status == Int(errSecInteractionNotAllowed)
                || status == Int(errSecNoAccessForItem)
            {
                return "Claude Keychain access was denied. Open the SturtBar menu and press ⌘R, "
                    + "then choose Always Allow. SturtBar backs off in the background until you do."
            }
            #endif
            return "Claude OAuth keychain error: \(status)"
        case let .readFailed(message):
            return "Claude OAuth credentials read failed: \(message)"
        case let .refreshFailed(kind, message):
            return "Claude OAuth token refresh failed [\(kind.rawValue)]: \(message)"
        case let .noRefreshToken(source):
            if source == .environment {
                return "Claude OAuth environment token expired and cannot be refreshed. "
                    + "Provide a fresh STURTBAR_CLAUDE_OAUTH_TOKEN."
            }
            let origin = source.map { " (from \($0.humanLabel))" } ?? ""
            return "Claude OAuth refresh token missing\(origin). Run `claude` to authenticate."
        case let .claudeKeychainAccessRequired(underlying):
            // Keep the action inside the first ~80 characters: the menu card truncates the detail.
            var text = "Open the SturtBar menu, press ⌘R, then allow Keychain access. "
                + "Claude Code's sign-in changed and SturtBar can't read it yet."
            if let underlying, !underlying.isEmpty {
                text += " (\(underlying))"
            }
            return text
        }
    }
}
