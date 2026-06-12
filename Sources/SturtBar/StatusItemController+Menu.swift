// StatusItemController+Menu.swift — the full status-item menu (Phase 4b).
//
// Structure (statusItem.menu — synchronous native open, no popUp tricks):
//   0  hosted UsageMenuCardView (persistent NSHostingView, disabled item — never highlighted)
//   1  "Cost History" → lazy chart submenu (present iff settings.costUsageEnabled; Swift Charts
//      first-frame cost is confined to the submenu's first menuWillOpen)
//   —  separator
//      Refresh Now ⌘R · Open Claude Console · Claude Status Page · Settings… ⌘, · About SturtBar
//   —  separator
//      Quit SturtBar ⌘Q
//   —  separator + debug items (DEBUG builds only)
//
// Open sequence (UsageStore's documented menu contract):
//   menuWillOpen  → store.isMenuOpen = true → re-make card model once with a fresh `now`
//                   (pure compute; no I/O before display) → async refresh(trigger: .menuOpen)
//   menuDidClose  → store.isMenuOpen = false → apply deferred re-measure / chart presence.
//
// Model re-make gating + shape-deferral mechanics live in MenuCardPresentation.swift's header.

import AppKit
import Observation
import SturtBarCore
import SwiftUI

extension StatusItemController {
    /// Index the chart item occupies when present (right after the card).
    static let chartItemIndex = 1

    // MARK: - Menu construction

    /// Builds the full menu, including the persistent card hosting view. Called once per
    /// controller start; afterwards only the chart item presence mutates the structure.
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Manual enablement: card stays disabled, action items stay enabled without validation.
        menu.autoenablesItems = false
        menu.delegate = self

        // Item 0: the usage card. ENABLED so AppKit routes mouse events into the hosted view
        // (whose consume-loop keeps the menu open on clicks — disabled view items dismiss
        // without the view ever seeing the click; legacy parity). No action and no custom
        // highlight drawing: NSMenu draws no system highlight for custom-view items, so the
        // hosted SwiftUI tree renders with `\.menuItemHighlighted == false` throughout
        // (static panel; see MenuCardPresentation.swift).
        let model = UsageMenuCardView.Model.derive(store: self.store, settings: self.settings, now: Date())
        self.lastCardModel = model
        self.lastCardShape = MenuCardShape(model: model)
        let hosting = MenuCardItemHostingView(rootView: UsageMenuCardView(model: model))
        // .preferredContentSize keeps intrinsicContentSize synced to the card's ideal size; the
        // explicit frame below pins the initial measurement (fixed width — the cost hint wraps,
        // so a drifting width would shift heights).
        hosting.sizingOptions = .preferredContentSize
        self.cardHostingView = hosting
        self.remeasureCard()

        let cardItem = NSMenuItem()
        cardItem.title = "" // NSMenuItem() defaults to "NSMenuItem"; the view carries the content
        cardItem.view = hosting
        cardItem.isEnabled = true // see above: enabled ⇒ events reach the view's consume-loop
        self.cardItem = cardItem
        menu.addItem(cardItem)

        if self.settings.costUsageEnabled {
            let chartItem = self.makeChartItem()
            self.chartItem = chartItem
            menu.addItem(chartItem)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: "Refresh Now",
            action: #selector(self.refreshNowFromMenu),
            keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = .command
        refresh.target = self
        menu.addItem(refresh)

        let console = NSMenuItem(
            title: "Open Claude Console",
            action: #selector(self.openClaudeConsole),
            keyEquivalent: "")
        console.target = self
        self.claudeConsoleItem = console
        menu.addItem(console)

        let statusPage = NSMenuItem(
            title: "Claude Status Page",
            action: #selector(self.openClaudeStatusPage),
            keyEquivalent: "")
        statusPage.target = self
        self.claudeStatusPageItem = statusPage
        menu.addItem(statusPage)

        let codexUsage = NSMenuItem(
            title: "Open Codex Usage",
            action: #selector(self.openCodexUsage),
            keyEquivalent: "")
        codexUsage.target = self
        self.codexUsageItem = codexUsage
        menu.addItem(codexUsage)

        let openAIStatus = NSMenuItem(
            title: "OpenAI Status Page",
            action: #selector(self.openOpenAIStatusPage),
            keyEquivalent: "")
        openAIStatus.target = self
        self.codexStatusPageItem = openAIStatus
        menu.addItem(openAIStatus)

        self.applyProviderLinkVisibility()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(self.showSettingsWindow),
            keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        let about = NSMenuItem(
            title: "About SturtBar",
            action: #selector(self.showAboutWindow),
            keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit SturtBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)

        #if DEBUG
        menu.addItem(.separator())
        // ⌘R moved to the production Refresh Now; the debug variant keeps its detailed logging.
        let debugRefresh = NSMenuItem(
            title: "Refresh Now (debug log)",
            action: #selector(self.refreshNowForDebug),
            keyEquivalent: "")
        debugRefresh.target = self
        menu.addItem(debugRefresh)

        let fetchUsage = NSMenuItem(
            title: "Fetch Usage (debug)",
            action: #selector(self.fetchUsageForDebug),
            keyEquivalent: "")
        fetchUsage.target = self
        menu.addItem(fetchUsage)
        #endif

        return menu
    }

    private func makeChartItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Cost History")
        submenu.autoenablesItems = false
        submenu.delegate = self
        // Single placeholder item; hydrated with the chart hosting view on submenu open.
        let content = NSMenuItem()
        content.isEnabled = false
        submenu.addItem(content)

        let item = NSMenuItem(title: "Cost History", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    // MARK: - Card model pipeline (re-make gating)

    /// One-shot Observation arm around `Model.derive`: any store/settings mutation the model
    /// depends on re-derives it exactly once (same coalescing pattern as the icon loop). Also
    /// reconciles chart-item presence, since `derive` reads `settings.costUsageEnabled`.
    func armCardPresentation() {
        guard self.isStarted, self.menu != nil else { return }
        let model = withObservationTracking {
            UsageMenuCardView.Model.derive(store: self.store, settings: self.settings, now: Date())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.armCardPresentation()
            }
        }
        self.applyCardModel(model)
        self.updateChartItemPresence()
        self.updateProviderLinkItems()
    }

    /// Non-arming re-derive for the wall-clock staleness flip (no observable mutation occurs;
    /// the live arm from `armCardPresentation` remains valid).
    func refreshCardPresentationForStalenessFlip() {
        guard self.menu != nil else { return }
        self.applyCardModel(
            UsageMenuCardView.Model.derive(store: self.store, settings: self.settings, now: Date()))
        self.updateChartItemPresence()
        self.updateProviderLinkItems()
    }

    /// Equatable-gated rootView swap + shape-fingerprint re-measure scheduling.
    func applyCardModel(_ model: UsageMenuCardView.Model) {
        guard model != self.lastCardModel else { return }
        self.lastCardModel = model
        let shape = MenuCardShape(model: model)
        let shapeChanged = shape != self.lastCardShape
        self.lastCardShape = shape

        guard let hosting = self.cardHostingView else { return }
        hosting.rootView = UsageMenuCardView(model: model)
        Self.log.debug(
            "Card model applied",
            metadata: ["shapeChanged": "\(shapeChanged)", "menuOpen": "\(self.menuIsOpen)"])
        #if DEBUG
        self.onCardModelApplied?(model)
        #endif

        if shapeChanged {
            if self.menuIsOpen {
                // NSMenu measures custom views at open; defer to menuDidClose.
                self.pendingCardRemeasure = true
            } else {
                self.remeasureCard()
            }
        }
    }

    /// Measures the card at its fixed width and pins the hosting view frame. The +1 descender
    /// safety mirrors legacy menu-card measurement.
    func remeasureCard() {
        guard let hosting = self.cardHostingView, let model = self.lastCardModel else { return }
        let width = UsageMenuCardLayout.defaultWidth
        let height = Self.idealHeight(for: UsageMenuCardView(model: model), width: width)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        #if DEBUG
        self.cardRemeasureCount += 1
        #endif
        Self.log.debug("Card re-measured", metadata: ["height": "\(height)"])
    }

    /// Sizing pass via a throwaway NSHostingController: `NSHostingView.fittingSize` /
    /// `intrinsicContentSize` report nothing until the view first attaches to a window, but
    /// `sizeThatFits(in:)` measures the content deterministically everywhere (menus measure
    /// BEFORE display, and tests run headless). Only runs at build and on shape changes.
    static func idealHeight(for view: some View, width: CGFloat) -> CGFloat {
        let sizing = NSHostingController(rootView: view)
        let measured = sizing.sizeThatFits(in: NSSize(width: width, height: 10000))
        return max(1, ceil(measured.height) + 1)
    }

    // MARK: - Chart item presence (cost toggle)

    /// Reconciles the per-provider link items' visibility with the enabled set; deferred to
    /// menuDidClose while the menu is open (same conservative rule as structure changes).
    func updateProviderLinkItems() {
        guard self.menu != nil else { return }
        let wantsUpdate = self.claudeConsoleItem?.isHidden == self.settings.claudeProviderEnabled
            || self.codexUsageItem?.isHidden == self.settings.codexProviderEnabled
        guard wantsUpdate else { return }
        if self.menuIsOpen {
            self.pendingProviderLinksUpdate = true
            return
        }
        self.applyProviderLinkVisibility()
    }

    func applyProviderLinkVisibility() {
        let claudeHidden = !self.settings.claudeProviderEnabled
        let codexHidden = !self.settings.codexProviderEnabled
        self.claudeConsoleItem?.isHidden = claudeHidden
        self.claudeStatusPageItem?.isHidden = claudeHidden
        self.codexUsageItem?.isHidden = codexHidden
        self.codexStatusPageItem?.isHidden = codexHidden
    }

    /// Inserts/removes the "Cost History" item to track `settings.costUsageEnabled` (and the
    /// Claude provider gate — cost reads ~/.claude logs). Menu structure changes are closed-menu
    /// operations — while open they defer to menuDidClose.
    func updateChartItemPresence() {
        guard let menu = self.menu else { return }
        let wantsChart = self.settings.costUsageEnabled && self.settings.claudeProviderEnabled
        guard wantsChart != (self.chartItem != nil) else { return }
        if self.menuIsOpen {
            self.pendingChartPresenceUpdate = true
            return
        }
        if wantsChart {
            let item = self.makeChartItem()
            self.chartItem = item
            menu.insertItem(item, at: Self.chartItemIndex)
        } else if let item = self.chartItem {
            menu.removeItem(item)
            self.chartItem = nil
            self.chartHostingView = nil // release Swift Charts resources with the item
        }
    }

    // MARK: - Chart submenu hydration (lazy)

    /// Attaches/updates the chart hosting view on submenu open. The first hydration pays the
    /// Swift Charts first-frame cost here — never on the root menu open path.
    func hydrateChartSubmenu(_ submenu: NSMenu) {
        guard let item = submenu.items.first else { return }
        let width = UsageMenuCardLayout.defaultWidth
        if let snapshot = self.store.cost, !snapshot.daily.isEmpty {
            let chart = CostHistoryChartMenuView(snapshot: snapshot, width: width)
            let hosting: MenuHostingView<CostHistoryChartMenuView>
            if let existing = self.chartHostingView {
                existing.rootView = chart
                hosting = existing
            } else {
                let created = MenuHostingView(rootView: chart)
                created.sizingOptions = .preferredContentSize
                self.chartHostingView = created
                hosting = created
            }
            let height = Self.idealHeight(for: chart, width: width)
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            item.view = hosting
            item.title = ""
            item.isEnabled = true
        } else {
            item.view = nil
            item.title = "No cost history data yet"
            item.isEnabled = false
        }
    }

    // MARK: - NSMenuDelegate

    // The NSMenu parameter is non-Sendable and must not cross into the assumeIsolated closure;
    // ObjectIdentifier carries the identity across instead.

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        MainActor.assumeIsolated {
            if let root = self.menu, ObjectIdentifier(root) == menuID {
                self.rootMenuWillOpen()
            } else if let chartSubmenu = self.chartItem?.submenu, ObjectIdentifier(chartSubmenu) == menuID {
                self.hydrateChartSubmenu(chartSubmenu)
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        MainActor.assumeIsolated {
            // Submenu closes need no bookkeeping; only the root tracks open state.
            guard let root = self.menu, ObjectIdentifier(root) == menuID else { return }
            self.rootMenuDidClose()
        }
    }

    private func rootMenuWillOpen() {
        self.menuOpenSignpostState = Signposts.menu.beginInterval("menuOpen")
        Self.log.debug("Menu will open")
        // Store contract order: isMenuOpen = true BEFORE refresh(trigger: .menuOpen), so any
        // observer reading isMenuOpen inside a refresh-triggered redraw already sees true.
        self.store.isMenuOpen = true
        // Build the model once per open with a fresh `now` (pace strings bake from it). This is
        // pure compute; `menuIsOpen` is still false, so a shape change re-measures immediately —
        // we are before display, which is still a "closed menu" for NSMenu measurement purposes.
        self.applyCardModel(
            UsageMenuCardView.Model.derive(store: self.store, settings: self.settings, now: Date()))
        self.menuIsOpen = true
        let store = self.store
        Task { await store.refresh(trigger: .menuOpen) }
    }

    private func rootMenuDidClose() {
        self.menuIsOpen = false
        self.store.isMenuOpen = false
        if self.pendingCardRemeasure {
            self.pendingCardRemeasure = false
            self.remeasureCard()
        }
        if self.pendingChartPresenceUpdate {
            self.pendingChartPresenceUpdate = false
            self.updateChartItemPresence()
        }
        if self.pendingProviderLinksUpdate {
            self.pendingProviderLinksUpdate = false
            self.applyProviderLinkVisibility()
        }
        if let state = self.menuOpenSignpostState {
            Signposts.menu.endInterval("menuOpen", state)
            self.menuOpenSignpostState = nil
        }
        Self.log.debug("Menu did close")
    }

    // MARK: - Actions

    @objc private func refreshNowFromMenu() {
        let store = self.store
        Task { await store.refresh(trigger: .manual) }
    }

    @objc private func openClaudeConsole() {
        self.open(urlString: ClaudeLinks.dashboardURL)
    }

    @objc private func openClaudeStatusPage() {
        self.open(urlString: ClaudeLinks.statusPageURL)
    }

    @objc private func openCodexUsage() {
        self.open(urlString: CodexLinks.usageDashboardURL)
    }

    @objc private func openOpenAIStatusPage() {
        self.open(urlString: CodexLinks.statusPageURL)
    }

    @objc private func showSettingsWindow() {
        self.windows?.showSettings()
    }

    @objc private func showAboutWindow() {
        self.windows?.showAbout()
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
