import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

/// Transport-level tests for ClaudeOAuthUsageFetcher plus ClaudeOAuthUsageRateLimitGate behavior.
/// Ported from CodexBarTests/ClaudeOAuthTests.swift (OAuth usage fetcher cases).
/// Serialized: ClaudeOAuthUsageRateLimitGate persists its block window in UserDefaults.standard.
@Suite(.serialized)
struct ClaudeOAuthUsageFetcherTests {
    private final class RequestBox: @unchecked Sendable {
        private let mutex = Mutex<[URLRequest]>([])

        func append(_ request: URLRequest) {
            self.mutex.withLock { $0.append(request) }
        }

        var requests: [URLRequest] {
            self.mutex.withLock { $0 }
        }
    }

    private func makeTransport(
        statusCode: Int,
        body: String = "{}",
        headers: [String: String] = [:],
        requestBox: RequestBox? = nil) -> HTTPTransportHandler
    {
        HTTPTransportHandler { request in
            requestBox?.append(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers)
            else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
    }

    @Test
    func `fetch usage sends oauth headers and decodes payload`() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2025-12-25T12:00:00.000Z" },
          "seven_day": { "utilization": 30 },
          "seven_day_cowork": { "utilization": 9, "resets_at": "2026-01-01T00:00:00.000Z" },
          "extra_usage": { "is_enabled": true, "monthly_limit": 2050, "used_credits": 325 }
        }
        """
        let requestBox = RequestBox()
        let transport = self.makeTransport(statusCode: 200, body: json, requestBox: requestBox)

        let usage = try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token-123", transport: transport)

        #expect(usage.fiveHour?.utilization == 12.5)
        #expect(usage.fiveHour?.resetsAt == "2025-12-25T12:00:00.000Z")
        #expect(usage.sevenDay?.utilization == 30)
        #expect(usage.sevenDayRoutines?.utilization == 9)
        #expect(usage.sevenDayRoutinesSourceKey == "seven_day_cowork")
        #expect(usage.extraUsage?.isEnabled == true)
        #expect(usage.extraUsage?.monthlyLimit == 2050)
        #expect(usage.extraUsage?.usedCredits == 325)

        let request = try #require(requestBox.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // The CLI-spawning version detector was removed; the pinned fallback version is always sent.
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
    }

    @Test
    func `fetch usage maps 401 to typed unauthorized error`() async {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let transport = self.makeTransport(statusCode: 401)
        do {
            _ = try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "stale", transport: transport)
            Issue.record("Expected ClaudeOAuthFetchError.unauthorized")
        } catch let error as ClaudeOAuthFetchError {
            guard case .unauthorized = error else {
                Issue.record("Expected .unauthorized, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ClaudeOAuthFetchError, got \(error)")
        }
    }

    @Test
    func `fetch usage 429 records gate and blocks background retries without hitting transport`() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let requestBox = RequestBox()
        let transport = self.makeTransport(
            statusCode: 429,
            body: #"{"type":"rate_limit_error"}"#,
            headers: ["Retry-After": "120"],
            requestBox: requestBox)

        do {
            _ = try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token", transport: transport)
            Issue.record("Expected ClaudeOAuthFetchError.rateLimited")
        } catch let error as ClaudeOAuthFetchError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
        }
        #expect(requestBox.requests.count == 1)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil() != nil)

        // Background retries are short-circuited by the persisted gate before any request is made.
        do {
            _ = try await InteractionContext.$current.withValue(.background) {
                try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token", transport: transport)
            }
            Issue.record("Expected ClaudeOAuthFetchError.rateLimited from gate")
        } catch let error as ClaudeOAuthFetchError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
        }
        #expect(requestBox.requests.count == 1)

        // User-initiated fetches bypass the cooldown gate and reach the endpoint again.
        do {
            _ = try await InteractionContext.$current.withValue(.userInitiated) {
                try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token", transport: transport)
            }
            Issue.record("Expected ClaudeOAuthFetchError.rateLimited from endpoint")
        } catch let error as ClaudeOAuthFetchError {
            guard case .rateLimited = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
        }
        #expect(requestBox.requests.count == 2)
    }

    @Test
    func `fetch usage success clears recorded rate limit`() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        ClaudeOAuthUsageRateLimitGate.recordRateLimit(retryAfter: Date().addingTimeInterval(300))
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil() != nil)

        let json = #"{"five_hour": { "utilization": 1 }}"#
        let transport = self.makeTransport(statusCode: 200, body: json)
        _ = try await InteractionContext.$current.withValue(.userInitiated) {
            try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token", transport: transport)
        }

        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil() == nil)
    }

    /// Moved from ClaudeOAuthCredentialModelTests so every test touching the gate's persisted
    /// UserDefaults state lives in this serialized suite.
    @Test
    func `OAuth usage rate limit gate blocks background retries until cooldown`() {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let retryAfter = now.addingTimeInterval(120)

        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(now: now) == nil)
        ClaudeOAuthUsageRateLimitGate.recordRateLimit(retryAfter: retryAfter, now: now)

        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(now: now) == retryAfter)
        #expect(ClaudeOAuthUsageRateLimitGate.blockedUntil(interaction: .background, now: now) == retryAfter)
        #expect(ClaudeOAuthUsageRateLimitGate.blockedUntil(interaction: .userInitiated, now: now) == nil)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(now: now.addingTimeInterval(119)) != nil)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(now: now.addingTimeInterval(121)) == nil)
    }

    @Test
    func `includes body in OAuth 403 error`() {
        let err = ClaudeOAuthFetchError.serverError(
            403,
            "HTTP 403: OAuth token does not meet scope requirement user:profile")
        #expect(err.localizedDescription.contains("user:profile"))
        #expect(err.localizedDescription.contains("HTTP 403"))
    }

    @Test
    func `OAuth 429 error gives actionable guidance without raw body`() {
        let err = ClaudeOAuthFetchError.rateLimited(retryAfter: Date().addingTimeInterval(300))
        #expect(err.localizedDescription.contains("rate limited"))
        #expect(err.localizedDescription.contains("claude logout && claude login"))
        #expect(!err.localizedDescription.contains("rate_limit_error"))
    }

    @Test
    func `OAuth retry after parses seconds`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "42"]))

        #expect(
            ClaudeOAuthUsageFetcher._retryAfterDateForTesting(from: response, now: now)
                == now.addingTimeInterval(42))
    }

    @Test
    func `OAuth retry after parses HTTP date`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]))

        #expect(
            ClaudeOAuthUsageFetcher._retryAfterDateForTesting(from: response, now: now)
                == Date(timeIntervalSince1970: 1_445_412_480))
    }

    @Test
    func `200 with garbage JSON throws invalidResponse not networkError`() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let transport = self.makeTransport(statusCode: 200, body: "not valid json {{{{")
        do {
            _ = try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token", transport: transport)
            Issue.record("Expected ClaudeOAuthFetchError.invalidResponse")
        } catch let error as ClaudeOAuthFetchError {
            guard case .invalidResponse = error else {
                Issue.record("Expected .invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ClaudeOAuthFetchError, got \(error)")
        }
    }

    @Test
    func `user agent always sends pinned claude code version`() async throws {
        ClaudeOAuthUsageRateLimitGate.resetForTesting()
        defer { ClaudeOAuthUsageRateLimitGate.resetForTesting() }

        let json = #"{"five_hour": { "utilization": 1 }}"#
        let requestBox = RequestBox()
        let transport = self.makeTransport(statusCode: 200, body: json, requestBox: requestBox)
        _ = try await ClaudeOAuthUsageFetcher.fetchUsage(accessToken: "token", transport: transport)

        let request = try #require(requestBox.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
    }
}
