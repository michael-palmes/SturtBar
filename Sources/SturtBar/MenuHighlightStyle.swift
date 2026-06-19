// MenuHighlightStyle.swift — menu-card colors that adapt to NSMenu item highlighting.
//
// Ported as-is from legacy CodexBar/MenuHighlightStyle.swift (Phase 4a), plus the single Claude
// brand color (legacy ClaudeProviderDescriptor branding terracotta) that replaces the per-provider
// `ProviderDescriptorRegistry` color lookup.

import SwiftUI

extension EnvironmentValues {
    /// Set by the NSMenu hosting layer (Phase 4b) when the menu item is highlighted.
    @Entry var menuItemHighlighted: Bool = false
}

enum MenuHighlightStyle {
    static let selectionText = Color(nsColor: .selectedMenuItemTextColor)
    static let normalPrimaryText = Color(nsColor: .controlTextColor)
    static let normalSecondaryText = Color(nsColor: .secondaryLabelColor)

    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalPrimaryText
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalSecondaryText
    }

    static func error(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : Color(nsColor: .systemRed)
    }

    static func progressTrack(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText.opacity(0.22) : Color(nsColor: .tertiaryLabelColor).opacity(0.22)
    }

    static func progressTint(_ highlighted: Bool, fallback: Color) -> Color {
        highlighted ? self.selectionText : fallback
    }

    static func selectionBackground(_ highlighted: Bool) -> Color {
        highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }
}

/// Per-provider branding (replaces the legacy registry colour lookup at n=2).
enum ProviderBranding {
    /// Claude terracotta — legacy ProviderColor(204, 124, 94).
    static let claude = Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
    /// Codex indigo — #3E46F6 (product call; deliberately not OpenAI's brand palette).
    static let codex = Color(red: 0x3E / 255, green: 0x46 / 255, blue: 0xF6 / 255)

    static func tint(_ provider: UsageProviderKind) -> Color {
        switch provider {
        case .claude: self.claude
        case .codex: self.codex
        }
    }
}
