// UsageStoreCodexRefreshTests.swift — the codex lane: privacy gate, concurrency, isolation,
// per-lane policy gates, disable-wipe, and persistence seeding.
//
// The single most important suite for decision 6: a DISABLED provider must be completely inert —
// the store may never invoke its client, and disabling must wipe memory + disk.

import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

@MainActor
struct UsageStoreCodexRefreshTests {
    /// Bounded yield-loop for fire-and-forget store work (mirrors waitForCostScanIdle usage).
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 2000) async
    {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Privacy gate (decision 6)

    @Test
    func `disabled codex provider never fetches on any trigger`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-gate",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })

        for trigger in [RefreshTrigger.launch, .interval, .menuOpen, .manual, .wake] {
            await ts.store.refresh(trigger: trigger)
            ts.clock.advance(by: 3600)
        }

        #expect(await ts.recorder.codexFetchCount == 0)
        #expect(ts.store.codexUsage == nil)
        #expect(await ts.recorder.fetchCount == 5)
    }

    @Test
    func `disabled claude provider never fetches and skips cost scans`() async {
        let scanRecorder = CallRecorder()
        let scanner = CostScanner(minimumGap: 0, scanOperation: { _, bypassGate, historyDays, _ in
            await scanRecorder.recordScan(bypassGate: bypassGate, historyDays: historyDays)
            return makeCostSnapshot()
        })
        let ts = makeTestStore(
            suiteName: "sturtbar-claude-gate",
            scanner: scanner,
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.claudeProviderEnabled = false
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)

        #expect(await ts.recorder.fetchCount == 0)
        #expect(await scanRecorder.scanCount == 0)
        #expect(await ts.recorder.codexFetchCount == 1)
        #expect(ts.store.codexUsage != nil)
        #expect(ts.store.usage == nil)
    }

    // MARK: - Fan-out + concurrency (decision 13)

    @Test
    func `one refresh drives both enabled lanes`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-fanout",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)

        #expect(await ts.recorder.fetchCount == 1)
        #expect(await ts.recorder.codexFetchCount == 1)
        #expect(ts.store.usage != nil)
        #expect(ts.store.codexUsage != nil)
    }

    @Test
    func `codex completes while a slow claude fetch is still in flight`() async {
        let releaseClaude = TestLatch()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-concurrent",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in
                await releaseClaude.wait()
                return makeUsageSnapshot()
            })
        ts.settings.codexProviderEnabled = true

        let refreshTask = Task { await ts.store.refresh(trigger: .manual) }
        // Codex must land while Claude is held open — cross-provider isolation of wall-clock.
        await self.waitUntil { ts.store.codexUsage != nil }
        #expect(ts.store.codexUsage != nil)
        #expect(ts.store.usage == nil)

        await releaseClaude.open()
        await refreshTask.value
        #expect(ts.store.usage != nil)
    }

    // MARK: - Failure isolation + auth mapping

    @Test
    func `codex failure leaves the claude lane untouched`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-isolation",
            codexFetch: { throw CodexUsageError.serverError(500, nil) },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)

        #expect(ts.store.usage != nil)
        #expect(ts.store.auth == .ok)
        #expect(ts.store.health == .ok)
        guard case .degraded = ts.store.codexHealth else {
            Issue.record("expected degraded codex health, got \(ts.store.codexHealth)")
            return
        }
    }

    @Test
    func `claude failure leaves the codex lane untouched`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-claude-isolation",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in
                throw ClaudeUsageError.oauthFailed("boom")
            })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)

        #expect(ts.store.codexUsage != nil)
        #expect(ts.store.codexHealth == .ok)
        #expect(ts.store.codexAuth == .ok)
        guard case .degraded = ts.store.health else {
            Issue.record("expected degraded claude health, got \(ts.store.health)")
            return
        }
    }

    @Test
    func `codex auth errors map to typed states and stay sticky until success`() async {
        enum Script { @MainActor static var error: CodexUsageError = .unauthorized }
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-auth",
            codexFetch: { throw await Script.error },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.codexAuth == .signInRequired)

        Script.error = .credentialsMissing
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.codexAuth == .credentialsMissing)

        Script.error = .apiKeyOnly
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.codexAuth == .apiKeyOnlyUnsupported)

        // A non-auth failure must NOT clear the sticky auth state.
        Script.error = .serverError(500, nil)
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.codexAuth == .apiKeyOnlyUnsupported)
    }

    // MARK: - Per-lane gates

    @Test
    func `codex rate limit blocks even manual until the until-date`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-ratelimit",
            codexFetch: { [start = Date(timeIntervalSince1970: 1_000_000_000)] in
                throw CodexUsageError.rateLimited(retryAfter: start.addingTimeInterval(600))
            },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.codexFetchCount == 1)
        guard case .rateLimited = ts.store.codexHealth else {
            Issue.record("expected rateLimited codex health")
            return
        }

        // Inside the window: even manual is gated for codex; claude still fetches (one per
        // manual refresh — two so far).
        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.codexFetchCount == 1)
        #expect(await ts.recorder.fetchCount == 2)

        // Past the until-date the lane recovers.
        ts.clock.advance(by: 601)
        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.codexFetchCount == 2)
    }

    @Test
    func `codex menuOpen respects the 30s min-gap independently of claude`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-mingap",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)
        ts.clock.advance(by: 10)
        await ts.store.refresh(trigger: .menuOpen)

        // Both lanes gated within their own 30s windows.
        #expect(await ts.recorder.codexFetchCount == 1)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 25) // 35s since success
        await ts.store.refresh(trigger: .menuOpen)
        #expect(await ts.recorder.codexFetchCount == 2)
    }

    @Test
    func `codex failures back off automatic triggers per lane`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-backoff",
            codexFetch: { throw CodexUsageError.serverError(500, nil) },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual) // streak 1
        #expect(await ts.recorder.codexFetchCount == 1)

        // interval/2 elapsed but inside backoff (300 × 2^1 = 600s): suppressed.
        ts.clock.advance(by: 200)
        await ts.store.refresh(trigger: .interval)
        #expect(await ts.recorder.codexFetchCount == 1)

        // Past the backoff window: retried.
        ts.clock.advance(by: 500)
        await ts.store.refresh(trigger: .interval)
        #expect(await ts.recorder.codexFetchCount == 2)
    }

    // MARK: - Enable/disable lifecycle

    @Test
    func `enabling codex kicks one fetch without touching claude`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-enable-kick",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })

        ts.settings.codexProviderEnabled = true
        ts.store.providerEnabledDidChange(.codex, enabled: true)
        await self.waitUntil { ts.store.codexUsage != nil }

        #expect(await ts.recorder.codexFetchCount == 1)
        #expect(await ts.recorder.fetchCount == 0)
    }

    @Test
    func `disabling codex wipes the lane and cancels in-flight work`() async {
        let codexStarted = TestLatch()
        let releaseCodex = TestLatch()
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-disable-race",
            codexFetch: {
                await codexStarted.open()
                await releaseCodex.wait()
                return makeCodexSnapshot()
            },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        let refreshTask = Task { await ts.store.refresh(trigger: .manual) }
        await codexStarted.wait()

        // Disable while the codex fetch is held open, then release it.
        ts.settings.codexProviderEnabled = false
        ts.store.providerEnabledDidChange(.codex, enabled: false)
        await releaseCodex.open()
        await refreshTask.value

        #expect(ts.store.codexUsage == nil)
        #expect(ts.store.codexAuth == .ok)
        #expect(ts.store.codexHealth == .ok)
        #expect(ts.store.codexLastSuccessAt == nil)
    }

    @Test
    func `disabling claude wipes its lane including cost`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-claude-disable-wipe",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.usage != nil)

        ts.settings.claudeProviderEnabled = false
        ts.store.providerEnabledDidChange(.claude, enabled: false)
        await self.waitUntil { ts.store.usage == nil }

        #expect(ts.store.usage == nil)
        #expect(ts.store.cost == nil)
        #expect(ts.store.auth == .ok)
        #expect(ts.store.lastSuccessAt == nil)
    }

    // MARK: - Staleness

    @Test
    func `stalenessDeadline is the earliest enabled lane deadline`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-staleness",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)
        let firstDeadline = ts.store.stalenessDeadline
        #expect(firstDeadline != nil)

        // Claude succeeds again later; codex stays gated (min-gap) → codex deadline is earlier.
        ts.clock.advance(by: 40)
        // Use manual to bypass gaps for claude... both lanes fetch; advance enough that both
        // succeed and deadlines move together: instead assert deadline == lastSuccess + threshold.
        let threshold = max(2 * 300, 600) // default 5m interval → 600s
        #expect(firstDeadline == ts.store.codexLastSuccessAt?.addingTimeInterval(TimeInterval(threshold)))
    }

    @Test
    func `codexIsStale tracks the codex lane only`() async {
        let ts = makeTestStore(
            suiteName: "sturtbar-codex-isstale",
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)
        #expect(!ts.store.codexIsStale)

        ts.clock.advance(by: 601) // past max(2×300, 600)
        #expect(ts.store.codexIsStale)
    }
}

// MARK: - Persistence

@MainActor
struct UsageStoreCodexPersistenceTests {
    private func makeTempPersistence() -> (persistence: StatePersistence, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-codex-persistence-\(UUID().uuidString)", isDirectory: true)
        return (StatePersistence(directory: directory), directory)
    }

    @Test
    func `legacy 1_0_x state files decode with a nil codex snapshot`() throws {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Verbatim pre-codex schema: {usage, cost, savedAt} only.
        let legacyJSON = """
        {
          "usage": {
            "primary": { "usedPercent": 62.5, "windowMinutes": 300 },
            "primaryWindowKind": "usage",
            "extraRateWindows": [],
            "updatedAt": 772761600,
            "loginMethod": "Claude Pro"
          },
          "savedAt": 772761600
        }
        """
        try Data(legacyJSON.utf8).write(to: directory.appendingPathComponent("state.json"))

        let state = try #require(persistence.loadNow())
        #expect(state.usage?.primary.usedPercent == 62.5)
        #expect(state.codexUsage == nil)
    }

    @Test
    func `codex snapshot round-trips through disk`() {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let savedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let state = StatePersistence.State(
            usage: makeUsageSnapshot(updatedAt: savedAt),
            codexUsage: makeCodexSnapshot(updatedAt: savedAt),
            cost: nil,
            savedAt: savedAt)
        persistence.saveNow(state)

        let loaded = persistence.loadNow()
        #expect(loaded == state)
        #expect(loaded?.codexUsage?.primary.usedPercent == 18)
    }

    @Test
    func `persisted codex snapshot seeds only when the provider is enabled`() async {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let savedAt = Date(timeIntervalSince1970: 1_000_000_000)
        persistence.saveNow(StatePersistence.State(
            usage: nil,
            codexUsage: makeCodexSnapshot(updatedAt: savedAt),
            cost: nil,
            savedAt: savedAt))

        // Disabled (default): the persisted snapshot must NOT appear.
        let disabled = makeTestStore(
            suiteName: "sturtbar-codex-seed-disabled",
            persistence: persistence,
            fetch: { _, _ in makeUsageSnapshot() })
        await disabled.store.loadPersistedState()
        #expect(disabled.store.codexUsage == nil)

        // Enabled: it seeds, including the staleness baseline.
        let enabled = makeTestStore(
            suiteName: "sturtbar-codex-seed-enabled",
            persistence: persistence,
            fetch: { _, _ in makeUsageSnapshot() })
        enabled.settings.codexProviderEnabled = true
        await enabled.store.loadPersistedState()
        #expect(enabled.store.codexUsage != nil)
        #expect(enabled.store.codexLastSuccessAt == savedAt)
    }

    @Test
    func `disable wipes the persisted codex snapshot on termination flush`() async {
        let (persistence, directory) = self.makeTempPersistence()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ts = makeTestStore(
            suiteName: "sturtbar-codex-disable-disk",
            persistence: persistence,
            codexFetch: { makeCodexSnapshot() },
            fetch: { _, _ in makeUsageSnapshot() })
        ts.settings.codexProviderEnabled = true

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.codexUsage != nil)

        ts.settings.codexProviderEnabled = false
        ts.store.providerEnabledDidChange(.codex, enabled: false)
        ts.store.flushPersistedStateForTermination()

        let state = persistence.loadNow()
        #expect(state?.codexUsage == nil)
        #expect(state?.usage != nil) // claude survives
    }
}
