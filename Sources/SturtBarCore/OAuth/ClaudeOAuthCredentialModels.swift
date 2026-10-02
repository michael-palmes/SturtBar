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
        let expiresAt = oauth.expiresAt.flatMap { millis in
            millis.isFinite ? Date(timeIntervalSince1970: millis / 1000.0) : nil
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
            // A corrupt credentials file can hold any number; Int(Double) would trap on it.
            let expiresAtMs = Int(exactly: (expiresAt.timeIntervalSince1970 * 1000.0).rounded(.towardZero))
            let expiresInSec = Int(exactly: expiresAt.timeIntervalSince(now).rounded())
            metadata["expiresAtMs"] = expiresAtMs.map { "\($0)" } ?? "out_of_range"
            metadata["expiresInSec"] = expiresInSec.map { "\($0)" } ?? "out_of_range"
            metadata["isExpired"] = "\(now >= expiresAt)"
        } else {
            metadata["expiresAtMs"] = "nil"
            metadata["expiresInSec"] = "nil"
            metadata["isExpired"] = "true"
        }

        return metadata
    }
}

/// A retired owner in an old cache entry fails to decode, so that entry is cleared.
public enum ClaudeOAuthCredentialOwner: String, Codable, Sendable {
    case claudeCLI
    case environment
}

extension ClaudeOAuthCredentialsStore {
    /// Identifies Claude Code's keychain item without reading its secret, to spot when Claude Code replaces it.
    struct ClaudeKeychainFingerprint: Codable, Equatable {
        let modifiedAt: Int?
        let createdAt: Int?
        let persistentRefHash: String?
    }
}

public enum ClaudeOAuthCredentialSource: String, Sendable {
    case environment
    case memoryCache
    case cacheKeychain
    case credentialsFile
    case claudeKeychain

    /// Names where credentials were read from, so a stale store (e.g. an old credentials file) is identifiable.
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

    /// Where an expiry is reported from; an environment token is always attributed to the environment.
    public var expirySource: ClaudeOAuthCredentialSource {
        self.owner == .environment ? .environment : self.source
    }

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

/// Why a keychain item exists but SturtBar cannot read it; typed so the tooltip explains the fix without string
/// parsing.
public enum ClaudeKeychainAccessRequiredReason: String, Sendable, Equatable {
    /// The item's access control no longer covers SturtBar (typical after a Claude Code re-login).
    case accessLost
    /// The stored prompt preference is never, so reads needing the OS dialog are disallowed.
    case promptsDisabled
}

public enum ClaudeOAuthCredentialsError: LocalizedError, Sendable {
    case decodeFailed
    case missingOAuth
    case missingAccessToken
    case notFound
    case keychainError(Int)
    case readFailed(String)
    /// The access token has expired; SturtBar never refreshes it, so it waits for its source to renew it.
    case tokenExpired(source: ClaudeOAuthCredentialSource)
    /// A keychain item exists that SturtBar could not read silently; the fix is granting Keychain access, not a
    /// re-login.
    case claudeKeychainAccessRequired(underlying: String?, reason: ClaudeKeychainAccessRequiredReason)

    public var errorDescription: String? {
        switch self {
        case .decodeFailed:
            return "Claude OAuth credentials are invalid."
        case .missingOAuth:
            return "Claude OAuth credentials missing. Run `claude /login` to sign in."
        case .missingAccessToken:
            return "Claude OAuth access token missing. Run `claude /login` to sign in."
        case .notFound:
            return "Claude OAuth credentials not found. Run `claude /login` to sign in."
        case let .keychainError(status):
            #if os(macOS)
            if status == Int(errSecUserCanceled)
                || status == Int(errSecAuthFailed)
                || status == Int(errSecInteractionNotAllowed)
                || status == Int(errSecNoAccessForItem)
            {
                return "Claude Keychain access was denied. Click the reconnect line in the SturtBar "
                    + "menu, then choose Always Allow. SturtBar backs off in the background until you do."
            }
            #endif
            return "Claude OAuth keychain error: \(status)"
        case let .readFailed(message):
            return "Claude OAuth credentials read failed: \(message)"
        case let .tokenExpired(source):
            if source == .environment {
                return "Claude OAuth environment token expired. Provide a fresh STURTBAR_CLAUDE_OAUTH_TOKEN."
            }
            return "Claude's sign-in token has expired. Claude Code renews it when it next runs."
        case let .claudeKeychainAccessRequired(underlying, reason):
            var text = switch reason {
            case .accessLost:
                "Claude Code's sign-in changed and SturtBar can't read the new token yet. "
                    + "Click the reconnect line, then choose Always Allow when macOS asks."
            case .promptsDisabled:
                "Keychain prompts are off, so SturtBar can't read Claude Code's sign-in yet. "
                    + "Click the reconnect line to allow access."
            }
            if let underlying, !underlying.isEmpty {
                text += " (\(underlying))"
            }
            return text
        }
    }
}
