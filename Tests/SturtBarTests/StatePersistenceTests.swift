// StatePersistenceTests.swift — disk round-trip + corrupt-file tolerance.

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

struct StatePersistenceTests {
    private func makeTempPersistence() -> (persistence: StatePersistence, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        return (StatePersistence(directory: directory), directory)
    }

    @Test
    func `state round-trips through disk`() {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let savedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let state = StatePersistence.State(
            usage: makeUsageSnapshot(primaryUsedPercent: 62.5, secondaryUsedPercent: 30, updatedAt: savedAt),
            cost: makeCostSnapshot(updatedAt: savedAt),
            savedAt: savedAt)

        persistence.saveNow(state)
        let loaded = persistence.loadNow()
        #expect(loaded == state)
    }

    @Test
    func `nil snapshots round-trip`() {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = StatePersistence.State(
            usage: nil,
            cost: nil,
            savedAt: Date(timeIntervalSince1970: 1_750_000_000))
        persistence.saveNow(state)
        #expect(persistence.loadNow() == state)
    }

    @Test
    func `missing file loads as nil`() {
        let (persistence, _) = self.makeTempPersistence()
        #expect(persistence.loadNow() == nil)
    }

    @Test
    func `corrupt file loads as nil instead of throwing`() throws {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json ]".utf8).write(to: directory.appendingPathComponent("state.json"))
        #expect(persistence.loadNow() == nil)
    }

    @Test
    func `save overwrites previous state atomically`() {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = StatePersistence.State(
            usage: makeUsageSnapshot(primaryUsedPercent: 10),
            cost: nil,
            savedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let second = StatePersistence.State(
            usage: makeUsageSnapshot(primaryUsedPercent: 90),
            cost: makeCostSnapshot(),
            savedAt: Date(timeIntervalSince1970: 1_750_000_100))

        persistence.saveNow(first)
        persistence.saveNow(second)
        #expect(persistence.loadNow() == second)
    }

    @Test
    func `default directory points at Application Support slash SturtBar`() {
        let persistence = StatePersistence()
        #expect(persistence.directory.path.hasSuffix("Application Support/SturtBar"))
    }
}

// MARK: - Store integration

@MainActor
struct UsageStorePersistenceTests {
    @Test
    func `termination flush writes pending state synchronously`() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-flush-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)

        let ts = makeTestStore(
            suiteName: "sturtbar-tests-flush",
            persistence: persistence)
        { _, _ in makeUsageSnapshot(primaryUsedPercent: 42) }

        await ts.store.refresh(trigger: .manual)
        // The debounced save (≥5s) has not fired yet; the flush must write it.
        #expect(persistence.loadNow() == nil)

        ts.store.flushPersistedStateForTermination()
        let state = persistence.loadNow()
        #expect(state?.usage?.primary.usedPercent == 42)
    }

    @Test
    func `termination flush without pending changes does not clobber the cache`() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-noclobber-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        let cached = StatePersistence.State(
            usage: makeUsageSnapshot(primaryUsedPercent: 77),
            cost: nil,
            savedAt: Date(timeIntervalSince1970: 1_750_000_000))
        persistence.saveNow(cached)

        let ts = makeTestStore(
            suiteName: "sturtbar-tests-noclobber",
            persistence: persistence)
        { _, _ in makeUsageSnapshot() }

        // No refresh ran — quitting now must not overwrite the good cache with empty state.
        ts.store.flushPersistedStateForTermination()
        #expect(persistence.loadNow() == cached)
    }

    @Test
    func `loadPersistedState seeds usage and cost without clobbering fresher data`() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-load-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        persistence.saveNow(StatePersistence.State(
            usage: makeUsageSnapshot(primaryUsedPercent: 11),
            cost: makeCostSnapshot(sessionCostUSD: 9.99),
            savedAt: Date(timeIntervalSince1970: 1_750_000_000)))

        let ts = makeTestStore(
            suiteName: "sturtbar-tests-load",
            persistence: persistence)
        { _, _ in makeUsageSnapshot(primaryUsedPercent: 55) }

        await ts.store.loadPersistedState()
        #expect(ts.store.usage?.primary.usedPercent == 11)
        #expect(ts.store.cost?.sessionCostUSD == 9.99)

        // A fetched snapshot wins; re-loading afterwards must not regress it.
        ts.clock.advance(by: 100)
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.usage?.primary.usedPercent == 55)
        await ts.store.loadPersistedState()
        #expect(ts.store.usage?.primary.usedPercent == 55)
    }
}
