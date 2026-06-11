// ClickToCopyOverlay.swift — invisible overlay that copies a string to the pasteboard on click.
//
// Ported from legacy CodexBar/ClickToCopyOverlay.swift (Phase 4a). Used by the menu card's
// status strip so a truncated error detail can still be copied in full.
//
// Phase 4b change: after copying, the click is consumed with a local mouse loop. NSMenu's
// tracking session treats a mouseUp over any item as "commit and dismiss" — without the consume,
// copying would also close the menu (see MenuClickConsumer).

import AppKit
import SwiftUI

struct ClickToCopyOverlay: NSViewRepresentable {
    let copyText: String

    func makeNSView(context: Context) -> ClickToCopyView {
        ClickToCopyView(copyText: self.copyText)
    }

    func updateNSView(_ nsView: ClickToCopyView, context: Context) {
        nsView.copyText = self.copyText
    }
}

final class ClickToCopyView: NSView {
    var copyText: String

    init(copyText: String) {
        self.copyText = copyText
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

    override func mouseDown(with event: NSEvent) {
        _ = event
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(self.copyText, forType: .string)
        // Keep the menu open: swallow the rest of the click so the menu tracking session never
        // sees the mouseUp (which would dismiss the menu).
        MenuClickConsumer.consumeClick(in: self.window)
    }
}
