// IconStateTests.swift — IconState derivation + StatusItemController observation loop (Phase 3b).
//
// Derivation: quantization, auth/stale/missing-creds mapping, display text, renderer-key folding.
// Loop: coalescing (N mutations → 1 render), reliable re-arm (sequential distinct states all
// render, including after an equality-skip), and the deliberate IconState exclusions
// (isMenuOpen / isRefreshing churn must not redraw).

import Foundation
import Synchronization
import Testing
@testable import SturtBar
@testable import SturtBarCore

// MARK: - Derivation

@MainActor
struct IconStateDerivationTests {
    @Test
    func `buckets quantize to whole points`() {
        #expect(IconState.bucket(52.4) == 52)
        #expect(IconState.bucket(52.6) == 53)
        #expect(IconState.bucket(0) == 0)
        #expect(IconState.bucket(-3) == 0)
        #expect(IconState.bucket(250) == 100)
    }

    @Test
    func `derives buckets from the snapshot remaining percentages`() async {
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-buckets") { _, _ in
            makeUsageSnapshot(primaryUsedPercent: 47.6, secondaryUsedPercent: 80)
        }
        await ts.store.refresh(trigger: .manual)

        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == 52) // 52.4% remaining → 52
        #expect(state.secondaryBucket == 20)
        #expect(!state.isStale)
        #expect(!state.needsAuth)
        #expect(!state.credentialsMissing)
        #expect(state.displayText == nil) // default mode .hidden
    }

    @Test
    func `usageBarsShowUsed fills the glyph buckets by consumption`() async {
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-used") { _, _ in
            makeUsageSnapshot(primaryUsedPercent: 47.6, secondaryUsedPercent: 80)
        }
        await ts.store.refresh(trigger: .manual)

        ts.settings.usageBarsShowUsed = true
        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == 48) // 47.6% used → 48
        #expect(state.secondaryBucket == 80)
    }

    @Test
    func `sub point usage moves derive equal states`() async {
        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 47.6)),
            .success(makeUsageSnapshot(primaryUsedPercent: 47.8)),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-subpoint") { _, _ in try script.next() }

        await ts.store.refresh(trigger: .manual)
        let first = IconState.derive(store: ts.store, settings: ts.settings)
        await ts.store.refresh(trigger: .manual)
        let second = IconState.derive(store: ts.store, settings: ts.settings)

        #expect(ts.store.usage?.primary.usedPercent == 47.8) // the snapshot did change…
        #expect(first == second) // …but the icon state must not
    }

    @Test
    func `missing snapshot derives empty buckets`() {
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-empty") { _, _ in makeUsageSnapshot() }
        let state = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(state.primaryBucket == nil)
        #expect(state.secondaryBucket == nil)
        #expect(!state.isStale)
    }

    @Test
    func `auth failures map to needsAuth and credentialsMissing`() async {
        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 40)),
            .failure(.credentials(.notFound)),
            .failure(.scopeUnsatisfied(message: "missing scope")),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-auth") { _, _ in try script.next() }

        await ts.store.refresh(trigger: .manual)
        #expect(!IconState.derive(store: ts.store, settings: ts.settings).credentialsMissing)

        await ts.store.refresh(trigger: .manual)
        let missing = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(missing.credentialsMissing)
        #expect(!missing.needsAuth)
        #expect(missing.primaryBucket == 60) // last good usage stays visible

        await ts.store.refresh(trigger: .manual)
        let reauth = IconState.derive(store: ts.store, settings: ts.settings)
        #expect(reauth.needsAuth)
        #expect(!reauth.credentialsMissing)
    }

    @Test
    func `staleness flips the stale flag`() async {
        let clock = TestClock()
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-stale", clock: clock) { _, _ in
            makeUsageSnapshot()
        }
        await ts.store.refresh(trigger: .manual)
        #expect(!IconState.derive(store: ts.store, settings: ts.settings).isStale)

        clock.advance(by: 2 * 3600) // way past max(2×interval, 10 min)
        #expect(IconState.derive(store: ts.store, settings: ts.settings).isStale)
    }

    @Test
    func `display text follows the settings mode`() async {
        let ts = makeTestStore(suiteName: "sturtbar-iconstate-text") { _, _ in
            makeUsageSnapshot(primaryUsedPercent: 47.6)
        }
        await ts.store.refresh(trigger: .manual)

        ts.settings.menuBarDisplayMode = .percent
        #expect(IconState.derive(store: ts.store, settings: ts.settings).displayText == "52%")

        ts.settings.menuBarDisplayMode = .hidden
        #expect(IconState.derive(store: ts.store, settings: ts.settings).displayText == nil)
    }

    @Test
    func `renderer key folds auth and staleness into dimmed`() {
        var state = IconState(
            primaryBucket: 52,
            secondaryBucket: nil,
            isStale: false,
            needsAuth: false,
            credentialsMissing: false,
            displayText: nil)
        #expect(!state.rendererKey.dimmed)

        state.isStale = true
        #expect(state.rendererKey.dimmed)

        state.isStale = false
        state.needsAuth = true
        #expect(state.rendererKey.dimmed)

        state.needsAuth = false
        state.credentialsMissing = true
        #expect(state.rendererKey.dimmed)

        // The key never contains the display text: text changes must not bust the image cache.
        state.displayText = "52%"
        #expect(state.rendererKey == IconRenderer.Key(
            primaryBucket: 52,
            secondaryBucket: nil,
            dimmed: true))
    }
}

// MARK: - Observation loop

/// MainActor-confined recorder — shared by observation and deadline test suites.
@MainActor
final class AppliedStates {
    private(set) var states: [IconState] = []
    func record(_ state: IconState) {
        self.states.append(state)
    }

    var count: Int {
        self.states.count
    }
}

@MainActor
struct StatusItemControllerObservationTests {
    private func makeLoop(
        suiteName: String,
        script: FetchScript) -> (ts: TestStore, controller: StatusItemController, applied: AppliedStates)
    {
        let ts = makeTestStore(suiteName: suiteName) { _, _ in try script.next() }
        let controller = StatusItemController(store: ts.store, settings: ts.settings)
        let applied = AppliedStates()
        controller.onIconApplied = { applied.record($0) }
        controller.startWithoutStatusItemForTesting()
        return (ts, controller, applied)
    }

    /// Polls until `applied.count >= count` (wall-clock bounded; ~200×5ms = ~1s max).
    private func waitForApplied(_ applied: AppliedStates, count: Int) async {
        for _ in 0..<200 {
            if applied.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test
    func `initial arm renders once and refresh coalesces its mutations into one more render`() async {
        let (ts, controller, applied) = self.makeLoop(
            suiteName: "sturtbar-loop-coalesce",
            script: FetchScript([.success(makeUsageSnapshot(primaryUsedPercent: 47.6))]))
        defer { controller.shutdown() }

        #expect(applied.count == 1) // initial state applied synchronously at start
        #expect(applied.states[0].primaryBucket == nil)

        // One refresh mutates usage + auth + health + lastSuccessAt in a single MainActor job;
        // the loop must coalesce that into exactly one extra render.
        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)

        #expect(applied.count == 2)
        #expect(applied.states[1].primaryBucket == 52)
    }

    @Test
    func `two sequential distinct states both render`() async {
        let (ts, controller, applied) = self.makeLoop(
            suiteName: "sturtbar-loop-sequential",
            script: FetchScript([
                .success(makeUsageSnapshot(primaryUsedPercent: 40)),
                .success(makeUsageSnapshot(primaryUsedPercent: 70)),
            ]))
        defer { controller.shutdown() }

        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)
        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 3)

        #expect(applied.states.map(\.primaryBucket) == [nil, 60, 30])
    }

    @Test
    func `re-arm survives equality-skipped updates`() async {
        let (ts, controller, applied) = self.makeLoop(
            suiteName: "sturtbar-loop-rearm-after-skip",
            script: FetchScript([
                .success(makeUsageSnapshot(primaryUsedPercent: 47.6)),
                .success(makeUsageSnapshot(primaryUsedPercent: 47.8)), // same bucket → skip
                .success(makeUsageSnapshot(primaryUsedPercent: 60)), // new bucket → render
            ]))
        defer { controller.shutdown() }

        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)
        #expect(applied.count == 2)

        // Sub-point move: the loop wakes (usage changed), derives an equal state, skips the
        // render — and must still re-arm.
        await ts.store.refresh(trigger: .manual)
        for _ in 0..<200 {
            await Task.yield()
        }
        #expect(applied.count == 2)

        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 3)
        #expect(applied.states.last?.primaryBucket == 40)
    }

    @Test
    func `excluded volatile state does not redraw`() async {
        let (ts, controller, applied) = self.makeLoop(
            suiteName: "sturtbar-loop-excluded",
            script: FetchScript([
                .success(makeUsageSnapshot(primaryUsedPercent: 40)),
                .success(makeUsageSnapshot(primaryUsedPercent: 70)),
            ]))
        defer { controller.shutdown() }

        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)

        // isMenuOpen is observable but deliberately excluded from IconState: flips must not
        // wake the loop at all, let alone render.
        ts.store.isMenuOpen = true
        ts.store.isMenuOpen = false
        for _ in 0..<200 {
            await Task.yield()
        }
        #expect(applied.count == 2)

        // The loop must still be armed afterwards.
        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 3)
        #expect(applied.states.last?.primaryBucket == 30)
    }

    @Test
    func `settings changes drive renders too`() async {
        let (ts, controller, applied) = self.makeLoop(
            suiteName: "sturtbar-loop-settings",
            script: FetchScript([.success(makeUsageSnapshot(primaryUsedPercent: 47.6))]))
        defer { controller.shutdown() }

        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)

        ts.settings.menuBarDisplayMode = .percent
        await self.waitForApplied(applied, count: 3)
        #expect(applied.states.last?.displayText == "52%")
    }
}

// MARK: - Staleness deadline re-render

/// Tests for the one-shot deadline task that fires when the icon needs to flip to stale even
/// when no Observable-tracked property mutates (e.g. a failure streak leaves lastAttemptAt /
/// health untracked, so the observation loop never wakes on its own).
@MainActor
struct StatusItemControllerStalenessDeadlineTests {
    /// Builds a controller with an instant-release `deadlineSleep` seam: the sleep closure
    /// resolves as soon as the test signals the latch, allowing precise control over timing.
    private func makeLoop(
        suiteName: String,
        clock: TestClock,
        script: FetchScript,
        sleepLatch: TestLatch) -> (ts: TestStore, controller: StatusItemController, applied: AppliedStates)
    {
        let ts = makeTestStore(suiteName: suiteName, clock: clock) { _, _ in try script.next() }
        let controller = StatusItemController(store: ts.store, settings: ts.settings)
        let applied = AppliedStates()
        controller.onIconApplied = { applied.record($0) }
        // Replace the real ContinuousClock sleep with a latch-controlled instant release.
        // The closure ignores the duration and just waits for the test to signal readiness.
        controller.deadlineSleep = { _ in
            await sleepLatch.wait()
        }
        controller.startWithoutStatusItemForTesting()
        return (ts, controller, applied)
    }

    /// Polls until `applied.count >= count` (wall-clock bounded; ~200×5ms = ~1s max).
    private func waitForApplied(_ applied: AppliedStates, count: Int) async {
        for _ in 0..<200 {
            if applied.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Fix 1 verification: after a successful fetch followed by a non-auth failure (which changes
    /// `health` — observable but excluded from IconState — and leaves `lastAttemptAt`/`failureStreak`
    /// untracked), the icon stays bright. The deadline task fires → armAndRender re-derives →
    /// icon flips to isStale=true/dimmed without the icon state changing for any other reason.
    ///
    /// Uses `.parseFailed` which does NOT set needsReauth/credentialsMissing — only `health`
    /// transitions to `.degraded`. Health is observable (arm fires on failure) but is not read
    /// by `IconState.derive`, so the failure-triggered re-arm produces an equal state (skipped
    /// render) while the deadline task is the sole path that delivers the stale flip.
    @Test
    func `deadline task fires and icon re-derives to stale without auth state change`() async {
        let clock = TestClock()
        let sleepLatch = TestLatch()
        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 40)),
            .failure(.parseFailed("network blip")),
        ])
        let (ts, controller, applied) = self.makeLoop(
            suiteName: "sturtbar-deadline-stale-flip",
            clock: clock,
            script: script,
            sleepLatch: sleepLatch)
        defer { controller.shutdown() }

        // Seed a successful fetch so the store has data and isStale starts false.
        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)
        #expect(applied.states.last?.isStale == false)
        #expect(applied.states.last?.needsAuth == false)

        // Trigger a non-auth failure — health mutates (observable, but not read in derive), so
        // the arm fires but produces an equal IconState → skipped render. Auth stays .ok.
        await ts.store.refresh(trigger: .manual)
        for _ in 0..<200 {
            await Task.yield()
        }
        let countAfterFailure = applied.count
        // Icon is still bright and unchanged from the last success render.
        #expect(applied.states.last?.isStale == false)
        #expect(applied.states.last?.needsAuth == false)

        // Advance the clock past the staleness threshold so isStale becomes true.
        // Default refreshFrequency is .fiveMinutes → threshold = max(2×300, 600) = 600 s.
        clock.advance(by: 601)

        // Release the deadline sleep — simulates the wall clock reaching the deadline.
        await sleepLatch.open()
        await self.waitForApplied(applied, count: countAfterFailure + 1)

        // The icon must now be stale/dimmed, delivered solely by the deadline task.
        #expect(applied.states.last?.isStale == true)
        #expect(applied.states.last?.primaryBucket == 60)
    }

    /// Fix 1 verification: after two renders, the controller holds at most one pending deadline
    /// task (cancel-and-replace semantics — no pile-up). Verified by counting active sleep entries:
    /// when the first task is cancelled and the second task begins its sleep, the cancelled task
    /// must exit its sleep (via cancellation propagation) so the count stays at 1.
    @Test
    func `multiple renders produce at most one live deadline task`() async {
        let clock = TestClock()
        // Count how many deadline sleeps are currently active (entered but not yet returned).
        let activeSleeps = Mutex(0)

        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 40)),
            .success(makeUsageSnapshot(primaryUsedPercent: 70)),
        ])
        let ts = makeTestStore(suiteName: "sturtbar-deadline-no-pileup", clock: clock) { _, _ in
            try script.next()
        }
        // Can't use makeLoop because we need to override deadlineSleep after construction.
        let controller = StatusItemController(store: ts.store, settings: ts.settings)
        let applied = AppliedStates()
        controller.onIconApplied = { applied.record($0) }
        // Sleep seam: counts active entries. Uses Task.sleep (a genuine cancellation point) so
        // that when the controller cancels a superseded deadline task the sleep exits immediately
        // and the active count drops back to 0 before the replacement task enters.
        controller.deadlineSleep = { _ in
            activeSleeps.withLock { $0 += 1 }
            defer { activeSleeps.withLock { $0 -= 1 } }
            // A very long sleep that cooperates with task cancellation (unlike latch.wait).
            try await Task.sleep(for: .seconds(3600))
        }
        controller.startWithoutStatusItemForTesting()
        defer { controller.shutdown() }

        // Two successful fetches → two distinct renders → deadline replaced each time.
        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 2)
        await ts.store.refresh(trigger: .manual)
        await self.waitForApplied(applied, count: 3)

        // Allow the cancelled first task's sleep to notice its cancellation and decrement.
        for _ in 0..<200 {
            if activeSleeps.withLock({ $0 }) == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        // Cancel-and-replace must leave exactly ONE active sleep, not two.
        #expect(activeSleeps.withLock { $0 } == 1)
    }
}
