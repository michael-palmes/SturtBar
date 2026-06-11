// UsageStoreRefreshPolicyTests.swift — refresh policy: single-flight, min-gap gates, backoff,
// health/auth mapping, staleness, cost-scan kicks.

import Foundation
import Synchronization
import Testing
@testable import SturtBar
@testable import SturtBarCore

// MARK: - Scripted fetch results

/// Sequential fetch results; the last entry repeats once the script is exhausted.
final class FetchScript: Sendable {
    private let mutex: Mutex<[Result<ClaudeUsageSnapshot, ClaudeUsageError>]>

    init(_ results: [Result<ClaudeUsageSnapshot, ClaudeUsageError>]) {
        precondition(!results.isEmpty)
        self.mutex = Mutex(results)
    }

    func next() throws -> ClaudeUsageSnapshot {
        let result = self.mutex.withLock { script -> Result<ClaudeUsageSnapshot, ClaudeUsageError> in
            script.count > 1 ? script.removeFirst() : script[0]
        }
        return try result.get()
    }
}

// MARK: - Single-flight + trigger semantics

@MainActor
struct UsageStoreSingleFlightTests {
    @Test
    func `concurrent refresh joins the in-flight run`() async {
        let started = TestLatch()
        let release = TestLatch()
        let ts = makeTestStore(suiteName: "sturtbar-tests-join") { _, _ in
            await started.open()
            await release.wait()
            return makeUsageSnapshot()
        }

        let first = Task { await ts.store.refresh(trigger: .interval) }
        await started.wait()
        #expect(ts.store.isRefreshing)
        // .launch has no min-gap: if it failed to join it would run a second fetch.
        let second = Task { await ts.store.refresh(trigger: .launch) }
        for _ in 0..<50 {
            await Task.yield()
        }
        await release.open()
        await first.value
        await second.value

        #expect(await ts.recorder.fetchCount == 1)
        #expect(ts.store.usage != nil)
        #expect(!ts.store.isRefreshing)
    }

    @Test
    func `manual awaits the in-flight run then runs once more as user-initiated`() async {
        let started = TestLatch()
        let release = TestLatch()
        let ts = makeTestStore(suiteName: "sturtbar-tests-manual-rerun") { _, _ in
            await started.open()
            await release.wait()
            return makeUsageSnapshot()
        }

        let first = Task { await ts.store.refresh(trigger: .interval) }
        await started.wait()
        let second = Task { await ts.store.refresh(trigger: .manual) }
        for _ in 0..<50 {
            await Task.yield()
        }
        await release.open()
        await first.value
        await second.value

        let fetches = await ts.recorder.fetches
        #expect(fetches.count == 2)
        #expect(fetches[0].interaction == .background)
        #expect(fetches[1].interaction == .userInitiated)
    }

    @Test
    func `triggers map to the documented interaction and phase`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-mapping") { _, _ in makeUsageSnapshot() }

        await ts.store.refresh(trigger: .launch)
        ts.clock.advance(by: 10000)
        await ts.store.refresh(trigger: .interval)
        ts.clock.advance(by: 10000)
        await ts.store.refresh(trigger: .wake)
        ts.clock.advance(by: 10000)
        await ts.store.refresh(trigger: .menuOpen)
        ts.clock.advance(by: 10000)
        await ts.store.refresh(trigger: .manual)

        let fetches = await ts.recorder.fetches
        #expect(fetches == [
            RecordedFetch(interaction: .background, phase: .startup),
            RecordedFetch(interaction: .background, phase: .regular),
            RecordedFetch(interaction: .background, phase: .regular),
            RecordedFetch(interaction: .userInitiated, phase: .regular),
            RecordedFetch(interaction: .userInitiated, phase: .regular),
        ])
    }
}

// MARK: - Min-gap gates

@MainActor
struct UsageStoreMinGapTests {
    @Test
    func `menuOpen is gated for 30s after a success`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-menugap") { _, _ in makeUsageSnapshot() }

        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 10)
        await ts.store.refresh(trigger: .menuOpen)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 21)
        await ts.store.refresh(trigger: .menuOpen)
        #expect(await ts.recorder.fetchCount == 2)
    }

    @Test
    func `interval and wake are gated for half the refresh interval`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-intervalgap") { _, _ in makeUsageSnapshot() }
        ts.settings.refreshFrequency = .fiveMinutes

        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 60)
        await ts.store.refresh(trigger: .interval)
        await ts.store.refresh(trigger: .wake)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 91) // 151s > 150s
        await ts.store.refresh(trigger: .interval)
        #expect(await ts.recorder.fetchCount == 2)
    }

    @Test
    func `manual and launch have no min-gap`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-nogap") { _, _ in makeUsageSnapshot() }

        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .launch)
        #expect(await ts.recorder.fetchCount == 3)
    }

    @Test
    func `persisted snapshot seeds the menuOpen min-gap baseline`() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-tests-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = StatePersistence(directory: directory)
        let clock = TestClock()
        persistence.saveNow(StatePersistence.State(
            usage: makeUsageSnapshot(updatedAt: clock.now),
            cost: nil,
            savedAt: clock.now))

        let ts = makeTestStore(
            suiteName: "sturtbar-tests-seed",
            clock: clock,
            persistence: persistence)
        { _, _ in makeUsageSnapshot() }

        await ts.store.loadPersistedState()
        #expect(ts.store.usage != nil)

        ts.clock.advance(by: 10)
        await ts.store.refresh(trigger: .menuOpen)
        #expect(await ts.recorder.fetchCount == 0) // snapshot is 10s old — gated

        ts.clock.advance(by: 25)
        await ts.store.refresh(trigger: .menuOpen)
        #expect(await ts.recorder.fetchCount == 1)
    }
}

// MARK: - Backoff

@MainActor
struct UsageStoreBackoffTests {
    @Test
    func `auto triggers back off exponentially after failures and manual bypasses`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-backoff") { _, _ in
            throw ClaudeUsageError.fetch(.serverError(503, nil))
        }
        ts.settings.refreshFrequency = .fiveMinutes

        await ts.store.refresh(trigger: .manual) // streak 1, lastAttempt = T0
        #expect(await ts.recorder.fetchCount == 1)
        #expect(ts.store.failureStreak == 1)

        ts.clock.advance(by: 301) // backoff requires 300 × 2^1 = 600s
        await ts.store.refresh(trigger: .interval)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 300) // 601s since attempt
        await ts.store.refresh(trigger: .interval)
        #expect(await ts.recorder.fetchCount == 2)
        #expect(ts.store.failureStreak == 2)

        ts.clock.advance(by: 700) // backoff now 1200s; 700 < 1200
        await ts.store.refresh(trigger: .interval)
        #expect(await ts.recorder.fetchCount == 2)

        // Manual bypasses backoff.
        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.fetchCount == 3)

        // menuOpen also bypasses backoff (no success yet, so no min-gap either).
        await ts.store.refresh(trigger: .menuOpen)
        #expect(await ts.recorder.fetchCount == 4)
    }

    @Test
    func `backoff caps at 30 minutes`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-backoffcap") { _, _ in
            throw ClaudeUsageError.fetch(.networkError(URLError(.notConnectedToInternet)))
        }
        ts.settings.refreshFrequency = .thirtyMinutes // 1800 × 2^streak would exceed the cap

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.failureStreak == 1)

        ts.clock.advance(by: 1801) // > 30 min cap (despite 1800 × 2 = 3600 uncapped)
        await ts.store.refresh(trigger: .wake)
        #expect(await ts.recorder.fetchCount == 2)
    }

    @Test
    func `success resets the failure streak`() async {
        let script = FetchScript([
            .failure(.fetch(.serverError(500, nil))),
            .success(makeUsageSnapshot()),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-tests-streakreset") { _, _ in try script.next() }
        ts.settings.refreshFrequency = .fiveMinutes

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.failureStreak == 1)

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.failureStreak == 0)
        #expect(ts.store.health == .ok)
        #expect(ts.store.auth == .ok)
    }
}

// MARK: - Rate limit gate

@MainActor
struct UsageStoreRateLimitTests {
    @Test
    func `rate limited blocks all triggers until the until-date passes`() async {
        let clock = TestClock()
        let until = clock.now.addingTimeInterval(120)
        let script = FetchScript([
            .failure(.fetch(.rateLimited(retryAfter: until))),
            .success(makeUsageSnapshot()),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-tests-ratelimit", clock: clock) { _, _ in
            try script.next()
        }

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .rateLimited(until: until))
        #expect(ts.store.failureStreak == 0) // the until-date is the gate, not the streak

        ts.clock.advance(by: 60)
        await ts.store.refresh(trigger: .manual)
        await ts.store.refresh(trigger: .interval)
        await ts.store.refresh(trigger: .launch)
        #expect(await ts.recorder.fetchCount == 1)

        ts.clock.advance(by: 61) // past `until`
        await ts.store.refresh(trigger: .manual)
        #expect(await ts.recorder.fetchCount == 2)
        #expect(ts.store.health == .ok)
    }
}

// MARK: - Health / auth mapping

@MainActor
struct UsageStoreHealthMappingTests {
    private func storeFailing(
        _ suite: String,
        error: ClaudeUsageError,
        blockStatus: @escaping @Sendable () -> ClaudeOAuthRefreshFailureGate.BlockStatus? = { nil }) -> TestStore
    {
        makeTestStore(suiteName: suite, blockStatus: blockStatus) { _, _ in throw error }
    }

    @Test
    func `server network and invalid-response errors map to degraded`() async {
        for (index, error) in [
            ClaudeUsageError.fetch(.serverError(500, "boom")),
            .fetch(.networkError(URLError(.timedOut))),
            .fetch(.invalidResponse),
        ].enumerated() {
            let ts = self.storeFailing("sturtbar-tests-degraded-\(index)", error: error)
            await ts.store.refresh(trigger: .manual)
            #expect(ts.store.health == .degraded(until: nil))
            #expect(ts.store.auth == .ok) // auth untouched by non-auth failures
            #expect(ts.store.failureStreak == 1)
        }
    }

    @Test
    func `transient and suppressed refresh failures map to degraded with the gate until-date`() async {
        let until = Date(timeIntervalSince1970: 2_000_000_000)
        let ts = self.storeFailing(
            "sturtbar-tests-degraded-transient",
            error: .credentials(.refreshFailed(kind: .transient, message: "token endpoint 503")),
            blockStatus: { .transient(until: until, failures: 1) })
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .degraded(until: until))
        #expect(ts.store.auth == .ok)

        let suppressed = self.storeFailing(
            "sturtbar-tests-degraded-suppressed",
            error: .credentials(.refreshFailed(kind: .suppressed, message: "gate active")))
        await suppressed.store.refresh(trigger: .manual)
        #expect(suppressed.store.health == .degraded(until: nil))
    }

    @Test
    func `credentials-missing errors map to credentialsMissing`() async {
        for (index, error) in [
            ClaudeUsageError.credentials(.notFound),
            .credentials(.missingOAuth),
            .credentials(.missingAccessToken),
            .credentials(.decodeFailed),
        ].enumerated() {
            let ts = self.storeFailing("sturtbar-tests-credmissing-\(index)", error: error)
            await ts.store.refresh(trigger: .manual)
            #expect(ts.store.auth == .credentialsMissing)
        }
    }

    @Test
    func `auth-required errors map to needsReauth`() async {
        for (index, error) in [
            ClaudeUsageError.scopeUnsatisfied(message: "missing user:profile"),
            .credentials(.noRefreshToken),
            .credentials(.refreshFailed(kind: .terminal, message: "invalid_grant")),
        ].enumerated() {
            let ts = self.storeFailing("sturtbar-tests-reauth-\(index)", error: error)
            await ts.store.refresh(trigger: .manual)
            guard case .needsReauth = ts.store.auth else {
                Issue.record("expected needsReauth for \(error), got \(ts.store.auth)")
                continue
            }
        }
    }

    @Test
    func `gate terminal block maps to needsReauth even for non-auth errors`() async {
        let ts = self.storeFailing(
            "sturtbar-tests-gate-terminal",
            error: .fetch(.networkError(URLError(.timedOut))),
            blockStatus: { .terminal(reason: "invalid_grant", failures: 3) })
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.auth == .needsReauth(message: "invalid_grant"))
        #expect(ts.store.health == .degraded(until: nil))
    }

    @Test
    func `auth is sticky across unrelated failures and resets on success`() async {
        let script = FetchScript([
            .failure(.credentials(.refreshFailed(kind: .terminal, message: "invalid_grant"))),
            .failure(.fetch(.networkError(URLError(.timedOut)))),
            .success(makeUsageSnapshot()),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-tests-authsticky") { _, _ in try script.next() }

        await ts.store.refresh(trigger: .manual)
        guard case .needsReauth = ts.store.auth else {
            Issue.record("expected needsReauth, got \(ts.store.auth)")
            return
        }

        await ts.store.refresh(trigger: .manual)
        guard case .needsReauth = ts.store.auth else {
            Issue.record("needsReauth must survive a network blip, got \(ts.store.auth)")
            return
        }

        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.auth == .ok)
        #expect(ts.store.health == .ok)
        #expect(ts.store.usage != nil)
    }
}

// MARK: - Staleness

@MainActor
struct UsageStoreStalenessTests {
    @Test
    func `isStale uses max of twice the interval and 10 minutes`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-stale") { _, _ in makeUsageSnapshot() }
        ts.settings.refreshFrequency = .fiveMinutes

        #expect(!ts.store.isStale) // no data yet

        await ts.store.refresh(trigger: .manual)
        #expect(!ts.store.isStale)

        ts.clock.advance(by: 599)
        #expect(!ts.store.isStale)

        ts.clock.advance(by: 2) // 601s > 600s
        #expect(ts.store.isStale)
    }

    @Test
    func `one-minute interval uses the 10 minute floor`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-stale-floor") { _, _ in makeUsageSnapshot() }
        ts.settings.refreshFrequency = .oneMinute

        await ts.store.refresh(trigger: .manual)
        ts.clock.advance(by: 130) // > 2×60s but < 600s floor
        #expect(!ts.store.isStale)
        ts.clock.advance(by: 480) // 610s
        #expect(ts.store.isStale)
    }

    @Test
    func `manual cadence uses a 60 minute staleness window`() async {
        let ts = makeTestStore(suiteName: "sturtbar-tests-stale-manual") { _, _ in makeUsageSnapshot() }
        ts.settings.refreshFrequency = .manual

        await ts.store.refresh(trigger: .manual)
        ts.clock.advance(by: 3599)
        #expect(!ts.store.isStale)
        ts.clock.advance(by: 2)
        #expect(ts.store.isStale)
    }
}

// MARK: - Cost scan kicks

@MainActor
struct UsageStoreCostScanTests {
    /// Polls until `costScanState == .idle` (wall-clock bounded; ~200×5ms = ~1s max).
    private func waitForCostScanIdle(_ store: UsageStore) async {
        for _ in 0..<200 {
            if store.costScanState == .idle { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("cost scan never settled")
    }

    private func makeRecordingScanner(_ recorder: CallRecorder) -> CostScanner {
        CostScanner(minimumGap: 60, scanOperation: { _, bypassGate, historyDays in
            await recorder.recordScan(bypassGate: bypassGate, historyDays: historyDays)
            return makeCostSnapshot()
        })
    }

    @Test
    func `menuOpen kicks a gated cost scan concurrent with the usage fetch`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-tests-cost-menuopen",
            scanner: self.makeRecordingScanner(recorder))
        { _, _ in makeUsageSnapshot() }

        await ts.store.refresh(trigger: .menuOpen)
        await self.waitForCostScanIdle(ts.store)

        let scans = await recorder.scans
        #expect(scans.count == 1)
        #expect(scans[0].bypassGate == false)
        #expect(ts.store.cost != nil)
    }

    @Test
    func `manual kicks a gate-bypassing cost scan`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-tests-cost-manual",
            scanner: self.makeRecordingScanner(recorder))
        { _, _ in makeUsageSnapshot() }

        await ts.store.refresh(trigger: .manual)
        await self.waitForCostScanIdle(ts.store)

        let scans = await recorder.scans
        #expect(scans.count == 1)
        #expect(scans[0].bypassGate == true)
    }

    @Test
    func `interval and launch do not kick cost scans`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-tests-cost-interval",
            scanner: self.makeRecordingScanner(recorder))
        { _, _ in makeUsageSnapshot() }

        await ts.store.refresh(trigger: .launch)
        ts.clock.advance(by: 10000)
        await ts.store.refresh(trigger: .interval)
        ts.clock.advance(by: 10000)
        await ts.store.refresh(trigger: .wake)
        await self.waitForCostScanIdle(ts.store)

        #expect(await recorder.scanCount == 0)
        #expect(ts.store.costScanState == .idle)
    }

    @Test
    func `cost scans honor the costUsageEnabled setting`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-tests-cost-disabled",
            scanner: self.makeRecordingScanner(recorder))
        { _, _ in makeUsageSnapshot() }
        ts.settings.costUsageEnabled = false

        await ts.store.refresh(trigger: .manual)
        await self.waitForCostScanIdle(ts.store)

        #expect(await recorder.scanCount == 0)
        #expect(ts.store.cost == nil)
    }

    @Test
    func `cost setting change rescans and disabling clears the snapshot`() async {
        let recorder = CallRecorder()
        let ts = makeTestStore(
            suiteName: "sturtbar-tests-cost-setting",
            scanner: self.makeRecordingScanner(recorder))
        { _, _ in makeUsageSnapshot() }

        ts.store.costSettingsDidChange()
        await self.waitForCostScanIdle(ts.store)
        #expect(await recorder.scanCount == 1)
        #expect(ts.store.cost != nil)

        ts.settings.costUsageEnabled = false
        ts.store.costSettingsDidChange()
        await self.waitForCostScanIdle(ts.store)
        #expect(await recorder.scanCount == 1)
        #expect(ts.store.cost == nil)
    }

    // MARK: Cost-disable race

    @Test
    func `disable mid-scan — scan completion does not republish cost`() async {
        // A scan that takes time finishes AFTER cost is disabled: the completion arm must
        // detect the disabled state and discard the result.
        let scanStarted = TestLatch()
        let releaseScan = TestLatch()
        let scanner = CostScanner(minimumGap: 0, scanOperation: { _, _, _ in
            await scanStarted.open()
            await releaseScan.wait()
            return makeCostSnapshot()
        })
        let ts = makeTestStore(suiteName: "sturtbar-tests-cost-race", scanner: scanner) { _, _ in
            makeUsageSnapshot()
        }

        // Kick the scan (enabled by default).
        ts.store.costSettingsDidChange()
        await scanStarted.wait()
        #expect(ts.store.costScanState == .scanning)

        // Disable while scan is still in-flight, then release the scan.
        ts.settings.costUsageEnabled = false
        ts.store.costSettingsDidChange()
        await releaseScan.open()

        // Wait for the scan slot to drain.
        await self.waitForCostScanIdle(ts.store)

        // The completion arm must have seen the disabled flag and not stored the result.
        #expect(ts.store.cost == nil)
    }

    @Test
    func `loadPersistedState does not seed cost when costUsageEnabled is false`() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-tests-cost-seed-disabled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = StatePersistence(directory: directory)
        let clock = TestClock()
        // Pre-persist a state that includes a cost snapshot.
        persistence.saveNow(StatePersistence.State(
            usage: makeUsageSnapshot(updatedAt: clock.now),
            cost: makeCostSnapshot(updatedAt: clock.now),
            savedAt: clock.now))

        let ts = makeTestStore(
            suiteName: "sturtbar-tests-cost-seed-disabled",
            clock: clock,
            persistence: persistence)
        { _, _ in makeUsageSnapshot() }

        // Disable cost before loading persisted state.
        ts.settings.costUsageEnabled = false
        await ts.store.loadPersistedState()

        // Usage should be seeded; cost must NOT be seeded.
        #expect(ts.store.usage != nil)
        #expect(ts.store.cost == nil)
    }
}

// MARK: - Equality-gate snapshot assignments

@MainActor
struct UsageStoreEqualityGateTests {
    @Test
    func `identical fetch results do not fire usage observation`() async {
        // Confirm the equality gate: when the incoming snapshot equals the stored one, the
        // `self.usage` assignment is skipped entirely, so Observation does not notify watchers.
        let snapshot = makeUsageSnapshot(primaryUsedPercent: 42)
        let ts = makeTestStore(suiteName: "sturtbar-tests-eq-gate") { _, _ in snapshot }

        // First fetch — populates self.usage.
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.usage == snapshot)

        // Install an observation tracking closure BEFORE the second fetch.
        // withObservationTracking fires onChange exactly once when any tracked property changes;
        // if it is never called the closure is simply not invoked.
        // Mutex because the onChange closure is @Sendable.
        let fired = Mutex(false)
        withObservationTracking {
            // Access the property so the framework tracks it.
            _ = ts.store.usage
        } onChange: {
            fired.withLock { $0 = true }
        }

        // Second fetch with an identical snapshot — equality gate must suppress the assignment.
        await ts.store.refresh(trigger: .manual)

        // Give the run-loop a cycle; onChange fires synchronously but let's be safe.
        await Task.yield()

        #expect(!fired.withLock { $0 }, "equality gate must not fire observation for an identical snapshot")
    }
}

// MARK: - Missing health-mapping cases

@MainActor
struct UsageStoreHealthMappingMissingTests {
    private func storeFailing(
        _ suite: String,
        error: ClaudeUsageError) -> TestStore
    {
        makeTestStore(suiteName: suite) { _, _ in throw error }
    }

    @Test
    func `parseFailed maps to degraded and auth is not downgraded`() async {
        let ts = self.storeFailing(
            "sturtbar-tests-parsefailed",
            error: .parseFailed("unexpected JSON shape"))
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .degraded(until: nil))
        #expect(ts.store.auth == .ok)
        #expect(ts.store.failureStreak == 1)
    }

    @Test
    func `oauthFailed maps to degraded and auth is not downgraded`() async {
        let ts = self.storeFailing(
            "sturtbar-tests-oauthfailed",
            error: .oauthFailed("token endpoint unreachable"))
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .degraded(until: nil))
        #expect(ts.store.auth == .ok)
        #expect(ts.store.failureStreak == 1)
    }

    @Test
    func `fetch unauthorized maps to degraded and auth is not downgraded`() async {
        // .fetch(.unauthorized) is NOT indicatesAuthenticationRequired (that's .scopeUnsatisfied /
        // .credentials(.refreshFailed(terminal)) / .credentials(.noRefreshToken)); it is a raw
        // HTTP 401 that didn't trigger a token refresh, so it maps to degraded.
        let ts = self.storeFailing(
            "sturtbar-tests-fetch-unauthorized",
            error: .fetch(.unauthorized))
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .degraded(until: nil))
        #expect(ts.store.auth == .ok)
        #expect(ts.store.failureStreak == 1)
    }

    @Test
    func `credentials keychainError maps to degraded and auth is not downgraded`() async {
        let ts = self.storeFailing(
            "sturtbar-tests-keychain-error",
            error: .credentials(.keychainError(-25300)))
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .degraded(until: nil))
        #expect(ts.store.auth == .ok)
        #expect(ts.store.failureStreak == 1)
    }

    @Test
    func `credentials readFailed maps to degraded and auth is not downgraded`() async {
        let ts = self.storeFailing(
            "sturtbar-tests-read-failed",
            error: .credentials(.readFailed("file not readable")))
        await ts.store.refresh(trigger: .manual)
        #expect(ts.store.health == .degraded(until: nil))
        #expect(ts.store.auth == .ok)
        #expect(ts.store.failureStreak == 1)
    }
}
