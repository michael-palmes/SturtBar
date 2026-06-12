// ProviderIcons.swift — optional provider logo glyphs for headers and settings rows.
//
// Icons live in the app bundle at `Contents/Resources/ProviderIcons/<provider>.png` (copied by
// Scripts/package_app.sh from the repo's `Resources/ProviderIcons/`). Loading is best-effort
// with a per-provider cache: a missing file simply renders text-only rows, so the app never
// depends on the assets existing (tests and bare `swift run` have no bundle resources).

import AppKit
import SwiftUI

@MainActor
enum ProviderIcons {
    /// Cache nil results too — a missing asset must not re-stat the bundle on every render.
    private static var cache: [UsageProviderKind: NSImage?] = [:]

    static func image(for provider: UsageProviderKind) -> NSImage? {
        if let cached = self.cache[provider] {
            return cached
        }
        let loaded = self.loadImage(for: provider, resourceURL: Bundle.main.resourceURL)
        self.cache[provider] = loaded
        return loaded
    }

    /// Uncached load with an injectable root (test seam). Pure file IO — no shared state, so it
    /// stays callable off the MainActor.
    nonisolated static func loadImage(for provider: UsageProviderKind, resourceURL: URL?) -> NSImage? {
        guard let resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("ProviderIcons", isDirectory: true)
            .appendingPathComponent("\(provider.rawValue).png", isDirectory: false)
        return NSImage(contentsOf: url)
    }
}

/// 16×16pt provider glyph; renders nothing when the asset is absent, so row layouts are
/// identical with or without the optional icon files (only width shifts, never height).
struct ProviderIconView: View {
    let provider: UsageProviderKind

    var body: some View {
        if let image = ProviderIcons.image(for: self.provider) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }
}
