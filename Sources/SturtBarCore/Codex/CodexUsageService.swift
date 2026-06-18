// CodexUsageService.swift — opt-in Codex usage: credentials → fetch → ProviderUsageSnapshot.
//
// The whole Codex lane is three small read-only pieces (credentials reader, wham fetcher, this
// mapper). There is deliberately no token refresh, no keychain, no JWT parsing, and no
// config.toml support — see the file headers of CodexCredentials.swift / CodexUsageFetcher.swift.

import Foundation

// MARK: - Links

/// Codex provider display metadata (mirrors `ClaudeLinks`).
public enum CodexLinks {
    public static let displayName = "Codex"
}

// MARK: - CodexUsageService

/// Fetches Codex usage via the ChatGPT wham endpoint. No prompts and no shared mutable state, so
/// unlike `ClaudeUsageService` it needs no interaction/phase plumbing; the app wraps it in a
/// single-flight actor (`CodexUsageClient`).
public struct CodexUsageService: Sendable {
    private let environment: [String: String]
    private let transport: any HTTPTransport
    private static let log = SturtBarLog.logger("codex-usage")

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any HTTPTransport = HTTPClient.shared)
    {
        self.environment = environment
        self.transport = transport
    }

    public func fetchUsage() async throws -> ProviderUsageSnapshot {
        let credentials: CodexCredentials
        do {
            credentials = try CodexCredentialsReader.load(environment: self.environment)
        } catch let error as CodexCredentialsError {
            switch error {
            case .notFound, .decodeFailed, .missingAccessToken:
                throw CodexUsageError.credentialsMissing
            case .apiKeyOnly:
                throw CodexUsageError.apiKeyOnly
            }
        }

        let response = try await CodexUsageFetcher.fetchUsage(
            credentials: credentials,
            transport: self.transport)
        return try Self.mapUsage(response, now: Date())
    }

    // MARK: - Mapping

    private static func mapUsage(
        _ response: CodexWhamUsageResponse,
        now: Date) throws -> ProviderUsageSnapshot
    {
        func makeWindow(_ window: CodexRateLimitWindow?) -> RateWindow? {
            guard let window, let usedPercent = window.usedPercent else { return nil }
            let resetDate: Date? = if let resetAt = window.resetAt, resetAt > 0 {
                Date(timeIntervalSince1970: resetAt)
            } else {
                nil
            }
            return RateWindow(
                usedPercent: usedPercent,
                windowMinutes: window.limitWindowSeconds.map { $0 / 60 },
                resetsAt: resetDate,
                resetDescription: resetDate.map(Self.formatResetDate))
        }

        // Normalize roles by window length: the shortest window (5h session) is always primary,
        // the weekly window secondary — regardless of the order the endpoint sent them in.
        let windows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow]
            .compactMap(makeWindow)
            .sorted { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }

        guard let primary = windows.first else {
            throw CodexUsageError.parseFailed("missing rate_limit windows")
        }

        return ProviderUsageSnapshot(
            primary: primary,
            secondary: windows.count > 1 ? windows[1] : nil,
            opus: nil,
            updatedAt: now,
            loginMethod: Self.planDisplayName(response.planType))
    }

    /// "pro" → "Pro", "free_workspace" → "Free Workspace". Pass-through title-casing — no plan
    /// enum needed for a display badge.
    private static func planDisplayName(_ planType: String?) -> String? {
        guard let planType else { return nil }
        let cleaned = planType
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.capitalized
    }

    /// Same pattern as `ClaudeUsageService.formatResetDate`.
    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

#if DEBUG
extension CodexUsageService {
    public static func _mapUsageForTesting(
        _ data: Data,
        now: Date = Date()) throws -> ProviderUsageSnapshot
    {
        let response = try JSONDecoder().decode(CodexWhamUsageResponse.self, from: data)
        return try Self.mapUsage(response, now: now)
    }
}
#endif
