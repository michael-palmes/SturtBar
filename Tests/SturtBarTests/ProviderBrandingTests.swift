// ProviderBrandingTests.swift — per-provider bar tints + the optional header icon loader.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SturtBar
@testable import SturtBarCore

struct ProviderBrandingTests {
    @Test
    func `tints map claude to terracotta and codex to indigo`() {
        #expect(ProviderBranding.tint(.claude) == Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255))
        // Codex indigo #3E46F6.
        #expect(ProviderBranding.tint(.codex) == Color(red: 0x3E / 255, green: 0x46 / 255, blue: 0xF6 / 255))
    }
}

struct MenuCardMainProviderTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test
    func `main slots carry the owning provider for tinting`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = makeUsageSnapshot(updatedAt: Self.now)
        #expect(UsageMenuCardView.Model.make(input).mainProvider == .claude)

        input.codexProviderEnabled = true
        input.codexSnapshot = makeCodexSnapshot(updatedAt: Self.now)
        let both = UsageMenuCardView.Model.make(input)
        #expect(both.mainProvider == .claude) // codex rows tint via the codex section itself

        input.claudeProviderEnabled = false
        #expect(UsageMenuCardView.Model.make(input).mainProvider == .codex)

        input.codexProviderEnabled = false
        #expect(UsageMenuCardView.Model.make(input).mainProvider == nil)
    }
}

struct ProviderIconsTests {
    /// 1×1 transparent PNG.
    private static let pngBytes = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABXvMqOgAAAABJRU5ErkJggg==")!

    @Test
    func `loads provider icons from a ProviderIcons resource folder`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturtbar-provider-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let iconsDir = directory.appendingPathComponent("ProviderIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
        try Self.pngBytes.write(to: iconsDir.appendingPathComponent("codex.png"))

        #expect(ProviderIcons.loadImage(for: .codex, resourceURL: directory) != nil)
        #expect(ProviderIcons.loadImage(for: .claude, resourceURL: directory) == nil) // file absent
    }

    @Test
    func `missing resource root degrades to nil`() {
        #expect(ProviderIcons.loadImage(for: .claude, resourceURL: nil) == nil)
    }
}
