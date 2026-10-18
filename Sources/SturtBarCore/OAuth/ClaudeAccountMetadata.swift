import CryptoKit
import Foundation

struct ClaudeAccountMetadata {
    private struct Root: Decodable {
        let oauthAccount: Account?
    }

    private struct Account: Decodable {
        let accountUuid: String
        let organizationUuid: String?
    }

    private let url: URL
    private var fingerprint: String?
    private var accountKey: String?

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")) {
        self.url = url
    }

    mutating func read() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: self.url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        let stamp = "\(modified.timeIntervalSince1970):\(size):\(attributes[.systemFileNumber] ?? "")"
        if stamp == self.fingerprint { return self.accountKey }
        self.fingerprint = stamp
        self.accountKey = nil
        guard let data = try? Data(contentsOf: self.url),
              let account = try? JSONDecoder().decode(Root.self, from: data).oauthAccount,
              !account.accountUuid.isEmpty
        else { return nil }
        let fields = [account.accountUuid, account.organizationUuid ?? ""]
        guard let encoded = try? JSONEncoder().encode(fields) else { return nil }
        self.accountKey = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        self.fingerprint = stamp
        return self.accountKey
    }
}
