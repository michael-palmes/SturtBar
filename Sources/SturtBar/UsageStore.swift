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

/// What fixes a needs-reauth state, typed from `ClaudeUsageError` so the card offers the right remedy.
enum ClaudeReauthRemedy: Equatable {
    /// A fresh sign-in via `claude /login`.
    case signIn
    /// Sign-in exists but SturtBar can't read it silently; the retry raises the Keychain consent prompt.
    case keychainAccess
}

enum AuthState: Equatable {
    case ok
    case needsReauth(message: String?, remedy: ClaudeReauthRemedy)
    case credentialsMissing
}

/// Codex auth states differ from Claude's in kind (no reauth message, plus the API-key-only
/// "unsupported" state), so they get their own small enum rather than overloading `AuthState`.
enum CodexAuthState: Equatable {
    case ok
    /// No auth.json / unusable auth file — run `codex` to connect.
    case credentialsMissing
    /// Token rejected (expired/revoked) — sign in again via the codex CLI. SturtBar never
    /// refreshes Codex tokens on the CLI's behalf (decision 3).
    case signInRequired
    /// Platform API-key account: no ChatGPT rate-limit usage exists to display (decision 4).
    case apiKeyOnlyUnsupported
}

enum FetchHealth: Equatable {
    case ok
    case degraded(until: Date?)
    case rateLimited(until: Date)
}

/// Minimal by design: `ClaudeCostFetcher` swallows scan failures into a nil snapshot (cost is
/// best-effort eye candy), so a `.failed` case would be unreachable; cancellation only happens at
/// shutdown where nobody is watching.
enum CostScanState: Equatable {
    case idle
    case scanning
}

enum RefreshTrigger: String {
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
    private(set) var usage: ProviderUsageSnapshot?
    /// Last cost snapshot (persisted across launches); nil = no data / cost disabled.
    private(set) var cost: CostUsageTokenSnapshot?
    private(set) var auth: AuthState = .ok
    private(set) var health: FetchHealth = .ok
    private(set) var isRefreshing = false
    private(set) var costScanState: CostScanState = .idle

    // Codex lane (decision 6: all of this stays empty while the provider is disabled).
    /// Last good Codex snapshot (persisted across launches; wiped on provider disable).
    private(set) var codexUsage: ProviderUsageSnapshot?
    private(set) var codexAuth: CodexAuthState = .ok
    private(set) var codexHealth: FetchHealth = .ok
    private(set) var codexIsRefreshing = false
    /// Last Codex cost snapshot (persisted; wiped on Codex provider or cost disable). Independent
    /// of the Claude `cost` lane, so disabling Claude leaves it intact.
    private(set) var codexCost: CostUsageTokenSnapshot?
    private(set) var codexCostScanState: CostScanState = .idle
    /// Set by the menu UI (Phase 3b); published so renderers can react.
    ///
    /// Expected call sequence (Phase 3b):
    ///   1. `menuWillOpen`:  set `isMenuOpen = true` **then** call `refresh(trigger: .menuOpen)`
    ///   2. `menuDidClose`:  set `isMenuOpen = false`
    ///
    /// The order in step 1 ensures any observer that reads `isMenuOpen` inside a refresh-triggered
    /// redraw already sees `true`; step 2 is fire-and-forget (no refresh on close).
    var isMenuOpen = false

    /// Quota crossing events (Phase 3b wires the notifier into this), tagged with the provider
    /// whose windows crossed.
    ///
    /// Contract: fires **synchronously** on `@MainActor` from inside the apply-success paths,
    /// mid-refresh. Callers may dispatch async work (e.g. `UNUserNotificationCenter.add`) but
    /// MUST NOT call `store.refresh(_:)` or otherwise mutate store state synchronously — doing so
    /// re-enters the refresh path and violates single-flight invariants.
    @ObservationIgnored var onQuotaThresholdCrossing: ((UsageProviderKind, QuotaCrossing) -> Void)?

    /// Shared staleness threshold: max(2×interval, 10 min); manual cadence 60 min.
    private var stalenessThreshold: TimeInterval {
        if let interval = self.settings.refreshFrequency.seconds {
            max(2 * interval, 600)
        } else {
            Self.manualCadenceIntervalSeconds
        }
    }

    private func laneIsStale(usage: ProviderUsageSnapshot?, lastSuccessAt: Date?) -> Bool {
        guard usage != nil else { return false }
        guard let lastSuccessAt else { return true }
        return self.now().timeIntervalSince(lastSuccessAt) > self.stalenessThreshold
    }

    private func laneStalenessDeadline(usage: ProviderUsageSnapshot?, lastSuccessAt: Date?) -> Date? {
        guard !self.laneIsStale(usage: usage, lastSuccessAt: lastSuccessAt),
              let lastSuccessAt else { return nil }
        return lastSuccessAt.addingTimeInterval(self.stalenessThreshold)
    }

    /// True when the last successful Claude fetch is older than the staleness threshold.
    var isStale: Bool {
        self.laneIsStale(usage: self.usage, lastSuccessAt: self.lastSuccessAt)
    }

    /// Codex twin of `isStale`, tracked entirely on the codex lane's fields.
    var codexIsStale: Bool {
        self.laneIsStale(usage: self.codexUsage, lastSuccessAt: self.codexLastSuccessAt)
    }

    /// The wall-clock date at which any enabled lane first becomes stale, or nil when nothing
    /// will (already stale / no data). Used by `StatusItemController` to schedule a one-shot
    /// wake-up that forces a re-derive even when no tracked property mutates. A disabled lane
    /// contributes nothing: its wiped fields make the per-lane deadline nil.
    var stalenessDeadline: Date? {
        [
            self.laneStalenessDeadline(usage: self.usage, lastSuccessAt: self.lastSuccessAt),
            self.laneStalenessDeadline(usage: self.codexUsage, lastSuccessAt: self.codexLastSuccessAt),
        ].compactMap(\.self).min()
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
    @ObservationIgnored private let codexClient: CodexUsageClient
    @ObservationIgnored private let scanner: CostScanner
    @ObservationIgnored private let codexScanner: CostScanner
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

    /// Codex twin of `lastSuccessAt` (observable: feeds `codexIsStale` and the card subtitle).
    private(set) var codexLastSuccessAt: Date?
    @ObservationIgnored private(set) var codexLastAttemptAt: Date?
    @ObservationIgnored private(set) var codexFailureStreak = 0
    @ObservationIgnored private var codexQuotaMachine = QuotaTransitionMachine()
    @ObservationIgnored private var codexRefreshTask: Task<Void, Never>?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var costScanTask: Task<Void, Never>?
    @ObservationIgnored private var codexCostScanTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
    /// Monotonically-incrementing token used by the save-debounce identity guard: the task
    /// captures its own token at creation and compares it before clearing the slot, so a stale
    /// completed task never nils a newer task's slot.
    @ObservationIgnored private var pendingSaveGeneration: UInt64 = 0

    private static let manualCadenceIntervalSeconds: TimeInterval = 60 * 60
    private static let persistDebounceSeconds: TimeInterval = 5
    private static let log = SturtBarLog.logger("usage-store")

    init(
        settings: SettingsStore,
        client: ClaudeUsageClient,
        codexClient: CodexUsageClient,
        scanner: CostScanner,
        codexScanner: CostScanner,
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
        self.codexClient = codexClient
        self.scanner = scanner
        self.codexScanner = codexScanner
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
        // Same gating for codex (decision 6): a snapshot persisted before a disable must never
        // flash on a later launch while the provider is off.
        if self.codexUsage == nil, let codexUsage = state.codexUsage, self.settings.codexProviderEnabled {
            self.codexUsage = codexUsage
            self.codexLastSuccessAt = codexUsage.updatedAt
        }
        // Codex cost seeds only when both the provider and the cost feature are on, so a snapshot
        // persisted before a disable never flashes on a later launch.
        if self.codexCost == nil, let codexCost = state.codexCost,
           self.settings.codexProviderEnabled, self.settings.costUsageEnabled
        {
            self.codexCost = codexCost
        }
    }

    // MARK: - Refresh

    /// Fans out to every ENABLED provider lane. The lanes run as concurrent child tasks: each
    /// suspends at its own client await, so a hung Codex fetch never delays Claude data (and
    /// vice versa). A disabled lane is an instant no-op — the privacy gate (decision 6).
    func refresh(trigger: RefreshTrigger) async {
        if trigger.kicksCostScan {
            self.kickCostScan(bypassGate: trigger == .manual)
            self.kickCodexCostScan(bypassGate: trigger == .manual)
        }
        async let claude: Void = self.refreshClaude(trigger: trigger)
        async let codex: Void = self.refreshCodex(trigger: trigger)
        _ = await (claude, codex)
    }

    private func refreshClaude(trigger: RefreshTrigger) async {
        guard self.settings.claudeProviderEnabled else { return }

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

    private func refreshCodex(trigger: RefreshTrigger) async {
        guard self.settings.codexProviderEnabled else { return }

        while let existing = self.codexRefreshTask {
            await existing.value
            if trigger != .manual { return }
        }

        guard self.shouldAttemptCodex(trigger: trigger) else { return }

        let task = Task {
            defer { self.codexRefreshTask = nil }
            await self.performCodexRefresh(trigger: trigger)
        }
        self.codexRefreshTask = task
        await task.value
    }

    private func shouldAttempt(trigger: RefreshTrigger) -> Bool {
        let decision = RefreshGatePolicy.decision(
            trigger: trigger,
            lane: RefreshGatePolicy.LaneState(
                health: self.health,
                lastSuccessAt: self.lastSuccessAt,
                lastAttemptAt: self.lastAttemptAt,
                failureStreak: self.failureStreak),
            intervalSeconds: self.effectiveIntervalSeconds,
            now: self.now())
        return self.logGateDecision(decision, lane: "claude", trigger: trigger, streak: self.failureStreak)
    }

    private func shouldAttemptCodex(trigger: RefreshTrigger) -> Bool {
        let decision = RefreshGatePolicy.decision(
            trigger: trigger,
            lane: RefreshGatePolicy.LaneState(
                health: self.codexHealth,
                lastSuccessAt: self.codexLastSuccessAt,
                lastAttemptAt: self.codexLastAttemptAt,
                failureStreak: self.codexFailureStreak),
            intervalSeconds: self.effectiveIntervalSeconds,
            now: self.now())
        return self.logGateDecision(decision, lane: "codex", trigger: trigger, streak: self.codexFailureStreak)
    }

    private func logGateDecision(
        _ decision: RefreshGateDecision,
        lane: String,
        trigger: RefreshTrigger,
        streak: Int) -> Bool
    {
        switch decision {
        case .proceed:
            return true
        case let .rateLimited(until):
            Self.log.info(
                "Refresh suppressed: rate limited",
                metadata: ["lane": lane, "trigger": trigger.rawValue, "until": "\(until)"])
            return false
        case .tooSoon:
            return false
        case .backingOff:
            Self.log.debug(
                "Refresh suppressed: backoff",
                metadata: ["lane": lane, "trigger": trigger.rawValue, "streak": "\(streak)"])
            return false
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

    private func performCodexRefresh(trigger: RefreshTrigger) async {
        self.codexIsRefreshing = true
        defer { self.codexIsRefreshing = false }

        do {
            let snapshot = try await self.codexClient.fetch()
            self.applyCodexSuccess(snapshot)
            Self.log.info(
                "Codex refresh succeeded",
                metadata: [
                    "trigger": trigger.rawValue,
                    "primaryUsedPercent": "\(snapshot.primary.usedPercent)",
                ])
        } catch is CancellationError {
            Self.log.debug("Codex refresh cancelled", metadata: ["trigger": trigger.rawValue])
        } catch {
            self.applyCodexFailure(error)
            Self.log.warning(
                "Codex refresh failed",
                metadata: ["trigger": trigger.rawValue, "error": error.localizedDescription])
        }
    }

    private func applySuccess(_ snapshot: ProviderUsageSnapshot) {
        // Disable race: a fetch completing after the provider was turned off must not
        // resurrect wiped state (same pattern as the cost-disable race).
        guard self.settings.claudeProviderEnabled else { return }
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

    private func applyCodexSuccess(_ snapshot: ProviderUsageSnapshot) {
        guard self.settings.codexProviderEnabled else { return }
        let now = self.now()
        if self.codexUsage != snapshot { self.codexUsage = snapshot }
        self.codexAuth = .ok
        self.codexHealth = .ok
        self.codexFailureStreak = 0
        self.codexLastSuccessAt = now
        self.codexLastAttemptAt = now
        self.emitCodexQuotaCrossings(for: snapshot)
        self.schedulePersist()
    }

    /// Codex failure mapping — typed predicates only, mirroring the Claude lane's rules:
    /// auth states are sticky across unrelated failures; rate limits gate without touching the
    /// backoff streak; everything else degrades health and grows the streak.
    private func applyCodexFailure(_ error: any Error) {
        guard self.settings.codexProviderEnabled else { return }
        self.codexLastAttemptAt = self.now()
        let usageError = error as? CodexUsageError

        if let usageError, usageError.indicatesCredentialsMissing {
            self.codexAuth = .credentialsMissing
        } else if let usageError, usageError.indicatesSignInRequired {
            self.codexAuth = .signInRequired
        } else if let usageError, usageError.indicatesUnsupportedAccount {
            self.codexAuth = .apiKeyOnlyUnsupported
        }

        if case let .rateLimited(retryAfter) = usageError {
            // The until-date is the gate; the failure streak stays untouched.
            self.codexHealth = .rateLimited(until: retryAfter)
        } else {
            self.codexHealth = .degraded(until: nil)
            self.codexFailureStreak += 1
        }
    }

    private func applyFailure(_ error: any Error) {
        guard self.settings.claudeProviderEnabled else { return }
        self.lastAttemptAt = self.now()
        let usageError = error as? ClaudeUsageError
        let gateStatus = self.blockStatus()

        // Auth state — typed predicates plus the cross-launch gate authority. Sticky otherwise.
        if let usageError, usageError.indicatesCredentialsMissing {
            self.auth = .credentialsMissing
        } else if let usageError, usageError.indicatesAuthenticationRequired {
            self.auth = .needsReauth(
                message: usageError.errorDescription,
                remedy: usageError.indicatesKeychainAccessRequired ? .keychainAccess : .signIn)
        } else if case let .terminal(reason, _) = gateStatus {
            self.auth = .needsReauth(message: reason, remedy: .signIn)
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

    /// One shared threshold configuration drives both providers (decision 15: full parity,
    /// no per-provider threshold settings).
    private var quotaConfiguration: QuotaTransitionMachine.Configuration {
        QuotaTransitionMachine.Configuration(
            sessionQuotaNotificationsEnabled: self.settings.sessionQuotaNotificationsEnabled,
            quotaWarningNotificationsEnabled: self.settings.quotaWarningNotificationsEnabled,
            sessionWarningEnabled: self.settings.quotaWarningWindowEnabled(.session),
            weeklyWarningEnabled: self.settings.quotaWarningWindowEnabled(.weekly),
            sessionThresholds: self.settings.quotaWarningThresholds(.session),
            weeklyThresholds: self.settings.quotaWarningThresholds(.weekly))
    }

    private func emitQuotaCrossings(for snapshot: ProviderUsageSnapshot) {
        for crossing in self.quotaMachine.process(snapshot: snapshot, configuration: self.quotaConfiguration) {
            Self.log.info("Quota crossing", metadata: ["provider": "claude", "crossing": "\(crossing)"])
            self.onQuotaThresholdCrossing?(.claude, crossing)
        }
    }

    private func emitCodexQuotaCrossings(for snapshot: ProviderUsageSnapshot) {
        for crossing in self.codexQuotaMachine.process(
            snapshot: snapshot,
            configuration: self.quotaConfiguration)
        {
            Self.log.info("Quota crossing", metadata: ["provider": "codex", "crossing": "\(crossing)"])
            self.onQuotaThresholdCrossing?(.codex, crossing)
        }
    }

    // MARK: - Provider lifecycle (decision 6)

    /// Settings wiring: a provider toggle either wipes the lane to inert (disable) or kicks one
    /// user-initiated fetch (enable). Wiping covers memory, in-flight work, the quota machine's
    /// fired-set, and — via the scheduled persist — disk.
    func providerEnabledDidChange(_ provider: UsageProviderKind, enabled: Bool) {
        switch (provider, enabled) {
        case (.claude, true):
            Task { await self.refreshClaude(trigger: .manual) }
            self.kickCostScan(bypassGate: true)

        case (.claude, false):
            self.refreshTask?.cancel()
            let client = self.client
            Task { await client.cancelInFlight() }
            self.usage = nil
            self.auth = .ok
            self.health = .ok
            self.isRefreshing = false
            self.lastSuccessAt = nil
            self.lastAttemptAt = nil
            self.failureStreak = 0
            self.quotaMachine = QuotaTransitionMachine()
            // A disabled Claude provider must be fully inert, including the ~/.claude cost-log
            // scanning — reuse the cost-disable arm's cancel+clear.
            self.costScanTask?.cancel()
            let scanner = self.scanner
            Task { await scanner.cancelInFlight() }
            self.cost = nil
            self.costScanState = .idle
            self.schedulePersist()

        case (.codex, true):
            Task { await self.refreshCodex(trigger: .manual) }
            self.kickCodexCostScan(bypassGate: true)

        case (.codex, false):
            self.codexRefreshTask?.cancel()
            let codexClient = self.codexClient
            Task { await codexClient.cancelInFlight() }
            self.codexUsage = nil
            self.codexAuth = .ok
            self.codexHealth = .ok
            self.codexIsRefreshing = false
            self.codexLastSuccessAt = nil
            self.codexLastAttemptAt = nil
            self.codexFailureStreak = 0
            self.codexQuotaMachine = QuotaTransitionMachine()
            // Codex cost is an independent lane; disabling Codex wipes it like the rest.
            self.codexCostScanTask?.cancel()
            let codexScanner = self.codexScanner
            Task { await codexScanner.cancelInFlight() }
            self.codexCost = nil
            self.codexCostScanState = .idle
            self.schedulePersist()
        }
    }

    // MARK: - Cost

    /// Settings wiring: cost enable/history-days changes re-scan immediately (or clear when
    /// disabled).
    func costSettingsDidChange() {
        guard self.settings.costUsageEnabled else {
            // Cancel any in-flight scans so their completion arms cannot resurrect a snapshot
            // after we clear it below (cost-disable race).
            self.costScanTask?.cancel()
            self.codexCostScanTask?.cancel()
            let scanner = self.scanner
            let codexScanner = self.codexScanner
            Task { await scanner.cancelInFlight() }
            Task { await codexScanner.cancelInFlight() }
            self.cost = nil
            self.codexCost = nil
            self.costScanState = .idle
            self.codexCostScanState = .idle
            self.schedulePersist()
            return
        }
        self.kickCostScan(bypassGate: true)
        self.kickCodexCostScan(bypassGate: true)
    }

    private func kickCostScan(bypassGate: Bool) {
        // Cost scanning reads ~/.claude project logs, so it rides the Claude provider gate too.
        guard self.settings.claudeProviderEnabled else { return }
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

    /// Codex twin of `kickCostScan`. Reads ~/.codex session logs, so it is gated on the **Codex**
    /// provider (NOT Claude) plus the shared cost toggle — a Codex-only user still gets cost.
    private func kickCodexCostScan(bypassGate: Bool) {
        guard self.settings.codexProviderEnabled else { return }
        guard self.settings.costUsageEnabled else { return }
        guard self.codexCostScanTask == nil else { return } // in-flight; the scanner would join anyway
        self.codexCostScanState = .scanning
        let historyDays = self.settings.costUsageHistoryDays
        let scanner = self.codexScanner
        let now = self.now
        self.codexCostScanTask = Task(priority: .utility) {
            defer { self.codexCostScanTask = nil }
            let result = await scanner.scan(bypassGate: bypassGate, historyDays: historyDays, now: now())
            switch result {
            case let .scanned(snapshot):
                // Disable race: a scan that finishes after the user turns Codex or cost off must
                // not resurrect the snapshot. Re-check both gates at completion time.
                guard self.settings.codexProviderEnabled, self.settings.costUsageEnabled else {
                    self.codexCostScanState = .idle
                    return
                }
                if self.codexCost != snapshot { self.codexCost = snapshot }
                self.codexCostScanState = .idle
                self.schedulePersist()
            case .skipped, .cancelled:
                self.codexCostScanState = .idle
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
        let state = StatePersistence.State(
            usage: self.usage,
            codexUsage: self.codexUsage,
            cost: self.cost,
            codexCost: self.codexCost,
            savedAt: self.now())
        await persistence.save(state)
    }

    /// applicationWillTerminate: flush a pending debounced save synchronously. Only writes when a
    /// save is actually pending — an unconditional write could clobber a good cache with the
    /// empty state of a young process.
    func flushPersistedStateForTermination() {
        guard self.pendingSaveTask != nil else { return }
        self.pendingSaveTask?.cancel()
        self.pendingSaveTask = nil
        self.persistence?.saveNow(StatePersistence.State(
            usage: self.usage,
            codexUsage: self.codexUsage,
            cost: self.cost,
            codexCost: self.codexCost,
            savedAt: self.now()))
    }

    /// App shutdown: flush state and cancel background work.
    func shutdown() {
        // flushPersistedStateForTermination cancels + nils pendingSaveTask if one is pending;
        // the refreshTask/costScanTask cancels below are the only remaining cleanup needed.
        self.flushPersistedStateForTermination()
        self.refreshTask?.cancel()
        self.codexRefreshTask?.cancel()
        self.costScanTask?.cancel()
        self.codexCostScanTask?.cancel()
        let scanner = self.scanner
        let codexScanner = self.codexScanner
        Task { await scanner.cancelInFlight() }
        Task { await codexScanner.cancelInFlight() }
    }
}
