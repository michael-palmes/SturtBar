// MenuCardQuotaWarningMarkers.swift — quota-warning + workday tick marks on the usage bars.
//
// Ported from legacy CodexBar/MenuCardQuotaWarningMarkers.swift (Phase 4a). Rebuild changes:
//   - The Codex `CodexConsumerProjection.RateLane` bridge is gone (Claude-only lanes).
//   - `QuotaWarningWindow` → the rebuild's `QuotaWindow` (QuotaWarnings.swift).
//   - `showUsed` stays a parameter on the pure helpers (ports the legacy tests verbatim) but the
//     card always calls with `false` — the rebuild displays remaining-style bars only.
//   - Workday markers are kept (math + tests) even though the rebuild has no workdays setting
//     yet; `Input.workDaysPerWeek` stays nil until a settings phase adds one.

import Foundation

extension UsageMenuCardView.Model {
    static func warningMarkerPercents(thresholds: [Int]?, showUsed: Bool) -> [Double] {
        guard let thresholds, !thresholds.isEmpty else { return [] }
        return QuotaWarningThresholds.active(thresholds)
            .map { showUsed ? 100 - Double($0) : Double($0) }
            .filter { $0 > 0 && $0 < 100 }
    }

    /// Merges quota warning markers with optional work-day boundary markers.
    /// Preserves original warning-marker ordering when workdayMarkers is empty,
    /// sorts the combined set when workday markers are present.
    static func mergedMarkerPercents(
        warningMarkers: [Double],
        workdayMarkers: [Double]) -> [Double]
    {
        let combined = warningMarkers + workdayMarkers
        return workdayMarkers.isEmpty ? combined : combined.sorted()
    }

    /// Combines quota warning markers with optional work-day boundary markers
    /// into a single sorted array. Workday markers are only applied when
    /// includeWorkdayMarkers is true and windowMinutes == 10080.
    static func markerPercents(
        thresholds: [Int]?,
        showUsed: Bool,
        workDays: Int?,
        windowMinutes: Int?,
        includeWorkdayMarkers: Bool) -> [Double]
    {
        let warningMarkers = Self.warningMarkerPercents(thresholds: thresholds, showUsed: showUsed)
        let workdayMarkers = includeWorkdayMarkers
            ? workDayMarkerPercents(workDays: workDays, windowMinutes: windowMinutes)
            : []
        return Self.mergedMarkerPercents(warningMarkers: warningMarkers, workdayMarkers: workdayMarkers)
    }

    static func weeklyMarkerPercents(input: Input, windowMinutes: Int?) -> [Double] {
        UsageMenuCardView.Model.markerPercents(
            thresholds: input.quotaWarningThresholds[.weekly],
            showUsed: false,
            workDays: input.workDaysPerWeek,
            windowMinutes: windowMinutes,
            includeWorkdayMarkers: true)
    }
}

/// Returns boundary percentages for work day markers on a weekly progress bar.
/// Only valid when windowMinutes == 10080 (standard 7-day week).
/// nil workDays means feature is disabled.
func workDayMarkerPercents(workDays: Int?, windowMinutes: Int?) -> [Double] {
    guard workDays != nil, windowMinutes == 10080 else { return [] }
    guard let wd = workDays, wd >= 2, wd <= 7 else { return [] }
    return (1..<wd).map { Double($0) * 100.0 / Double(wd) }
}
