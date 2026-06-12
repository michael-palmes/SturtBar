// IconRenderer.swift — pixel-grid menu bar icon rasterizer.
//
// Ported from legacy CodexBar/IconRenderer.swift (46KB → ~8KB), trimmed for the single-provider
// rebuild:
//   - KEPT: the pixel-grid two-bar usage meter (track + crisp inset stroke + straight-edge fill),
//     stale/dimmed rendering, the render-once-per-state cache.
//   - DROPPED: every provider style twist, including the Claude "crab critter" (BRAND.md hard
//     boundary #1: no provider imitation). SturtBar renders one glyph: the two-bar meter. The
//     lighthouse tower silhouette of BRAND.md §4.5 is a later dedicated icon pass.
//   - TRIMMED: ProviderStatusIndicator overlay (no status polling), makeMorphIcon + 512-entry
//     morph cache (loading animation dropped), blink/wiggle/tilt animation params, credits lanes.
//   - Layout simplification: legacy switched the bottom lane between two rect heights (8px vs the
//     credits 6px lane) depending on weekly-exhausted/credits availability; without credits the
//     rebuild always uses the 12px top + 8px bottom lanes. A missing secondary window renders a
//     dimmed empty bottom track (Claude enterprise case); an exhausted one renders an empty fill.
//
// Caching: legacy used an NSLock-guarded @unchecked Sendable store (64 entries) because renders
// could come from animation timers off-main. The rebuild renders exclusively on the MainActor
// (StatusItemController observation loop), so the cache is a plain MainActor-confined dictionary
// LRU capped at 16 — one entry per distinct quantized state, evicting least-recently-used.

import AppKit
import SturtBarCore

@MainActor
enum IconRenderer {
    // Geometry constants are nonisolated: the drawing closures passed through `renderImage` are
    // typed non-isolated even though they only ever run synchronously on the MainActor.
    // Render to an 18×18 pt template (36×36 px at 2×) to match the system menu bar size.
    private nonisolated static let outputSize = NSSize(width: 18, height: 18)
    private nonisolated static let outputScale: CGFloat = 2
    private nonisolated static let canvasPx = Int(outputSize.width * outputScale)

    // MARK: - Inputs

    /// Quantized render inputs == cache key. Whole-point buckets (sub-point usage moves never
    /// re-render: at 30px bar width a whole point is already below pixel resolution).
    struct Key: Hashable {
        /// Remaining percent of the primary window, 0...100; nil = no data (empty track).
        var primaryBucket: Int?
        /// Remaining percent of the secondary/weekly window; nil = window absent (dimmed track).
        var secondaryBucket: Int?
        /// Dimmed presentation: stale data or broken auth (the controller folds those states).
        var dimmed: Bool
    }

    // MARK: - Pixel grid

    private struct PixelGrid {
        let scale: CGFloat

        func pt(_ px: Int) -> CGFloat {
            CGFloat(px) / self.scale
        }

        func rect(x: Int, y: Int, w: Int, h: Int) -> CGRect {
            CGRect(x: self.pt(x), y: self.pt(y), width: self.pt(w), height: self.pt(h))
        }
    }

    private nonisolated static let grid = PixelGrid(scale: outputScale)

    private struct RectPx {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        var midXPx: Int {
            self.x + self.w / 2
        }

        func rect() -> CGRect {
            IconRenderer.grid.rect(x: self.x, y: self.y, w: self.w, h: self.h)
        }
    }

    // MARK: - LRU cache (MainActor-confined)

    private static var cache: [Key: NSImage] = [:]
    private static var order: [Key] = []
    static let cacheLimit = 16

    private static func cachedIcon(for key: Key) -> NSImage? {
        guard let image = self.cache[key] else { return nil }
        if let idx = self.order.firstIndex(of: key) {
            self.order.remove(at: idx)
            self.order.append(key)
        }
        return image
    }

    private static func storeIcon(_ image: NSImage, for key: Key) {
        self.cache[key] = image
        self.order.removeAll { $0 == key }
        self.order.append(key)
        while self.order.count > self.cacheLimit {
            let oldest = self.order.removeFirst()
            self.cache.removeValue(forKey: oldest)
        }
    }

    #if DEBUG
    static var cacheCountForTesting: Int {
        self.cache.count
    }

    static var cacheOrderForTesting: [Key] {
        self.order
    }

    static func resetCacheForTesting() {
        self.cache.removeAll()
        self.order.removeAll()
    }
    #endif

    // MARK: - Entry point

    static func icon(for key: Key) -> NSImage {
        if let cached = self.cachedIcon(for: key) {
            return cached
        }
        let signpostID = Signposts.iconRender.makeSignpostID()
        let state = Signposts.iconRender.beginInterval("iconRender", id: signpostID)
        defer { Signposts.iconRender.endInterval("iconRender", state) }

        let image = self.render(key: key)
        self.storeIcon(image, for: key)
        return image
    }

    // MARK: - Drawing

    private static func render(key: Key) -> NSImage {
        self.renderImage {
            // Monochrome template icon; states read through alpha + shape only.
            let baseFill = NSColor.labelColor
            let dimmed = key.dimmed
            let trackFillAlpha: CGFloat = dimmed ? 0.18 : 0.28
            let trackStrokeAlpha: CGFloat = dimmed ? 0.28 : 0.44
            let fillColor = baseFill.withAlphaComponent(dimmed ? 0.55 : 1.0)

            let barWidthPx = 30 // 15 pt at 2×, uses the slot better without touching edges.
            let barXPx = (self.canvasPx - barWidthPx) / 2
            let topRectPx = RectPx(x: barXPx, y: 19, w: barWidthPx, h: 12)
            let bottomRectPx = RectPx(x: barXPx, y: 5, w: barWidthPx, h: 8)

            func drawBar(
                rectPx: RectPx,
                remaining: Double?,
                alpha: CGFloat = 1.0)
            {
                let rect = rectPx.rect()
                let cornerRadiusPx = rectPx.h / 2

                let trackPath = NSBezierPath(
                    roundedRect: rect,
                    xRadius: self.grid.pt(cornerRadiusPx),
                    yRadius: self.grid.pt(cornerRadiusPx))
                baseFill.withAlphaComponent(trackFillAlpha * alpha).setFill()
                trackPath.fill()

                // Crisp outline: stroke an inset path so the stroke stays within pixel bounds.
                let strokeWidthPx = 2 // 1 pt == 2 px at 2×
                let insetPx = strokeWidthPx / 2
                let strokeRect = self.grid.rect(
                    x: rectPx.x + insetPx,
                    y: rectPx.y + insetPx,
                    w: max(0, rectPx.w - insetPx * 2),
                    h: max(0, rectPx.h - insetPx * 2))
                let strokePath = NSBezierPath(
                    roundedRect: strokeRect,
                    xRadius: self.grid.pt(max(0, cornerRadiusPx - insetPx)),
                    yRadius: self.grid.pt(max(0, cornerRadiusPx - insetPx)))
                strokePath.lineWidth = CGFloat(strokeWidthPx) / self.outputScale
                baseFill.withAlphaComponent(trackStrokeAlpha * alpha).setStroke()
                strokePath.stroke()

                // Fill: clip to the bar and paint a left-to-right rect so the progress edge is straight.
                if let remaining {
                    let clamped = max(0, min(remaining / 100, 1))
                    let fillWidthPx = max(0, min(rectPx.w, Int((CGFloat(rectPx.w) * CGFloat(clamped)).rounded())))
                    if fillWidthPx > 0 {
                        NSGraphicsContext.current?.cgContext.saveGState()
                        trackPath.addClip()
                        fillColor.withAlphaComponent(alpha).setFill()
                        NSBezierPath(
                            rect: self.grid.rect(
                                x: rectPx.x,
                                y: rectPx.y,
                                w: fillWidthPx,
                                h: rectPx.h)).fill()
                        NSGraphicsContext.current?.cgContext.restoreGState()
                    }
                }
            }

            // Top = primary window; bottom = secondary/weekly. A missing secondary dims the
            // bottom track to read as N/A (single-window plans have no weekly window).
            drawBar(
                rectPx: topRectPx,
                remaining: key.primaryBucket.map(Double.init))
            if let secondary = key.secondaryBucket {
                drawBar(rectPx: bottomRectPx, remaining: Double(secondary))
            } else {
                drawBar(rectPx: bottomRectPx, remaining: nil, alpha: 0.45)
            }
        }
    }

    // MARK: - Bitmap plumbing (ported as-is)

    private static func withScaledContext(_ draw: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            draw()
            return
        }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .none
        draw()
        ctx.restoreGState()
    }

    private static func renderImage(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: Self.outputSize)

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.outputSize.width * Self.outputScale),
            pixelsHigh: Int(Self.outputSize.height * Self.outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = Self.outputSize // points
            image.addRepresentation(rep)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                Self.withScaledContext(draw)
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Fallback to legacy focus if the bitmap rep fails for any reason.
            image.lockFocus()
            Self.withScaledContext(draw)
            image.unlockFocus()
        }

        image.isTemplate = true
        return image
    }
}
