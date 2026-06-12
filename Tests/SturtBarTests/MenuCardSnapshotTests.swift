// MenuCardSnapshotTests.swift — opt-in visual snapshot of the real card for layout review.
//
// Gated behind STURTBAR_SNAPSHOT=1 because it writes PNGs to /tmp rather than asserting:
// the output is for HUMAN (or agent) eyes when iterating on card layout. Run with:
//   STURTBAR_SNAPSHOT=1 swift test --filter MenuCardSnapshotTests
// Icons load from the repo's Resources/ProviderIcons via the test seam (the test bundle has
// no resources); absent assets degrade to text-only headers exactly like the app.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SturtBar
@testable import SturtBarCore

@MainActor
struct MenuCardSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STURTBAR_SNAPSHOT"] == "1"))
    func `renders the two-provider card to a png for visual review`() throws {
        // Repo root derived from this file's compile-time path (dev-only tool).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SturtBarTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
        ProviderIcons._setResourceURLOverrideForTesting(repoRoot.appendingPathComponent("Resources"))
        defer { ProviderIcons._setResourceURLOverrideForTesting(nil) }

        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var input = UsageMenuCardView.Model.Input(now: now)
        input.snapshot = ProviderUsageSnapshot(
            primary: RateWindow(
                usedPercent: 40,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3000),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 63,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(200_000),
                resetDescription: nil),
            opus: nil,
            updatedAt: now,
            loginMethod: "Claude Max")
        input.lastSuccessAt = now
        input.codexProviderEnabled = true
        input.codexSnapshot = makeCodexSnapshot(primaryUsedPercent: 1, secondaryUsedPercent: 9, updatedAt: now)
        input.codexLastSuccessAt = now
        let model = UsageMenuCardView.Model.make(input)

        let renderer = ImageRenderer(content: UsageMenuCardView(model: model)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let out = URL(fileURLWithPath: "/tmp/sturtbar-card-snapshot.png")
        try png.write(to: out)
        print("snapshot written: \(out.path)")
    }
}
