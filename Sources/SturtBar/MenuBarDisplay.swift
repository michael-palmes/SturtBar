// MenuBarDisplay.swift — optional text next to the menu bar icon.
//
// Ported from legacy CodexBar (Phase 3b): MenuBarDisplayMode.swift, MenuBarDisplayText.swift and
// MenuBarMetricWindowResolver.swift, merged into one file and trimmed for the single-provider
// rebuild:
//   - `MenuBarDisplayMode` gains a `.hidden` default case. Legacy gated text behind the separate
//     `menuBarShowsBrandIconWithPercent` toggle (default OFF) and only ever drew text next to a
//     brand logo; the rebuild always shows the usage meter, so "no text" becomes a mode instead
//     of a second setting. `L(...)` labels → literals.
//   - `MenuBarDisplayText` is ported as-is (percent / pace-delta / both formatting).
//   - `MenuBarMetricWindowResolver` shrinks to the Claude lanes: every legacy preference order
//     collapses to "primary, else secondary" once the per-provider branches go, and the legacy
//     Claude spend-limit special case (`shouldUseClaudeSpendLimit` → synthetic extra-usage window)
//     is already folded into `snapshot.primary` by the rebuild's ClaudeUsageService
//     (`primaryWindowKind == .spendLimit`).
//   - Pace parity: legacy computed Claude pace on the same window the percent shows
//     (`paceWindow = percentWindow`) via `UsagePace.weekly`, which uses the window's own
//     duration. Same here. The legacy HistoricalUsagePace refinement stays dropped.

import Foundation
import SturtBarCore

// MARK: - MenuBarDisplayMode

/// Controls what text (if any) the menu bar shows next to the usage meter icon.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Icon only (legacy default: brand-percent text was opt-in).
    case hidden
    case percent
    case pace
    case both

    static let `default`: MenuBarDisplayMode = .hidden

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .hidden: "Hidden"
        case .percent: "Percent"
        case .pace: "Pace"
        case .both: "Both"
        }
    }

    var description: String {
        switch self {
        case .hidden: "Show the icon only"
        case .percent: "Show remaining/used percentage (e.g. 45%)"
        case .pace: "Show pace indicator (e.g. +5%)"
        case .both: "Show both percentage and pace (e.g. 45% · +5%)"
        }
    }
}

// MARK: - MenuBarDisplayText

enum MenuBarDisplayText {
    static func percentText(window: RateWindow?, showUsed: Bool) -> String? {
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, percent))
        return String(format: "%.0f%%", clamped)
    }

    static func paceText(pace: UsagePace?) -> String? {
        guard let pace else { return nil }
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        let sign = pace.deltaPercent >= 0 ? "+" : "-"
        return "\(sign)\(deltaValue)%"
    }

    static func displayText(
        mode: MenuBarDisplayMode,
        percentWindow: RateWindow?,
        pace: UsagePace? = nil,
        showUsed: Bool) -> String?
    {
        switch mode {
        case .hidden:
            return nil
        case .percent:
            return self.percentText(window: percentWindow, showUsed: showUsed)
        case .pace:
            return self.paceText(pace: pace)
        case .both:
            guard let percent = percentText(window: percentWindow, showUsed: showUsed) else { return nil }
            // Fall back to percent-only when pace is unavailable (no reset date yet).
            guard let paceText = Self.paceText(pace: pace) else { return percent }
            return "\(percent) · \(paceText)"
        }
    }
}

// MARK: - MenuBarMetricWindowResolver

enum MenuBarMetricWindowResolver {
    /// The window whose percentage the menu bar text shows (legacy `automatic` lane for Claude).
    static func percentWindow(snapshot: ClaudeUsageSnapshot?) -> RateWindow? {
        snapshot?.primary
    }

    /// Resolved display text for a snapshot. Pace is computed on the percent window (legacy
    /// Claude behavior); `showUsed` flips the percent between consumption and remaining.
    static func displayText(
        mode: MenuBarDisplayMode,
        snapshot: ClaudeUsageSnapshot?,
        showUsed: Bool = false,
        now: Date = .init()) -> String?
    {
        guard mode != .hidden else { return nil }
        let percentWindow = self.percentWindow(snapshot: snapshot)
        let pace: UsagePace? = switch mode {
        case .hidden, .percent:
            nil
        case .pace, .both:
            percentWindow.flatMap { UsagePace.weekly(window: $0, now: now) }
        }
        return MenuBarDisplayText.displayText(
            mode: mode,
            percentWindow: percentWindow,
            pace: pace,
            showUsed: showUsed)
    }
}
