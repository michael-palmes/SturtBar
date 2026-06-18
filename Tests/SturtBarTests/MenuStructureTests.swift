// MenuStructureTests.swift — the per-provider menu: structure, visibility, card re-make gating.
//
// These tests build the REAL menu (NSMenu + per-provider NSHostingView cards) headlessly via
// `startWithMenuForTesting` — no NSStatusBar, no window, no tracking session. The menu carries a
// card item per provider, each followed by that provider's Cost History submenu; all items are
// built once and toggle `isHidden` with the enabled set (no insert/remove). Provider dashboards,
// status pages, and About moved to Settings, so the action area is just Refresh / Settings / Quit.
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
    func `menu has per-provider cards, charts, placeholder, disclaimer, and focused actions`() throws {
        let (controller, _) = self.makeController(suiteName: "sturtbar-menu-structure")
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)
        #expect(!menu.autoenablesItems)

        // Order: per-provider [card, Cost History] pairs split by a divider, then placeholder,
        // disclaimer, and the focused actions.
        #expect(menu.items[0] === controller.claudeCardSlot?.item)
        #expect(menu.items[1] === controller.chartItem)
        #expect(menu.items[1].title == "Claude Cost History")
        #expect(menu.items[2] === controller.providerDividerItem)
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3] === controller.codexCardSlot?.item)
        #expect(menu.items[4] === controller.codexChartItem)
        #expect(menu.items[4].title == "Codex Cost History")
        #expect(menu.items[5] === controller.placeholderCardSlot?.item)
        #expect(menu.items[6] === controller.disclaimerItem)
        #expect(menu.items[6].attributedTitle?.string.contains("estimated") == true)
        #expect(menu.items[7].isSeparatorItem)
        #expect(menu.items[8].title == "Refresh Now")
        #expect(menu.items[8].keyEquivalent == "r")
        #expect(menu.items[8].keyEquivalentModifierMask == .command)
        #expect(menu.items[9].title == "Settings…")
        #expect(menu.items[9].keyEquivalent == ",")
        #expect(menu.items[10].isSeparatorItem)
        #expect(menu.items[11].title == "Quit SturtBar")
        #expect(menu.items[11].keyEquivalent == "q")
        #expect(menu.items[11].action == #selector(NSApplication.terminate(_:)))

        // The old provider-link / About items are gone (moved to Settings → Resources).
        #expect(!menu.items.contains { $0.title == "Open Claude Console" })
        #expect(!menu.items.contains { $0.title == "About SturtBar" })

        #if DEBUG
        #expect(menu.items.count == 15) // + separator, Refresh (debug), Fetch Usage (debug)
        #else
        #expect(menu.items.count == 12)
        #endif
    }

    // MARK: - Visibility

    @Test
    func `default visibility shows claude, hides codex and placeholder`() {
        let (controller, _) = self.makeController(suiteName: "sturtbar-menu-visibility-default")
        controller.startWithMenuForTesting()
        // Defaults: claude on, codex off (opt-in), cost on.
        #expect(controller.claudeCardSlot?.item.isHidden == false)
        #expect(controller.chartItem?.isHidden == false)
        #expect(controller.codexCardSlot?.item.isHidden == true)
        #expect(controller.codexChartItem?.isHidden == true)
        #expect(controller.placeholderCardSlot?.item.isHidden == true)
        #expect(controller.providerDividerItem?.isHidden == true) // codex off ⇒ no divider
        #expect(controller.disclaimerItem?.isHidden == false) // cost on + a provider on
    }

    @Test
    func `enabling codex reveals its card and chart`() async {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-visibility-codex")
        controller.startWithMenuForTesting()
        #expect(controller.codexCardSlot?.item.isHidden == true)
        #expect(controller.providerDividerItem?.isHidden == true) // only one provider on

        ts.settings.codexProviderEnabled = true
        await self.drainMainQueue()
        #expect(controller.codexCardSlot?.item.isHidden == false)
        #expect(controller.codexChartItem?.isHidden == false)
        #expect(controller.providerDividerItem?.isHidden == false) // both on ⇒ divider shows
        // Claude's card stays put.
        #expect(controller.claudeCardSlot?.item.isHidden == false)
    }

    @Test
    func `disabling cost hides charts and the disclaimer but keeps the cards`() async {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-visibility-cost")
        controller.startWithMenuForTesting()
        #expect(controller.chartItem?.isHidden == false)

        ts.settings.costUsageEnabled = false
        await self.drainMainQueue()
        #expect(controller.chartItem?.isHidden == true)
        #expect(controller.disclaimerItem?.isHidden == true)
        #expect(controller.claudeCardSlot?.item.isHidden == false) // the usage card stays
    }

    @Test
    func `no providers enabled shows the placeholder card`() async {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-visibility-none")
        controller.startWithMenuForTesting()

        ts.settings.claudeProviderEnabled = false
        await self.drainMainQueue()
        #expect(controller.claudeCardSlot?.item.isHidden == true)
        #expect(controller.codexCardSlot?.item.isHidden == true)
        #expect(controller.placeholderCardSlot?.item.isHidden == false)
        #expect(controller.disclaimerItem?.isHidden == true) // no provider ⇒ no cost shown
    }

    @Test
    func `visibility change while the menu is open defers to close`() async throws {
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-visibility-defer")
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)

        controller.menuWillOpen(menu)
        ts.settings.codexProviderEnabled = true
        await self.drainMainQueue()
        // Structure changes are deferred while open.
        #expect(controller.codexCardSlot?.item.isHidden == true)
        #expect(controller.pendingMenuVisibilityUpdate)

        controller.menuDidClose(menu)
        #expect(!controller.pendingMenuVisibilityUpdate)
        #expect(controller.codexCardSlot?.item.isHidden == false)
        await self.drainMainQueue() // drain the .menuOpen refresh task spawned by menuWillOpen
    }

    // MARK: - Card slot

    @Test
    func `claude card slot hosts the persistent view and cannot be selected`() throws {
        let (controller, _) = self.makeController(suiteName: "sturtbar-menu-card-slot")
        controller.startWithMenuForTesting()
        let slot = try #require(controller.claudeCardSlot)

        // ENABLED so AppKit routes clicks into the hosted view's consume-loop; no action/target so
        // NSMenu never highlights or "selects" it.
        #expect(slot.item.isEnabled)
        #expect(slot.item.action == nil)
        #expect(slot.item.target == nil)
        #expect(slot.item.view === slot.hostingView)
        #expect(controller.menu?.items.first === slot.item)
        // Fixed-width contract: width drift would shift heights.
        #expect(slot.hostingView.frame.width == UsageMenuCardLayout.defaultWidth)
        #expect(slot.hostingView.frame.height > 0)
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
        controller.claudeCardSlot?.onApply = { _ in applied += 1 }

        ts.clock.advance(by: 60)
        await ts.store.refresh(trigger: .manual)
        await self.drainMainQueue()
        #expect(applied == 1) // claude data changed → exactly one rootView swap

        // Wall-clock time passing without a store mutation must NOT re-make the model.
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
        controller.claudeCardSlot?.onApply = { _ in applied += 1 }
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
        // Build (no snapshot) → first snapshot with primary-only: a SHAPE change (metric-row count)
        // landing on the claude card while the menu is open.
        let (controller, ts) = self.makeController(suiteName: "sturtbar-menu-shape-defer") { _, _ in
            makeUsageSnapshot(primaryUsedPercent: 30)
        }
        ts.settings.costUsageEnabled = false
        controller.startWithMenuForTesting()
        let menu = try #require(controller.menu)
        let slot = try #require(controller.claudeCardSlot)
        let measuresAfterBuild = slot.remeasureCount
        let heightBefore = slot.hostingView.frame.height

        controller.menuWillOpen(menu)
        await ts.store.refresh(trigger: .manual) // snapshot lands mid-open
        await self.drainMainQueue()

        #expect(slot.lastShape?.metricCount == 1)
        #expect(slot.pendingRemeasure) // deferred: NSMenu can't resize a visible item
        #expect(slot.remeasureCount == measuresAfterBuild)
        #expect(slot.hostingView.frame.height == heightBefore)

        controller.menuDidClose(menu)
        #expect(!slot.pendingRemeasure)
        #expect(slot.remeasureCount == measuresAfterBuild + 1)
        #expect(slot.hostingView.frame.height != heightBefore)
        await self.drainMainQueue()
    }

    @Test
    func `data-only change keeps the shape and skips re-measure`() async throws {
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
        let slot = try #require(controller.claudeCardSlot)
        let measures = slot.remeasureCount
        var applied = 0
        slot.onApply = { _ in applied += 1 }

        ts.clock.advance(by: 60)
        await ts.store.refresh(trigger: .manual)
        await self.drainMainQueue()

        #expect(applied == 1) // model re-made (data changed)…
        #expect(slot.remeasureCount == measures) // …but same shape ⇒ no re-measure
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
