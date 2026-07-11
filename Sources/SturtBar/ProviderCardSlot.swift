// ProviderCardSlot.swift — one hosted usage-card menu item (per provider, plus the placeholder).
//
// The menu now carries a card item per provider (Claude / Codex) so each provider's "Cost History"
// submenu can sit directly beneath it. Each slot owns its persistent hosting view + the Equatable
// re-make gate + the fixed-height re-measure (deferred while the menu is open, applied on close) —
// the exact contract the single unified card used to enforce inline.

import AppKit
import SwiftUI

@MainActor
final class ProviderCardSlot {
    /// The menu item hosting this provider's card; visibility is toggled by the controller.
    let item = NSMenuItem()
    private let hosting: MenuCardItemHostingView<UsageMenuCardView>
    private(set) var lastModel: UsageMenuCardView.Model?
    private(set) var lastShape: MenuCardShape?
    private(set) var pendingRemeasure = false

    /// Exposed for the debug driver's screenshot path.
    var hostingView: MenuCardItemHostingView<UsageMenuCardView> {
        self.hosting
    }

    #if DEBUG
    /// Fires whenever a NEW model is applied (passes the Equatable gate) — live-verification hook.
    var onApply: ((UsageMenuCardView.Model) -> Void)?
    /// Counts re-measures so tests can prove a same-shape data change does NOT re-measure.
    private(set) var remeasureCount = 0
    #endif

    /// Status-line action handler; stable across model swaps so the Equatable re-make gate still compares models only.
    private let onStatusAction: ((UsageMenuCardView.Model.StatusLine.Action) -> Void)?

    init(
        model: UsageMenuCardView.Model,
        onStatusAction: ((UsageMenuCardView.Model.StatusLine.Action) -> Void)? = nil)
    {
        self.onStatusAction = onStatusAction
        self.hosting = MenuCardItemHostingView(
            rootView: UsageMenuCardView(model: model, onStatusAction: onStatusAction))
        // .preferredContentSize keeps intrinsicContentSize synced; the explicit frame below pins
        // the initial measurement at the fixed width.
        self.hosting.sizingOptions = .preferredContentSize
        self.lastModel = model
        self.lastShape = MenuCardShape(model: model)
        self.item.title = "" // NSMenuItem() defaults to "NSMenuItem"; the view carries the content
        self.item.view = self.hosting
        self.item.isEnabled = true // enabled ⇒ events reach the view's click-consume loop
        self.remeasure()
    }

    /// Equatable-gated rootView swap + shape-fingerprint re-measure scheduling (mirrors the legacy
    /// single-card `applyCardModel`).
    func apply(_ model: UsageMenuCardView.Model, menuIsOpen: Bool) {
        guard model != self.lastModel else { return }
        self.lastModel = model
        let shape = MenuCardShape(model: model)
        let shapeChanged = shape != self.lastShape
        self.lastShape = shape
        self.hosting.rootView = UsageMenuCardView(model: model, onStatusAction: self.onStatusAction)
        #if DEBUG
        self.onApply?(model)
        #endif
        if shapeChanged {
            if menuIsOpen {
                // NSMenu measures custom views at open; defer to menuDidClose.
                self.pendingRemeasure = true
            } else {
                self.remeasure()
            }
        }
    }

    /// Applies a deferred re-measure (called from menuDidClose).
    func remeasureIfPending() {
        guard self.pendingRemeasure else { return }
        self.pendingRemeasure = false
        self.remeasure()
    }

    func remeasure() {
        guard let model = self.lastModel else { return }
        let width = UsageMenuCardLayout.defaultWidth
        let height = StatusItemController.idealHeight(
            for: UsageMenuCardView(model: model, onStatusAction: self.onStatusAction),
            width: width)
        self.hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        #if DEBUG
        self.remeasureCount += 1
        #endif
    }
}
