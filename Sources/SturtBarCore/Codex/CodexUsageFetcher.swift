// CodexUsageFetcher.swift — single-endpoint fetch of Codex usage from the ChatGPT backend.
//
// Deliberate omissions versus the Claude lane (decisions 1, 3, 8):
// - No token refresh: a 401 surfaces as `.unauthorized` and the UI says "sign in via the codex
//   CLI". SturtBar never calls auth.openai.com and never mutates ~/.codex/auth.json.
// - No persisted rate-limit gate: the store-level `FetchHealth.rateLimited(until:)` covers 429s;
//   a gap across relaunch is acceptable for this endpoint.
// - No custom User-Agent: URLSession's default applies (the Claude endpoint requires a pinned
//   client UA; this one does not get one on purpose).

import Foundation

// MARK: - Errors

/// All Codex-lane failures (credentials, fetch, parse) in one enum with typed predicates —
/// never string-matched (mirrors the `ClaudeUsageError` convention).
public enum CodexUsageError: LocalizedError, Sendable {
    /// No auth file / unusable auth file — the user has never signed in via the codex CLI.
    case credentialsMissing
    /// `auth.json` only carries a platform API key; there is no rate-limit usage to show.
    case apiKeyOnly
    /// The access token was rejected (expired/revoked). The codex CLI refreshes its own tokens
    /// whenever the user runs it; SturtBar never refreshes on its behalf.
    case unauthorized
    case rateLimited(retryAfter: Date)
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing:
            return "No Codex sign-in found. Run `codex` to connect."
        case .apiKeyOnly:
            return "API-key Codex accounts have no usage limits to show."
        case .unauthorized:
            return "Codex session expired. Sign in via the codex CLI."
        case .rateLimited:
            return "Codex usage endpoint is rate limited right now. It will recover on its own."
        case .invalidResponse:
            return "Codex usage response was invalid."
        case let .serverError(code, body):
            if let body, !body.isEmpty {
                let cleaned = body
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let shortened = cleaned.count > 400 ? String(cleaned.prefix(400)) + "…" : cleaned
                return "Codex usage error: HTTP \(code) – \(shortened)"
            }
            return "Codex usage error: HTTP \(code)"
        case let .networkError(error):
            return "Codex network error: \(error.localizedDescription)"
        case let .parseFailed(details):
            return "Could not parse Codex usage: \(details)"
        }
    }

    /// True when no usable Codex credentials exist and the user must run `codex` to log in.
    public var indicatesCredentialsMissing: Bool {
        if case .credentialsMissing = self { return true }
        return false
    }

    /// True when the stored token was rejected and the user must sign in again via the codex CLI.
    public var indicatesSignInRequired: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// True for API-key-only accounts (no ChatGPT subscription usage to display).
    public var indicatesUnsupportedAccount: Bool {
        if case .apiKeyOnly = self { return true }
        return false
    }
}

// MARK: - Response models

/// Wire shape of `GET /backend-api/wham/usage`. All fields optional — the endpoint is
/// unofficial, so decoding must never hard-fail on drift. `credits` and
/// `additional_rate_limits` are deliberately not decoded (decision 14: plan badge only).
struct CodexWhamUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow?
    let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double?
    /// Unix timestamp (seconds since epoch).
    let resetAt: Double?
    let limitWindowSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

// MARK: - Fetcher

enum CodexUsageFetcher {
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    static func fetchUsage(
        credentials: CodexCredentials,
        transport: any HTTPTransport = HTTPClient.shared) async throws -> CodexWhamUsageResponse
    {
        guard let url = URL(string: self.usageURL) else {
            throw CodexUsageError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let response = try await transport.response(for: request)
            switch response.statusCode {
            case 200:
                return try JSONDecoder().decode(CodexWhamUsageResponse.self, from: response.data)
            case 401, 403:
                throw CodexUsageError.unauthorized
            case 429:
                let now = Date()
                let retryAfter = self.retryAfterDate(from: response.response, now: now)
                throw CodexUsageError.rateLimited(retryAfter: retryAfter ?? now.addingTimeInterval(300))
            default:
                let body = String(data: response.data, encoding: .utf8)
                throw CodexUsageError.serverError(response.statusCode, body)
            }
        } catch let error as CodexUsageError {
            throw error
        } catch is DecodingError {
            // A 200 with an unparseable body is a server contract violation, not a network failure.
            throw CodexUsageError.invalidResponse
        } catch {
            throw CodexUsageError.networkError(error)
        }
    }

    /// Same parsing rules as the Claude fetcher's helper (seconds value or HTTP-date).
    static func retryAfterDate(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }
}
