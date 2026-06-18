// StatePersistence.swift — cached app state on disk.
//
// Persists the last good usage + cost snapshots so a relaunch shows data immediately instead of
// an empty menu until the first fetch lands. Plain JSON at
// ~/Library/Application Support/SturtBar/state.json (directory injectable for tests).
//
// Policy split: this type is dumb, synchronous-core IO (load/save, atomic write, corrupt-file
// tolerance). The ≥5s save debounce is OWNED BY UsageStore — debouncing is store policy, and
// keeping it there lets the store flush synchronously at app termination.

import Foundation
import SturtBarCore

struct StatePersistence {
    struct State: Codable, Equatable {
        /// Claude snapshot. The JSON key stays `usage` (pre-codex schema) so existing users'
        /// state files keep decoding; renaming the property would break that for zero gain.
        var usage: ProviderUsageSnapshot?
        /// Codex snapshot; absent in pre-1.1 files (decodes nil) and ignored by older app
        /// versions reading newer files.
        var codexUsage: ProviderUsageSnapshot?
        var cost: CostUsageTokenSnapshot?
        /// Codex cost snapshot; absent in pre-codex-cost files (decodes nil) and ignored by older
        /// app versions reading newer files.
        var codexCost: CostUsageTokenSnapshot?
        var savedAt: Date

        /// Explicit init so legacy `State(usage:cost:savedAt:)` call sites stay valid; Codable
        /// synthesis is unaffected.
        init(
            usage: ProviderUsageSnapshot?,
            codexUsage: ProviderUsageSnapshot? = nil,
            cost: CostUsageTokenSnapshot?,
            codexCost: CostUsageTokenSnapshot? = nil,
            savedAt: Date)
        {
            self.usage = usage
            self.codexUsage = codexUsage
            self.cost = cost
            self.codexCost = codexCost
            self.savedAt = savedAt
        }
    }

    private static let log = SturtBarLog.logger("state-persistence")
    private static let fileName = "state.json"

    let directory: URL

    /// - Parameter directory: storage directory; defaults to
    ///   `~/Library/Application Support/SturtBar`.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("SturtBar", isDirectory: true)
    }

    private var fileURL: URL {
        self.directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: Async wrappers (run off the caller's actor)

    func load() async -> State? {
        self.loadNow()
    }

    func save(_ state: State) async {
        self.saveNow(state)
    }

    // MARK: Synchronous core

    /// Returns nil when the file is missing, unreadable, or corrupt (never throws — cached state
    /// is best-effort and a bad file must not break launch).
    func loadNow() -> State? {
        let url = self.fileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            Self.log.warning(
                "Cached state file is corrupt; ignoring",
                metadata: ["path": url.path, "error": "\(error)"])
            return nil
        }
    }

    /// Best-effort atomic write; failures are logged, not thrown (losing the cache is acceptable,
    /// crashing or blocking the app is not).
    func saveNow(_ state: State) {
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: self.fileURL, options: [.atomic])
        } catch {
            Self.log.warning(
                "Failed to persist cached state",
                metadata: ["path": self.fileURL.path, "error": "\(error)"])
        }
    }
}
