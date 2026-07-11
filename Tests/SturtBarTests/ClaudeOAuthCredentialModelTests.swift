import Foundation
import Testing
@testable import SturtBarCore

/// Tests for ClaudeOAuthCredentials (parse/error cases).
/// Ported from CodexBarTests/ClaudeOAuthTests.swift — store-dependent cases deferred to step 2.
/// The ClaudeOAuthUsageRateLimitGate case moved to ClaudeOAuthUsageFetcherTests (serialized suite)
/// alongside the other tests touching the gate's persisted UserDefaults state.
struct ClaudeOAuthCredentialModelTests {
    @Test
    func `parses OAuth credentials`() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "test-token",
            "refreshToken": "test-refresh",
            "expiresAt": 4102444800000,
            "scopes": ["usage:read"],
            "rateLimitTier": "default_claude_max_20x",
            "subscriptionType": "pro"
          }
        }
        """
        let creds = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "test-token")
        #expect(creds.refreshToken == "test-refresh")
        #expect(creds.scopes == ["usage:read"])
        #expect(creds.rateLimitTier == "default_claude_max_20x")
        #expect(creds.subscriptionType == "pro")
        #expect(creds.isExpired == false)
    }

    @Test
    func `missing access token throws`() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "",
            "refreshToken": "test-refresh",
            "expiresAt": 1735689600000
          }
        }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func `missing OAuth block throws`() {
        let json = """
        { "other": { "accessToken": "nope" } }
        """
        #expect(throws: ClaudeOAuthCredentialsError.self) {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        }
    }

    @Test
    func `mcp oauth only keychain payload maps to missing credentials`() {
        // Claude Code 2.1.x can leave only MCP server OAuth state after the login lapses.
        let json = """
        { "mcpOAuth": { "plugin:synthetic": { "accessToken": "synthetic-mcp-token" } } }
        """
        #expect {
            _ = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        } throws: { error in
            guard case ClaudeOAuthCredentialsError.missingOAuth = error else { return false }
            return ClaudeUsageError.credentials(.missingOAuth).indicatesCredentialsMissing
        }
    }

    @Test
    func `treats missing expiry as expired`() {
        let creds = ClaudeOAuthCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            scopes: [],
            rateLimitTier: nil)
        #expect(creds.isExpired == true)
    }

    @Test
    func `no refresh token description names the credential source`() {
        let fromFile = ClaudeOAuthCredentialsError.noRefreshToken(source: .credentialsFile)
        #expect(fromFile.errorDescription
            == "Claude OAuth refresh token missing (from ~/.claude/.credentials.json). "
            + "Run `claude /login` to sign in again.")

        let fromCache = ClaudeOAuthCredentialsError.noRefreshToken(source: .cacheKeychain)
        #expect(fromCache.errorDescription
            == "Claude OAuth refresh token missing (from SturtBar's cached copy). "
            + "Run `claude /login` to sign in again.")

        // Environment tokens cannot be refreshed via `claude`; the remedy is a fresh token.
        let fromEnvironment = ClaudeOAuthCredentialsError.noRefreshToken(source: .environment)
        #expect(fromEnvironment.errorDescription?.contains("STURTBAR_CLAUDE_OAUTH_TOKEN") == true)
        #expect(fromEnvironment.errorDescription?.contains("Run `claude") == false)

        // Unknown source keeps the generic wording.
        let unknown = ClaudeOAuthCredentialsError.noRefreshToken(source: nil)
        #expect(unknown.errorDescription
            == "Claude OAuth refresh token missing. Run `claude /login` to sign in again.")
    }

    @Test
    func `keychain access required description names the right fix per reason`() {
        let lost = ClaudeOAuthCredentialsError.claudeKeychainAccessRequired(
            underlying: nil,
            reason: .accessLost)
        #expect(lost.errorDescription
            == "Claude Code's sign-in changed and SturtBar can't read the new token yet. "
            + "Click the reconnect line, then choose Always Allow when macOS asks.")

        let promptsOff = ClaudeOAuthCredentialsError.claudeKeychainAccessRequired(
            underlying: "probe detail",
            reason: .promptsDisabled)
        #expect(promptsOff.errorDescription
            == "Keychain prompts are off, so SturtBar can't read Claude Code's sign-in yet. "
            + "Click the reconnect line to allow access. (probe detail)")
    }
}
