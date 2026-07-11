// StatusItemController+Menu.swift — the full status-item menu (Phase 4b).
//
// Structure (statusItem.menu — synchronous native open, no popUp tricks):
//   0  hosted UsageMenuCardView (persistent NSHostingView, disabled item — never highlighted)
//   1  "Cost History" → lazy chart submenu (present iff settings.costUsageEnabled; Swift Charts
//      first-frame cost is confined to the submenu's first menuWillOpen)
//   —  separator
//      Refresh Now ⌘R · Settings… ⌘, · About SturtBar
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
    // MARK: - Menu construction

    /// Builds the full menu, including the persistent card hosting view. Called once per
    /// controller start; afterwards only the chart item presence mutates the structure.
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Manual enablement: card stays disabled, action items stay enabled without validation.
        menu.autoenablesItems = false
        menu.delegate = self

        let now = Date()
        // Per-provider usage cards, each immediately followed by that provider's Cost History
        // submenu, then the no-providers placeholder and a single estimate disclaimer. All built
        // once; visibility toggles with the enabled set (applyMenuVisibility) so the menu structure
        // never mutates. Cards are ENABLED so AppKit routes mouse events into the hosted view's
        // click-consume loop (disabled view items dismiss without the view seeing the click).
        let onStatusAction: (UsageMenuCardView.Model.StatusLine.Action) -> Void = { [weak self] action in
            self?.handleCardStatusAction(action)
        }
        let claudeCard = ProviderCardSlot(
            model: UsageMenuCardView.Model.deriveClaude(
                store: self.store, settings: self.settings, now: now),
            onStatusAction: onStatusAction)
        self.claudeCardSlot = claudeCard
        menu.addItem(claudeCard.item)

        let claudeChart = self.makeChartItem(title: "Claude Cost History")
        self.chartItem = claudeChart
        menu.addItem(claudeChart)

        // Divider between the two provider sections — shown only when both are enabled.
        let providerDivider = NSMenuItem.separator()
        self.providerDividerItem = providerDivider
        menu.addItem(providerDivider)

        let codexCard = ProviderCardSlot(
            model: UsageMenuCardView.Model.deriveCodex(
                store: self.store, settings: self.settings, now: now),
            onStatusAction: onStatusAction)
        self.codexCardSlot = codexCard
        menu.addItem(codexCard.item)

        let codexChart = self.makeChartItem(title: "Codex Cost History")
        self.codexChartItem = codexChart
        menu.addItem(codexChart)

        let placeholderCard = ProviderCardSlot(
            model: UsageMenuCardView.Model.derivePlaceholder(now: now))
        self.placeholderCardSlot = placeholderCard
        menu.addItem(placeholderCard.item)

        let disclaimer = Self.makeDisclaimerItem()
        self.disclaimerItem = disclaimer
        menu.addItem(disclaimer)

        menu.addItem(.separator())

        let refresh = NSMenuItem(
            title: "Refresh Now",
            action: #selector(self.refreshNowFromMenu),
            keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = .command
        refresh.target = self
        refresh.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh")
        menu.addItem(refresh)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(self.showSettingsWindow),
            keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: "About SturtBar",
            action: #selector(self.showAboutWindow),
            keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

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

        self.applyMenuVisibility()
        return menu
    }

    /// The single "estimated" disclaimer line shown above Refresh when cost is on for any provider
    /// (the full caveat lives in Settings → Cost). Hosted as a FIXED-WIDTH custom view at the card
    /// width, not a native text item: a native item inherits the menu's image-column inset (forced
    /// by the system About/Quit icons) plus margins, which lays this one long line out ~21pt wider
    /// than the 320pt cards. NSMenu then sizes to that widest item, padding every card short on the
    /// right. A view pinned to the card width keeps the menu (and the bars) flush.
    private static func makeDisclaimerItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let width = UsageMenuCardLayout.defaultWidth
        let hosting = MenuHostingView(rootView: CostDisclaimerMenuView())
        hosting.sizingOptions = .preferredContentSize
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: Self.idealHeight(for: CostDisclaimerMenuView(), width: width)))
        item.view = hosting
        return item
    }

    private func makeChartItem(title: String) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        submenu.delegate = self
        // Single placeholder item; hydrated with the chart hosting view on submenu open.
        let content = NSMenuItem()
        content.isEnabled = false
        submenu.addItem(content)

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    // MARK: - Card model pipeline (re-make gating)

    /// One-shot Observation arm: any store/settings mutation the per-provider models depend on
    /// re-derives them exactly once (same coalescing pattern as the icon loop) and reconciles
    /// item visibility (which reads the provider/cost toggles). Each `ProviderCardSlot` owns its
    /// Equatable re-make gate + deferred re-measure.
    func armCardPresentation() {
        guard self.isStarted, self.menu != nil else { return }
        let now = Date()
        let models = withObservationTracking {
            (
                claude: UsageMenuCardView.Model.deriveClaude(store: self.store, settings: self.settings, now: now),
                codex: UsageMenuCardView.Model.deriveCodex(store: self.store, settings: self.settings, now: now))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.armCardPresentation()
            }
        }
        self.claudeCardSlot?.apply(models.claude, menuIsOpen: self.menuIsOpen)
        self.codexCardSlot?.apply(models.codex, menuIsOpen: self.menuIsOpen)
        self.reconcileMenuVisibility()
    }

    /// Non-arming re-derive for the wall-clock staleness flip (no observable mutation occurs;
    /// the live arm from `armCardPresentation` remains valid).
    func refreshCardPresentationForStalenessFlip() {
        guard self.menu != nil else { return }
        let now = Date()
        self.claudeCardSlot?.apply(
            UsageMenuCardView.Model.deriveClaude(store: self.store, settings: self.settings, now: now),
            menuIsOpen: self.menuIsOpen)
        self.codexCardSlot?.apply(
            UsageMenuCardView.Model.deriveCodex(store: self.store, settings: self.settings, now: now),
            menuIsOpen: self.menuIsOpen)
        self.reconcileMenuVisibility()
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

    // MARK: - Menu item visibility (provider + cost toggles)

    /// Desired hidden-state for each toggle-driven item, given the enabled set. Each provider's
    /// card + Cost History track that provider; the placeholder shows only when neither is on; the
    /// disclaimer shows when cost is on for any enabled provider.
    private func desiredItemVisibility() -> [(item: NSMenuItem?, hidden: Bool)] {
        let claude = self.settings.claudeProviderEnabled
        let codex = self.settings.codexProviderEnabled
        let cost = self.settings.costUsageEnabled
        return [
            (self.claudeCardSlot?.item, !claude),
            (self.chartItem, !(claude && cost)),
            (self.providerDividerItem, !(claude && codex)),
            (self.codexCardSlot?.item, !codex),
            (self.codexChartItem, !(codex && cost)),
            (self.placeholderCardSlot?.item, claude || codex),
            (self.disclaimerItem, !(cost && (claude || codex))),
        ]
    }

    func applyMenuVisibility() {
        for entry in self.desiredItemVisibility() {
            entry.item?.isHidden = entry.hidden
        }
    }

    /// Reconciles item visibility with the enabled set; deferred to menuDidClose while the menu is
    /// open (NSMenu can't restructure a visible menu). No-op when nothing changed.
    func reconcileMenuVisibility() {
        guard self.menu != nil else { return }
        let changed = self.desiredItemVisibility().contains { $0.item?.isHidden != $0.hidden }
        guard changed else { return }
        if self.menuIsOpen {
            self.pendingMenuVisibilityUpdate = true
            return
        }
        self.applyMenuVisibility()
    }

    // MARK: - Chart submenu hydration (lazy)

    /// Attaches/updates the chart hosting view on submenu open. The first hydration pays the
    /// Swift Charts first-frame cost here — never on the root menu open path.
    func hydrateChartSubmenu(_ submenu: NSMenu) {
        guard let item = submenu.items.first else { return }
        // Route by which provider's submenu opened (decision 7: separate chart per provider).
        let isCodex = self.codexChartItem?.submenu === submenu
        let snapshot = isCodex ? self.store.codexCost : self.store.cost
        let width = UsageMenuCardLayout.defaultWidth
        if let snapshot, !snapshot.daily.isEmpty {
            let chart = CostHistoryChartMenuView(snapshot: snapshot, width: width)
            let hosting: MenuHostingView<CostHistoryChartMenuView>
            if let existing = isCodex ? self.codexChartHostingView : self.chartHostingView {
                existing.rootView = chart
                hosting = existing
            } else {
                let created = MenuHostingView(rootView: chart)
                created.sizingOptions = .preferredContentSize
                if isCodex {
                    self.codexChartHostingView = created
                } else {
                    self.chartHostingView = created
                }
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
            } else if let codexChartSubmenu = self.codexChartItem?.submenu,
                      ObjectIdentifier(codexChartSubmenu) == menuID
            {
                self.hydrateChartSubmenu(codexChartSubmenu)
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
        // Re-derive each provider card once per open with a fresh `now` (pace strings bake from
        // it). Pure compute; `menuIsOpen` is still false, so a shape change re-measures immediately
        // — we are before display, which is still a "closed menu" for NSMenu measurement purposes.
        let now = Date()
        self.claudeCardSlot?.apply(
            UsageMenuCardView.Model.deriveClaude(store: self.store, settings: self.settings, now: now),
            menuIsOpen: false)
        self.codexCardSlot?.apply(
            UsageMenuCardView.Model.deriveCodex(store: self.store, settings: self.settings, now: now),
            menuIsOpen: false)
        self.reconcileMenuVisibility()
        self.menuIsOpen = true
        let store = self.store
        Task { await store.refresh(trigger: .menuOpen) }
    }

    private func rootMenuDidClose() {
        self.menuIsOpen = false
        self.store.isMenuOpen = false
        self.claudeCardSlot?.remeasureIfPending()
        self.codexCardSlot?.remeasureIfPending()
        self.placeholderCardSlot?.remeasureIfPending()
        if self.pendingMenuVisibilityUpdate {
            self.pendingMenuVisibilityUpdate = false
            self.applyMenuVisibility()
        }
        if let state = self.menuOpenSignpostState {
            Signposts.menu.endInterval("menuOpen", state)
            self.menuOpenSignpostState = nil
        }
        Self.log.debug("Menu did close")
    }

    // MARK: - Actions

    /// Routes clicks on the cards' actionable status lines; the overlay has already dismissed the menu.
    func handleCardStatusAction(_ action: UsageMenuCardView.Model.StatusLine.Action) {
        switch action {
        case .claudeSignIn:
            if self.signInLauncher.launch(.claude) {
                // Login completes in the terminal; recheck so the card and badge clear on their own.
                self.store.beginPostSignInRecheck()
            }
        case .claudeKeychainRetry:
            if self.settings.claudeKeychainPromptsEnabled {
                // Same as ⌘R: user-initiated rights clear the cooldown and let the consent prompt appear.
                let store = self.store
                Task { await store.refresh(trigger: .manual) }
            } else {
                // Opt-in (prompts off): Continue enables the setting, whose callback refreshes. Register consent first
                // so the pre-alert does not repeat.
                guard self.keychainOptInPresenter() == .proceed else { return }
                KeychainPromptCoordinator.registerRecentConsent()
                self.settings.claudeKeychainPromptsEnabled = true
            }
        }
    }

    @objc private func refreshNowFromMenu() {
        let store = self.store
        Task { await store.refresh(trigger: .manual) }
    }

    @objc private func showSettingsWindow() {
        self.windows?.showSettings()
    }

    @objc private func showAboutWindow() {
        self.windows?.showAbout()
    }
}

// MARK: - Cost disclaimer view

/// One-line cost disclaimer, hosted at the card width so it can never drive the menu wider than the
/// cards (see `makeDisclaimerItem`). The text lays out at ~239pt, well within the 284pt content box,
/// so it stays on one line; the leading inset matches the cards' horizontal padding.
private struct CostDisclaimerMenuView: View {
    var body: some View {
        Text("Cost is estimated from local logs at API rates.")
            .font(.system(size: NSFont.smallSystemFontSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
            .padding(.vertical, 3)
            .frame(width: UsageMenuCardLayout.defaultWidth, alignment: .leading)
    }
}
