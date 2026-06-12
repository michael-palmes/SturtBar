// UsageProviders.swift — the app-side provider vocabulary.
//
// Deliberately small: an identity enum and the menu-bar source picker. There is no provider
// protocol or descriptor registry — each provider's service/client stays concrete and the few
// places that branch on provider do so explicitly (n=2; revisit only if a third provider lands).

import Foundation

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
