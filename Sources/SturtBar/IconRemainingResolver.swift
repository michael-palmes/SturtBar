// IconRemainingResolver.swift — resolves which window percentages the menu bar icon shows.
//
// Ported from legacy CodexBar/IconRemainingResolver.swift, trimmed to the Claude lane: the legacy
// per-style branches (perplexity ordered windows, antigravity tertiary packing, the Codex consumer
// projection) are provider-specific and dropped. What remains is the legacy default branch:
// primary → top bar, secondary → bottom bar.
//
// Spend-limit note: legacy mapped Claude spend-limit accounts to `primary == nil` + providerCost,
// leaving the icon empty. The rebuild's `ClaudeUsageService` folds the spend window INTO `primary`
// (kind `.spendLimit`), so those accounts get a meaningful top bar (percent of monthly spend
// remaining) for free — matching what legacy's menu-bar TEXT showed for them (`automatic` →
// extra-usage window).

import SturtBarCore

enum IconRemainingResolver {
    static func resolvedRemaining(
        snapshot: ClaudeUsageSnapshot?)
        -> (primary: Double?, secondary: Double?)
    {
        (
            primary: snapshot?.primary.remainingPercent,
            secondary: snapshot?.secondary?.remainingPercent)
    }
}
