// MenuCardCodexSectionTests.swift — provider routing for the menu card (decision 9):
// claude-only renders exactly today's card, codex-only carries the main slots, both providers
// stack a codex section after the claude metrics, none shows the placeholder. Shape fingerprint
// changes whenever the codex section's presence or row count changes.

import Foundation
import SturtBarCore
import Testing
@testable import SturtBar

struct MenuCardCodexSectionTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func claudeSnapshot() -> ProviderUsageSnapshot {
        makeUsageSnapshot(primaryUsedPercent: 22, secondaryUsedPercent: 40, updatedAt: Self.now)
    }

    private func codexSnapshot(
        primaryUsed: Double = 18,
        secondaryUsed: Double? = 43) -> ProviderUsageSnapshot
    {
        makeCodexSnapshot(
            primaryUsedPercent: primaryUsed,
            secondaryUsedPercent: secondaryUsed,
            updatedAt: Self.now)
    }

    // MARK: - Routing

    @Test
    func `claude-only input produces today's card with no codex section`() {
        let model = UsageMenuCardView.Model.make(.init(
            snapshot: self.claudeSnapshot(),
            lastSuccessAt: Self.now.addingTimeInterval(-300),
            now: Self.now))

        #expect(model.providerTitle == "Claude")
        #expect(model.codexSection == nil)
        #expect(model.sections == [.header, .status, .metrics])
        #expect(model.metrics.map(\.id) == ["primary", "secondary"])
    }

    @Test
    func `codex-only input carries the main slots`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.claudeProviderEnabled = false
        input.codexProviderEnabled = true
        input.codexSnapshot = self.codexSnapshot()
        input.codexLastSuccessAt = Self.now.addingTimeInterval(-120)
        input.costUsageEnabled = true // must still hide: cost is claude-gated
        let model = UsageMenuCardView.Model.make(input)

        #expect(model.providerTitle == "Codex")
        #expect(model.planText == "Pro")
        #expect(model.codexSection == nil) // single provider: no stacked section
        #expect(model.metrics.map(\.id) == ["codex-primary", "codex-secondary"])
        #expect(model.metrics.map(\.title) == ["Session", "Weekly"])
        #expect(model.metrics.first?.percent == 82) // 18 used → 82 left
        #expect(model.costSection == nil)
        #expect(model.subtitle.text(now: Self.now).hasPrefix("Updated"))
        #expect(model.sections == [.header, .status, .metrics])
    }

    @Test
    func `both providers stack a codex section after the claude metrics`() throws {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        input.lastSuccessAt = Self.now.addingTimeInterval(-300)
        input.codexProviderEnabled = true
        input.codexSnapshot = self.codexSnapshot()
        input.codexLastSuccessAt = Self.now.addingTimeInterval(-120)
        input.quotaWarningThresholds = [.session: [50, 20]]
        let model = UsageMenuCardView.Model.make(input)

        #expect(model.providerTitle == "Claude")
        let codex = try #require(model.codexSection)
        #expect(codex.title == "Codex")
        #expect(codex.planText == "Pro")
        #expect(codex.metrics.map(\.id) == ["codex-primary", "codex-secondary"])
        #expect(codex.metrics.first?.warningMarkerPercents == [50, 20])
        #expect(codex.subtitle.text(now: Self.now).hasPrefix("Updated"))
        #expect(model.sections == [.header, .status, .metrics, .codex])
        // Claude's own slots are untouched by the codex section.
        #expect(model.metrics.map(\.id) == ["primary", "secondary"])
    }

    @Test
    func `cost section renders only while claude is enabled`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        input.cost = makeCostSnapshot(updatedAt: Self.now)
        input.costUsageEnabled = true
        let withClaude = UsageMenuCardView.Model.make(input)
        #expect(withClaude.costSection != nil)
        #expect(withClaude.sections == [.header, .status, .metrics, .cost])

        input.claudeProviderEnabled = false
        input.codexProviderEnabled = true
        input.codexSnapshot = self.codexSnapshot()
        let withoutClaude = UsageMenuCardView.Model.make(input)
        #expect(withoutClaude.costSection == nil)
    }

    @Test
    func `no providers enabled renders the placeholder card`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.claudeProviderEnabled = false
        let model = UsageMenuCardView.Model.make(input)

        #expect(model.providerTitle == "SturtBar")
        #expect(model.status == .noProvidersEnabled)
        #expect(!model.status.isError)
        #expect(model.status.text(now: Self.now) == "No providers enabled. Turn one on in Settings.")
        #expect(model.metrics.isEmpty)
        #expect(model.codexSection == nil)
        #expect(model.subtitle == .blank)
    }

    // MARK: - Codex placeholders + status

    @Test
    func `codex section shows a fixed session-weekly placeholder pair before data arrives`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        input.codexProviderEnabled = true
        let model = UsageMenuCardView.Model.make(input)

        let metrics = model.codexSection?.metrics ?? []
        let allPlaceholders = metrics.allSatisfy(\.isPlaceholder)
        #expect(metrics.map(\.id) == ["codex-primary", "codex-secondary"])
        #expect(allPlaceholders)
        #expect(metrics.map(\.title) == ["Session", "Weekly"])
    }

    @Test
    func `codex status lines map auth and health states`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        input.codexProviderEnabled = true

        input.codexAuth = .credentialsMissing
        var model = UsageMenuCardView.Model.make(input)
        #expect(model.codexSection?.status == .codexCredentialsMissing)
        #expect(model.codexSection?.status.isError == true)
        #expect(model.codexSection?.status.text(now: Self.now) == "No Codex sign-in found. Run `codex` to connect.")

        input.codexAuth = .signInRequired
        model = UsageMenuCardView.Model.make(input)
        #expect(model.codexSection?.status == .codexSignInRequired)
        #expect(model.codexSection?.status.isError == true)
        #expect(model.codexSection?.status.text(now: Self.now) == "Sign in again via the codex CLI.")

        input.codexAuth = .apiKeyOnlyUnsupported
        model = UsageMenuCardView.Model.make(input)
        #expect(model.codexSection?.status == .codexApiKeyUnsupported)
        #expect(model.codexSection?.status.isError == false) // informational, not actionable-red
        #expect(
            model.codexSection?.status.text(now: Self.now)
                == "API-key accounts have no usage limits to show.")

        input.codexAuth = .ok
        input.codexHealth = .degraded(until: nil)
        model = UsageMenuCardView.Model.make(input)
        #expect(model.codexSection?.status == .retrying)

        input.codexHealth = .ok
        input.codexIsStale = true
        input.codexSnapshot = self.codexSnapshot()
        model = UsageMenuCardView.Model.make(input)
        #expect(model.codexSection?.status == .stale)
    }

    // MARK: - Shape fingerprint

    @Test
    func `codex section presence and row count are part of the shape`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        let withoutCodex = MenuCardShape(model: UsageMenuCardView.Model.make(input))

        input.codexProviderEnabled = true
        input.codexSnapshot = self.codexSnapshot()
        let withCodex = MenuCardShape(model: UsageMenuCardView.Model.make(input))
        #expect(withoutCodex != withCodex)

        input.codexSnapshot = self.codexSnapshot(secondaryUsed: nil) // one row fewer
        let oneRow = MenuCardShape(model: UsageMenuCardView.Model.make(input))
        #expect(withCodex != oneRow)
    }
}
