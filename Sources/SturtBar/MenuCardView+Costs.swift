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
        /// Today-slot text: totals line when data exists, scanning/no-data placeholder otherwise.
        let sessionLine: String
        /// Window-totals slot text; " " (reserved blank) in skeleton state.
        let monthLine: String
        /// Top models by cost across the scanned window (≤ breakdownRowSlots entries).
        let breakdown: [BreakdownRow]
        /// Constant estimate disclaimer (identical for every state).
        let hint: String
    }
}

extension UsageMenuCardView.Model {
    /// nil iff cost usage is disabled — presence is configuration-derived (fixed-height contract).
    static func costSection(input: Input) -> UsageMenuCardView.CostSection? {
        guard input.costUsageEnabled else { return nil }
        guard let snapshot = input.cost else {
            return UsageMenuCardView.CostSection(
                isSkeleton: true,
                sessionLine: input.costScanState == .scanning ? "Scanning session logs…" : "No cost data yet",
                monthLine: " ",
                breakdown: [],
                hint: UsageFormatter.costEstimateHint)
        }

        let sessionCost = snapshot.sessionCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
        } ?? "—"
        let sessionTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let sessionLine = if let sessionTokens {
            "Today: \(sessionCost) · \(sessionTokens) tokens"
        } else {
            "Today: \(sessionCost)"
        }

        let monthCost = snapshot.last30DaysCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
        } ?? "—"
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let monthTokens = monthTokensValue.map { UsageFormatter.tokenCountString($0) }
        let windowLabel = snapshot.historyLabel ?? Self.costHistoryWindowLabel(days: snapshot.historyDays)
        let monthLine = if let monthTokens {
            "\(windowLabel): \(monthCost) · \(monthTokens) tokens"
        } else {
            "\(windowLabel): \(monthCost)"
        }

        return UsageMenuCardView.CostSection(
            isSkeleton: false,
            sessionLine: sessionLine,
            monthLine: monthLine,
            breakdown: Self.costBreakdownRows(snapshot: snapshot),
            hint: UsageFormatter.costEstimateHint)
    }

    static func costHistoryWindowLabel(days: Int) -> String {
        days == 1 ? "Today" : "Last \(days) days"
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

// MARK: - Cost section view (slot: header + 2 lines + breakdownRowSlots rows + constant hint)

struct CostSectionContent: View {
    let section: UsageMenuCardView.CostSection
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cost (estimated)")
                .font(.body)
                .fontWeight(.medium)
            Text(self.section.sessionLine)
                .font(.footnote)
                .foregroundStyle(
                    self.section.isSkeleton
                        ? MenuHighlightStyle.secondary(self.isHighlighted)
                        : MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
            Text(self.section.monthLine)
                .font(.footnote)
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
            // Blank padding keeps the breakdown block at exactly breakdownRowSlots lines.
            ForEach(
                0..<max(UsageMenuCardView.CostSection.breakdownRowSlots - self.section.breakdown.count, 0),
                id: \.self)
            { _ in
                Text(" ")
                    .font(.footnote)
                    .lineLimit(1)
            }
            // Constant disclaimer: same string in every state, so its wrapped height is constant
            // for a given card width.
            Text(self.section.hint)
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
