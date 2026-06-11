// UsageStore.swift — MainActor app state: usage/cost snapshots, fetch health, refresh policy.
//
// Architecture (Phase 3a):
//   - ALL usage fetching goes through `ClaudeUsageClient` (serial actor) — the store never touches
//     OAuth-store sync entry points from the MainActor.
//   - The store layers refresh POLICY on top: single-flight per trigger semantics, min-gap gates,
//     failure backoff, health/auth mapping, quota-crossing events, persistence.
//   - Cost scans are on-demand only (menu open / manual / cost-setting change), run via the
//     `CostScanner` actor at utility priority, concurrent with (never sequenced after) the usage
//     fetch, with progress published through `costScanState`.
//
// Refresh policy summary:
//   triggers     .launch (.background + .startup phase), .interval/.wake (.background),
//                .menuOpen/.manual (.userInitiated)
//   single-flight one in-flight refresh; `.manual` awaits the in-flight run then runs once more
//                (a manual gesture must always produce a fresh user-initiated fetch); all other
//                triggers join the in-flight run.
//   min-gap      .menuOpen: 30s since last success; .interval/.wake: interval/2 since last
//                success; .manual/.launch: none.
//   backoff      after a failure, auto triggers (.interval/.wake) wait
//                min(interval × 2^streak, 30 min) since the last attempt. Manual/menuOpen bypass
//                backoff. The streak applies to ALL non-rate-limited failures (including auth
//                failures — retrying needs-reauth every tick wastes keychain/security-CLI work;
//                user gestures recover instantly because they bypass backoff).
//   rate limit   `.fetch(.rateLimited(retryAfter:))` gates ALL triggers (including manual) until
//                the server-provided date — hammering a 429 helps nobody, and the core-level
//                ClaudeOAuthUsageRateLimitGate would fail the attempt anyway.
//
// Health/auth mapping (typed — never string-matched):
//   .ok               ← snapshot (gates self-heal on success; the store only READS gates)
//   .rateLimited      ← .fetch(.rateLimited(retryAfter:)) (authoritative until-date)
//   .degraded(until:) ← any other failure; until = refresh-failure gate's transient block, if any
//   needsReauth       ← error.indicatesAuthenticationRequired OR gate .terminal
//   credentialsMissing← error.indicatesCredentialsMissing
//   auth is sticky across unrelated failures: a network blip never clears needs-reauth; only a
//   successful fetch resets auth to .ok.

import Foundation
import Observation
import SturtBarCore

// MARK: - State types

enum AuthState: Equatable, Sendable {
    case ok
    case needsReauth(message: String?)
    case credentialsMissing
}

enum FetchHealth: Equatable, Sendable {
    case ok
    case degraded(until: Date?)
    case rateLimited(until: Date)
}

/// Minimal by design: `ClaudeCostFetcher` swallows scan failures into a nil snapshot (cost is
/// best-effort eye candy), so a `.failed` case would be unreachable; cancellation only happens at
/// shutdown where nobody is watching.
enum CostScanState: Equatable, Sendable {
    case idle
    case scanning
}

enum RefreshTrigger: String, Sendable {
    case launch
    case interval
    case menuOpen
    case manual
    case wake

    var interaction: Interaction {
        switch self {
        case .manual, .menuOpen: .userInitiated
        case .launch, .interval, .wake: .background
        }
    }

    var phase: RefreshPhase {
        self == .launch ? .startup : .regular
    }

    /// Menu open and manual refresh also kick the (independently gated) cost scan.
    var kicksCostScan: Bool {
        self == .menuOpen || self == .manual
    }
}

// MARK: - UsageStore

@MainActor
@Observable
final class UsageStore {
    // MARK: Published state

    /// Last good usage snapshot (persisted across launches).
    private(set) var usage: ClaudeUsageSnapshot?
    /// Last cost snapshot (persisted across launches); nil = no data / cost disabled.
    private(set) var cost: CostUsageTokenSnapshot?
    private(set) var auth: AuthState = .ok
    private(set) var health: FetchHealth = .ok
    private(set) var isRefreshing = false
    private(set) var costScanState: CostScanState = .idle
    /// Set by the menu UI (Phase 3b); published so renderers can react.
    ///
    /// Expected call sequence (Phase 3b):
    ///   1. `menuWillOpen`:  set `isMenuOpen = true` **then** call `refresh(trigger: .menuOpen)`
    ///   2. `menuDidClose`:  set `isMenuOpen = false`
    ///
    /// The order in step 1 ensures any observer that reads `isMenuOpen` inside a refresh-triggered
    /// redraw already sees `true`; step 2 is fire-and-forget (no refresh on close).
    var isMenuOpen = false

    /// Quota crossing events (Phase 3b wires the notifier into this).
    ///
    /// Contract: fires **synchronously** on `@MainActor` from inside `applySuccess`, mid-refresh.
    /// Callers may dispatch async work (e.g. `UNUserNotificationCenter.add`) but MUST NOT call
    /// `store.refresh(_:)` or otherwise mutate store state synchronously — doing so re-enters
    /// the refresh path and violates single-flight invariants.
    @ObservationIgnored var onQuotaThresholdCrossing: ((QuotaCrossing) -> Void)?

    /// True when the last successful fetch is older than max(2×interval, 10 min)
    /// (manual cadence: 60 min).
    var isStale: Bool {
        guard self.usage != nil else { return false }
        guard let lastSuccessAt = self.lastSuccessAt else { return true }
        let threshold: TimeInterval = if let interval = self.settings.refreshFrequency.seconds {
            max(2 * interval, 600)
        } else {
            Self.manualCadenceIntervalSeconds
        }
        return self.now().timeIntervalSince(lastSuccessAt) > threshold
    }

    /// The wall-clock date at which `isStale` will first become true, or nil when already stale
    /// or when there is no successful fetch to be stale from. Used by `StatusItemController` to
    /// schedule a one-shot wake-up that forces a re-derive even when no tracked property mutates.
    ///
    /// Policy lives here — next to `isStale` — so the staleness threshold is defined in one place.
    var stalenessDeadline: Date? {
        guard !self.isStale, let lastSuccessAt = self.lastSuccessAt else { return nil }
        let threshold: TimeInterval = if let interval = self.settings.refreshFrequency.seconds {
            max(2 * interval, 600)
        } else {
            Self.manualCadenceIntervalSeconds
        }
        return lastSuccessAt.addingTimeInterval(threshold)
    }

    /// Current date per the injected clock. Exposed so `StatusItemController` can compute the
    /// deadline sleep gap using the SAME clock as `isStale` / `stalenessDeadline`, which is
    /// critical when the clock is test-injected (TestClock) rather than the real wall clock.
    var currentDate: Date {
        self.now()
    }

    // MARK: Internals

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let client: ClaudeUsageClient
    @ObservationIgnored private let scanner: CostScanner
    @ObservationIgnored private let persistence: StatePersistence?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let blockStatus: @Sendable () -> ClaudeOAuthRefreshFailureGate.BlockStatus?

    /// Wall-clock time of the last successful usage fetch.
    ///
    /// Distinct from `usage.updatedAt`, which is the API-reported snapshot timestamp (the moment
    /// the server recorded the data). `lastSuccessAt` is the local clock time at which this client
    /// received a good response — the basis for staleness calculations and min-gap gates.
    ///
    /// Observable: `isStale` is a computed property that reads this value, so any change here
    /// automatically invalidates `isStale` observations (Phase 4 "Updated Xm ago" label source).
    private(set) var lastSuccessAt: Date?
    @ObservationIgnored private(set) var lastAttemptAt: Date?
    @ObservationIgnored private(set) var failureStreak = 0
    @ObservationIgnored private var quotaMachine = QuotaTransitionMachine()

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var costScanTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
    /// Monotonically-incrementing token used by the save-debounce identity guard: the task
    /// captures its own token at creation and compares it before clearing the slot, so a stale
    /// completed task never nils a newer task's slot.
    @ObservationIgnored private var pendingSaveGeneration: UInt64 = 0

    private static let menuOpenMinimumGapSeconds: TimeInterval = 30
    private static let backoffCapSeconds: TimeInterval = 30 * 60
    private static let manualCadenceIntervalSeconds: TimeInterval = 60 * 60
    private static let persistDebounceSeconds: TimeInterval = 5
    private static let log = SturtBarLog.logger("usage-store")

    init(
        settings: SettingsStore,
        client: ClaudeUsageClient,
        scanner: CostScanner,
        persistence: StatePersistence?,
        now: @escaping @Sendable () -> Date = { Date() },
        blockStatus: @escaping @Sendable () -> ClaudeOAuthRefreshFailureGate.BlockStatus? = {
            // Gate init-ordering contract: register the credential fingerprint provider before
            // consulting the gate, so a persisted terminal block can self-heal on re-auth.
            ClaudeOAuthCredentialsStore.ensureRefreshFailureGateFingerprintProvider()
            return ClaudeOAuthRefreshFailureGate.currentBlockStatus()
        })
    {
        self.settings = settings
        self.client = client
        self.scanner = scanner
        self.persistence = persistence
        self.now = now
        self.blockStatus = blockStatus
    }

    // MARK: - Persisted state

    /// Loads the cached `{usage, cost, savedAt}` from disk. Called once, early in launch, BEFORE
    /// the first refresh — never clobbers fresher in-memory data if ordering ever changes.
    func loadPersistedState() async {
        guard let persistence = self.persistence else { return }
        guard let state = await persistence.load() else { return }
        if self.usage == nil, let usage = state.usage {
            self.usage = usage
            // Seed staleness/min-gap baselines from the snapshot's own timestamp. The quota
            // machine is deliberately NOT seeded: crossings replay only from live fetch deltas
            // (legacy semantics — every launch starts with a fresh baseline).
            self.lastSuccessAt = usage.updatedAt
        }
        // Don't seed cost when the feature is disabled: a stale persisted snapshot from before
        // disable would otherwise appear briefly until the next settings-driven clear.
        if self.cost == nil, let cost = state.cost, self.settings.costUsageEnabled {
            self.cost = cost
        }
    }

    // MARK: - Refresh

    func refresh(trigger: RefreshTrigger) async {
        if trigger.kicksCostScan {
            self.kickCostScan(bypassGate: trigger == .manual)
        }

        // Single-flight: join the in-flight refresh. `.manual` then loops to run once more —
        // when the slot frees up it starts its own user-initiated run.
        while let existing = self.refreshTask {
            await existing.value
            if trigger != .manual { return }
        }

        guard self.shouldAttempt(trigger: trigger) else { return }

        // Self-clearing slot: the defer runs inside the task closure (MainActor), so the slot is
        // empty before any joiner awaiting `existing.value` resumes.
        let task = Task {
            defer { self.refreshTask = nil }
            await self.performRefresh(trigger: trigger)
        }
        self.refreshTask = task
        await task.value
    }

    private func shouldAttempt(trigger: RefreshTrigger) -> Bool {
        let now = self.now()

        // Rate-limit gate: blocks ALL triggers (manual included) until the server-provided date.
        if case let .rateLimited(until) = self.health, now < until {
            Self.log.info(
                "Refresh suppressed: rate limited",
                metadata: ["trigger": trigger.rawValue, "until": "\(until)"])
            return false
        }

        switch trigger {
        case .manual, .launch:
            return true

        case .menuOpen:
            guard let lastSuccessAt = self.lastSuccessAt else { return true }
            return now.timeIntervalSince(lastSuccessAt) >= Self.menuOpenMinimumGapSeconds

        case .interval, .wake:
            if let lastSuccessAt = self.lastSuccessAt,
               now.timeIntervalSince(lastSuccessAt) < self.effectiveIntervalSeconds / 2
            {
                return false
            }
            if self.failureStreak > 0, let lastAttemptAt = self.lastAttemptAt {
                let backoff = min(
                    self.effectiveIntervalSeconds * pow(2, Double(self.failureStreak)),
                    Self.backoffCapSeconds)
                if now.timeIntervalSince(lastAttemptAt) < backoff {
                    Self.log.debug(
                        "Refresh suppressed: backoff",
                        metadata: ["trigger": trigger.rawValue, "streak": "\(self.failureStreak)"])
                    return false
                }
            }
            return true
        }
    }

    private func performRefresh(trigger: RefreshTrigger) async {
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        let signpostID = Signposts.refresh.makeSignpostID()
        let signpostState = Signposts.refresh.beginInterval("refresh", id: signpostID)
        defer { Signposts.refresh.endInterval("refresh", signpostState) }

        do {
            let snapshot = try await self.client.fetch(
                interaction: trigger.interaction,
                phase: trigger.phase)
            self.applySuccess(snapshot)
            Self.log.info(
                "Refresh succeeded",
                metadata: [
                    "trigger": trigger.rawValue,
                    "primaryUsedPercent": "\(snapshot.primary.usedPercent)",
                ])
        } catch is CancellationError {
            Self.log.debug("Refresh cancelled", metadata: ["trigger": trigger.rawValue])
        } catch {
            self.applyFailure(error)
            Self.log.warning(
                "Refresh failed",
                metadata: ["trigger": trigger.rawValue, "error": error.localizedDescription])
        }
    }

    private func applySuccess(_ snapshot: ClaudeUsageSnapshot) {
        let now = self.now()
        // Equality gate: suppress unnecessary observation notifications when the snapshot is
        // identical to the one already in memory (e.g. two back-to-back fetches within the same
        // billing period).
        if self.usage != snapshot { self.usage = snapshot }
        self.auth = .ok
        self.health = .ok
        self.failureStreak = 0
        self.lastSuccessAt = now
        self.lastAttemptAt = now
        self.emitQuotaCrossings(for: snapshot)
        self.schedulePersist()
    }

    private func applyFailure(_ error: any Error) {
        self.lastAttemptAt = self.now()
        let usageError = error as? ClaudeUsageError
        let gateStatus = self.blockStatus()

        // Auth state — typed predicates plus the cross-launch gate authority. Sticky otherwise.
        if let usageError, usageError.indicatesCredentialsMissing {
            self.auth = .credentialsMissing
        } else if let usageError, usageError.indicatesAuthenticationRequired {
            self.auth = .needsReauth(message: usageError.errorDescription)
        } else if case let .terminal(reason, _) = gateStatus {
            self.auth = .needsReauth(message: reason)
        }

        // Fetch health.
        if case let .fetch(.rateLimited(retryAfter)) = usageError {
            // The until-date is the gate; the failure streak stays untouched.
            self.health = .rateLimited(until: retryAfter)
        } else {
            let until: Date? = if case let .transient(date, _) = gateStatus { date } else { nil }
            self.health = .degraded(until: until)
            self.failureStreak += 1
        }
    }

    private var effectiveIntervalSeconds: TimeInterval {
        self.settings.refreshFrequency.seconds ?? Self.manualCadenceIntervalSeconds
    }

    // MARK: - Quota crossings

    private func emitQuotaCrossings(for snapshot: ClaudeUsageSnapshot) {
        let configuration = QuotaTransitionMachine.Configuration(
            sessionQuotaNotificationsEnabled: self.settings.sessionQuotaNotificationsEnabled,
            quotaWarningNotificationsEnabled: self.settings.quotaWarningNotificationsEnabled,
            sessionWarningEnabled: self.settings.quotaWarningWindowEnabled(.session),
            weeklyWarningEnabled: self.settings.quotaWarningWindowEnabled(.weekly),
            sessionThresholds: self.settings.quotaWarningThresholds(.session),
            weeklyThresholds: self.settings.quotaWarningThresholds(.weekly))
        for crossing in self.quotaMachine.process(snapshot: snapshot, configuration: configuration) {
            Self.log.info("Quota crossing", metadata: ["crossing": "\(crossing)"])
            self.onQuotaThresholdCrossing?(crossing)
        }
    }

    // MARK: - Cost

    /// Settings wiring: cost enable/history-days changes re-scan immediately (or clear when
    /// disabled).
    func costSettingsDidChange() {
        guard self.settings.costUsageEnabled else {
            // Cancel any in-flight scan so its completion arm cannot resurrect the snapshot
            // after we clear it below (cost-disable race).
            self.costScanTask?.cancel()
            let scanner = self.scanner
            Task { await scanner.cancelInFlight() }
            self.cost = nil
            self.costScanState = .idle
            self.schedulePersist()
            return
        }
        self.kickCostScan(bypassGate: true)
    }

    private func kickCostScan(bypassGate: Bool) {
        guard self.settings.costUsageEnabled else { return }
        guard self.costScanTask == nil else { return } // in-flight; the scanner would join anyway
        self.costScanState = .scanning
        let historyDays = self.settings.costUsageHistoryDays
        let scanner = self.scanner
        let now = self.now
        // Utility priority: a cold daily rescan can take 10s+; it must never compete with UI work.
        // The closure itself runs on the MainActor (inherited) — the heavy lifting happens inside
        // the scanner actor at this task's priority.
        self.costScanTask = Task(priority: .utility) {
            defer { self.costScanTask = nil }
            let result = await scanner.scan(bypassGate: bypassGate, historyDays: historyDays, now: now())
            switch result {
            case let .scanned(snapshot):
                // Cost-disable race: a 10s+ scan that finishes after the user disables cost usage
                // must not resurrect the snapshot. Re-check the setting at completion time.
                guard self.settings.costUsageEnabled else {
                    self.costScanState = .idle
                    return
                }
                // Equality gate: suppress observation noise for identical snapshots.
                if self.cost != snapshot { self.cost = snapshot }
                self.costScanState = .idle
                self.schedulePersist()
            case .skipped, .cancelled:
                self.costScanState = .idle
            }
        }
    }

    // MARK: - Persistence (debounce lives here, IO lives in StatePersistence)

    private func schedulePersist() {
        guard self.persistence != nil else { return }
        self.pendingSaveTask?.cancel()
        self.pendingSaveGeneration &+= 1
        let generation = self.pendingSaveGeneration
        self.pendingSaveTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.persistDebounceSeconds))
            } catch {
                return // superseded by a newer change, or shutting down
            }
            guard let self else { return }
            // Identity guard: only clear the slot if this task's generation is still current —
            // prevents a stale completed task from nilling a newer scheduled task's slot.
            if self.pendingSaveGeneration == generation { self.pendingSaveTask = nil }
            await self.persistNow()
        }
    }

    private func persistNow() async {
        guard let persistence = self.persistence else { return }
        let state = StatePersistence.State(usage: self.usage, cost: self.cost, savedAt: self.now())
        await persistence.save(state)
    }

    /// applicationWillTerminate: flush a pending debounced save synchronously. Only writes when a
    /// save is actually pending — an unconditional write could clobber a good cache with the
    /// empty state of a young process.
    func flushPersistedStateForTermination() {
        guard self.pendingSaveTask != nil else { return }
        self.pendingSaveTask?.cancel()
        self.pendingSaveTask = nil
        self.persistence?.saveNow(
            StatePersistence.State(usage: self.usage, cost: self.cost, savedAt: self.now()))
    }

    /// App shutdown: flush state and cancel background work.
    func shutdown() {
        // flushPersistedStateForTermination cancels + nils pendingSaveTask if one is pending;
        // the refreshTask/costScanTask cancels below are the only remaining cleanup needed.
        self.flushPersistedStateForTermination()
        self.refreshTask?.cancel()
        self.costScanTask?.cancel()
        let scanner = self.scanner
        Task { await scanner.cancelInFlight() }
    }
}
