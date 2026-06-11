// MenuStructureTests.swift — Phase 4b menu: structure, card-model re-make gating, shape deferral.
//
// These tests build the REAL menu (NSMenu + NSHostingView card) headlessly via
// `startWithMenuForTesting` — no NSStatusBar, no window, no tracking session. AppKit menu/item
// objects are plain models until displayed, and NSHostingView construction + fittingSize layout
// works without a running app, so this stays CI-safe (the brittle parts — tracking, highlight,
// hover — are covered by the live-verification driver instead; see MenuDebugDriver).
//
// Determinism notes: the cost-usage SKELETON swaps strings while a scan is in flight, so tests
// that count model applies disable cost usage first; tests that count across a refresh seed a
// snapshot before installing the counter (with a snapshot present, the mid-refresh derive is
// model-equal and the count is exactly the data delta).

import AppKit
import Foundation
import Testing
@testable import SturtBar
@testable import SturtBarCore

@MainActor
struct MenuStructureTests {
    private func makeController(
        suiteName: String,
        scanner: CostScanner? = nil,
        fetch: @escaping ClaudeUsageClient.FetchOperation = { _, _ in makeUsageSnapshot() })
        -> (controller: StatusItemController, ts: TestStore)
    {
        let ts = makeTestStore(suiteName: suiteName, scanner: scanner, fetch: fetch)
        let controller = StatusItemController(store: ts.store, settings: ts.settings)
        return (controller, ts)
    }

    /// Pumps the MainActor queue so one-shot observation `onChange` tasks land.
    private func drainMainQueue() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }

    // MARK: - Structure

    @Test
    func `menu items have the expected order titles and shortcuts`() throws {
        let (controller, _) = self.makeController(suiteName: "sturtbar-menu-structure")
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)

        #expect(!menu.autoenablesItems)

        var expected: [(title: String, key: String)] = [
            ("", ""), // card (custom view)
            ("Cost History", ""),
            ("", ""), // separator
            ("Refresh Now", "r"),
            ("Open Claude Console", ""),
            ("Claude Status Page", ""),
            ("Settings…", ","),
            ("About SturtBar", ""),
            ("", ""), // separator
            ("Quit SturtBar", "q"),
        ]
        #if DEBUG
        expected += [
            ("", ""), // separator
            ("Refresh Now (debug log)", ""),
            ("Fetch Usage (debug)", ""),
        ]
        #endif

        #expect(menu.items.count == expected.count)
        for (index, item) in menu.items.enumerated() {
            #expect(item.title == expected[index].title, "item \(index)")
            #expect(item.keyEquivalent == expected[index].key, "item \(index)")
        }
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[8].isSeparatorItem)

        // Shortcuts are ⌘-only; Quit goes through the standard responder-chain terminate.
        #expect(menu.items[3].keyEquivalentModifierMask == .command)
        #expect(menu.items[6].keyEquivalentModifierMask == .command)
        #expect(menu.items[9].keyEquivalentModifierMask == .command)
        #expect(menu.items[9].action == #selector(NSApplication.terminate(_:)))

        // Action wiring: every native item targets the controller with its @objc selector
        // (private cross-file ⇒ string selectors instead of #selector).
        let expectedActions: [(index: Int, selector: String)] = [
            (3, "refreshNowFromMenu"),
            (4, "openClaudeConsole"),
            (5, "openClaudeStatusPage"),
            (6, "showSettingsWindow"),
            (7, "showAboutWindow"),
        ]
        for (index, selector) in expectedActions {
            #expect(menu.items[index].action == Selector(selector), "item \(index)")
            #expect(menu.items[index].target === controller, "item \(index)")
        }
        #expect(menu.items[9].target == nil) // terminate goes to NSApp via the responder chain
    }

    @Test
    func `card item hosts the persistent view and cannot be selected`() throws {
        let (controller, _) = self.makeController(suiteName: "sturtbar-menu-card-item")
        controller.startWithMenuForTesting()
        let cardItem = try #require(controller.cardItem)

        // ENABLED so AppKit routes clicks into the hosted view, whose consume-loop keeps the
        // menu open (disabled view items dismiss without the view seeing the click — verified
        // live). No action + no custom highlight drawing ⇒ the card can never be "selected"
        // and renders unhighlighted (NSMenu draws no system highlight for view items).
        #expect(cardItem.isEnabled)
        #expect(cardItem.action == nil)
        #expect(cardItem.target == nil)
        #expect(cardItem.view === controller.cardHostingView)
        #expect(controller.menu?.items.first === cardItem)
        // Fixed-width contract: the cost hint wraps, so width drift would shift heights.
        #expect(controller.cardHostingView?.frame.width == UsageMenuCardLayout.defaultWidth)
        #expect((controller.cardHostingView?.frame.height ?? 0) > 0)
    }

    @Test
    func `chart item presence tracks costUsageEnabled`() async throws {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-chart-presence")
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)

        // Default ON → present at index 1 with a lazy one-item submenu.
        let chartItem = try #require(controller.chartItem)
        #expect(menu.items[StatusItemController.chartItemIndex] === chartItem)
        #expect(chartItem.submenu?.items.count == 1)
        #expect(chartItem.submenu?.items.first?.view == nil) // not hydrated until submenu opens

        // Toggle OFF (closed menu) → removed via the observation arm.
        ts.settings.costUsageEnabled = false
        await self.drainMainQueue()
        #expect(controller.chartItem == nil)
        #expect(!menu.items.contains { $0.title == "Cost History" })
        #expect(controller.chartHostingView == nil)

        // Toggle back ON → reinserted at the same index.
        ts.settings.costUsageEnabled = true
        await self.drainMainQueue()
        #expect(controller.chartItem != nil)
        #expect(menu.items[StatusItemController.chartItemIndex] === controller.chartItem)
    }

    @Test
    func `chart removal while open defers to menuDidClose`() async throws {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-chart-defer")
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)

        controller.menuWillOpen(menu)
        ts.settings.costUsageEnabled = false
        await self.drainMainQueue()
        #expect(controller.chartItem != nil) // structure change deferred while open
        #expect(controller.pendingChartPresenceUpdate)

        controller.menuDidClose(menu)
        #expect(controller.chartItem == nil)
        #expect(!controller.pendingChartPresenceUpdate)
        await self.drainMainQueue() // drain the .menuOpen refresh task spawned by menuWillOpen
    }

    // MARK: - Card model re-make gating

    @Test
    func `store change re-makes the model once and idle time does not`() async {
        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 30, secondaryUsedPercent: 50)),
            .success(makeUsageSnapshot(primaryUsedPercent: 55, secondaryUsedPercent: 60)),
        ])
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-model-gate") { _, _ in
            try script.next()
        }
        ts.settings.costUsageEnabled = false // no cost skeleton churn while a scan flips state
        controller.startWithMenuForTesting()
        await ts.store.refresh(trigger: .manual) // seed a snapshot so mid-refresh derives are equal
        await self.drainMainQueue()

        var applied = 0
        controller.onCardModelApplied = { _ in applied += 1 }

        ts.clock.advance(by: 60)
        await ts.store.refresh(trigger: .manual)
        await self.drainMainQueue()
        #expect(applied == 1) // data changed → exactly one rootView swap

        // Wall-clock time passing without a store mutation (what a TimelineView tick is to the
        // hosting layer) must NOT re-make the model.
        ts.clock.advance(by: 120)
        await self.drainMainQueue()
        #expect(applied == 1)
    }

    @Test
    func `menu open with unchanged data does not churn the root view`() async throws {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-open-nochurn")
        ts.settings.costUsageEnabled = false
        controller.startWithMenuForTesting()
        await ts.store.refresh(trigger: .manual)
        await self.drainMainQueue()

        var applied = 0
        controller.onCardModelApplied = { _ in applied += 1 }
        let menu = try #require(controller.menu)
        controller.menuWillOpen(menu) // re-makes with a fresh now; equal model ⇒ gated
        #expect(applied == 0)
        #expect(ts.store.isMenuOpen) // store contract: set before the async refresh
        controller.menuDidClose(menu)
        #expect(!ts.store.isMenuOpen)
        await self.drainMainQueue() // drain the .menuOpen refresh task
    }

    @Test
    func `shape change while open defers re-measure to close`() async throws {
        // Placeholder card (3 reserved metric rows) → first snapshot with primary-only
        // (1 metric row): a SHAPE change landing while the menu is open.
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-shape-defer") { _, _ in
            makeUsageSnapshot(primaryUsedPercent: 30)
        }
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)
        let measuresAfterBuild = controller.cardRemeasureCount
        let heightBefore = controller.cardHostingView?.frame.height

        controller.menuWillOpen(menu)
        await ts.store.refresh(trigger: .manual) // snapshot lands mid-open
        await self.drainMainQueue()

        #expect(controller.lastCardShape?.metricCount == 1)
        #expect(controller.pendingCardRemeasure) // deferred: NSMenu can't resize a visible item
        #expect(controller.cardRemeasureCount == measuresAfterBuild)
        #expect(controller.cardHostingView?.frame.height == heightBefore)

        controller.menuDidClose(menu)
        #expect(!controller.pendingCardRemeasure)
        #expect(controller.cardRemeasureCount == measuresAfterBuild + 1)
        #expect(controller.cardHostingView?.frame.height != heightBefore)
        await self.drainMainQueue()
    }

    @Test
    func `data-only change keeps the shape and skips re-measure`() async {
        let script = FetchScript([
            .success(makeUsageSnapshot(primaryUsedPercent: 30, secondaryUsedPercent: 50)),
            .success(makeUsageSnapshot(primaryUsedPercent: 55, secondaryUsedPercent: 60)),
        ])
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-shape-stable") { _, _ in
            try script.next()
        }
        ts.settings.costUsageEnabled = false
        controller.startWithMenuForTesting()
        await ts.store.refresh(trigger: .manual)
        await self.drainMainQueue()
        let measures = controller.cardRemeasureCount
        var applied = 0
        controller.onCardModelApplied = { _ in applied += 1 }

        ts.clock.advance(by: 60)
        await ts.store.refresh(trigger: .manual)
        await self.drainMainQueue()

        #expect(applied == 1) // model re-made (data changed)…
        #expect(controller.cardRemeasureCount == measures) // …but same shape ⇒ no re-measure
    }

    // MARK: - Chart submenu hydration

    @Test
    func `chart submenu hydrates lazily on submenu open`() async throws {
        let scanner = CostScanner(scanOperation: { _, _, _ in makeCostSnapshot() })
        let (controller, ts) = self.makeController(
            suiteName: "sturtbar-menu-chart-hydrate",
            scanner: scanner)
        controller.startWithMenuForTesting()
        let submenu = try #require(controller.chartItem?.submenu)

        // No cost data yet → disabled placeholder, no hosting view.
        controller.menuWillOpen(submenu)
        #expect(controller.chartHostingView == nil)
        #expect(submenu.items.first?.isEnabled == false)
        #expect(submenu.items.first?.title == "No cost history data yet")

        // Scan lands cost data → next submenu open attaches the chart hosting view.
        await ts.store.refresh(trigger: .manual) // kicks the cost scan (bypassing its gate)
        for _ in 0..<200 where ts.store.cost == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ts.store.cost != nil)

        controller.menuWillOpen(submenu)
        let hosting = try #require(controller.chartHostingView)
        #expect(submenu.items.first?.view === hosting)
        #expect(submenu.items.first?.isEnabled == true)
        #expect(hosting.frame.width == UsageMenuCardLayout.defaultWidth)
        #expect(hosting.frame.height > 0)
        await self.drainMainQueue()
    }
}
