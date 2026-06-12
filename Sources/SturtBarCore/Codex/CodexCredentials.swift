// CodexCredentials.swift — read-only access to the Codex CLI auth file.
//
// Privacy contract (see README): SturtBar is a strictly read-only consumer of
// `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`). It never writes the file, never
// refreshes Codex tokens, and never parses the `id_token` JWT. The token is held in memory for
// the duration of a fetch only. `authFileExists` is a pure stat() used by the Settings hint and
// must never read file contents.

import Foundation

/// The minimal credential material a Codex usage fetch needs.
public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    /// ChatGPT workspace/account discriminator; sent as `ChatGPT-Account-Id` when present.
    public let accountId: String?
}

public enum CodexCredentialsError: LocalizedError, Equatable, Sendable {
    /// No auth file on disk — the user has never signed in via the codex CLI.
    case notFound
    /// The auth file exists but is not parseable JSON of the expected shape.
    case decodeFailed
    /// The auth file only carries a platform `OPENAI_API_KEY`; API-key accounts have no
    /// ChatGPT rate-limit usage to show (mapped to the "unsupported" status, not an error row).
    case apiKeyOnly
    /// The auth file exists but contains no usable ChatGPT access token.
    case missingAccessToken

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "No Codex sign-in found (auth.json is missing)."
        case .decodeFailed:
            "Could not read the Codex auth file."
        case .apiKeyOnly:
            "API-key Codex accounts have no usage limits to show."
        case .missingAccessToken:
            "The Codex auth file has no access token."
        }
    }
}

public enum CodexCredentialsReader {
    /// Decode only the fields we use; `refresh_token`, `id_token`, and `last_refresh` are
    /// deliberately ignored (no refresh, no JWT parsing).
    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }

        let apiKey: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case apiKey = "OPENAI_API_KEY"
            case tokens
        }
    }

    /// `$CODEX_HOME/auth.json` when set (non-blank), else `~/.codex/auth.json`.
    static func authFileURL(environment: [String: String]) -> URL {
        let home: URL = if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !codexHome.isEmpty
        {
            URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return home.appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Pure existence stat for the Settings "codex CLI not detected" hint. Never reads contents.
    public static func authFileExists(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        FileManager.default.fileExists(atPath: self.authFileURL(environment: environment).path)
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexCredentials
    {
        let url = self.authFileURL(environment: environment)
        guard let data = try? Data(contentsOf: url) else {
            throw CodexCredentialsError.notFound
        }
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            throw CodexCredentialsError.decodeFailed
        }

        let accessToken = file.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !accessToken.isEmpty {
            let accountId = file.tokens?.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexCredentials(
                accessToken: accessToken,
                accountId: (accountId?.isEmpty ?? true) ? nil : accountId)
        }

        let apiKey = file.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !apiKey.isEmpty {
            throw CodexCredentialsError.apiKeyOnly
        }
        throw CodexCredentialsError.missingAccessToken
    }
}
