// CodexUsageServiceTests.swift — wham response → ProviderUsageSnapshot mapping + service-level
// credential error mapping. All file IO goes through temp CODEX_HOME dirs.

import Foundation
import Testing
@testable import SturtBarCore

// MARK: - Mapping

struct CodexUsageMappingTests {
    private let now = Date(timeIntervalSince1970: 1_766_000_000)

    @Test
    func `maps both windows with normalized roles`() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12.5, "reset_at": 1766948068, "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 43, "reset_at": 1767407914, "limit_window_seconds": 604800
            }
          }
        }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)

        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.primary.windowMinutes == 300)
        #expect(snap.primary.resetsAt == Date(timeIntervalSince1970: 1_766_948_068))
        #expect(snap.primary.resetDescription != nil)
        #expect(snap.secondary?.usedPercent == 43)
        #expect(snap.secondary?.windowMinutes == 10080)
        #expect(snap.primaryWindowKind == .usage)
        #expect(snap.opus == nil)
        #expect(snap.extraRateWindows.isEmpty)
        #expect(snap.providerCost == nil)
        #expect(snap.loginMethod == "Pro")
        #expect(snap.updatedAt == self.now)
    }

    @Test
    func `swapped windows are normalized so the session window is primary`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 43, "limit_window_seconds": 604800 },
            "secondary_window": { "used_percent": 12.5, "limit_window_seconds": 18000 }
          }
        }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)

        #expect(snap.primary.usedPercent == 12.5)
        #expect(snap.primary.windowMinutes == 300)
        #expect(snap.secondary?.usedPercent == 43)
        #expect(snap.secondary?.windowMinutes == 10080)
    }

    @Test
    func `single window maps to primary with no secondary`() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 7, "limit_window_seconds": 18000 } } }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)

        #expect(snap.primary.usedPercent == 7)
        #expect(snap.secondary == nil)
    }

    @Test
    func `windows without used_percent are dropped`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "reset_at": 1766948068, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 43, "limit_window_seconds": 604800 }
          }
        }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)

        #expect(snap.primary.usedPercent == 43)
        #expect(snap.primary.windowMinutes == 10080)
        #expect(snap.secondary == nil)
    }

    @Test
    func `missing rate limit throws parseFailed`() throws {
        let json = """
        { "plan_type": "pro" }
        """
        #expect(throws: CodexUsageError.self) {
            try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)
        }
    }

    @Test
    func `plan type is title-cased with underscores expanded`() throws {
        let json = """
        {
          "plan_type": "free_workspace",
          "rate_limit": { "primary_window": { "used_percent": 1, "limit_window_seconds": 18000 } }
        }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)
        #expect(snap.loginMethod == "Free Workspace")
    }

    @Test
    func `absent plan type maps to nil login method`() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 1, "limit_window_seconds": 18000 } } }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)
        #expect(snap.loginMethod == nil)
    }

    @Test
    func `non-positive reset timestamps map to nil resetsAt`() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 1, "reset_at": 0, "limit_window_seconds": 18000 } } }
        """
        let snap = try CodexUsageService._mapUsageForTesting(Data(json.utf8), now: self.now)
        #expect(snap.primary.resetsAt == nil)
        #expect(snap.primary.resetDescription == nil)
    }
}

// MARK: - Service credential mapping

struct CodexUsageServiceTests {
    private func makeCodexHome(authJSON: String? = nil) throws -> (environment: [String: String], directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-codex-service-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let authJSON {
            try Data(authJSON.utf8).write(to: directory.appendingPathComponent("auth.json"))
        }
        return (["CODEX_HOME": directory.path], directory)
    }

    @Test
    func `missing auth file surfaces as credentialsMissing`() async throws {
        let (environment, directory) = try self.makeCodexHome()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = CodexUsageService(
            environment: environment,
            transport: HTTPTransportHandler { _ in throw URLError(.badURL) })

        do {
            _ = try await service.fetchUsage()
            Issue.record("expected credentialsMissing")
        } catch let error as CodexUsageError {
            #expect(error.indicatesCredentialsMissing)
        }
    }

    @Test
    func `api-key-only auth surfaces as apiKeyOnly`() async throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "OPENAI_API_KEY": "sk-legacy" }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = CodexUsageService(
            environment: environment,
            transport: HTTPTransportHandler { _ in throw URLError(.badURL) })

        do {
            _ = try await service.fetchUsage()
            Issue.record("expected apiKeyOnly")
        } catch let error as CodexUsageError {
            #expect(error.indicatesUnsupportedAccount)
        }
    }

    @Test
    func `valid tokens drive a fetch and return the mapped snapshot`() async throws {
        let (environment, directory) = try self.makeCodexHome(authJSON: """
        { "tokens": { "access_token": "token-123", "account_id": "acct-1" } }
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = CodexUsageService(
            environment: environment,
            transport: HTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
                let body = """
                {
                  "plan_type": "plus",
                  "rate_limit": { "primary_window": { "used_percent": 9, "limit_window_seconds": 18000 } }
                }
                """
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), response)
            })

        let snap = try await service.fetchUsage()
        #expect(snap.primary.usedPercent == 9)
        #expect(snap.loginMethod == "Plus")
    }
}
