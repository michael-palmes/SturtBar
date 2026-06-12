// UsageProviders.swift — the app-side provider vocabulary.
//
// Deliberately small: an identity enum and the menu-bar source picker. There is no provider
// protocol or descriptor registry — each provider's service/client stays concrete and the few
// places that branch on provider do so explicitly (n=2; revisit only if a third provider lands).

import Foundation
import SturtBarCore

/// Identity of a usage provider. `allCases` order is the canonical display and tiebreak order.
enum UsageProviderKind: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// One-letter menu bar text prefix, shown only when 2+ providers are enabled ("X 81%").
    var menuBarPrefix: String {
        switch self {
        case .claude: "C"
        case .codex: "X"
        }
    }
}

/// Which provider drives the menu bar icon AND text. One setting governs both so they can never
/// disagree. `.auto` = most-constrained wins (highest primary used%).
enum MenuBarProviderSource: String, CaseIterable, Identifiable {
    case auto
    case claude
    case codex

    static let `default`: MenuBarProviderSource = .auto

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .auto: "Auto (most used)"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The forced provider, nil for `.auto`.
    var forcedProvider: UsageProviderKind? {
        switch self {
        case .auto: nil
        case .claude: .claude
        case .codex: .codex
        }
    }
}

// MARK: - MenuBarProviderResolver

/// Picks which provider the menu bar icon AND text show (decisions 10+11). Pure and total:
/// forced source iff enabled; otherwise most-constrained (highest primary used%) among enabled
/// providers with data; tie → canonical order; no data → first enabled; nothing enabled → nil.
enum MenuBarProviderResolver {
    static func winner(
        source: MenuBarProviderSource,
        claudeEnabled: Bool,
        claude: ProviderUsageSnapshot?,
        codexEnabled: Bool,
        codex: ProviderUsageSnapshot?) -> UsageProviderKind?
    {
        let candidates: [(provider: UsageProviderKind, snapshot: ProviderUsageSnapshot?)] = [
            (.claude, claude),
            (.codex, codex),
        ].filter { provider, _ in
            switch provider {
            case .claude: claudeEnabled
            case .codex: codexEnabled
            }
        }
        guard !candidates.isEmpty else { return nil }

        // A forced-but-disabled source falls through to auto rather than blanking the icon.
        if let forced = source.forcedProvider,
           candidates.contains(where: { $0.provider == forced })
        {
            return forced
        }

        // Most-constrained wins; max(by:) returns the LAST max for equal elements, so iterate
        // explicitly to keep ties on canonical (first-listed) order.
        var winner: (provider: UsageProviderKind, usedPercent: Double)?
        for candidate in candidates {
            guard let usedPercent = candidate.snapshot?.primary.usedPercent else { continue }
            if let current = winner, usedPercent <= current.usedPercent { continue }
            winner = (candidate.provider, usedPercent)
        }
        return winner?.provider ?? candidates[0].provider
    }

    /// One-letter provider prefix ("X 81%"), applied only when 2+ providers are enabled —
    /// single-provider text stays byte-identical to the pre-codex format.
    static func prefixed(
        _ text: String?,
        provider: UsageProviderKind,
        multiProvider: Bool) -> String?
    {
        guard let text else { return nil }
        guard multiProvider else { return text }
        return "\(provider.menuBarPrefix) \(text)"
    }
}
