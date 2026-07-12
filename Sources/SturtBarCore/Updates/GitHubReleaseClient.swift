// GitHubReleaseClient.swift: fetches the latest GitHub release for the updater.
//
// Unauthenticated, ETag conditional requests (a 304 costs a few hundred bytes), typed errors
// only. Destinations (api.github.com, plus the asset hosts reached on install) are disclosed in
// BRAND.md 6.3 and the README; the whole lane is gated behind the update-check opt-in.

import Foundation

// MARK: - Transport seam

public protocol GitHubReleaseHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionGitHubReleaseTransport: GitHubReleaseHTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Self.session.data(for: request)
    }

    /// Ephemeral: no cookies, no shared cache; the stored ETag is the only cross-run state.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
}

// MARK: - Models

public struct ReleaseInfo: Equatable, Sendable, Codable {
    public let version: SemanticVersion
    public let tagName: String
    public let zipAssetURL: URL
    public let zipAssetName: String
    public let zipAssetSize: Int
    /// GitHub's own "sha256:<hex>" digest for the zip asset, when the API provides one.
    public let zipAssetDigest: String?
    /// The release's `SturtBar-<ver>.zip.sha256` asset; absent on releases older than the updater.
    public let checksumAssetURL: URL?
    public let notes: String?

    public init(
        version: SemanticVersion,
        tagName: String,
        zipAssetURL: URL,
        zipAssetName: String,
        zipAssetSize: Int,
        zipAssetDigest: String?,
        checksumAssetURL: URL?,
        notes: String?)
    {
        self.version = version
        self.tagName = tagName
        self.zipAssetURL = zipAssetURL
        self.zipAssetName = zipAssetName
        self.zipAssetSize = zipAssetSize
        self.zipAssetDigest = zipAssetDigest
        self.checksumAssetURL = checksumAssetURL
        self.notes = notes
    }
}

public enum LatestReleaseResponse: Equatable, Sendable {
    case notModified
    case release(ReleaseInfo, etag: String?)
}

// MARK: - Checker seam (UpdateStore injects a fake in tests)

public protocol UpdateChecking: Sendable {
    func fetchLatestRelease(etag: String?) async throws -> LatestReleaseResponse
}

// MARK: - Client

public struct GitHubReleaseClient: UpdateChecking {
    public enum Error: Swift.Error, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case rateLimited
        case invalidJSON
        case invalidTag(String)
        case missingAsset(String)
    }

    public static let defaultRepoSlug = "michael-palmes/SturtBar"

    var repoSlug: String
    var userAgent: String
    var transport: any GitHubReleaseHTTPTransport

    public init(
        repoSlug: String = Self.defaultRepoSlug,
        userAgent: String,
        transport: any GitHubReleaseHTTPTransport = URLSessionGitHubReleaseTransport())
    {
        self.repoSlug = repoSlug
        self.userAgent = userAgent
        self.transport = transport
    }

    /// One GET of releases/latest (drafts and pre-releases are excluded by the endpoint itself).
    public func fetchLatestRelease(etag: String?) async throws -> LatestReleaseResponse {
        guard let url = URL(string: "https://api.github.com/repos/\(self.repoSlug)/releases/latest") else {
            throw Error.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await self.transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.invalidResponse }
        switch http.statusCode {
        case 304: return .notModified
        case 200..<300: break
        case 403, 429: throw Error.rateLimited
        default: throw Error.httpStatus(http.statusCode)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw Error.invalidJSON
        }
        guard let version = SemanticVersion(string: payload.tagName) else {
            throw Error.invalidTag(payload.tagName)
        }
        // Asset names derive from the tag (release.sh names both from version.env).
        let bareVersion = payload.tagName.hasPrefix("v")
            ? String(payload.tagName.dropFirst())
            : payload.tagName
        let zipName = "SturtBar-\(bareVersion).zip"
        guard let zip = payload.assets.first(where: { $0.name == zipName }) else {
            throw Error.missingAsset(zipName)
        }
        let checksum = payload.assets.first { $0.name == "\(zipName).sha256" }
        let info = ReleaseInfo(
            version: version,
            tagName: payload.tagName,
            zipAssetURL: zip.browserDownloadURL,
            zipAssetName: zip.name,
            zipAssetSize: zip.size,
            zipAssetDigest: zip.digest,
            checksumAssetURL: checksum?.browserDownloadURL,
            notes: payload.body)
        return .release(info, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    private struct Payload: Decodable {
        let tagName: String
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let size: Int
            let digest: String?
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case size
                case digest
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}
