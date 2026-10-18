import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

struct ClaudeUsageAccountSwitchTests {
    @Test
    func `usage response from a superseded account is replaced once`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        let tokens = Mutex<[String]>([])
        let service = ClaudeUsageService(environment: [:])
        let load: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
            CredentialSessionFixture.record("token-a").credentials
        }
        let fetch: @Sendable (String) async throws -> OAuthUsageResponse = { token in
            tokens.withLock { $0.append(token) }
            fixture.switchTo("b")
            return try JSONDecoder().decode(OAuthUsageResponse.self, from: Data("""
            {"five_hour":{"utilization":\(token == "token-a" ? 80 : 10)}}
            """.utf8))
        }
        let result = try await ClaudeUsageService.$credentialSessionOverride.withValue(session) {
            try await ClaudeUsageService.$loadOAuthCredentialsOverride.withValue(load) {
                try await ClaudeUsageService.$fetchOAuthUsageOverride.withValue(fetch) {
                    try await ClaudeCredentialEvents.$handler.withValue(fixture.observer) {
                        try await service.fetchUsage(interaction: .background)
                    }
                }
            }
        }
        #expect(result.primary.usedPercent == 10)
        #expect(tokens.withLock { $0 } == ["token-a", "token-b"])
        #expect(fixture.state.withLock { $0.events.contains(where: \.invalidatesUsage) })
    }

    @Test
    func `environment token does not inspect local account state`() async throws {
        let fixture = CredentialSessionFixture()
        let service = ClaudeUsageService(environment: [ClaudeOAuthCredentialsStore.environmentTokenKey: "explicit"])
        let fetch: @Sendable (String) async throws -> OAuthUsageResponse = { token in
            #expect(token == "explicit")
            return try JSONDecoder().decode(OAuthUsageResponse.self, from: Data("""
            {"five_hour":{"utilization":10}}
            """.utf8))
        }
        try await ClaudeUsageService.$credentialSessionOverride.withValue(fixture.session()) {
            try await ClaudeUsageService.$fetchOAuthUsageOverride.withValue(fetch) {
                _ = try await service.fetchUsage(interaction: .background)
            }
        }
        #expect(fixture.state.withLock { $0.observations } == 0)
    }

    @Test
    func `unauthorised recovery and account changes share one retry budget`() async throws {
        let fixture = CredentialSessionFixture()
        let calls = Mutex(0)
        let service = ClaudeUsageService(environment: [:])
        let load: @Sendable ([String: String], Bool, Bool) async throws -> ClaudeOAuthCredentials = { _, _, _ in
            CredentialSessionFixture.record("token-a").credentials
        }
        let fetch: @Sendable (String) async throws -> OAuthUsageResponse = { _ in
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { throw ClaudeOAuthFetchError.unauthorized }
            fixture.switchTo("b")
            return try JSONDecoder().decode(OAuthUsageResponse.self, from: Data("""
            {"five_hour":{"utilization":80}}
            """.utf8))
        }
        do {
            _ = try await ClaudeUsageService.$credentialSessionOverride.withValue(fixture.session()) {
                try await ClaudeUsageService.$loadOAuthCredentialsOverride.withValue(load) {
                    try await ClaudeUsageService.$fetchOAuthUsageOverride.withValue(fetch) {
                        try await service.fetchUsage(interaction: .background)
                    }
                }
            }
            Issue.record("Expected the obsolete result to be discarded")
        } catch ClaudeUsageError.credentials(.signInChanging) {}
        #expect(calls.withLock { $0 } == 2)
    }
}
