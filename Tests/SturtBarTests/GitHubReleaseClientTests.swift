// GitHubReleaseClientTests.swift — fixture decode, ETag/304 path, typed errors and asset
// selection for the release checker.

import Foundation
import Testing
@testable import SturtBarCore

private struct MockTransport: GitHubReleaseHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try self.handler(request)
    }
}

private func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://api.github.com/repos/michael-palmes/SturtBar/releases/latest")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: headers)!
}

private func fixtureData() throws -> Data {
    guard let url = Bundle.module.url(
        forResource: "github-releases-latest",
        withExtension: "json",
        subdirectory: "Fixtures")
    else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: url)
}

private func makeClient(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse))
    -> GitHubReleaseClient
{
    GitHubReleaseClient(userAgent: "SturtBar/1.2.0", transport: MockTransport(handler: handler))
}

struct GitHubReleaseClientTests {
    @Test
    func `decodes the fixture release and selects the zip and checksum assets`() async throws {
        let data = try fixtureData()
        let client = makeClient { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "SturtBar/1.2.0")
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
            return (data, response(status: 200, headers: ["ETag": "W/\"fixture\""]))
        }
        let result = try await client.fetchLatestRelease(etag: nil)
        guard case let .release(info, etag) = result else {
            Issue.record("expected a release, got \(result)")
            return
        }
        #expect(etag == "W/\"fixture\"")
        #expect(info.version == SemanticVersion(string: "9.9.9"))
        #expect(info.tagName == "v9.9.9")
        #expect(info.zipAssetName == "SturtBar-9.9.9.zip")
        #expect(info.zipAssetSize == 5_084_230)
        #expect(info.zipAssetDigest == "sha256:\(String(repeating: "2", count: 64))")
        #expect(info.zipAssetURL.absoluteString.hasSuffix("/v9.9.9/SturtBar-9.9.9.zip"))
        #expect(info.checksumAssetURL?.absoluteString.hasSuffix("SturtBar-9.9.9.zip.sha256") == true)
        #expect(info.notes?.contains("fixture release") == true)
    }

    @Test
    func `sends the stored ETag and maps 304 to notModified`() async throws {
        let client = makeClient { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "W/\"fixture\"")
            return (Data(), response(status: 304))
        }
        let result = try await client.fetchLatestRelease(etag: "W/\"fixture\"")
        #expect(result == .notModified)
    }

    @Test
    func `maps status codes to typed errors`() async throws {
        for (status, expected) in [
            (403, GitHubReleaseClient.Error.rateLimited),
            (429, .rateLimited),
            (500, .httpStatus(500)),
            (404, .httpStatus(404)),
        ] {
            let client = makeClient { _ in (Data(), response(status: status)) }
            await #expect(throws: expected) {
                try await client.fetchLatestRelease(etag: nil)
            }
        }
    }

    @Test
    func `rejects malformed JSON, unparseable tags and missing assets`() async throws {
        let garbage = makeClient { _ in (Data("not json".utf8), response(status: 200)) }
        await #expect(throws: GitHubReleaseClient.Error.invalidJSON) {
            try await garbage.fetchLatestRelease(etag: nil)
        }

        let badTag = Data(#"{"tag_name": "nightly", "assets": []}"#.utf8)
        let badTagClient = makeClient { _ in (badTag, response(status: 200)) }
        await #expect(throws: GitHubReleaseClient.Error.invalidTag("nightly")) {
            try await badTagClient.fetchLatestRelease(etag: nil)
        }

        let noZipJSON = #"""
        {"tag_name": "v9.9.9", "assets": [
          {"name": "SturtBar-9.9.9.dmg", "size": 1, "browser_download_url": "https://example.com/a.dmg"}
        ]}
        """#
        let noZipClient = makeClient { _ in (Data(noZipJSON.utf8), response(status: 200)) }
        await #expect(throws: GitHubReleaseClient.Error.missingAsset("SturtBar-9.9.9.zip")) {
            try await noZipClient.fetchLatestRelease(etag: nil)
        }
    }
}
