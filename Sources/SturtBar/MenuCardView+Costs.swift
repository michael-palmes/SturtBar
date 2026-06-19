// MenuCardView+Costs.swift — the menu card's cost-usage section + Claude extra-usage derivation.
//
// Ported from legacy CodexBar/MenuCardView+Costs.swift (Phase 4a), trimmed to Claude: provider
// params, descriptor capability checks, Bedrock/Mistral billing-day labels, OpenRouter/Factory/
// MiniMax balance branches, and `L(...)` are gone. The legacy free-form TokenUsageSection becomes
// a slotted `CostSection` so the section's height is identical across skeleton/empty/data states.
//
// Fixed-height contract (.cost slot, present iff costUsageEnabled):
//   1 header line ("Cost (estimated)", body/medium)
//   1 today line     — data: "Today: $4.31 · 2.4M tokens"; empty: scanning/no-data placeholder
//   1 window line    — data: "Last 30 days: …"; empty: blank reserved line
//   `breakdownRowSlots` one-line model rows — top models by cost over the window, blank-padded
//   1 constant hint  — UsageFormatter.costEstimateHint (same string always ⇒ constant height)
// The scan spinner state only swaps STRINGS inside these slots, never adds or removes lines, so
// a scan finishing while the menu is open cannot change the card height.

import Foundation
import SturtBarCore
import SwiftUI

// MARK: - CostSection model

extension UsageMenuCardView {
    struct CostSection: Equatable {
        struct BreakdownRow: Identifiable, Equatable {
            let id: String
            let name: String
            let detail: String?
        }

        /// Reserved one-line model rows (blank-padded below this count, truncated above it).
        static let breakdownRowSlots = 3

        /// True while the section shows placeholders instead of data (cost == nil).
        let isSkeleton: Bool
        /// One-line cost summary: "Cost  $4.31 today · $45.12 30d" when data exists, or a
        /// scanning/no-data placeholder. Always exactly one line (fixed-height contract).
        let summaryLine: String
        /// Top models by cost across the scanned window (≤ breakdownRowSlots entries).
        let breakdown: [BreakdownRow]

        /// Rendered model-row count: the actual rows once data is present (0…breakdownRowSlots),
        /// or the full reserve while skeleton so a FIRST scan's data (always ≤ the reserve) never
        /// grows the card mid-open. Drives the card height via MenuCardShape, so fewer models ⇒ a
        /// shorter card.
        var renderedRowCount: Int {
            self.isSkeleton ? Self.breakdownRowSlots : self.breakdown.count
        }
    }
}

extension UsageMenuCardView.Model {
    /// Claude inline cost. nil iff Claude or cost usage is disabled (configuration-derived —
    /// fixed-height contract). Reads ~/.claude logs, so it rides the Claude provider gate.
    static func claudeCostSection(input: Input) -> UsageMenuCardView.CostSection? {
        guard input.claudeProviderEnabled, input.costUsageEnabled else { return nil }
        return self.makeCostSection(snapshot: input.cost, scanState: input.costScanState)
    }

    /// Codex inline cost. Gated on the Codex provider + the shared cost toggle (NOT Claude), so a
    /// Codex-only user still sees cost. Reads ~/.codex session logs.
    static func codexCostSection(input: Input) -> UsageMenuCardView.CostSection? {
        guard input.codexProviderEnabled, input.costUsageEnabled else { return nil }
        return self.makeCostSection(snapshot: input.codexCost, scanState: input.codexCostScanState)
    }

    /// Builds the compact one-line cost summary + top-model breakdown. Provider-agnostic.
    private static func makeCostSection(
        snapshot: CostUsageTokenSnapshot?,
        scanState: CostScanState) -> UsageMenuCardView.CostSection
    {
        guard let snapshot else {
            return UsageMenuCardView.CostSection(
                isSkeleton: true,
                summaryLine: scanState == .scanning ? "Scanning session logs…" : "No cost data yet",
                breakdown: [])
        }

        let sessionCost = snapshot.sessionCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
        } ?? "—"
        let monthCost = snapshot.last30DaysCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
        } ?? "—"
        let summaryLine = "Cost  \(sessionCost) today · \(monthCost) \(snapshot.historyDays)d"

        return UsageMenuCardView.CostSection(
            isSkeleton: false,
            summaryLine: summaryLine,
            breakdown: Self.costBreakdownRows(snapshot: snapshot))
    }

    /// Aggregates per-model cost/tokens across the scanned window and returns the top rows by
    /// cost (token count breaks ties), capped at `breakdownRowSlots`.
    static func costBreakdownRows(snapshot: CostUsageTokenSnapshot) -> [UsageMenuCardView.CostSection.BreakdownRow] {
        struct Totals {
            var costUSD: Double?
            var totalTokens: Int?
        }

        var totalsByModel: [String: Totals] = [:]
        for entry in snapshot.daily {
            for breakdown in entry.modelBreakdowns ?? [] {
                var totals = totalsByModel[breakdown.modelName] ?? Totals()
                if let cost = breakdown.costUSD {
                    totals.costUSD = (totals.costUSD ?? 0) + cost
                }
                if let tokens = breakdown.totalTokens {
                    totals.totalTokens = (totals.totalTokens ?? 0) + tokens
                }
                totalsByModel[breakdown.modelName] = totals
            }
        }

        return totalsByModel
            .sorted { lhs, rhs in
                let lhsCost = lhs.value.costUSD ?? -1
                let rhsCost = rhs.value.costUSD ?? -1
                if lhsCost != rhsCost { return lhsCost > rhsCost }
                let lhsTokens = lhs.value.totalTokens ?? -1
                let rhsTokens = rhs.value.totalTokens ?? -1
                if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
                return lhs.key < rhs.key
            }
            .prefix(UsageMenuCardView.CostSection.breakdownRowSlots)
            .map { modelName, totals in
                UsageMenuCardView.CostSection.BreakdownRow(
                    id: modelName,
                    name: UsageFormatter.modelDisplayName(modelName),
                    detail: UsageFormatter.modelCostDetail(
                        modelName,
                        costUSD: totals.costUSD,
                        totalTokens: totals.totalTokens,
                        currencyCode: snapshot.currencyCode))
            }
    }

    // MARK: Extra usage (snapshot.providerCost)

    /// Claude extra-usage spend (legacy `providerCostSection` Claude branch). Skipped for
    /// spend-limit primaries: there the SAME cap data already renders as the primary bar.
    static func extraUsageSection(snapshot: ProviderUsageSnapshot?) -> ExtraUsageSection? {
        guard let snapshot, snapshot.primaryWindowKind == .usage else { return nil }
        guard let cost = snapshot.providerCost else { return nil }

        if cost.limit <= 0 {
            let spend = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ExtraUsageSection(
                title: "API spend",
                percentUsed: nil,
                spendLine: "\(cost.period ?? "Last 30 days"): \(spend)",
                percentLine: nil)
        }

        let used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
        let limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
        let percentUsed = Self.clamped((cost.used / cost.limit) * 100)
        return ExtraUsageSection(
            title: "Extra usage",
            percentUsed: percentUsed,
            spendLine: "\(cost.period ?? "This month"): \(used) / \(limit)",
            percentLine: String(format: "%.0f%% used", percentUsed))
    }
}

// MARK: - Inline cost view (slot: 1 summary line + breakdownRowSlots model rows)

/// Rendered INSIDE each provider's block. Always emits exactly one summary line plus
/// `breakdownRowSlots` model rows (blank-padded), so a scan completing mid-open only swaps
/// strings — never the line count (fixed-height contract).
struct CostSectionContent: View {
    let section: UsageMenuCardView.CostSection
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.metricRowSpacing) {
            Text(self.section.summaryLine)
                .font(.footnote)
                .foregroundStyle(
                    self.section.isSkeleton
                        ? MenuHighlightStyle.secondary(self.isHighlighted)
                        : MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
            ForEach(self.section.breakdown) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if let detail = row.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }
                }
            }
            // Skeleton reserves the full breakdown block so a first scan's data (always ≤ the
            // reserve) never grows the card mid-open. Once data is present the block shrinks to the
            // actual model count to save vertical space; that row-count change rides MenuCardShape,
            // so the card re-measures at open (and defers a mid-open change to menuDidClose).
            if self.section.isSkeleton {
                ForEach(0..<UsageMenuCardView.CostSection.breakdownRowSlots, id: \.self) { _ in
                    Text(" ")
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
