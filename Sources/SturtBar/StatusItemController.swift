// StatusItemController.swift — owns the NSStatusItem and the live icon pipeline (Phase 3b).
//
// Replaces the legacy ~700-line string-signature assembly (StatusItemController+IconObservation's
// storeIconObservationSignature) with a small Equatable `IconState` struct: derive → compare →
// render. Phase 4b adds the full menu (hosted usage card, lazy cost-history chart submenu, native
// action items) in StatusItemController+Menu.swift; the stored menu state lives here because
// extensions cannot add stored properties.
//
// Observation loop design:
//   - `armAndRender()` derives IconState INSIDE `withObservationTracking`, registering every
//     observable read (store.usage / store.auth / store.isStale → lastSuccessAt / settings.*) as
//     a dependency, then renders only when the derived state differs from the last rendered one.
//   - Re-arm: tracking is one-shot. `onChange` (which may fire on willSet, potentially off the
//     MainActor) only hops to the MainActor via `Task { @MainActor … }`; the scheduled task calls
//     `armAndRender()` again, which both re-arms tracking and re-reads CURRENT state.
//   - Coalescing: because tracking is one-shot, N property mutations in one MainActor job fire
//     `onChange` exactly once → exactly one scheduled task → one derive+render that sees all N
//     changes (the task runs after the mutating job completes, so willSet timing is harmless).
//     Mutations landing between the fire and the task run are simply picked up by that same
//     re-read; the fresh arm catches anything later. Invariant: exactly one live arm — only
//     `start()` (once) and the onChange task call `armAndRender()`.
//
// IconState field choices (what redraws the icon, and what deliberately does not):
//   IN  primaryBucket/secondaryBucket — whole-point remaining-% buckets; sub-point usage moves
//       must not re-render (below pixel resolution at 30px bar width).
//   IN  isStale, needsAuth, credentialsMissing — change the dimmed presentation immediately
//       (broken auth means data can't refresh; waiting for the staleness clock would hide it).
//   IN  displayText — the rendered button title (mode-dependent percent/pace text).
//   IN  style — settings-driven meter style.
//   OUT isRefreshing — the loading animation was dropped with the morph cache; without a visual,
//       including it would force two no-op renders per refresh tick.
//   OUT isMenuOpen — no visual representation in the icon; flips twice per menu interaction.
//   OUT health (degraded/rateLimited) — surfaces through staleness dimming over time and the
//       Phase 4b menu, not through a distinct icon treatment (legacy parity: fetch errors never
//       changed the legacy icon either).
//   OUT cost / costScanState — the icon never displays cost data.

import AppKit
import Foundation
import Observation
import os
import SturtBarCore
import SwiftUI

// MARK: - IconState

/// Everything the menu bar rendering depends on — quantized so that equality == "would render
/// identically".
struct IconState: Equatable {
    /// Whole-point remaining-% bucket for the primary window (52.4% remaining → 52); nil = no data.
    var primaryBucket: Int?
    /// Whole-point remaining-% bucket for the secondary/weekly window; nil = window absent.
    var secondaryBucket: Int?
    var isStale: Bool
    var needsAuth: Bool
    var credentialsMissing: Bool
    /// Dims without badging (Codex API-key-only): badging a permanent state would nag forever.
    var unsupported: Bool = false
    /// Text next to the icon (nil = icon only).
    var displayText: String?

    @MainActor
    static func derive(store: UsageStore, settings: SettingsStore, now: Date = .init()) -> IconState {
        // Read EVERY input unconditionally before branching: each read registers as an
        // observation dependency, so a change to either lane (or any toggle) re-derives even
        // when the current winner doesn't display it.
        let claudeEnabled = settings.claudeProviderEnabled
        let codexEnabled = settings.codexProviderEnabled
        let source = settings.menuBarProviderSource
        let showUsed = settings.usageBarsShowUsed
        let mode = settings.menuBarDisplayMode
        let claudeUsage = store.usage
        let codexUsage = store.codexUsage
        let claudeAuth = store.auth
        let codexAuth = store.codexAuth
        let claudeStale = store.isStale
        let codexStale = store.codexIsStale

        let winner = MenuBarProviderResolver.winner(
            source: source,
            claudeEnabled: claudeEnabled,
            claude: claudeUsage,
            codexEnabled: codexEnabled,
            codex: codexUsage)
        let multiProvider = claudeEnabled && codexEnabled

        // The winning lane supplies the snapshot AND the dim-state inputs; both-off is the
        // neutral empty icon (decision 6).
        let snapshot: ProviderUsageSnapshot?
        let isStale: Bool
        let needsAuth: Bool
        let credentialsMissing: Bool
        let unsupported: Bool
        switch winner {
        case .claude:
            snapshot = claudeUsage
            isStale = claudeStale
            needsAuth = claudeAuth.isNeedsReauth
            credentialsMissing = claudeAuth == .credentialsMissing
            unsupported = false
        case .codex:
            snapshot = codexUsage
            isStale = codexStale
            needsAuth = codexAuth == .signInRequired
            credentialsMissing = codexAuth == .credentialsMissing
            unsupported = codexAuth == .apiKeyOnlyUnsupported
        case nil:
            snapshot = nil
            isStale = false
            needsAuth = false
            credentialsMissing = false
            unsupported = false
        }

        let fill = IconRemainingResolver.resolvedRemaining(snapshot: snapshot, showUsed: showUsed)
        let baseText = MenuBarMetricWindowResolver.displayText(
            mode: mode,
            snapshot: snapshot,
            showUsed: showUsed,
            now: now)
        return IconState(
            primaryBucket: fill.primary.map(Self.bucket),
            secondaryBucket: fill.secondary.map(Self.bucket),
            isStale: isStale,
            needsAuth: needsAuth,
            credentialsMissing: credentialsMissing,
            unsupported: unsupported,
            displayText: winner.flatMap {
                MenuBarProviderResolver.prefixed(baseText, provider: $0, multiProvider: multiProvider)
            })
    }

    /// Whole-point quantization, clamped to 0...100.
    static func bucket(_ percent: Double) -> Int {
        Int(min(100, max(0, percent)).rounded())
    }

    /// Every attention state dims; only the fixable auth states also badge.
    var rendererKey: IconRenderer.Key {
        IconRenderer.Key(
            primaryBucket: self.primaryBucket,
            secondaryBucket: self.secondaryBucket,
            dimmed: self.isStale || self.needsAuth || self.credentialsMissing || self.unsupported,
            authBadge: self.needsAuth || self.credentialsMissing)
    }
}

extension AuthState {
    fileprivate var isNeedsReauth: Bool {
        if case .needsReauth = self { return true }
        return false
    }
}

// MARK: - StatusItemController

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let store: UsageStore
    let settings: SettingsStore
    /// Settings/About window owner; menu actions route here. nil in icon-only tests.
    let windows: WindowsController?
    /// Opens the default terminal running a provider sign-in command (card status-line action).
    let signInLauncher: TerminalLoginLauncher
    /// Presents the Keychain opt-in consent for the reconnect line; injectable since NSAlert cannot run headless.
    let keychainOptInPresenter: @MainActor () -> KeychainPromptDecision
    private let statusBar: NSStatusBar
    private(set) var statusItem: NSStatusItem?
    private var lastRendered: IconState?
    private var started = false
    /// One-shot task that sleeps until the staleness deadline and then re-derives the icon.
    /// Cancel-and-replaced on every render; cancelled in shutdown().
    private var stalenessDeadlineTask: Task<Void, Never>?

    // MARK: Menu state (Phase 4b; behavior in StatusItemController+Menu.swift)

    /// The status item's root menu. Built once; items mutate in place (chart presence).
    var menu: NSMenu?
    /// Per-provider usage cards, each followed by its Cost History submenu, plus the no-providers
    /// placeholder. Built once; visibility toggles with the enabled set (no insert/remove churn).
    var claudeCardSlot: ProviderCardSlot?
    var codexCardSlot: ProviderCardSlot?
    var placeholderCardSlot: ProviderCardSlot?
    /// "Claude Cost History" item with the lazy chart submenu (under the Claude card).
    var chartItem: NSMenuItem?
    /// Lazily-created Claude chart hosting view.
    var chartHostingView: MenuHostingView<CostHistoryChartMenuView>?
    /// "Codex Cost History" item + its lazy chart hosting view (under the Codex card).
    var codexChartItem: NSMenuItem?
    var codexChartHostingView: MenuHostingView<CostHistoryChartMenuView>?
    /// Single "estimated" cost disclaimer line, shown above Refresh when cost is on for any provider.
    var disclaimerItem: NSMenuItem?
    /// Separator between the Claude and Codex sections, shown only when BOTH providers are enabled.
    var providerDividerItem: NSMenuItem?
    /// Local (non-observable) mirror of "the root menu is open" for defer decisions. The store's
    /// `isMenuOpen` stays the published contract; reading it in the card pipeline would register
    /// it as an observation dependency and re-derive the model twice per menu interaction.
    var menuIsOpen = false
    /// Provider/cost toggled while the menu was open; apply item visibility on close (NSMenu can't
    /// restructure a visible menu).
    var pendingMenuVisibilityUpdate = false
    /// Open-interval signpost state ("menu" category).
    var menuOpenSignpostState: OSSignpostIntervalState?

    #if DEBUG
    /// Retained only for the debug-menu raw fetch action; production paths go through the store.
    let debugUsageClient: ClaudeUsageClient?
    /// Test hook: observes every applied state without needing a real status item button.
    var onIconApplied: ((IconState) -> Void)?
    /// Seam for testing: replace with an instant-release closure to avoid real sleeps.
    /// Receives the sleep duration and throws CancellationError when the task is cancelled.
    var deadlineSleep: (Duration) async throws -> Void = { duration in
        // ContinuousClock measures elapsed real time (wall clock minus any deep-sleep overshoot
        // is fine: on fire armAndRender re-derives isStale from wall-clock Date, so a lid-closed
        // overshoot just fires slightly late and self-corrects immediately).
        try await Task.sleep(for: duration, clock: .continuous)
    }
    #endif

    static let log = SturtBarLog.logger("status-item")

    init(
        store: UsageStore,
        settings: SettingsStore,
        windows: WindowsController? = nil,
        signInLauncher: TerminalLoginLauncher = TerminalLoginLauncher(),
        keychainOptInPresenter: @escaping @MainActor () -> KeychainPromptDecision =
            { KeychainPromptCoordinator.presentClaudeKeychainOptIn() },
        debugUsageClient: ClaudeUsageClient? = nil,
        statusBar: NSStatusBar = .system)
    {
        self.store = store
        self.settings = settings
        self.windows = windows
        self.signInLauncher = signInLauncher
        self.keychainOptInPresenter = keychainOptInPresenter
        self.statusBar = statusBar
        #if DEBUG
        self.debugUsageClient = debugUsageClient
        #else
        _ = debugUsageClient
        #endif
        super.init()
    }

    /// Creates the status item + menu and starts the observation loops. Idempotent.
    func start() {
        guard !self.started else { return }
        self.started = true
        self.buildStatusItem()
        self.armAndRender()
        self.armCardPresentation()
    }

    #if DEBUG
    /// Test entry: runs the icon observation loop without creating an NSStatusItem or menu.
    func startWithoutStatusItemForTesting() {
        guard !self.started else { return }
        self.started = true
        self.armAndRender()
    }

    /// Test entry: builds the full menu (card hosting view included) and runs both observation
    /// loops, without touching NSStatusBar.
    func startWithMenuForTesting() {
        guard !self.started else { return }
        self.started = true
        self.menu = self.buildMenu()
        self.armAndRender()
        self.armCardPresentation()
    }
    #endif

    /// Stops applying updates (the one-shot arms die with the weak self / started flag).
    func shutdown() {
        self.started = false
        self.stalenessDeadlineTask?.cancel()
        self.stalenessDeadlineTask = nil
    }

    /// One-shot-arm guard shared by both observation loops.
    var isStarted: Bool {
        self.started
    }

    // MARK: - Observation loop

    private func armAndRender() {
        guard self.started else { return }
        let state = withObservationTracking {
            IconState.derive(store: self.store, settings: self.settings)
        } onChange: { [weak self] in
            // May fire on willSet, possibly off the MainActor — hop and re-read. One-shot
            // tracking coalesces any further changes in this turn into this single task.
            Task { @MainActor [weak self] in
                self?.armAndRender()
            }
        }
        self.renderIfNeeded(state)
        self.scheduleDeadlineTaskIfNeeded()
    }

    /// Schedules (or replaces) a one-shot task that fires just after the staleness deadline so
    /// the icon transitions to dimmed even when no tracked property ever mutates after a failure
    /// streak (health/failureStreak/lastAttemptAt are all @ObservationIgnored — they never wake
    /// the observation loop, so only the wall-clock deadline task can trigger the stale flip).
    ///
    /// Only scheduled when not already stale and a deadline exists. Cancels any previous task so
    /// at most one pending deadline is live at a time.
    private func scheduleDeadlineTaskIfNeeded() {
        self.stalenessDeadlineTask?.cancel()
        self.stalenessDeadlineTask = nil
        guard let deadline = self.store.stalenessDeadline else { return }
        // Use the store's injected clock for consistency with isStale / stalenessDeadline.
        // In production this is the real wall clock; in tests it may be a TestClock.
        let now = self.store.currentDate
        // Add a 1-second grace so isStale is definitively true when armAndRender fires.
        let gap = deadline.timeIntervalSince(now) + 1
        guard gap > 0 else { return }
        let duration = Duration.seconds(gap)
        #if DEBUG
        let sleep = self.deadlineSleep
        #endif
        self.stalenessDeadlineTask = Task { @MainActor [weak self] in
            do {
                #if DEBUG
                try await sleep(duration)
                #else
                try await Task.sleep(for: duration, clock: .continuous)
                #endif
            } catch {
                return // cancelled — controller shut down or deadline was superseded
            }
            guard let self, self.started else { return }
            self.armAndRender()
            // The card's status strip also surfaces staleness ("Data may be out of date"); the
            // wall-clock flip mutates nothing observable, so re-derive the model here too. This
            // is a NON-arming re-derive — the live card arm stays valid for real mutations.
            self.refreshCardPresentationForStalenessFlip()
        }
    }

    private func renderIfNeeded(_ state: IconState) {
        guard state != self.lastRendered else { return }
        self.lastRendered = state
        self.apply(state)
    }

    private func apply(_ state: IconState) {
        #if DEBUG
        self.onIconApplied?(state)
        #endif
        guard let button = self.statusItem?.button else { return }
        let image = IconRenderer.icon(for: state.rendererKey)
        if button.image !== image {
            button.image = image
        }
        self.applyTitle(state.displayText, to: button)
        button.toolTip = "SturtBar"
    }

    private func applyTitle(_ title: String?, to button: NSStatusBarButton) {
        let value = Self.buttonTitle(title, hasImage: button.image != nil)
        if button.title != value {
            button.title = value
        }
        let position: NSControl.ImagePosition = value.isEmpty ? .imageOnly : .imageLeft
        if button.imagePosition != position {
            button.imagePosition = position
        }
    }

    /// Legacy spacing rule: a leading space separates the text from the icon.
    nonisolated static func buttonTitle(_ title: String?, hasImage: Bool) -> String {
        guard let title, !title.isEmpty else { return "" }
        return hasImage ? " \(title)" : title
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = self.statusBar.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.setAccessibilityLabel("SturtBar")
        let menu = self.buildMenu()
        item.menu = menu
        self.menu = menu
        self.statusItem = item
    }

    // MARK: - Debug actions (moved from SturtBarApp)

    #if DEBUG
    /// Full store-path refresh (policy + health mapping + persistence). Inspect via Console.app.
    @objc func refreshNowForDebug() {
        let store = self.store
        Self.log.info("Debug store refresh started")
        Task {
            await store.refresh(trigger: .manual)
            Self.log.info(
                "Debug store refresh finished",
                metadata: [
                    "auth": "\(store.auth)",
                    "health": "\(store.health)",
                    "primaryUsedPercent": store.usage.map { "\($0.primary.usedPercent)" } ?? "nil",
                    "costSessionUSD": store.cost?.sessionCostUSD.map { "\($0)" } ?? "nil",
                    "isStale": "\(store.isStale)",
                ])
        }
    }

    /// Raw client fetch (bypasses store policy but NOT the single-flight actor) — logs the full
    /// snapshot field-by-field for endpoint debugging.
    @objc func fetchUsageForDebug() {
        guard let client = self.debugUsageClient else { return }
        Self.log.info("Debug usage fetch started")
        Task {
            do {
                let snapshot = try await client.fetch(interaction: .userInitiated)
                var metadata: [String: String] = [
                    "primaryUsedPercent": "\(snapshot.primary.usedPercent)",
                    "primaryWindowKind": snapshot.primaryWindowKind.rawValue,
                    "primaryResetsAt": snapshot.primary.resetsAt.map { "\($0)" } ?? "nil",
                    "secondaryUsedPercent": snapshot.secondary.map { "\($0.usedPercent)" } ?? "nil",
                    "opusUsedPercent": snapshot.opus.map { "\($0.usedPercent)" } ?? "nil",
                    "loginMethod": snapshot.loginMethod ?? "nil",
                    "updatedAt": "\(snapshot.updatedAt)",
                ]
                for extra in snapshot.extraRateWindows {
                    metadata["extra.\(extra.id)"] = "\(extra.window.usedPercent)"
                }
                if let cost = snapshot.providerCost {
                    metadata["cost"] = "\(cost.used)/\(cost.limit) \(cost.currencyCode) (\(cost.period ?? "-"))"
                }
                Self.log.info("Debug usage fetch succeeded", metadata: metadata)
            } catch {
                Self.log.error("Debug usage fetch failed: \(error.localizedDescription)")
            }
        }
    }
    #endif
}
