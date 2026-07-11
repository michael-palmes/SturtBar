// IconRendererTests.swift — render cache (LRU) behavior (Phase 3b).
//
// Serialized: the renderer's MainActor-confined cache is process-global state.

import AppKit
import Testing
@testable import SturtBar

@MainActor
@Suite(.serialized)
struct IconRendererTests {
    private func key(_ primary: Int?, secondary: Int? = nil, dimmed: Bool = false) -> IconRenderer.Key {
        IconRenderer.Key(primaryBucket: primary, secondaryBucket: secondary, dimmed: dimmed)
    }

    @Test
    func `same state hits the cache and returns the identical image`() {
        IconRenderer.resetCacheForTesting()
        let first = IconRenderer.icon(for: self.key(52))
        let second = IconRenderer.icon(for: self.key(52))
        #expect(first === second)
        #expect(IconRenderer.cacheCountForTesting == 1)
    }

    @Test
    func `distinct states render distinct images`() {
        IconRenderer.resetCacheForTesting()
        let plain = IconRenderer.icon(for: self.key(52))
        let dimmed = IconRenderer.icon(for: self.key(52, dimmed: true))
        let withWeekly = IconRenderer.icon(for: self.key(52, secondary: 80))
        #expect(plain !== dimmed)
        #expect(plain !== withWeekly)
        #expect(IconRenderer.cacheCountForTesting == 3)
    }

    @Test
    func `auth badge is a distinct cache state with visibly different pixels`() {
        IconRenderer.resetCacheForTesting()
        let dimmed = IconRenderer.icon(for: self.key(52, dimmed: true))
        let badged = IconRenderer.icon(
            for: IconRenderer.Key(primaryBucket: 52, secondaryBucket: nil, dimmed: true, authBadge: true))
        #expect(dimmed !== badged)
        #expect(IconRenderer.cacheCountForTesting == 2)

        /// Samples a solid-disc pixel clear of the glyph to prove the badge landed in the bitmap.
        func alphaOnBadgeDisc(_ image: NSImage) -> CGFloat {
            guard let rep = image.representations.first as? NSBitmapImageRep else { return -1 }
            // (22, 8) top-down maps inside the disc but clear of the glyph (bottom-up centre 27,27, radius 8).
            return rep.colorAt(x: 22, y: 8)?.alphaComponent ?? -1
        }
        #expect(alphaOnBadgeDisc(badged) == 1.0)
        #expect(alphaOnBadgeDisc(dimmed) < 1.0)
    }

    @Test
    func `cache caps at 16 and evicts the least recently used`() {
        IconRenderer.resetCacheForTesting()
        let firstKey = self.key(0)
        let firstImage = IconRenderer.icon(for: firstKey)
        for bucket in 1...15 {
            _ = IconRenderer.icon(for: self.key(bucket))
        }
        #expect(IconRenderer.cacheCountForTesting == 16)

        // 17th distinct state evicts the oldest entry (bucket 0).
        _ = IconRenderer.icon(for: self.key(16))
        #expect(IconRenderer.cacheCountForTesting == 16)
        #expect(!IconRenderer.cacheOrderForTesting.contains(firstKey))

        // Re-requesting the evicted state re-renders (a fresh instance, not the old one).
        let rerendered = IconRenderer.icon(for: firstKey)
        #expect(rerendered !== firstImage)
        #expect(IconRenderer.cacheCountForTesting == 16)
    }

    @Test
    func `cache hits refresh recency so hot states survive eviction`() {
        IconRenderer.resetCacheForTesting()
        let hotKey = self.key(0)
        let hotImage = IconRenderer.icon(for: hotKey)
        for bucket in 1...15 {
            _ = IconRenderer.icon(for: self.key(bucket))
        }
        // Touch the oldest entry, then overflow: bucket 1 (now oldest) gets evicted instead.
        _ = IconRenderer.icon(for: hotKey)
        _ = IconRenderer.icon(for: self.key(16))

        #expect(IconRenderer.cacheOrderForTesting.contains(hotKey))
        #expect(!IconRenderer.cacheOrderForTesting.contains(self.key(1)))
        #expect(IconRenderer.icon(for: hotKey) === hotImage)
    }

    @Test
    func `rendered icons are menu bar templates`() {
        IconRenderer.resetCacheForTesting()
        let image = IconRenderer.icon(for: self.key(75, secondary: 30))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }
}
