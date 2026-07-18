// UpdateMenuPresentation.swift: pure title/enablement for the update menu item.

import SturtBarCore

enum UpdateMenuPresentation {
    struct Item: Equatable {
        let title: String
        let enabled: Bool
    }

    /// One always-visible item: "Check for Updates…" morphs to "Install Update X.Y.Z…" when an
    /// offer stands, and disables with a progress title while the lane is busy.
    static func item(phase: UpdateStore.Phase, availableVersion: SemanticVersion?) -> Item {
        switch phase {
        case .checking:
            Item(title: "Checking for Updates…", enabled: false)
        case .downloading:
            Item(title: "Downloading Update…", enabled: false)
        case .installing:
            Item(title: "Installing Update…", enabled: false)
        case .idle:
            if let availableVersion {
                Item(title: "Install Update \(availableVersion)…", enabled: true)
            } else {
                Item(title: "Check for Updates…", enabled: true)
            }
        }
    }
}
