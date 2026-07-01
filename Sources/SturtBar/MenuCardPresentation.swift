// MenuCardPresentation.swift — store→card-model derivation, shape fingerprint, menu hosting views.
//
// Phase 4b hosts ONE persistent `NSHostingView<UsageMenuCardView>` as menu item 0. Three rules
// keep it cheap and stable (4a review-handoff contract):
//
//   1. Model re-make gating — the controller re-makes the Model only when observable
//      store/settings state changes (`withObservationTracking` around `Model.derive`) plus once
//      per menu open (fresh `now` so pace strings bake against the open moment). TimelineView
//      ticks format time-dependent strings INSIDE the card from stored dates; they never re-make
//      the Model, so the Equatable gate on `rootView` assignment stays meaningful.
//
//   2. Shape fingerprint — the card's height depends only on its SHAPE (section list, metric row
//      count, extra-usage block presence/bar) thanks to the Phase 4a fixed-height discipline.
//      The hosting view is measured at build and re-measured only when the shape changes. If the
//      shape changes while the menu is OPEN (NSMenu cannot re-measure a visible item), the
//      re-measure defers to `menuDidClose`.
//
//   3. Highlight — the card item is ENABLED (AppKit only routes mouse events into a view-backed
//      item when its `isEnabled` is true) but has no action and no target, so NSMenu never
//      highlights it and `\.menuItemHighlighted` keeps its default `false` (normal colors).
//      Legacy only plumbed the highlight environment for clickable/submenu-bearing cards; the
//      rebuild card swallows clicks inside `MenuCardItemHostingView`, so no `menu(_:willHighlight:)`
//      plumbing is needed.

import AppKit
import SturtBarCore
import SwiftUI
#if DEBUG
import Synchronization
#endif

// MARK: - MenuCardShape

/// Height-relevant structure of a card Model. Equal shapes ⇒ equal rendered heights at a fixed
/// width (fixed-height discipline), so the hosting view only re-measures when this changes.
struct MenuCardShape: Equatable {
    let sections: [UsageMenuCardView.Model.Section]
    let metricCount: Int
    let hasExtraUsage: Bool
    let extraUsageHasBar: Bool
    /// Codex block structure (decision 9): presence rides `sections`, but the ROW COUNT inside
    /// the section is data-shape-derived exactly like `metricCount`.
    let codexMetricCount: Int
    /// Rendered cost model-row counts (main block + stacked Codex block). Data-derived like
    /// `metricCount`: fewer models ⇒ fewer rows ⇒ a shorter card. A change rides the shape, so the
    /// hosting view re-measures at open and defers a mid-open change to menuDidClose. The skeleton
    /// reserves the full breakdown, so a first scan's data (≤ the reserve) never clips.
    let costRowCount: Int
    let codexCostRowCount: Int

    init(model: UsageMenuCardView.Model) {
        self.sections = model.sections
        self.metricCount = model.metrics.count
        self.hasExtraUsage = model.extraUsage != nil
        self.extraUsageHasBar = model.extraUsage?.percentUsed != nil
        self.codexMetricCount = model.codexSection?.metrics.count ?? 0
        self.costRowCount = model.costSection?.renderedRowCount ?? 0
        self.codexCostRowCount = model.codexSection?.cost?.renderedRowCount ?? 0
    }
}

// MARK: - UsageMenuCardView.Model + store derivation

extension UsageMenuCardView.Model {
    /// Builds the card model straight from app state. Every observable read in here registers as
    /// a dependency when the call happens inside `withObservationTracking` — that is the entire
    /// re-make gating mechanism (`StatusItemController.armCardPresentation`).
    @MainActor
    static func makeInput(store: UsageStore, settings: SettingsStore, now: Date) -> Input {
        var input = UsageMenuCardView.Model.Input(now: now)
        input.snapshot = store.usage
        input.cost = store.cost
        input.auth = store.auth
        input.health = store.health
        input.isRefreshing = store.isRefreshing
        input.isStale = store.isStale
        input.lastSuccessAt = store.lastSuccessAt
        input.claudeProviderEnabled = settings.claudeProviderEnabled
        input.codexProviderEnabled = settings.codexProviderEnabled
        input.codexSnapshot = store.codexUsage
        input.codexAuth = store.codexAuth
        input.codexHealth = store.codexHealth
        input.codexIsRefreshing = store.codexIsRefreshing
        input.codexIsStale = store.codexIsStale
        input.codexLastSuccessAt = store.codexLastSuccessAt
        input.codexCost = store.codexCost
        input.codexCostScanState = store.codexCostScanState
        input.costUsageEnabled = settings.costUsageEnabled
        input.costScanState = store.costScanState
        input.resetTimesShowAbsolute = settings.resetTimesShowAbsolute
        input.usageBarsShowUsed = settings.usageBarsShowUsed
        input.showModelWeeklyLimits = settings.showModelWeeklyLimits
        input.quotaWarningThresholds = Self.cardQuotaThresholds(settings: settings)
        // 5-day Mon-Fri pacing reshapes the weekly pace marker and lights the workday ticks.
        input.workDaysPerWeek = settings.weeklyWorkWeekPacingEnabled ? 5 : nil
        return input
    }

    @MainActor
    static func derive(store: UsageStore, settings: SettingsStore, now: Date) -> UsageMenuCardView.Model {
        make(self.makeInput(store: store, settings: settings, now: now))
    }

    /// Single-provider Claude card model — forces the claude-only branch regardless of the codex
    /// toggle, since each provider now renders its own card item (the card's visibility, not the
    /// model, tracks the enabled state).
    @MainActor
    static func deriveClaude(store: UsageStore, settings: SettingsStore, now: Date) -> UsageMenuCardView.Model {
        var input = Self.makeInput(store: store, settings: settings, now: now)
        input.claudeProviderEnabled = true
        input.codexProviderEnabled = false
        return Self.make(input)
    }

    /// Single-provider Codex card model — forces the codex-only branch.
    @MainActor
    static func deriveCodex(store: UsageStore, settings: SettingsStore, now: Date) -> UsageMenuCardView.Model {
        var input = Self.makeInput(store: store, settings: settings, now: now)
        input.claudeProviderEnabled = false
        input.codexProviderEnabled = true
        return Self.make(input)
    }

    /// The "no providers enabled" placeholder card (data-independent).
    @MainActor
    static func derivePlaceholder(now: Date) -> UsageMenuCardView.Model {
        var input = UsageMenuCardView.Model.Input(now: now)
        input.claudeProviderEnabled = false
        input.codexProviderEnabled = false
        return Self.make(input)
    }

    /// Marker thresholds per window. Legacy gated markers on `quotaWarningMarkersVisible`
    /// (display setting, default ON) && the per-window warning enable; the rebuild has no
    /// separate display toggle, so markers follow the per-window enables (both default ON).
    @MainActor
    static func cardQuotaThresholds(settings: SettingsStore) -> [QuotaWindow: [Int]] {
        var thresholds: [QuotaWindow: [Int]] = [:]
        for window in QuotaWindow.allCases where settings.quotaWarningWindowEnabled(window) {
            thresholds[window] = settings.quotaWarningThresholds(window)
        }
        return thresholds
    }
}

// MARK: - MenuHostingView

/// Hosting view for menu item content; `allowsVibrancy` matches the menu material (legacy
/// `MenuHostingView` behavior).
final class MenuHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool {
        true
    }
}

/// Card hosting view: also swallows clicks. The menu tracking session treats a click over an
/// item as "commit and dismiss" unless the item's view consumes the whole click itself with a
/// local event loop (Apple's slider-in-menu pattern) — so the session never sees the mouseUp.
/// The card item must be ENABLED for AppKit to route mouse events to the view at all (legacy
/// `makeMenuCardItem` parity); disabled view items dismiss without the view ever seeing the
/// click. Verified live via posted-event clicks (Phase 4b).
final class MenuCardItemHostingView<Content: View>: NSHostingView<Content> {
    #if DEBUG
    private static var clickLog: SturtBarLogger {
        SturtBarLog.logger("card-click")
    }
    #endif

    override var allowsVibrancy: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        Self.clickLog.debug("Card mouseDown received; consuming click")
        #endif
        MenuClickConsumer.consumeClick(in: self.window)
    }
}

/// Shared local mouse loop: pulls events off the app queue until the matching mouseUp arrives.
@MainActor
enum MenuClickConsumer {
    static func consumeClick(in window: NSWindow?) {
        guard let window else { return }
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return }
            if next.type == .leftMouseUp { return }
        }
    }
}

// MARK: - MenuCardRenderProbe

#if DEBUG
/// Live-verification probe (Phase 4b): counts card content evaluations so `log stream` can show
/// that an open menu ticks once per minute and a closed menu's retained hosting view renders
/// nothing. nonisolated + Mutex because SwiftUI body evaluation isn't actor-annotated here.
enum MenuCardRenderProbe {
    private static let count = Atomic<Int>(0)
    private static let log = SturtBarLog.logger("card-render")

    static var renderCount: Int {
        self.count.load(ordering: .relaxed)
    }

    static func recordRender(now: Date) {
        let value = self.count.add(1, ordering: .relaxed).newValue
        self.log.debug("Card content rendered", metadata: ["n": "\(value)", "timelineNow": "\(now)"])
    }
}
#endif
