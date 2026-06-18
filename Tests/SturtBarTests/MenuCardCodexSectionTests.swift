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
        input.costUsageEnabled = true // Codex cost is independent of the Claude gate
        let model = UsageMenuCardView.Model.make(input)

        #expect(model.providerTitle == "Codex")
        #expect(model.planText == "Pro")
        #expect(model.codexSection == nil) // single provider: no stacked section
        #expect(model.metrics.map(\.id) == ["codex-primary", "codex-secondary"])
        #expect(model.metrics.map(\.title) == ["Session", "Weekly"])
        #expect(model.metrics.first?.percent == 82) // 18 used → 82 left
        #expect(model.costSection != nil) // codex-only: cost rides the Codex gate (skeleton, no data)
        #expect(model.isCostSkeleton)
        #expect(model.subtitle.text(now: Self.now).hasPrefix("Updated"))
        #expect(model.sections == [.header, .status, .metrics, .cost])
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
    func `cost section follows each provider's own gate`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        input.cost = makeCostSnapshot(updatedAt: Self.now)
        input.costUsageEnabled = true
        let withClaude = UsageMenuCardView.Model.make(input)
        #expect(withClaude.costSection != nil)
        #expect(withClaude.sections == [.header, .status, .metrics, .cost])

        // Claude off, Codex on: the main block becomes Codex and shows Codex cost (un-gated
        // from Claude — decision 4).
        input.claudeProviderEnabled = false
        input.codexProviderEnabled = true
        input.codexSnapshot = self.codexSnapshot()
        input.codexCost = makeCodexCostSnapshot(updatedAt: Self.now)
        let codexOnly = UsageMenuCardView.Model.make(input)
        #expect(codexOnly.costSection != nil)
        #expect(codexOnly.costSection?.summaryLine.hasPrefix("Cost") == true)

        // Cost off: nothing anywhere.
        input.costUsageEnabled = false
        let costOff = UsageMenuCardView.Model.make(input)
        #expect(costOff.costSection == nil)
    }

    @Test
    func `both providers show inline cost in each block with one shared disclaimer`() {
        var input = UsageMenuCardView.Model.Input(now: Self.now)
        input.snapshot = self.claudeSnapshot()
        input.cost = makeCostSnapshot(updatedAt: Self.now)
        input.codexProviderEnabled = true
        input.codexSnapshot = self.codexSnapshot()
        input.codexCost = makeCodexCostSnapshot(updatedAt: Self.now)
        input.costUsageEnabled = true
        let model = UsageMenuCardView.Model.make(input)

        #expect(model.costSection != nil) // Claude cost in the main block
        #expect(model.codexSection?.cost != nil) // Codex cost in the stacked block
        #expect(model.sections == [.header, .status, .metrics, .codex, .cost])
    }

    @Test
    func `codex inline cost row count is part of the shape`() {
        func make(codexCost: CostUsageTokenSnapshot?, scanState: CostScanState) -> UsageMenuCardView.Model {
            var input = UsageMenuCardView.Model.Input(now: Self.now)
            input.snapshot = self.claudeSnapshot()
            input.codexProviderEnabled = true
            input.codexSnapshot = self.codexSnapshot()
            input.codexCost = codexCost
            input.codexCostScanState = scanState
            input.costUsageEnabled = true
            return UsageMenuCardView.Model.make(input)
        }

        // The skeleton reserves the full breakdown; populated data shrinks to its model count, so
        // the row count — and thus the shape — differs. The card re-measures at open and defers a
        // mid-open change to close, preserving the fixed-height contract while saving space.
        let skeleton = MenuCardShape(model: make(codexCost: nil, scanState: .scanning))
        let populated = MenuCardShape(model: make(
            codexCost: makeCodexCostSnapshot(updatedAt: Self.now),
            scanState: .idle))
        #expect(skeleton != populated)

        // Toggling cost OFF also changes the shape (the cost section disappears entirely).
        var noCostInput = UsageMenuCardView.Model.Input(now: Self.now)
        noCostInput.snapshot = self.claudeSnapshot()
        noCostInput.codexProviderEnabled = true
        noCostInput.codexSnapshot = self.codexSnapshot()
        noCostInput.costUsageEnabled = false
        let noCost = MenuCardShape(model: UsageMenuCardView.Model.make(noCostInput))
        #expect(noCost != populated)
    }

    @Test
    func `cost section row count shrinks to the model count to save space`() {
        func model(modelCount: Int) -> UsageMenuCardView.Model {
            let breakdowns = (0..<modelCount).map { index in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: "model-\(index)",
                    costUSD: Double(modelCount - index),
                    totalTokens: 100)
            }
            let cost = CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: 1,
                daily: [CostUsageDailyReport.Entry(
                    date: "2026-06-10",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: nil,
                    costUSD: 1,
                    modelsUsed: breakdowns.map(\.modelName),
                    modelBreakdowns: breakdowns)],
                updatedAt: Self.now)
            return UsageMenuCardView.Model.make(.init(snapshot: nil, cost: cost, costUsageEnabled: true, now: Self.now))
        }

        #expect(model(modelCount: 1).costSection?.renderedRowCount == 1)
        #expect(model(modelCount: 2).costSection?.renderedRowCount == 2)
        // Capped at the reserve so the card never overflows.
        #expect(model(modelCount: 5).costSection?.renderedRowCount == UsageMenuCardView.CostSection.breakdownRowSlots)
        // Fewer models ⇒ a structurally shorter card (re-measured at open).
        #expect(MenuCardShape(model: model(modelCount: 1)) != MenuCardShape(model: model(modelCount: 2)))
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
