// ProviderIcons.swift — optional provider logo glyphs for headers and settings rows.
//
// Icons live in the app bundle at `Contents/Resources/ProviderIcons/<provider>.svg` (or `.png`;
// svg wins when both exist — vector stays crisp at every scale), copied by Scripts/package_app.sh
// from the repo's `Resources/ProviderIcons/`. Loading is best-effort with a per-provider cache:
// a missing file simply renders text-only rows, so the app never depends on the assets existing
// (tests and bare `swift run` have no bundle resources).
//
// Light/dark: assets are MONOCHROME stencils (solid black on transparent). `ProviderIconView`
// renders them as templates tinted with the label colour, so one asset adapts to light mode,
// dark mode, AND the menu-item highlight — the same mechanism as system menu glyphs.

import AppKit
import SwiftUI

@MainActor
enum ProviderIcons {
    /// Cache nil results too — a missing asset must not re-stat the bundle on every render.
    private static var cache: [UsageProviderKind: NSImage?] = [:]

    #if DEBUG
    /// Snapshot-test seam: points lookups at a repo checkout instead of Bundle.main (test
    /// bundles carry no resources). Clears the cache so the override takes effect immediately.
    static func _setResourceURLOverrideForTesting(_ url: URL?) {
        self.resourceURLOverride = url
        self.cache = [:]
    }

    private static var resourceURLOverride: URL?
    #endif

    static func image(for provider: UsageProviderKind) -> NSImage? {
        if let cached = self.cache[provider] {
            return cached
        }
        var root = Bundle.main.resourceURL
        #if DEBUG
        if let resourceURLOverride = self.resourceURLOverride {
            root = resourceURLOverride
        }
        #endif
        let loaded = self.loadImage(for: provider, resourceURL: root)
        self.cache[provider] = loaded
        return loaded
    }

    /// Uncached load with an injectable root (test seam). Pure file IO — no shared state, so it
    /// stays callable off the MainActor.
    nonisolated static func loadImage(for provider: UsageProviderKind, resourceURL: URL?) -> NSImage? {
        guard let resourceURL else { return nil }
        let iconsDir = resourceURL.appendingPathComponent("ProviderIcons", isDirectory: true)
        for ext in ["svg", "png"] {
            let url = iconsDir.appendingPathComponent("\(provider.rawValue).\(ext)", isDirectory: false)
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return nil
    }
}

/// 16×16pt provider glyph rendered as a TEMPLATE: the asset's alpha is the stencil and the fill
/// is the label colour, so monochrome icons track light/dark appearance and the menu highlight
/// for free. Renders nothing when the asset is absent, so row layouts are identical with or
/// without the optional icon files (only width shifts, never height).
struct ProviderIconView: View {
    let provider: UsageProviderKind
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        if let image = ProviderIcons.image(for: self.provider) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
        }
    }
}
