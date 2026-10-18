import Foundation
import Synchronization
import Testing
@testable import SturtBarCore

final class CredentialSessionFixture: Sendable {
    struct State {
        var observation = ClaudeCredentialObservation(accountKey: "account-a", keychain: "item-a")
        var binding: ClaudeCredentialBinding?
        var token = "token-a"
        var readFailure = false
        var observations = 0
        var freshReads = 0
        var promptRequests = 0
        var fileReads: [Bool] = []
        var replacementDuringRead: ClaudeCredentialObservation?
        var readError: ClaudeOAuthCredentialsError?
        var events: [ClaudeCredentialContext] = []
        var now = Date()
        var storedAt = Date()
    }

    let state: Mutex<State>

    init(bound: Bool = true) {
        var state = State()
        if bound { state.binding = ClaudeCredentialBinding(observation: state.observation) }
        self.state = Mutex(state)
    }

    func session() -> ClaudeCredentialSession {
        var operations = ClaudeCredentialSession.Operations()
        operations.observe = { _ in
            self.state.withLock { state in
                state.observations += 1
                return state.observation
            }
        }
        operations
            .cache = { self.state.withLock { ClaudeCachedCredential(binding: $0.binding, storedAt: $0.storedAt) } }
        operations.bind = { binding in self.state.withLock { $0.binding = binding } }
        operations.commit = { _, binding in self.state.withLock { $0.binding = binding } }
        operations.now = { self.state.withLock { $0.now } }
        operations.fresh = { includeFile, prompt in
            try self.state.withLock { state in
                state.freshReads += 1
                state.fileReads.append(includeFile)
                if prompt { state.promptRequests += 1 }
                if let error = state.readError { throw error }
                if state.readFailure {
                    throw ClaudeOAuthCredentialsError.claudeKeychainAccessRequired(
                        underlying: nil, reason: .promptsDisabled)
                }
                let record = Self.record(state.token, source: .claudeKeychain)
                if let replacement = state.replacementDuringRead {
                    state.observation = replacement
                    state.replacementDuringRead = nil
                }
                return record
            }
        }
        return ClaudeCredentialSession(
            operations: operations,
            metadata: ClaudeAccountMetadata(url: URL(fileURLWithPath: "/tmp/sturtbar-no-account-\(UUID())")))
    }

    static func record(
        _ token: String,
        source: ClaudeOAuthCredentialSource = .memoryCache) -> ClaudeOAuthCredentialRecord
    {
        ClaudeOAuthCredentialRecord(
            credentials: ClaudeOAuthCredentials(
                accessToken: token,
                refreshToken: nil,
                expiresAt: Date(timeIntervalSinceNow: 3600),
                scopes: ["user:profile"],
                rateLimitTier: nil),
            owner: .claudeCLI,
            source: source)
    }

    func load(_ session: ClaudeCredentialSession, force: Bool = true) async throws -> ClaudeOAuthCredentialRecord {
        try await session.load(force: force, allowPrompt: false, observer: self.observer) {
            Self.record("cached-token")
        }
    }

    var observer: ClaudeCredentialEvents.Handler {
        { context in self.state.withLock { $0.events.append(context) } }
    }

    func switchTo(_ account: String) {
        self.state.withLock {
            $0.observation.accountKey = "account-\(account)"
            $0.observation.keychain = "item-\(account)"
            $0.token = "token-\(account)"
        }
    }
}

struct ClaudeCredentialSessionTests {
    @Test
    func `follows both directions while the old tokens are valid and prompts are off`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        _ = try await fixture.load(session)
        fixture.switchTo("b")
        #expect(try await fixture.load(session).credentials.accessToken == "token-b")
        fixture.switchTo("a")
        #expect(try await fixture.load(session).credentials.accessToken == "token-a")
        let events = fixture.state.withLock { $0.events.filter(\.invalidatesUsage) }
        #expect(events.map(\.accountKey) == ["account-b", "account-a"])
        #expect(fixture.state.withLock { $0.promptRequests } == 0)
    }

    @Test
    func `unchanged account keeps the fast cached path and automatic checks are throttled`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        for _ in 0..<5 {
            _ = try await fixture.load(session, force: false)
        }
        #expect(fixture.state.withLock { $0.observations } == 1)
        #expect(fixture.state.withLock { $0.freshReads } == 0)
        _ = try await fixture.load(session)
        #expect(fixture.state.withLock { $0.observations } == 2)
    }

    @Test
    func `same account renewal preserves usage and its quota baseline`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        _ = try await fixture.load(session)
        fixture.state.withLock {
            $0.observation.keychain = "renewed-item"
            $0.token = "renewed-token"
        }
        #expect(try await fixture.load(session).credentials.accessToken == "renewed-token")
        #expect(fixture.state.withLock { $0.events.allSatisfy { !$0.invalidatesUsage } })
    }

    @Test
    func `unreadable same account renewal retains the valid cached token`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        _ = try await fixture.load(session)
        fixture.state.withLock {
            $0.observation.keychain = "renewed-item"
            $0.readFailure = true
        }
        #expect(try await fixture.load(session).credentials.accessToken == "cached-token")
        #expect(fixture.state.withLock { $0.events.allSatisfy { !$0.invalidatesUsage } })
    }

    @Test
    func `unreadable account change invalidates before failing and stays invalid across relaunch`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.switchTo("b")
        fixture.state.withLock { $0.readFailure = true }
        for _ in 0..<2 {
            await #expect(throws: ClaudeOAuthCredentialsError.self) {
                try await fixture.load(fixture.session())
            }
            #expect(fixture.state.withLock { $0.events.last?.invalidatesUsage } == true)
            #expect(fixture.state.withLock { $0.binding?.invalidated } == true)
        }
        fixture.state.withLock { $0.readFailure = false }
        #expect(try await fixture.load(fixture.session()).credentials.accessToken == "token-b")
        #expect(fixture.state.withLock { $0.binding?.invalidated } == false)
    }

    @Test
    func `unavailable probes are not sign out or account changes`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.state.withLock {
            $0.observation.accountKey = nil
            $0.observation.keychain = nil
            $0.observation.keychainAvailable = false
            $0.observation.fileAvailable = false
        }
        #expect(try await fixture.load(fixture.session()).credentials.accessToken == "cached-token")
        #expect(fixture.state.withLock { $0.freshReads } == 0)
        #expect(fixture.state.withLock { $0.events.allSatisfy { !$0.invalidatesUsage } })
    }

    @Test
    func `confirmed removal invalidates even when the cached token is valid`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.state.withLock { $0.observation.keychain = nil }
        do {
            _ = try await fixture.load(fixture.session())
            Issue.record("Expected missing credentials")
        } catch ClaudeOAuthCredentialsError.notFound {}
        #expect(fixture.state.withLock { $0.freshReads } == 0)
        #expect(fixture.state.withLock { $0.events.last?.invalidatesUsage } == true)
    }

    @Test
    func `legacy cache is not assigned an account when source verification fails`() async throws {
        let fixture = CredentialSessionFixture(bound: false)
        fixture.state.withLock { $0.readFailure = true }
        #expect(try await fixture.load(fixture.session()).credentials.accessToken == "cached-token")
        #expect(fixture.state.withLock { $0.binding } == nil)
        #expect(fixture.state.withLock { $0.events.last?.accountKey } == nil)
    }

    @Test
    func `legacy cache older than the source cannot hide a switch`() async throws {
        let fixture = CredentialSessionFixture(bound: false)
        fixture.state.withLock { $0.observation.newestModification = $0.storedAt.addingTimeInterval(10) }
        _ = try await fixture.load(fixture.session())
        #expect(fixture.state.withLock { $0.events.first?.invalidatesUsage } == true)
        #expect(fixture.state.withLock { $0.binding?.observation.accountKey } == "account-a")
    }

    @Test
    func `a response from an account replaced during the request is rejected`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        _ = try await fixture.load(session)
        fixture.switchTo("b")
        #expect(await session.validateResponse(observer: fixture.observer) == false)
        #expect(fixture.state.withLock { $0.events.last?.invalidatesUsage } == true)
    }

    @Test
    func `unchanged credentials file stays excluded through failed reads and relaunch`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.state.withLock {
            $0.observation.file = "old-file"
            $0.binding = ClaudeCredentialBinding(observation: $0.observation)
        }
        fixture.switchTo("b")
        fixture.state.withLock { $0.readFailure = true }
        await #expect(throws: ClaudeOAuthCredentialsError.self) { try await fixture.load(fixture.session()) }
        fixture.state.withLock { $0.readFailure = false }
        _ = try await fixture.load(fixture.session())
        #expect(fixture.state.withLock { $0.fileReads } == [false, false])
    }

    @Test
    func `legacy cache excludes a credentials file older than its saved copy`() async throws {
        let fixture = CredentialSessionFixture(bound: false)
        fixture.state.withLock {
            $0.observation.file = "old-file"
            $0.observation.fileModification = $0.storedAt.addingTimeInterval(-10)
            $0.observation.newestModification = $0.storedAt.addingTimeInterval(10)
        }
        _ = try await fixture.load(fixture.session())
        #expect(fixture.state.withLock { $0.fileReads } == [false])
    }

    @Test
    func `switch during a source read cannot bind the token to the wrong account`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.switchTo("b")
        fixture.state.withLock {
            $0.replacementDuringRead = ClaudeCredentialObservation(accountKey: "account-c", keychain: "item-c")
        }
        do {
            _ = try await fixture.load(fixture.session())
            Issue.record("Expected a changing sign-in")
        } catch ClaudeOAuthCredentialsError.signInChanging {}
        #expect(fixture.state.withLock { $0.binding?.invalidated } == true)
        #expect(fixture.state.withLock { $0.events.filter(\.invalidatesUsage).map(\.accountKey) }
            == ["account-b", "account-c"])
    }

    @Test
    func `source replacement without account metadata clears the old baseline`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.state.withLock {
            $0.observation.accountKey = nil
            $0.observation.keychain = "replacement"
        }
        _ = try await fixture.load(fixture.session())
        #expect(fixture.state.withLock { $0.events.first?.invalidatesUsage } == true)
        #expect(fixture.state.withLock { $0.events.first?.accountKey } == nil)
    }

    @Test
    func `renewal during a source read retries without clearing the same account`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.state.withLock {
            $0.observation.keychain = "renewal-1"
            $0.replacementDuringRead = ClaudeCredentialObservation(accountKey: "account-a", keychain: "renewal-2")
        }
        let session = fixture.session()
        do {
            _ = try await fixture.load(session, force: false)
            Issue.record("Expected the changing token to be retried")
        } catch ClaudeOAuthCredentialsError.signInChanging {}
        fixture.state.withLock { $0.token = "renewed-token" }
        let record = try await fixture.load(session, force: false)
        #expect(record.credentials.accessToken == "renewed-token")
        #expect(fixture.state.withLock { $0.freshReads } == 2)
        #expect(fixture.state.withLock { $0.events.allSatisfy { !$0.invalidatesUsage } })
        #expect(fixture.state.withLock { $0.binding?.observation.keychain } == "renewal-2")
    }

    @Test
    func `partial credentials after a switch do not report sign out`() async throws {
        let fixture = CredentialSessionFixture()
        fixture.switchTo("b")
        fixture.state.withLock { $0.readError = .decodeFailed }
        do {
            _ = try await fixture.load(fixture.session())
            Issue.record("Expected a changing sign-in")
        } catch ClaudeOAuthCredentialsError.signInChanging {}
        #expect(fixture.state.withLock { $0.binding?.invalidated } == true)
    }

    @Test
    func `a superseded generation stays obsolete after switching back`() async throws {
        let fixture = CredentialSessionFixture()
        let session = fixture.session()
        _ = try await fixture.load(session)
        let original = await session.currentGeneration()
        fixture.switchTo("b")
        _ = try await fixture.load(session)
        fixture.switchTo("a")
        _ = try await fixture.load(session)
        #expect(await session.validateResponse(generation: original, observer: fixture.observer) == false)
    }
}
