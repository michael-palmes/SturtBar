// CodexUsageFetcherTests.swift — transport-level tests for the Codex wham/usage fetcher.
//
// Unlike the Claude fetcher there is no persisted rate-limit gate and no token refresh: a 401 is
// terminal-quiet ("sign in via the codex CLI") and 429 handling is store-level only.

import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

struct CodexUsageFetcherTests {
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

    private static let usageJSON = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "primary_window": {
          "used_percent": 12.5,
          "reset_at": 1766948068,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 43,
          "reset_at": 1767407914,
          "limit_window_seconds": 604800
        }
      },
      "credits": { "has_credits": true, "unlimited": false, "balance": 5.5 },
      "additional_rate_limits": [
        { "limit_name": "Spark", "rate_limit": { "primary_window": { "used_percent": 1 } } }
      ]
    }
    """

    // MARK: - Request shape

    @Test
    func `sends bearer and account id headers to the wham usage endpoint`() async throws {
        let requestBox = RequestBox()
        let transport = self.makeTransport(
            statusCode: 200, body: Self.usageJSON, requestBox: requestBox)

        let credentials = CodexCredentials(accessToken: "token-123", accountId: "acct-1")
        _ = try await CodexUsageFetcher.fetchUsage(credentials: credentials, transport: transport)

        let request = try #require(requestBox.requests.first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        // Decision 8: no custom User-Agent — URLSession's default applies at session level.
        #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
    }

    @Test
    func `omits account id header when credentials have none`() async throws {
        let requestBox = RequestBox()
        let transport = self.makeTransport(
            statusCode: 200, body: Self.usageJSON, requestBox: requestBox)

        let credentials = CodexCredentials(accessToken: "token-123", accountId: nil)
        _ = try await CodexUsageFetcher.fetchUsage(credentials: credentials, transport: transport)

        let request = try #require(requestBox.requests.first)
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
    }

    // MARK: - Decoding

    @Test
    func `decodes plan type and both rate limit windows`() async throws {
        let transport = self.makeTransport(statusCode: 200, body: Self.usageJSON)

        let response = try await CodexUsageFetcher.fetchUsage(
            credentials: CodexCredentials(accessToken: "t", accountId: nil),
            transport: transport)

        #expect(response.planType == "pro")
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 12.5)
        #expect(response.rateLimit?.primaryWindow?.resetAt == 1_766_948_068)
        #expect(response.rateLimit?.primaryWindow?.limitWindowSeconds == 18000)
        #expect(response.rateLimit?.secondaryWindow?.usedPercent == 43)
        #expect(response.rateLimit?.secondaryWindow?.limitWindowSeconds == 604_800)
    }

    @Test
    func `tolerates missing windows and unknown fields`() async throws {
        let transport = self.makeTransport(statusCode: 200, body: """
        { "plan_type": "plus", "rate_limit": { "primary_window": { "used_percent": 7 } }, "future_field": 1 }
        """)

        let response = try await CodexUsageFetcher.fetchUsage(
            credentials: CodexCredentials(accessToken: "t", accountId: nil),
            transport: transport)

        #expect(response.planType == "plus")
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 7)
        #expect(response.rateLimit?.secondaryWindow == nil)
    }

    // MARK: - Status mapping

    @Test
    func `401 maps to unauthorized`() async throws {
        let transport = self.makeTransport(statusCode: 401)

        await #expect(throws: CodexUsageError.self) {
            try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
        }
        do {
            _ = try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
        } catch let error as CodexUsageError {
            #expect(error.indicatesSignInRequired)
            #expect(!error.indicatesCredentialsMissing)
        }
    }

    @Test
    func `429 with Retry-After seconds maps to rateLimited`() async throws {
        let now = Date()
        let transport = self.makeTransport(statusCode: 429, headers: ["Retry-After": "120"])

        do {
            _ = try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
            Issue.record("expected rateLimited")
        } catch let CodexUsageError.rateLimited(retryAfter) {
            #expect(abs(retryAfter.timeIntervalSince(now) - 120) < 5)
        }
    }

    @Test
    func `429 without Retry-After falls back to five minutes`() async throws {
        let now = Date()
        let transport = self.makeTransport(statusCode: 429)

        do {
            _ = try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
            Issue.record("expected rateLimited")
        } catch let CodexUsageError.rateLimited(retryAfter) {
            #expect(abs(retryAfter.timeIntervalSince(now) - 300) < 5)
        }
    }

    @Test
    func `server errors carry status code and body`() async throws {
        let transport = self.makeTransport(statusCode: 503, body: "upstream sad")

        do {
            _ = try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
            Issue.record("expected serverError")
        } catch let CodexUsageError.serverError(code, body) {
            #expect(code == 503)
            #expect(body == "upstream sad")
        }
    }

    @Test
    func `200 with unparseable body maps to invalidResponse`() async throws {
        let transport = self.makeTransport(statusCode: 200, body: "[not, the, shape]")

        do {
            _ = try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
            Issue.record("expected invalidResponse")
        } catch let error as CodexUsageError {
            guard case .invalidResponse = error else {
                Issue.record("expected invalidResponse, got \(error)")
                return
            }
        }
    }

    @Test
    func `transport failures map to networkError`() async throws {
        let transport = HTTPTransportHandler { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await CodexUsageFetcher.fetchUsage(
                credentials: CodexCredentials(accessToken: "t", accountId: nil),
                transport: transport)
            Issue.record("expected networkError")
        } catch let error as CodexUsageError {
            guard case .networkError = error else {
                Issue.record("expected networkError, got \(error)")
                return
            }
        }
    }
}
