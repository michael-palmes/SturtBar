import Foundation
import Testing
@testable import SturtBarCore

// MARK: - HTTPClient configuration tests

@Suite("HTTPClient")
struct HTTPClientConfigurationTests {
    @Test("default configuration sets expected timeouts")
    func defaultConfigurationTimeouts() {
        let configuration = HTTPClient.defaultConfiguration()
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.timeoutIntervalForResource == 90)
        #expect(configuration.waitsForConnectivity == false)
    }
}

// MARK: - HTTPRetryPolicy.delaySeconds tests

@Suite("HTTPRetryPolicy.delaySeconds")
struct HTTPRetryPolicyDelayTests {
    private static let policy = HTTPRetryPolicy(
        maxRetries: 3,
        baseDelaySeconds: 1,
        maxDelaySeconds: 10)

    @Test("Retry-After header takes precedence over exponential backoff")
    func retryAfterHeaderOverridesBackoff() {
        let response = self.makeResponse(headers: ["Retry-After": "5"])
        let delay = Self.policy.delaySeconds(attempt: 0, response: response)
        #expect(delay == 5)
    }

    @Test("Retry-After header is clamped to maxDelaySeconds")
    func retryAfterHeaderClampsToMax() {
        let response = self.makeResponse(headers: ["Retry-After": "999"])
        let delay = Self.policy.delaySeconds(attempt: 0, response: response)
        #expect(delay == 10)
    }

    @Test("Retry-After header with whitespace is parsed")
    func retryAfterWithWhitespace() {
        let response = self.makeResponse(headers: ["Retry-After": "  3  "])
        let delay = Self.policy.delaySeconds(attempt: 0, response: response)
        #expect(delay == 3)
    }

    @Test("Retry-After with non-numeric date string falls back to exponential")
    func retryAfterNonNumericFallsBack() {
        // RFC 7231 date strings are not parsed — they fall back to exponential
        let response = self.makeResponse(headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"])
        let delay = Self.policy.delaySeconds(attempt: 0, response: response)
        #expect(delay == 1) // base * 2^0
    }

    @Test("no Retry-After gives exponential backoff starting at base")
    func exponentialBackoffAttemptZero() {
        let delay = Self.policy.delaySeconds(attempt: 0, response: nil)
        #expect(delay == 1) // base * 2^0
    }

    @Test("exponential backoff doubles each attempt")
    func exponentialBackoffDoubles() {
        let d0 = Self.policy.delaySeconds(attempt: 0, response: nil)
        let d1 = Self.policy.delaySeconds(attempt: 1, response: nil)
        let d2 = Self.policy.delaySeconds(attempt: 2, response: nil)
        #expect(d1 == d0 * 2)
        #expect(d2 == d0 * 4)
    }

    @Test("exponential backoff is capped at maxDelaySeconds")
    func exponentialBackoffCapped() {
        let delay = Self.policy.delaySeconds(attempt: 10, response: nil)
        #expect(delay == 10)
    }

    @Test("zero base delay returns 0 regardless of attempt")
    func zeroBaseDelayAlwaysZero() {
        let noDelay = HTTPRetryPolicy(
            maxRetries: 3,
            baseDelaySeconds: 0,
            maxDelaySeconds: 10)
        #expect(noDelay.delaySeconds(attempt: 0, response: nil) == 0)
        #expect(noDelay.delaySeconds(attempt: 5, response: nil) == 0)
    }

    // MARK: - Helper

    private func makeResponse(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: headers)!
    }
}

// MARK: - HTTPRetryPolicy.shouldRetry tests

@Suite("HTTPRetryPolicy.shouldRetry")
struct HTTPRetryPolicyShouldRetryTests {
    private static let policy = HTTPRetryPolicy.transientIdempotent

    @Test("retryable status on GET retries")
    func retryableStatusGETRetries() throws {
        let request = try URLRequest(url: #require(URL(string: "https://example.com")))
        #expect(Self.policy.shouldRetry(request: request, attempt: 0, statusCode: 503))
    }

    @Test("non-retryable status on GET does not retry")
    func nonRetryableStatusGETNoRetry() throws {
        let request = try URLRequest(url: #require(URL(string: "https://example.com")))
        #expect(Self.policy.shouldRetry(request: request, attempt: 0, statusCode: 403) == false)
    }

    @Test("retryable status on POST does not retry")
    func retryableStatusPOSTNoRetry() throws {
        var request = try URLRequest(url: #require(URL(string: "https://example.com")))
        request.httpMethod = "POST"
        #expect(Self.policy.shouldRetry(request: request, attempt: 0, statusCode: 503) == false)
    }

    @Test("retryable URL error on GET retries")
    func retryableURLErrorGETRetries() throws {
        let request = try URLRequest(url: #require(URL(string: "https://example.com")))
        #expect(Self.policy.shouldRetry(request: request, attempt: 0, error: URLError(.timedOut)))
    }

    @Test("non-retryable URL error on GET does not retry")
    func nonRetryableURLErrorNoRetry() throws {
        let request = try URLRequest(url: #require(URL(string: "https://example.com")))
        #expect(Self.policy
            .shouldRetry(request: request, attempt: 0, error: URLError(.userAuthenticationRequired)) == false)
    }

    @Test("attempt at maxRetries does not retry")
    func atMaxRetriesNoRetry() throws {
        let request = try URLRequest(url: #require(URL(string: "https://example.com")))
        // transientIdempotent has maxRetries=1; attempt 1 is already at the limit
        #expect(Self.policy.shouldRetry(request: request, attempt: 1, statusCode: 503) == false)
    }
}

// MARK: - Retry loop tests

@Suite("HTTPTransport retry loop", .serialized)
struct HTTPTransportRetryLoopTests {
    @Test("retries transient HTTP status once and returns success")
    func retriesTransientStatusOnce() async throws {
        let transport = ScriptedHTTPTransport(statusCodes: [503, 200])
        let request = try URLRequest(url: #require(URL(string: "https://example.com/retry")))

        let response = try await transport.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 200)
        #expect(await transport.requestCount() == 2)
    }

    @Test("retries transient URL error once and returns success")
    func retriesURLErrorOnce() async throws {
        let transport = ScriptedHTTPTransport(results: [
            .failure(URLError(.timedOut)),
            .success(200),
        ])
        let request = try URLRequest(url: #require(URL(string: "https://example.com/retry-error")))

        let response = try await transport.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 200)
        #expect(await transport.requestCount() == 2)
    }

    @Test("does not retry POST on transient status")
    func doesNotRetryPostOnTransientStatus() async throws {
        let transport = ScriptedHTTPTransport(statusCodes: [503, 200])
        var request = try URLRequest(url: #require(URL(string: "https://example.com/post")))
        request.httpMethod = "POST"

        let response = try await transport.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 503)
        #expect(await transport.requestCount() == 1)
    }

    @Test("does not retry auth failures")
    func doesNotRetryAuthFailures() async throws {
        let transport = ScriptedHTTPTransport(statusCodes: [403, 200])
        let request = try URLRequest(url: #require(URL(string: "https://example.com/forbidden")))

        let response = try await transport.response(for: request, retryPolicy: .testOneRetry)

        #expect(response.statusCode == 403)
        #expect(await transport.requestCount() == 1)
    }

    @Test("response helper unwraps HTTP response")
    func responseHelperUnwrapsHTTPResponse() async throws {
        let transport = HTTPTransportHandler { request in
            let resp = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-Test": "ok"])!
            return (Data("done".utf8), resp)
        }
        let request = try URLRequest(url: #require(URL(string: "https://example.com/ok")))
        let response = try await transport.response(for: request)
        #expect(response.statusCode == 204)
        #expect(response.response.value(forHTTPHeaderField: "X-Test") == "ok")
        #expect(String(data: response.data, encoding: .utf8) == "done")
    }

    @Test("response helper rejects non-HTTP responses")
    func responseHelperRejectsNonHTTP() async throws {
        let transport = HTTPTransportHandler { request in
            let resp = URLResponse(
                url: request.url ?? URL(string: "https://example.com/not-http")!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil)
            return (Data(), resp)
        }
        let request = try URLRequest(url: #require(URL(string: "https://example.com/not-http")))
        await #expect(throws: URLError.self) {
            _ = try await transport.response(for: request)
        }
    }
}

// MARK: - Helpers

extension HTTPRetryPolicy {
    fileprivate static let testOneRetry = HTTPRetryPolicy(
        maxRetries: 1,
        baseDelaySeconds: 0,
        maxDelaySeconds: 0)
}

private actor ScriptedHTTPTransport: HTTPTransport {
    enum ScriptResult {
        case success(Int)
        case failure(URLError)
    }

    private var results: [ScriptResult]
    private var requests: [URLRequest] = []

    init(statusCodes: [Int]) {
        self.results = statusCodes.map(ScriptResult.success)
    }

    init(results: [ScriptResult]) {
        self.results = results
    }

    func requestCount() -> Int {
        self.requests.count
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests.append(request)
        let next = self.results.isEmpty ? .success(200) : self.results.removeFirst()
        switch next {
        case let .success(statusCode):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (Data(#"{"ok":true}"#.utf8), response)
        case let .failure(error):
            throw error
        }
    }
}
