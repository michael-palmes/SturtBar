import Foundation
import Testing
@testable import SturtBarCore

// MARK: - LogRedactor tests

@Suite("LogRedactor", .serialized)
struct LogRedactorTests {
    // MARK: - Email

    @Test("email address is redacted")
    func emailIsRedacted() {
        let input = "Contact: user@example.com"
        let output = LogRedactor.redact(input)
        #expect(output.contains("user@example.com") == false)
        #expect(output.contains("<redacted-email>"))
    }

    @Test("email in longer string leaves surrounding text intact")
    func emailLeavesContext() {
        let input = "Sending to user@example.com for billing"
        let output = LogRedactor.redact(input)
        #expect(output.contains("user@example.com") == false)
        #expect(output.hasPrefix("Sending to"))
        #expect(output.hasSuffix("for billing"))
    }

    // MARK: - Bearer header

    @Test("Bearer token in Authorization header is redacted")
    func bearerInAuthorizationHeader() {
        let input = "Authorization: Bearer fake-bearer-token"
        let output = LogRedactor.redact(input)
        #expect(output.contains("fake-bearer-token") == false)
        #expect(output.contains("Authorization:"))
    }

    @Test("lowercase bearer token is redacted")
    func lowercaseBearerToken() {
        let input = "authorization: bearer eyJhbGciOiJSUzI1NiJ9.payload.sig"
        let output = LogRedactor.redact(input)
        #expect(output.contains("eyJhbGciOiJSUzI1NiJ9") == false)
    }

    // MARK: - Cookie header

    @Test("Cookie header value is redacted")
    func cookieHeaderIsRedacted() {
        let input = "Cookie: session=abc123; token=xyz789"
        let output = LogRedactor.redact(input)
        #expect(output.contains("abc123") == false)
        #expect(output.contains("xyz789") == false)
        #expect(output.contains("Cookie: <redacted>"))
    }

    @Test("Authorization header value is redacted")
    func authorizationHeaderIsRedacted() {
        let input = "Authorization: CustomScheme some-opaque-credential"
        let output = LogRedactor.redact(input)
        #expect(output.contains("some-opaque-credential") == false)
        #expect(output.contains("Authorization: <redacted>"))
    }

    // MARK: - Anthropic tokens (sk-ant-oat01 / sk-ant-ort01)

    @Test("bare sk-ant-oat01 access token is redacted")
    func skAntOat01BareIsRedacted() {
        let token = self.buildToken(prefix: "sk-ant-oat01")
        let input = token
        let output = LogRedactor.redact(input)
        #expect(output.contains("sk-ant-oat01") == false)
        #expect(output.contains("placeholder") == false)
        #expect(output.contains("sk-ant-***"))
    }

    @Test("bare sk-ant-ort01 refresh token is redacted")
    func skAntOrt01BareIsRedacted() {
        let token = self.buildToken(prefix: "sk-ant-ort01")
        let input = token
        let output = LogRedactor.redact(input)
        #expect(output.contains("sk-ant-ort01") == false)
        #expect(output.contains("sk-ant-***"))
    }

    @Test("sk-ant token in a longer log string is redacted")
    func skAntTokenInLongerString() {
        let token = self.buildToken(prefix: "sk-ant-oat01")
        let input = "Refreshing credentials token=\(token) for account"
        let output = LogRedactor.redact(input)
        #expect(output.contains("sk-ant-oat01") == false)
        #expect(output.contains("placeholder") == false)
        #expect(output.hasPrefix("Refreshing credentials token="))
        #expect(output.hasSuffix("for account"))
    }

    @Test("sk-ant token inside double-quoted JSON value is redacted")
    func skAntTokenInJsonQuotes() {
        let token = self.buildToken(prefix: "sk-ant-oat01")
        let input = #"{"access_token":"\#(token)"}"#
        let output = LogRedactor.redact(input)
        #expect(output.contains("sk-ant-oat01") == false)
        #expect(output.contains("placeholder") == false)
        #expect(output.contains("sk-ant-***"))
    }

    @Test("sk-ant token inside single-quoted attribute is redacted")
    func skAntTokenInSingleQuotes() {
        let token = self.buildToken(prefix: "sk-ant-ort01")
        let input = "token='\(token)'"
        let output = LogRedactor.redact(input)
        #expect(output.contains("sk-ant-ort01") == false)
        #expect(output.contains("sk-ant-***"))
    }

    @Test("sk-ant token in Authorization: Bearer is fully redacted")
    func skAntTokenInBearerHeader() {
        let token = self.buildToken(prefix: "sk-ant-oat01")
        let input = "Authorization: Bearer \(token)"
        let output = LogRedactor.redact(input)
        #expect(output.contains("sk-ant-oat01") == false)
        #expect(output.contains("placeholder") == false)
        // Either the sk-ant rule or the bearer rule (or both) must have fired
        #expect(output.contains("Authorization: <redacted>") || output.contains("Bearer <redacted>"))
    }

    // MARK: - Helpers

    /// Build a plausible-looking token without embedding a real secret in source.
    private func buildToken(prefix: String) -> String {
        [prefix, "placeholder-test-value-00001AA"].joined(separator: "-")
    }
}
