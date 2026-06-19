// CodexCredentialsTests.swift — read-only parsing of the Codex CLI auth file.
//
// All tests operate on temp directories via the CODEX_HOME override; nothing ever touches the
// real ~/.codex (privacy contract: SturtBar must not read it outside an enabled provider fetch).

import Foundation
import Testing
@testable import SturtBarCore

struct CodexCredentialsTests {
    /// Creates a temp CODEX_HOME directory, optionally writing `auth.json` with the given content.
    private func makeCodexHome(authJSON: String? = nil) throws -> (environment: [String: String], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-codex-credentials-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let authJSON {
            try Data(authJSON.utf8).write(to: directory.appendingPathComponent("auth.json"))
        }
        return (["CODEX_HOME": directory.path], directory)
    }

    @Test
    func `loads ChatGPT tokens with account id`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        {
          "OPENAI_API_KEY": null,
          "tokens": {
            "access_token": "token-123",
            "refresh_token": "refresh-456",
            "id_token": "jwt-789",
            "account_id": "acct-1"
          },
          "last_refresh": "2026-06-01T00:00:00Z"
        }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentials = try CodexCredentialsReader.load(environment: environment)
        #expect(credentials.accessToken == "token-123")
        #expect(credentials.accountId == "acct-1")
    }

    @Test
    func `loads tokens without account id`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "tokens": { "access_token": "token-123" } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentials = try CodexCredentialsReader.load(environment: environment)
        #expect(credentials.accessToken == "token-123")
        #expect(credentials.accountId == nil)
    }

    @Test
    func `tokens win when both API key and tokens are present`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        {
          "OPENAI_API_KEY": "sk-legacy",
          "tokens": { "access_token": "token-123", "account_id": "acct-1" }
        }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentials = try CodexCredentialsReader.load(environment: environment)
        #expect(credentials.accessToken == "token-123")
    }

    @Test
    func `API-key-only auth file throws apiKeyOnly`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "OPENAI_API_KEY": "sk-legacy" }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CodexCredentialsError.apiKeyOnly) {
            try CodexCredentialsReader.load(environment: environment)
        }
    }

    @Test
    func `missing auth file throws notFound`() throws {
        let (environment, directory) = try self.makeCodexHome()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CodexCredentialsError.notFound) {
            try CodexCredentialsReader.load(environment: environment)
        }
    }

    @Test
    func `malformed JSON throws decodeFailed`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: "not json {")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CodexCredentialsError.decodeFailed) {
            try CodexCredentialsReader.load(environment: environment)
        }
    }

    @Test
    func `auth file with neither key nor tokens throws missingAccessToken`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "OPENAI_API_KEY": null }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CodexCredentialsError.missingAccessToken) {
            try CodexCredentialsReader.load(environment: environment)
        }
    }

    @Test
    func `whitespace-only access token throws missingAccessToken`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "tokens": { "access_token": "   " } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CodexCredentialsError.missingAccessToken) {
            try CodexCredentialsReader.load(environment: environment)
        }
    }

    @Test
    func `trims token whitespace and collapses empty account id to nil`() throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "tokens": { "access_token": " token-123\\n", "account_id": "  " } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentials = try CodexCredentialsReader.load(environment: environment)
        #expect(credentials.accessToken == "token-123")
        #expect(credentials.accountId == nil)
    }

    // MARK: - Existence probe (Settings hint)

    @Test
    func `authFileExists reflects presence without reading contents`() throws {
        let (present, presentDir) = try self.makeCodexHome(authJSON: "not even json — stat only")
        defer { try? FileManager.default.removeItem(at: presentDir) }
        let (absent, absentDir) = try self.makeCodexHome()
        defer { try? FileManager.default.removeItem(at: absentDir) }

        #expect(CodexCredentialsReader.authFileExists(environment: present))
        #expect(!CodexCredentialsReader.authFileExists(environment: absent))
    }

    // MARK: - Path resolution

    @Test
    func `CODEX_HOME overrides the default auth file location`() {
        let url = CodexCredentialsReader.authFileURL(environment: ["CODEX_HOME": "/tmp/custom-codex"])
        #expect(url.path == "/tmp/custom-codex/auth.json")
    }

    @Test
    func `default auth file lives under ~slash-dot-codex`() {
        let url = CodexCredentialsReader.authFileURL(environment: [:])
        #expect(url.path.hasSuffix("/.codex/auth.json"))
        #expect(url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test
    func `blank CODEX_HOME falls back to the default location`() {
        let url = CodexCredentialsReader.authFileURL(environment: ["CODEX_HOME": "   "])
        #expect(url.path.hasSuffix("/.codex/auth.json"))
    }
}
