// ClickToLaunchOverlay.swift — invisible menu overlay that dismisses the menu then runs an action.
// Unlike the legacy ClickToCopyOverlay, a launch hands focus away, so the menu must close first.

import AppKit
import SwiftUI

struct ClickToLaunchOverlay: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> ClickToLaunchView {
        ClickToLaunchView(action: self.action)
    }

    func updateNSView(_ nsView: ClickToLaunchView, context: Context) {
        nsView.action = self.action
    }
}

final class ClickToLaunchView: NSView {
    var action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(frame: .zero)
        self.wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        _ = event
        // Dismiss first: the launched app taking focus would otherwise end the tracking session mid-action.
        self.enclosingMenuItem?.menu?.cancelTracking()
        let action = self.action
        // Let the tracking session unwind before launching, or the dismissal animation can stall.
        DispatchQueue.main.async {
            action()
        }
    }
}
